# Data Model: Employee History

**Feature**: 006-employee-history | **Date**: 2026-01-10

## Overview

This document defines the data model for the Employee History feature, including database schema changes, Flutter models, and state transitions.

---

## Database Schema

### Existing Tables (No Changes)

#### employee_profiles
Already exists from Spec 002. **One field addition needed**.

```sql
-- Current columns (no changes)
id UUID PRIMARY KEY
email TEXT NOT NULL UNIQUE
full_name TEXT
employee_id TEXT
status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'suspended'))
privacy_consent_at TIMESTAMPTZ
created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()

-- NEW: Add role field
role TEXT NOT NULL DEFAULT 'employee' CHECK (role IN ('employee', 'manager', 'admin'))
```

#### shifts
Already exists from Spec 003. No changes needed.

```sql
id UUID PRIMARY KEY
employee_id UUID NOT NULL REFERENCES employee_profiles(id)
request_id UUID UNIQUE
status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'completed'))
clocked_in_at TIMESTAMPTZ NOT NULL
clock_in_location JSONB
clock_in_accuracy DECIMAL(8, 2)
clocked_out_at TIMESTAMPTZ
clock_out_location JSONB
clock_out_accuracy DECIMAL(8, 2)
created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
```

#### gps_points
Already exists from Spec 003. No changes needed.

```sql
id UUID PRIMARY KEY
client_id UUID NOT NULL UNIQUE
shift_id UUID NOT NULL REFERENCES shifts(id)
employee_id UUID NOT NULL REFERENCES employee_profiles(id)
latitude DECIMAL(10, 8) NOT NULL CHECK (latitude >= -90.0 AND latitude <= 90.0)
longitude DECIMAL(11, 8) NOT NULL CHECK (longitude >= -180.0 AND longitude <= 180.0)
accuracy DECIMAL(8, 2)
captured_at TIMESTAMPTZ NOT NULL
received_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
device_id TEXT
created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
```

---

### New Table: employee_supervisors

Junction table defining manager-employee supervision relationships.

```sql
CREATE TABLE employee_supervisors (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    manager_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
    supervision_type TEXT NOT NULL DEFAULT 'direct'
        CHECK (supervision_type IN ('direct', 'matrix', 'temporary')),
    effective_from DATE NOT NULL DEFAULT CURRENT_DATE,
    effective_to DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT no_self_supervision CHECK (manager_id != employee_id),
    CONSTRAINT valid_date_range CHECK (effective_to IS NULL OR effective_to > effective_from),
    CONSTRAINT unique_active_supervision UNIQUE (manager_id, employee_id, effective_from)
);

COMMENT ON TABLE employee_supervisors IS 'Manager-employee supervision relationships with effective dates';
COMMENT ON COLUMN employee_supervisors.supervision_type IS 'Type of supervision: direct (primary), matrix (secondary), temporary';
COMMENT ON COLUMN employee_supervisors.effective_to IS 'NULL indicates currently active supervision';

-- Indexes
CREATE INDEX idx_employee_supervisors_manager ON employee_supervisors(manager_id);
CREATE INDEX idx_employee_supervisors_employee ON employee_supervisors(employee_id);
CREATE INDEX idx_employee_supervisors_active ON employee_supervisors(manager_id)
    WHERE effective_to IS NULL;
```

**Field Descriptions**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | UUID | Yes | Primary key |
| manager_id | UUID | Yes | FK to employee_profiles (the manager) |
| employee_id | UUID | Yes | FK to employee_profiles (the supervised employee) |
| supervision_type | TEXT | Yes | Type: 'direct', 'matrix', 'temporary' |
| effective_from | DATE | Yes | When supervision started |
| effective_to | DATE | No | When supervision ended (NULL = active) |
| created_at | TIMESTAMPTZ | Yes | Record creation timestamp |

---

## New RLS Policies

### Update Existing Policies

