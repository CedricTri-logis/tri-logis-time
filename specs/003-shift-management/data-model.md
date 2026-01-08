# Data Model: Shift Management

**Feature Branch**: `003-shift-management`
**Date**: 2026-01-08

## Overview

This document defines the data entities, relationships, and validation rules for the shift management feature.

---

## Entity Relationship Diagram

```
┌─────────────────────┐     ┌─────────────────────┐
│  employee_profiles  │     │       shifts        │
│─────────────────────│     │─────────────────────│
│ id (PK)             │←────│ employee_id (FK)    │
│ email               │     │ id (PK)             │
│ full_name           │     │ status              │
│ privacy_consent_at  │     │ clocked_in_at       │
│ ...                 │     │ clock_in_location   │
└─────────────────────┘     │ clocked_out_at      │
                            │ clock_out_location  │
                            │ ...                 │
                            └──────────┬──────────┘
                                       │
                                       │ 1:N
                                       ▼
                            ┌─────────────────────┐
                            │     gps_points      │
                            │─────────────────────│
                            │ id (PK)             │
                            │ shift_id (FK)       │
                            │ employee_id (FK)    │
                            │ latitude            │
                            │ longitude           │
                            │ captured_at         │
                            │ ...                 │
                            └─────────────────────┘
```

---

## Entities

### 1. Shift

Represents a work session for an employee from clock-in to clock-out.

#### Supabase Schema (Existing)

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| id | UUID | PK, DEFAULT gen_random_uuid() | Unique identifier |
| employee_id | UUID | FK → employee_profiles(id), NOT NULL | Owner of the shift |
| request_id | UUID | UNIQUE | Client-generated idempotency key |
| status | TEXT | CHECK IN ('active', 'completed'), DEFAULT 'active' | Shift state |
| clocked_in_at | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Clock-in timestamp (UTC) |
| clock_in_location | JSONB | nullable | {latitude: number, longitude: number} |
| clock_in_accuracy | DECIMAL(8,2) | nullable | GPS accuracy in meters |
| clocked_out_at | TIMESTAMPTZ | nullable | Clock-out timestamp (UTC) |
| clock_out_location | JSONB | nullable | {latitude: number, longitude: number} |
| clock_out_accuracy | DECIMAL(8,2) | nullable | GPS accuracy in meters |
| created_at | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Record creation |
| updated_at | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Last modification |

#### Dart Model

```dart
@immutable
class Shift {
  final String id;
  final String employeeId;
  final ShiftStatus status;
  final DateTime clockedInAt;
  final GeoPoint? clockInLocation;
  final double? clockInAccuracy;
  final DateTime? clockedOutAt;
  final GeoPoint? clockOutLocation;
  final double? clockOutAccuracy;
  final SyncStatus syncStatus;       // Local only
  final DateTime createdAt;
  final DateTime updatedAt;
}

enum ShiftStatus { active, completed }
enum SyncStatus { pending, syncing, synced, error }
```

#### Validation Rules

| Rule | Description | Source |
|------|-------------|--------|
| Single active shift | Employee cannot have more than one `status = 'active'` shift | FR-003 |
| Clock-out after clock-in | `clocked_out_at > clocked_in_at` when set | DB constraint |
| Privacy consent required | Cannot clock in without `privacy_consent_at` set | Constitution III, clock_in() function |
| Timestamps in UTC | All times stored as TIMESTAMPTZ | FR-013 |

#### State Transitions

```
    ┌──────────┐     clock_in()     ┌──────────┐
    │ (none)   │ ─────────────────► │  active  │
    └──────────┘                    └────┬─────┘
                                         │
                                   clock_out()
                                         │
                                         ▼
                                    ┌──────────┐
                                    │completed │
                                    └──────────┘
```

---

### 2. GeoPoint

Value object representing a GPS coordinate pair.

#### Dart Model

```dart
@immutable
class GeoPoint {
  final double latitude;   // -90.0 to 90.0
  final double longitude;  // -180.0 to 180.0

  const GeoPoint({required this.latitude, required this.longitude});

  factory GeoPoint.fromJson(Map<String, dynamic> json) => GeoPoint(
    latitude: (json['latitude'] as num).toDouble(),
    longitude: (json['longitude'] as num).toDouble(),
  );

  Map<String, dynamic> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
  };
}
```

#### Validation Rules

| Rule | Description |
|------|-------------|
| Latitude range | Must be between -90.0 and 90.0 |
| Longitude range | Must be between -180.0 and 180.0 |

