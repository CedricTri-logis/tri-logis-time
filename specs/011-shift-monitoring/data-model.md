# Data Model: Shift Monitoring

**Feature Branch**: `011-shift-monitoring`
**Created**: 2026-01-15
**Status**: Complete

## Overview

This feature uses existing database tables with new read-only views and RPC functions for monitoring-specific data access patterns. No schema changes required.

## Existing Entities (Read-Only Access)

### employee_profiles

Used to display supervised employee information.

| Field | Type | Description |
|-------|------|-------------|
| id | UUID | Primary key, references auth.users |
| email | TEXT | Employee email |
| full_name | TEXT | Display name |
| employee_id | TEXT | Company employee ID |
| role | TEXT | 'employee' \| 'manager' \| 'admin' \| 'super_admin' |
| status | TEXT | 'active' \| 'inactive' \| 'suspended' |

**Monitoring Usage**: Display employee name, ID in team list and shift details.

### shifts

Used to display current and recent shift information.

| Field | Type | Description |
|-------|------|-------------|
| id | UUID | Primary key |
| employee_id | UUID | FK to employee_profiles |
| status | TEXT | 'active' \| 'completed' |
| clocked_in_at | TIMESTAMPTZ | Shift start time |
| clocked_out_at | TIMESTAMPTZ | Shift end time (null if active) |
| clock_in_location | JSONB | {latitude, longitude} at clock-in |
| clock_in_accuracy | DECIMAL | GPS accuracy in meters |

**Monitoring Usage**:
- Display active/off-shift status
- Calculate live duration from `clocked_in_at`
- Show clock-in location on map

### gps_points

Used to display employee movement during active shifts.

| Field | Type | Description |
|-------|------|-------------|
| id | UUID | Primary key |
| shift_id | UUID | FK to shifts |
| employee_id | UUID | FK to employee_profiles |
| latitude | DECIMAL | GPS latitude (-90 to 90) |
| longitude | DECIMAL | GPS longitude (-180 to 180) |
| accuracy | DECIMAL | GPS accuracy in meters |
| captured_at | TIMESTAMPTZ | Client timestamp |

**Monitoring Usage**:
- Display current location (latest point)
- Render GPS trail as connected path
- Show accuracy circles and staleness indicators

### employee_supervisors

Used to filter employees to those under supervision.

| Field | Type | Description |
|-------|------|-------------|
| manager_id | UUID | FK to employee_profiles (supervisor) |
| employee_id | UUID | FK to employee_profiles (supervised) |
| supervision_type | TEXT | 'direct' \| 'matrix' \| 'temporary' |
| effective_from | DATE | Relationship start |
| effective_to | DATE | Relationship end (null = active) |

**Monitoring Usage**: Filter team list to authorized employees only.

## Frontend Data Types

### MonitoredEmployee

Composite type for team list display.

```typescript
interface MonitoredEmployee {
  id: string                    // employee_profiles.id
  fullName: string              // employee_profiles.full_name
  employeeId: string | null     // employee_profiles.employee_id
  shiftStatus: 'on-shift' | 'off-shift'
  currentShift: ActiveShift | null
  currentLocation: LocationPoint | null
}
```

### ActiveShift

Current shift information for display.

```typescript
interface ActiveShift {
  id: string                    // shifts.id
  clockedInAt: Date             // shifts.clocked_in_at
  clockInLocation: {            // shifts.clock_in_location
    latitude: number
    longitude: number
  } | null
  clockInAccuracy: number | null // shifts.clock_in_accuracy
}
```

### LocationPoint

GPS location with metadata.

```typescript
interface LocationPoint {
  latitude: number              // gps_points.latitude
  longitude: number             // gps_points.longitude
  accuracy: number              // gps_points.accuracy
  capturedAt: Date              // gps_points.captured_at
  isStale: boolean              // computed: capturedAt > 5 min ago
}
```

### GpsTrailPoint

Point in GPS trail for path rendering.

```typescript
interface GpsTrailPoint {
  id: string                    // gps_points.id
  latitude: number              // gps_points.latitude
  longitude: number             // gps_points.longitude
  accuracy: number              // gps_points.accuracy
  capturedAt: Date              // gps_points.captured_at
}
```

### ShiftDetail

Full shift information for detail view.

```typescript
interface ShiftDetail {
  id: string                    // shifts.id
  employeeId: string            // shifts.employee_id
  employeeName: string          // joined from employee_profiles
  status: 'active' | 'completed'
  clockedInAt: Date             // shifts.clocked_in_at
  clockedOutAt: Date | null     // shifts.clocked_out_at
  clockInLocation: {
    latitude: number
    longitude: number
  } | null
  duration: number              // computed seconds
  gpsPointCount: number         // count of GPS points
}
```

### RealtimePayload Types

For Supabase Realtime subscription handlers.

```typescript
interface ShiftChangePayload {
  eventType: 'INSERT' | 'UPDATE' | 'DELETE'
  new: {
    id: string
    employee_id: string
    status: string
    clocked_in_at: string
    clocked_out_at: string | null
  } | null
  old: {
    id: string
    status: string
  } | null
}

interface GpsPointPayload {
  eventType: 'INSERT'
  new: {
    id: string
    shift_id: string
    employee_id: string
    latitude: number
    longitude: number
    accuracy: number
    captured_at: string
  }
}
```

## State Transitions

### Employee Shift Status

```
off-shift ──[clock-in]──> on-shift ──[clock-out]──> off-shift
                              │
                              └──[GPS update]──> (location updates)
```

### Location Freshness

```
fresh (≤5min) ──[time passes]──> stale (5-15min) ──[time passes]──> very-stale (>15min)
     ^                                                                      │
     └──────────────────────[new GPS point received]────────────────────────┘
```

## Validation Rules

### Filter Inputs

```typescript
const monitoringFilterSchema = z.object({
  search: z.string().max(100).optional(),
  shiftStatus: z.enum(['all', 'on-shift', 'off-shift']).default('all'),
})
```

### Employee ID Path Parameter

```typescript
const employeeIdSchema = z.string().uuid()
```

## Relationships Diagram

```
employee_supervisors
        │
        │ manager_id, employee_id
        ▼
employee_profiles ◄──────┐
        │                │
        │ id             │ employee_id
        ▼                │
     shifts ─────────────┤
        │                │
        │ id             │ shift_id, employee_id
        ▼                │
   gps_points ───────────┘
```

## Access Control Summary

| Entity | Supervisor Access | Admin Access |
|--------|-------------------|--------------|
| employee_profiles | Own + supervised employees | All employees |
| shifts | Own + supervised employees' shifts | All shifts |
| gps_points | Own + supervised employees' points | All points |
| employee_supervisors | Own relationships | All relationships |

Access controlled via existing RLS policies and role-based middleware.