```sql
-- Drop existing restrictive policy on employee_profiles
DROP POLICY IF EXISTS "Users can view own profile" ON employee_profiles;

-- Replace with policy that allows managers to view supervised employees
CREATE POLICY "Users can view own or supervised profiles"
ON employee_profiles FOR SELECT TO authenticated
USING (
    (SELECT auth.uid()) = id
    OR EXISTS (
        SELECT 1 FROM employee_supervisors es
        WHERE es.manager_id = (SELECT auth.uid())
        AND es.employee_id = employee_profiles.id
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
    )
);

-- Drop existing shift view policy
DROP POLICY IF EXISTS "Users can view own shifts" ON shifts;

-- Replace with policy allowing manager access
CREATE POLICY "Users can view own or supervised employee shifts"
ON shifts FOR SELECT TO authenticated
USING (
    (SELECT auth.uid()) = employee_id
    OR EXISTS (
        SELECT 1 FROM employee_supervisors es
        WHERE es.manager_id = (SELECT auth.uid())
        AND es.employee_id = shifts.employee_id
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
    )
);

-- Drop existing GPS points view policy
DROP POLICY IF EXISTS "Users can view own GPS points" ON gps_points;

-- Replace with policy allowing manager access
CREATE POLICY "Users can view own or supervised employee GPS points"
ON gps_points FOR SELECT TO authenticated
USING (
    (SELECT auth.uid()) = employee_id
    OR EXISTS (
        SELECT 1 FROM employee_supervisors es
        WHERE es.manager_id = (SELECT auth.uid())
        AND es.employee_id = gps_points.employee_id
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
    )
);
```

### New Policies for employee_supervisors

```sql
ALTER TABLE employee_supervisors ENABLE ROW LEVEL SECURITY;

-- Users can view supervision relationships they are part of (as manager or employee)
CREATE POLICY "Users can view own supervision relationships"
ON employee_supervisors FOR SELECT TO authenticated
USING (
    (SELECT auth.uid()) = manager_id
    OR (SELECT auth.uid()) = employee_id
);

-- Only admins can insert/update/delete supervision relationships
-- (This would typically be done via admin API or database admin)
CREATE POLICY "Only admins can manage supervision relationships"
ON employee_supervisors FOR ALL TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM employee_profiles ep
        WHERE ep.id = (SELECT auth.uid())
        AND ep.role = 'admin'
    )
);
```

---

## Flutter Models

### UserRole (New)

```dart
// lib/shared/models/user_role.dart

/// User role enumeration for access control
enum UserRole {
  employee('employee'),
  manager('manager'),
  admin('admin');

  final String value;
  const UserRole(this.value);

  static UserRole fromString(String value) {
    return UserRole.values.firstWhere(
      (e) => e.value == value,
      orElse: () => UserRole.employee,
    );
  }

  /// Whether this role has manager capabilities
  bool get isManager => this == UserRole.manager || this == UserRole.admin;

  /// Whether this role has admin capabilities
  bool get isAdmin => this == UserRole.admin;
}
```

### EmployeeProfile (Modified)

```dart
// lib/features/auth/models/employee_profile.dart
// ADD: role field

@immutable
class EmployeeProfile {
  final String id;
  final String email;
  final String? fullName;
  final String? employeeId;
  final EmployeeStatus status;
  final UserRole role;  // NEW FIELD
  final DateTime? privacyConsentAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  const EmployeeProfile({
    required this.id,
    required this.email,
    required this.status,
    required this.role,  // NEW
    required this.createdAt,
    required this.updatedAt,
    this.fullName,
    this.employeeId,
    this.privacyConsentAt,
  });

  factory EmployeeProfile.fromJson(Map<String, dynamic> json) {
    return EmployeeProfile(
      id: json['id'] as String,
      email: json['email'] as String,
      fullName: json['full_name'] as String?,
      employeeId: json['employee_id'] as String?,
      status: EmployeeStatus.fromString(json['status'] as String),
      role: UserRole.fromString(json['role'] as String? ?? 'employee'),  // NEW
      privacyConsentAt: json['privacy_consent_at'] != null
          ? DateTime.parse(json['privacy_consent_at'] as String)
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'email': email,
      'full_name': fullName,
      'employee_id': employeeId,
      'status': status.value,
      'role': role.value,  // NEW
      'privacy_consent_at': privacyConsentAt?.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  /// Whether the user has manager or admin role
  bool get isManager => role.isManager;

  /// Whether the user has admin role
  bool get isAdmin => role.isAdmin;
}
```

### SupervisionRecord (New)