---

### 3. ClockEvent

Logical representation of a clock-in or clock-out event (not persisted separately - derived from Shift).

#### Dart Model

```dart
@immutable
class ClockEvent {
  final ClockEventType type;
  final DateTime timestamp;
  final GeoPoint? location;
  final double? accuracy;

  const ClockEvent({
    required this.type,
    required this.timestamp,
    this.location,
    this.accuracy,
  });
}

enum ClockEventType { clockIn, clockOut }
```

---

### 4. ShiftSummary

Aggregated view for history display (computed, not stored).

#### Dart Model

```dart
@immutable
class ShiftSummary {
  final String id;
  final DateTime date;          // Date portion of clocked_in_at in local TZ
  final Duration duration;      // Computed: clocked_out_at - clocked_in_at
  final String? locationSummary; // Human-readable location description
  final ShiftStatus status;

  String get formattedDuration {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    return '${hours}h ${minutes}m';
  }
}
```

---

### 5. LocalShift (SQLite Schema)

Local table mirroring Supabase with sync tracking.

#### SQLite Schema

```sql
CREATE TABLE local_shifts (
  id TEXT PRIMARY KEY,
  employee_id TEXT NOT NULL,
  request_id TEXT UNIQUE,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'completed')),
  clocked_in_at TEXT NOT NULL,
  clock_in_latitude REAL,
  clock_in_longitude REAL,
  clock_in_accuracy REAL,
  clocked_out_at TEXT,
  clock_out_latitude REAL,
  clock_out_longitude REAL,
  clock_out_accuracy REAL,
  sync_status TEXT NOT NULL DEFAULT 'pending' CHECK (sync_status IN ('pending', 'syncing', 'synced', 'error')),
  last_sync_attempt TEXT,
  sync_error TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX idx_local_shifts_employee ON local_shifts(employee_id);
CREATE INDEX idx_local_shifts_status ON local_shifts(status);
CREATE INDEX idx_local_shifts_sync ON local_shifts(sync_status);
```

---

### 6. LocalGpsPoint (SQLite Schema)

Local GPS point storage for batch sync.

#### SQLite Schema

```sql
CREATE TABLE local_gps_points (
  id TEXT PRIMARY KEY,
  shift_id TEXT NOT NULL,
  employee_id TEXT NOT NULL,
  latitude REAL NOT NULL CHECK (latitude >= -90.0 AND latitude <= 90.0),
  longitude REAL NOT NULL CHECK (longitude >= -180.0 AND longitude <= 180.0),
  accuracy REAL,
  captured_at TEXT NOT NULL,
  device_id TEXT,
  sync_status TEXT NOT NULL DEFAULT 'pending' CHECK (sync_status IN ('pending', 'synced')),
  created_at TEXT NOT NULL,
  FOREIGN KEY (shift_id) REFERENCES local_shifts(id) ON DELETE CASCADE
);

CREATE INDEX idx_local_gps_shift ON local_gps_points(shift_id);
CREATE INDEX idx_local_gps_sync ON local_gps_points(sync_status);
```

---

## Computed Values

### Shift Duration

```dart
Duration get duration {
  if (clockedOutAt == null) {
    return DateTime.now().difference(clockedInAt);
  }
  return clockedOutAt!.difference(clockedInAt);
}
```

### Active Shift Check

```dart
// Single query to check for active shift
SELECT * FROM shifts
WHERE employee_id = $1 AND status = 'active'
LIMIT 1;
```

---

## Indexes (Supabase - Existing)

| Table | Index | Purpose |
|-------|-------|---------|
| shifts | idx_shifts_employee_id | Filter by employee |
| shifts | idx_shifts_status | Filter active/completed |
| shifts | idx_shifts_employee_active | Fast active shift lookup |
| shifts | idx_shifts_clocked_in_at | History ordering |
| gps_points | idx_gps_points_shift_id | GPS points per shift |
| gps_points | idx_gps_points_captured_at | Chronological ordering |

---

## Row Level Security (Existing)

All tables have RLS enabled with policies:
- **SELECT**: Users can view only their own records
- **INSERT**: Users can insert only with their own employee_id
- **UPDATE**: Users can update only their own records (shifts, profiles)
- **DELETE**: Not allowed for shifts/gps_points (immutable audit trail)

---

## Notes

- Database schema already exists in `supabase/migrations/001_initial_schema.sql`
- No schema modifications required for this feature
- Local SQLite tables will be created by `LocalDatabase` service on first app launch
