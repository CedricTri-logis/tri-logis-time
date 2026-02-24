# Data Model: Cleaning Session Tracking via QR Code

**Feature**: 016-cleaning-qr-tracking
**Date**: 2026-02-12

## Entity Relationship Diagram

```
employee_profiles (existing)
  ├── 1:N → cleaning_sessions (via employee_id)
  └── 1:N → shifts (existing, via employee_id)

buildings
  └── 1:N → studios (via building_id)

studios
  └── 1:N → cleaning_sessions (via studio_id)

shifts (existing)
  └── 1:N → cleaning_sessions (via shift_id)

cleaning_sessions
  ├── N:1 → employee_profiles (via employee_id)
  ├── N:1 → studios (via studio_id)
  └── N:1 → shifts (via shift_id)
```

## Entities

### buildings

| Column     | Type                     | Constraints                    |
|------------|--------------------------|--------------------------------|
| id         | UUID                     | PK, DEFAULT gen_random_uuid()  |
| name       | TEXT                     | NOT NULL, UNIQUE               |
| created_at | TIMESTAMPTZ              | DEFAULT now()                  |
| updated_at | TIMESTAMPTZ              | DEFAULT now()                  |

### studio_type (enum)

Values: `unit`, `common_area`, `conciergerie`

### studios

| Column      | Type                     | Constraints                        |
|-------------|--------------------------|-----------------------------------|
| id          | UUID                     | PK, DEFAULT gen_random_uuid()      |
| qr_code     | TEXT                     | NOT NULL, UNIQUE                   |
| studio_number | TEXT                   | NOT NULL                           |
| building_id | UUID                     | FK → buildings(id), NOT NULL       |
| studio_type | studio_type              | NOT NULL, DEFAULT 'unit'           |
| is_active   | BOOLEAN                  | DEFAULT true                       |
| created_at  | TIMESTAMPTZ              | DEFAULT now()                      |
| updated_at  | TIMESTAMPTZ              | DEFAULT now()                      |

**Unique constraint**: (building_id, studio_number) — no duplicate studio numbers within a building

### cleaning_session_status (enum)

Values: `in_progress`, `completed`, `auto_closed`, `manually_closed`

### cleaning_sessions

| Column       | Type                       | Constraints                        |
|--------------|----------------------------|------------------------------------|
| id           | UUID                       | PK, DEFAULT gen_random_uuid()      |
| employee_id  | UUID                       | FK → employee_profiles(id), NOT NULL |
| studio_id    | UUID                       | FK → studios(id), NOT NULL         |
| shift_id     | UUID                       | FK → shifts(id), NOT NULL          |
| status       | cleaning_session_status    | NOT NULL, DEFAULT 'in_progress'    |
| started_at   | TIMESTAMPTZ                | NOT NULL, DEFAULT now()            |
| completed_at | TIMESTAMPTZ                | NULL                               |
| duration_minutes | NUMERIC(10,2)          | NULL (computed on close)           |
| is_flagged   | BOOLEAN                    | DEFAULT false                      |
| flag_reason  | TEXT                       | NULL                               |
| created_at   | TIMESTAMPTZ                | DEFAULT now()                      |
| updated_at   | TIMESTAMPTZ                | DEFAULT now()                      |

**Constraints**:
- `completed_at > started_at` (when not null)
- `duration_minutes >= 0` (when not null)

**Indexes**:
- `(employee_id, status)` — find active sessions for an employee
- `(studio_id, started_at)` — find cleaning history for a studio
- `(shift_id)` — find all sessions in a shift
- `(status)` WHERE status = 'in_progress' — partial index for active sessions

## Validation Rules

### Cleaning Session Creation (scan-in)
1. Employee must have an active shift
2. QR code must map to an active studio
3. Warn (not block) if employee already has an active session for another room

### Cleaning Session Completion (scan-out)
1. Active session must exist for this employee + studio combination
2. Duration is computed as `completed_at - started_at` in minutes
3. Flag if duration < 5 min (unit) / < 2 min (common_area, conciergerie)
4. Flag if duration > 240 min (4 hours) for any type

### Auto-Close on Shift End
1. All sessions with status `in_progress` for the shift are closed
2. Status set to `auto_closed`
3. `completed_at` set to shift's `clocked_out_at` time
4. Duration computed, flagged if abnormal

## State Transitions

```
[scan-in] → in_progress
  ├── [scan-out] → completed
  ├── [shift ends] → auto_closed
  └── [supervisor action] → manually_closed
```

## Local Storage (Flutter SQLCipher)

### local_studios

Mirror of the `studios` table with `buildings` data denormalized for offline use.

| Column         | Type    | Notes                         |
|----------------|---------|-------------------------------|
| id             | TEXT    | PK (UUID)                     |
| qr_code        | TEXT    | UNIQUE, NOT NULL              |
| studio_number  | TEXT    | NOT NULL                      |
| building_id    | TEXT    | NOT NULL                      |
| building_name  | TEXT    | Denormalized from buildings   |
| studio_type    | TEXT    | 'unit' / 'common_area' / 'conciergerie' |
| is_active      | INTEGER | 0 or 1                        |
| updated_at     | TEXT    | ISO 8601                      |

### local_cleaning_sessions

| Column           | Type    | Notes                         |
|------------------|---------|-------------------------------|
| id               | TEXT    | PK (UUID)                     |
| employee_id      | TEXT    | NOT NULL                      |
| studio_id        | TEXT    | FK → local_studios(id)        |
| shift_id         | TEXT    | FK → local_shifts(id)         |
| status           | TEXT    | NOT NULL                      |
| started_at       | TEXT    | ISO 8601, NOT NULL            |
| completed_at     | TEXT    | ISO 8601, NULL                |
| duration_minutes | REAL    | NULL                          |
| is_flagged       | INTEGER | 0 or 1                        |
| flag_reason      | TEXT    | NULL                          |
| sync_status      | TEXT    | 'pending' / 'synced' / 'error' |
| server_id        | TEXT    | NULL until synced              |
| created_at       | TEXT    | ISO 8601                      |
| updated_at       | TEXT    | ISO 8601                      |

**Indexes**: (employee_id, status), (studio_id), (shift_id), (sync_status)

## Migration Summary

**File**: `supabase/migrations/016_cleaning_qr_tracking.sql`

1. Create `studio_type` enum
2. Create `cleaning_session_status` enum
3. Create `buildings` table
4. Create `studios` table with FK to buildings
5. Create `cleaning_sessions` table with FKs to employee_profiles, studios, shifts
6. Add indexes
7. Add triggers for `updated_at` auto-update
8. Create RLS policies
9. Create RPC functions (scan_in, scan_out, auto_close_sessions, get_cleaning_dashboard)
10. Seed buildings and studios data (all 115 entries)

## RLS Policies

### buildings
- All authenticated users can SELECT (read-only reference data)
- Only admin/super_admin can INSERT/UPDATE/DELETE

### studios
- All authenticated users can SELECT (read-only reference data)
- Only admin/super_admin can INSERT/UPDATE/DELETE

### cleaning_sessions
- Employees can SELECT their own sessions
- Employees can INSERT (create sessions linked to their own active shift)
- Employees can UPDATE their own `in_progress` sessions (scan-out)
- Supervisors (manager+) can SELECT sessions for their supervised employees
- Supervisors can UPDATE sessions (manual close)
- Admin/super_admin can SELECT/UPDATE all sessions