```dart
// lib/features/history/models/supervision_record.dart

import 'package:flutter/foundation.dart';

/// Represents a manager-employee supervision relationship
@immutable
class SupervisionRecord {
  final String id;
  final String managerId;
  final String employeeId;
  final SupervisionType type;
  final DateTime effectiveFrom;
  final DateTime? effectiveTo;
  final DateTime createdAt;

  const SupervisionRecord({
    required this.id,
    required this.managerId,
    required this.employeeId,
    required this.type,
    required this.effectiveFrom,
    this.effectiveTo,
    required this.createdAt,
  });

  /// Whether this supervision is currently active
  bool get isActive => effectiveTo == null || effectiveTo!.isAfter(DateTime.now());

  factory SupervisionRecord.fromJson(Map<String, dynamic> json) {
    return SupervisionRecord(
      id: json['id'] as String,
      managerId: json['manager_id'] as String,
      employeeId: json['employee_id'] as String,
      type: SupervisionType.fromString(json['supervision_type'] as String),
      effectiveFrom: DateTime.parse(json['effective_from'] as String),
      effectiveTo: json['effective_to'] != null
          ? DateTime.parse(json['effective_to'] as String)
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'manager_id': managerId,
    'employee_id': employeeId,
    'supervision_type': type.value,
    'effective_from': effectiveFrom.toIso8601String(),
    'effective_to': effectiveTo?.toIso8601String(),
    'created_at': createdAt.toIso8601String(),
  };
}

enum SupervisionType {
  direct('direct'),
  matrix('matrix'),
  temporary('temporary');

  final String value;
  const SupervisionType(this.value);

  static SupervisionType fromString(String value) {
    return SupervisionType.values.firstWhere(
      (e) => e.value == value,
      orElse: () => SupervisionType.direct,
    );
  }
}
```

### EmployeeSummary (New)

```dart
// lib/features/history/models/employee_summary.dart

import 'package:flutter/foundation.dart';

/// Summary view of an employee for the supervised employees list
@immutable
class EmployeeSummary {
  final String id;
  final String email;
  final String? fullName;
  final String? employeeId;
  final DateTime? lastShiftAt;
  final int totalShiftsThisMonth;
  final Duration totalHoursThisMonth;

  const EmployeeSummary({
    required this.id,
    required this.email,
    this.fullName,
    this.employeeId,
    this.lastShiftAt,
    this.totalShiftsThisMonth = 0,
    this.totalHoursThisMonth = Duration.zero,
  });

  /// Display name for the employee (full name or email fallback)
  String get displayName => fullName ?? email;

  factory EmployeeSummary.fromJson(Map<String, dynamic> json) {
    return EmployeeSummary(
      id: json['id'] as String,
      email: json['email'] as String,
      fullName: json['full_name'] as String?,
      employeeId: json['employee_id'] as String?,
      lastShiftAt: json['last_shift_at'] != null
          ? DateTime.parse(json['last_shift_at'] as String)
          : null,
      totalShiftsThisMonth: json['total_shifts_this_month'] as int? ?? 0,
      totalHoursThisMonth: Duration(
        seconds: (json['total_hours_this_month'] as num?)?.toInt() ?? 0,
      ),
    );
  }
}
```

### ShiftHistoryFilter (New)

```dart
// lib/features/history/models/shift_history_filter.dart

import 'package:flutter/foundation.dart';

/// Filter criteria for shift history queries
@immutable
class ShiftHistoryFilter {
  final String? employeeId;
  final DateTime? startDate;
  final DateTime? endDate;
  final String? searchQuery;
  final int limit;
  final int offset;

  const ShiftHistoryFilter({
    this.employeeId,
    this.startDate,
    this.endDate,
    this.searchQuery,
    this.limit = 50,
    this.offset = 0,
  });

  /// Default filter for last 30 days
  factory ShiftHistoryFilter.defaultFilter({String? employeeId}) {
    final now = DateTime.now();
    return ShiftHistoryFilter(
      employeeId: employeeId,
      startDate: now.subtract(const Duration(days: 30)),
      endDate: now,
    );
  }

  ShiftHistoryFilter copyWith({
    String? employeeId,
    DateTime? startDate,
    DateTime? endDate,
    String? searchQuery,
    int? limit,
    int? offset,
  }) {
    return ShiftHistoryFilter(
      employeeId: employeeId ?? this.employeeId,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      searchQuery: searchQuery ?? this.searchQuery,
      limit: limit ?? this.limit,
      offset: offset ?? this.offset,
    );
  }

  /// Next page of results
  ShiftHistoryFilter nextPage() => copyWith(offset: offset + limit);

  /// Reset to first page
  ShiftHistoryFilter firstPage() => copyWith(offset: 0);

  /// Convert to query parameters for Supabase
  Map<String, dynamic> toQueryParams() => {
    if (employeeId != null) 'employee_id': employeeId,
    if (startDate != null) 'start_date': startDate!.toUtc().toIso8601String(),
    if (endDate != null) 'end_date': endDate!.toUtc().toIso8601String(),
    'limit': limit,
    'offset': offset,
  };
}
```

### HistoryStatistics (New)

