# Data Model: Employee & Shift Dashboard

**Feature Branch**: `008-employee-shift-dashboard`
**Date**: 2026-01-10

## Overview

This document defines the data models for the Employee & Shift Dashboard feature. Most models extend or compose existing models from previous specs. New models focus on dashboard-specific state management.

---

## New Entities

### 1. EmployeeDashboardState

**Purpose**: Represents the complete state of an employee's personal dashboard.

**Location**: `lib/features/dashboard/models/dashboard_state.dart`

| Field | Type | Description | Constraints |
|-------|------|-------------|-------------|
| `currentShiftStatus` | `ShiftStatusInfo` | Active shift details or inactive state | Required |
| `todayStats` | `DailyStatistics` | Today's accumulated hours and shift count | Required |
| `monthlyStats` | `HistoryStatistics` | This month's totals (reuse existing) | Required |
| `recentShifts` | `List<Shift>` | Last 7 days of shifts | Required, max 50 |
| `syncStatus` | `SyncState` | Current sync state (reuse existing) | Required |
| `lastUpdated` | `DateTime?` | Last successful data refresh | Nullable |
| `isLoading` | `bool` | Dashboard data loading state | Required, default false |
| `error` | `String?` | Error message if load failed | Nullable |

**State Transitions**:
```
idle → loading → loaded
idle → loading → error
loaded → refreshing → loaded
loaded → refreshing → error
```

**Validation Rules**:
- `recentShifts` must be sorted by `clockedInAt` DESC
- `lastUpdated` must be in user's local timezone for display
- `todayStats` period must match current calendar day in user's timezone

---

### 2. ShiftStatusInfo

**Purpose**: Current shift status indicator for dashboard display.

**Location**: `lib/features/dashboard/models/dashboard_state.dart`

| Field | Type | Description | Constraints |
|-------|------|-------------|-------------|
| `isActive` | `bool` | Whether employee is currently clocked in | Required |
| `activeShift` | `Shift?` | Current shift if active | Nullable |
| `lastClockOutAt` | `DateTime?` | Time of last clock-out if inactive | Nullable |
| `elapsedDuration` | `Duration` | Time since clock-in (live computed) | Computed |

**Computed Properties**:
```dart
bool get showClockInPrompt => !isActive;
bool get showLiveTimer => isActive && activeShift != null;
Duration get elapsedDuration => isActive
  ? DateTime.now().difference(activeShift!.clockedInAt)
  : Duration.zero;
```

---

### 3. DailyStatistics

**Purpose**: Today's work summary for dashboard display.

**Location**: `lib/features/dashboard/models/dashboard_state.dart`

| Field | Type | Description | Constraints |
|-------|------|-------------|-------------|
| `date` | `DateTime` | The date these stats represent | Required, date only |
| `completedShiftCount` | `int` | Number of completed shifts today | Required, >= 0 |
| `totalDuration` | `Duration` | Total worked time today | Required, >= 0 |
| `activeShiftDuration` | `Duration` | Current shift duration (if active) | Required, >= 0 |

**Computed Properties**:
```dart
Duration get totalIncludingActive => totalDuration + activeShiftDuration;
String get formattedHours => _formatDuration(totalIncludingActive);
bool get hasWorkedToday => completedShiftCount > 0 || activeShiftDuration > Duration.zero;
```

---

### 4. TeamDashboardState

**Purpose**: Manager's team overview state.

**Location**: `lib/features/dashboard/models/team_dashboard_state.dart`

| Field | Type | Description | Constraints |
|-------|------|-------------|-------------|
| `employees` | `List<TeamEmployeeStatus>` | All supervised employees with status | Required |
| `activeCount` | `int` | Count of currently clocked-in employees | Computed |
| `searchQuery` | `String` | Current search/filter text | Default "" |
| `filteredEmployees` | `List<TeamEmployeeStatus>` | Search-filtered list | Computed |
| `lastUpdated` | `DateTime?` | Last data refresh timestamp | Nullable |
| `isLoading` | `bool` | Data loading state | Required, default false |
| `error` | `String?` | Error message if load failed | Nullable |

**Computed Properties**:
```dart
int get activeCount => employees.where((e) => e.isActive).length;
int get totalCount => employees.length;
List<TeamEmployeeStatus> get filteredEmployees => _filterBySearch(searchQuery);
bool get hasEmployees => employees.isNotEmpty;
```

---

### 5. TeamEmployeeStatus

**Purpose**: Single employee row in team dashboard list.

**Location**: `lib/features/dashboard/models/employee_work_status.dart`

| Field | Type | Description | Constraints |
|-------|------|-------------|-------------|
| `employeeId` | `String` | Employee profile ID | Required, UUID |
| `displayName` | `String` | Full name or email fallback | Required |
| `email` | `String` | Employee email | Required |
| `employeeNumber` | `String?` | Company employee ID | Nullable |
| `isActive` | `bool` | Currently clocked in | Required |
| `currentShiftStartedAt` | `DateTime?` | Clock-in time if active | Nullable |
| `todayHours` | `Duration` | Today's total worked time | Required |
| `monthlyHours` | `Duration` | This month's total hours | Required |
| `monthlyShiftCount` | `int` | This month's shift count | Required |