```dart
// lib/features/history/models/history_statistics.dart

import 'package:flutter/foundation.dart';

/// Aggregated statistics for shift history
@immutable
class HistoryStatistics {
  final int totalShifts;
  final Duration totalHours;
  final Duration averageShiftDuration;
  final DateTime? earliestShift;
  final DateTime? latestShift;
  final int totalGpsPoints;
  final Duration periodCovered;

  const HistoryStatistics({
    required this.totalShifts,
    required this.totalHours,
    required this.averageShiftDuration,
    this.earliestShift,
    this.latestShift,
    this.totalGpsPoints = 0,
    this.periodCovered = Duration.zero,
  });

  /// Empty statistics
  static const empty = HistoryStatistics(
    totalShifts: 0,
    totalHours: Duration.zero,
    averageShiftDuration: Duration.zero,
  );

  /// Calculate statistics from a list of shifts
  factory HistoryStatistics.fromShifts(List<dynamic> shifts) {
    if (shifts.isEmpty) return empty;

    Duration totalDuration = Duration.zero;
    DateTime? earliest;
    DateTime? latest;
    int gpsPointCount = 0;

    for (final shift in shifts) {
      totalDuration += shift.duration;
      if (earliest == null || shift.clockedInAt.isBefore(earliest)) {
        earliest = shift.clockedInAt;
      }
      if (latest == null || shift.clockedInAt.isAfter(latest)) {
        latest = shift.clockedInAt;
      }
      gpsPointCount += shift.gpsPointCount ?? 0;
    }

    final avgDuration = shifts.isNotEmpty
        ? Duration(microseconds: totalDuration.inMicroseconds ~/ shifts.length)
        : Duration.zero;

    return HistoryStatistics(
      totalShifts: shifts.length,
      totalHours: totalDuration,
      averageShiftDuration: avgDuration,
      earliestShift: earliest,
      latestShift: latest,
      totalGpsPoints: gpsPointCount,
      periodCovered: earliest != null && latest != null
          ? latest.difference(earliest)
          : Duration.zero,
    );
  }

  factory HistoryStatistics.fromJson(Map<String, dynamic> json) {
    return HistoryStatistics(
      totalShifts: json['total_shifts'] as int? ?? 0,
      totalHours: Duration(seconds: (json['total_seconds'] as num?)?.toInt() ?? 0),
      averageShiftDuration: Duration(
        seconds: (json['avg_duration_seconds'] as num?)?.toInt() ?? 0,
      ),
      earliestShift: json['earliest_shift'] != null
          ? DateTime.parse(json['earliest_shift'] as String)
          : null,
      latestShift: json['latest_shift'] != null
          ? DateTime.parse(json['latest_shift'] as String)
          : null,
      totalGpsPoints: json['total_gps_points'] as int? ?? 0,
    );
  }
}
```

---

## State Transitions

### History View States

```
┌─────────────┐
│   Initial   │
└──────┬──────┘
       │ Load employees/history
       ▼
┌─────────────┐     Load error      ┌─────────────┐
│   Loading   │────────────────────▶│    Error    │
└──────┬──────┘                     └──────┬──────┘
       │ Success                           │ Retry
       ▼                                   │
┌─────────────┐                            │
│   Loaded    │◀───────────────────────────┘
└──────┬──────┘
       │ Apply filter
       ▼
┌─────────────┐
│  Filtering  │
└──────┬──────┘
       │ Filter applied
       ▼
┌─────────────┐
│  Filtered   │
└─────────────┘
```

### Export States

```
┌─────────────┐
│    Idle     │
└──────┬──────┘
       │ Start export
       ▼
┌─────────────┐     Error      ┌─────────────┐
│  Exporting  │───────────────▶│   Failed    │
└──────┬──────┘                └──────┬──────┘
       │ Success                      │ Retry
       ▼                              │
┌─────────────┐                       │
│  Completed  │◀──────────────────────┘
│  (file path)│
└─────────────┘
```

---

## Entity Relationships

```
employee_profiles
       │
       │ 1───* shifts
       │        │
       │        │ 1───* gps_points
       │
       │ *───1 employee_supervisors (as manager)
       │
       └ *───1 employee_supervisors (as employee)
```

---

## Validation Rules

### SupervisionRecord
- `manager_id` cannot equal `employee_id` (no self-supervision)
- `effective_to` must be after `effective_from` if set
- Active supervisions should have `effective_to = NULL`

### ShiftHistoryFilter
- `startDate` must be before `endDate` if both set
- `limit` must be positive (default: 50, max: 200)
- `offset` must be non-negative

### HistoryStatistics
- All duration values must be non-negative
- `totalShifts` must equal count of shifts used in calculation
- `averageShiftDuration` = `totalHours / totalShifts`