**Visual State**:
- `isActive: true` → Highlighted/badged row, shows live duration
- `isActive: false` → Normal row, shows "Not clocked in"

---

### 6. TeamStatisticsState

**Purpose**: Team aggregate statistics with date filtering.

**Location**: `lib/features/dashboard/models/team_dashboard_state.dart`

| Field | Type | Description | Constraints |
|-------|------|-------------|-------------|
| `dateRange` | `DateTimeRange` | Selected period for statistics | Required |
| `dateRangePreset` | `DateRangePreset` | Active preset or custom | Required |
| `statistics` | `TeamStatistics` | Aggregate team metrics (reuse) | Required |
| `employeeHours` | `List<EmployeeHoursData>` | Per-employee hours for chart | Required |
| `isLoading` | `bool` | Data loading state | Required |
| `error` | `String?` | Error if load failed | Nullable |

---

### 7. DateRangePreset

**Purpose**: Enum for date range filter presets.

**Location**: `lib/features/dashboard/models/team_dashboard_state.dart`

```dart
enum DateRangePreset {
  today('Today'),
  thisWeek('This Week'),
  thisMonth('This Month'),
  custom('Custom Range');

  final String label;
  const DateRangePreset(this.label);

  DateTimeRange toDateRange() {
    final now = DateTime.now();
    switch (this) {
      case DateRangePreset.today:
        return DateTimeRange(
          start: DateTime(now.year, now.month, now.day),
          end: now,
        );
      case DateRangePreset.thisWeek:
        final weekStart = now.subtract(Duration(days: now.weekday - 1));
        return DateTimeRange(
          start: DateTime(weekStart.year, weekStart.month, weekStart.day),
          end: now,
        );
      case DateRangePreset.thisMonth:
        return DateTimeRange(
          start: DateTime(now.year, now.month, 1),
          end: now,
        );
      case DateRangePreset.custom:
        throw StateError('Custom preset requires explicit date range');
    }
  }
}
```

---

### 8. EmployeeHoursData

**Purpose**: Single employee data point for bar chart.

**Location**: `lib/features/dashboard/models/team_dashboard_state.dart`

| Field | Type | Description | Constraints |
|-------|------|-------------|-------------|
| `employeeId` | `String` | Employee identifier | Required |
| `displayName` | `String` | Employee name for chart label | Required |
| `totalHours` | `double` | Hours worked in period (decimal) | Required, >= 0 |

---

## Reused Entities (from previous specs)

### From Spec 003 (Shift Management)
- **Shift**: Work session with clock-in/out times
- **ShiftStatus**: active/completed enum
- **SyncStatus**: synced/pending/syncing/error enum

### From Spec 005 (Offline Resilience)
- **SyncState**: Provider state for sync status
- **SyncMetadata**: Persisted sync tracking

### From Spec 006 (Employee History)
- **EmployeeSummary**: Employee with monthly stats
- **HistoryStatistics**: Aggregated shift metrics
- **TeamStatistics**: Team aggregate metrics

---

## Database Schema (Local Cache)

### New Table: dashboard_cache

```sql
CREATE TABLE IF NOT EXISTS dashboard_cache (
  id TEXT PRIMARY KEY,                  -- Format: 'employee_{uuid}' or 'team_{uuid}'
  cache_type TEXT NOT NULL,             -- 'employee' or 'team'
  employee_id TEXT NOT NULL,            -- Owner of this cache
  cached_data TEXT NOT NULL,            -- JSON blob of state
  last_updated TEXT NOT NULL,           -- ISO8601 UTC timestamp
  expires_at TEXT NOT NULL,             -- Cache expiry (7 days from update)
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_dashboard_cache_employee ON dashboard_cache(employee_id);
CREATE INDEX idx_dashboard_cache_type ON dashboard_cache(cache_type);
CREATE INDEX idx_dashboard_cache_expires ON dashboard_cache(expires_at);
```

### Cache Key Patterns
- Employee dashboard: `employee_{employee_id}`
- Team dashboard: `team_{manager_id}`
- Team statistics: `team_stats_{manager_id}_{date_range_hash}`

---

## Entity Relationships

```
EmployeeDashboardState
├── ShiftStatusInfo
│   └── Shift (nullable, existing)
├── DailyStatistics (new)
├── HistoryStatistics (existing)
├── List<Shift> (existing)
└── SyncState (existing)

TeamDashboardState
├── List<TeamEmployeeStatus> (new)
└── EmployeeSummary (composed, existing)

TeamStatisticsState
├── DateTimeRange (Flutter core)
├── DateRangePreset (new enum)
├── TeamStatistics (existing)
└── List<EmployeeHoursData> (new)
```

---

## Serialization

All new models implement:
- `factory Model.fromJson(Map<String, dynamic> json)`
- `Map<String, dynamic> toJson()`
- JSON storage in `dashboard_cache.cached_data`

Duration fields serialized as seconds (int) for consistency with existing patterns.
