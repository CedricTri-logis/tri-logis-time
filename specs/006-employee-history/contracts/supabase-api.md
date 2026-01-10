# API Contracts: Employee History

**Feature**: 006-employee-history | **Date**: 2026-01-10

This document defines the Supabase API contracts for the Employee History feature. These contracts define the expected request/response formats for database operations.

---

## Table Operations

### employee_profiles (Read - Extended)

Existing table with new `role` field. Managers can now read profiles of supervised employees.

#### Get Supervised Employees

```http
GET /rest/v1/employee_profiles?select=*&id=in.(SELECT employee_id FROM employee_supervisors WHERE manager_id=eq.{current_user_id}&effective_to=is.null)
```

**Alternative using RPC**:
```sql
-- Supabase RPC function
CREATE OR REPLACE FUNCTION get_supervised_employees()
RETURNS TABLE (
    id UUID,
    email TEXT,
    full_name TEXT,
    employee_id TEXT,
    status TEXT,
    role TEXT,
    last_shift_at TIMESTAMPTZ,
    total_shifts_this_month INT,
    total_hours_this_month INTERVAL
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        ep.id,
        ep.email,
        ep.full_name,
        ep.employee_id,
        ep.status,
        ep.role,
        (SELECT MAX(clocked_in_at) FROM shifts WHERE shifts.employee_id = ep.id) as last_shift_at,
        (SELECT COUNT(*)::INT FROM shifts
         WHERE shifts.employee_id = ep.id
         AND clocked_in_at >= date_trunc('month', CURRENT_DATE)) as total_shifts_this_month,
        (SELECT COALESCE(SUM(
            CASE WHEN clocked_out_at IS NOT NULL
            THEN clocked_out_at - clocked_in_at
            ELSE INTERVAL '0'
            END), INTERVAL '0')
         FROM shifts
         WHERE shifts.employee_id = ep.id
         AND clocked_in_at >= date_trunc('month', CURRENT_DATE)) as total_hours_this_month
    FROM employee_profiles ep
    INNER JOIN employee_supervisors es ON es.employee_id = ep.id
    WHERE es.manager_id = auth.uid()
    AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

**Request (Flutter)**:
```dart
final response = await supabase.rpc('get_supervised_employees');
```

**Response**:
```json
[
  {
    "id": "uuid-1",
    "email": "employee1@example.com",
    "full_name": "John Doe",
    "employee_id": "EMP001",
    "status": "active",
    "role": "employee",
    "last_shift_at": "2026-01-09T17:30:00Z",
    "total_shifts_this_month": 15,
    "total_hours_this_month": "PT120H30M"
  }
]
```

---

### shifts (Read - Extended)

Managers can now read shifts of supervised employees via updated RLS.

#### Get Employee Shift History (Paginated)

```sql
CREATE OR REPLACE FUNCTION get_employee_shifts(
    p_employee_id UUID,
    p_start_date TIMESTAMPTZ DEFAULT NULL,
    p_end_date TIMESTAMPTZ DEFAULT NULL,
    p_limit INT DEFAULT 50,
    p_offset INT DEFAULT 0
)
RETURNS TABLE (
    id UUID,
    employee_id UUID,
    status TEXT,
    clocked_in_at TIMESTAMPTZ,
    clock_in_location JSONB,
    clock_in_accuracy DECIMAL,
    clocked_out_at TIMESTAMPTZ,
    clock_out_location JSONB,
    clock_out_accuracy DECIMAL,
    duration_seconds INT,
    gps_point_count INT,
    created_at TIMESTAMPTZ
) AS $$
BEGIN
    -- Verify caller has access to this employee
    IF NOT (
        p_employee_id = auth.uid()
        OR EXISTS (
            SELECT 1 FROM employee_supervisors
            WHERE manager_id = auth.uid()
            AND employee_id = p_employee_id
            AND (effective_to IS NULL OR effective_to >= CURRENT_DATE)
        )
    ) THEN
        RAISE EXCEPTION 'Access denied';
    END IF;

    RETURN QUERY
    SELECT
        s.id,
        s.employee_id,
        s.status,
        s.clocked_in_at,
        s.clock_in_location,
        s.clock_in_accuracy,
        s.clocked_out_at,
        s.clock_out_location,
        s.clock_out_accuracy,
        EXTRACT(EPOCH FROM COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at)::INT as duration_seconds,
        (SELECT COUNT(*)::INT FROM gps_points gp WHERE gp.shift_id = s.id) as gps_point_count,
        s.created_at
    FROM shifts s
    WHERE s.employee_id = p_employee_id
    AND (p_start_date IS NULL OR s.clocked_in_at >= p_start_date)
    AND (p_end_date IS NULL OR s.clocked_in_at <= p_end_date)
    ORDER BY s.clocked_in_at DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

**Request (Flutter)**:
```dart
final response = await supabase.rpc('get_employee_shifts', params: {
  'p_employee_id': employeeId,
  'p_start_date': startDate?.toUtc().toIso8601String(),
  'p_end_date': endDate?.toUtc().toIso8601String(),
  'p_limit': 50,
  'p_offset': 0,
});
```

**Response**:
```json
[
  {
    "id": "shift-uuid-1",
    "employee_id": "uuid-1",
    "status": "completed",
    "clocked_in_at": "2026-01-09T08:00:00Z",
    "clock_in_location": {"latitude": 37.7749, "longitude": -122.4194},
    "clock_in_accuracy": 10.5,
    "clocked_out_at": "2026-01-09T17:30:00Z",
    "clock_out_location": {"latitude": 37.7749, "longitude": -122.4194},
    "clock_out_accuracy": 8.2,
    "duration_seconds": 34200,
    "gps_point_count": 114,
    "created_at": "2026-01-09T08:00:00Z"
  }
]
```

---

### gps_points (Read - Extended)

Managers can now read GPS points of supervised employees via updated RLS.

#### Get Shift GPS Points

```sql
CREATE OR REPLACE FUNCTION get_shift_gps_points(p_shift_id UUID)
RETURNS TABLE (
    id UUID,
    latitude DECIMAL,
    longitude DECIMAL,
    accuracy DECIMAL,
    captured_at TIMESTAMPTZ
) AS $$
DECLARE
    v_employee_id UUID;
BEGIN
    -- Get employee ID for the shift
    SELECT employee_id INTO v_employee_id FROM shifts WHERE id = p_shift_id;

    -- Verify caller has access
    IF NOT (
        v_employee_id = auth.uid()
        OR EXISTS (
            SELECT 1 FROM employee_supervisors
            WHERE manager_id = auth.uid()
            AND employee_id = v_employee_id
            AND (effective_to IS NULL OR effective_to >= CURRENT_DATE)
        )
    ) THEN
        RAISE EXCEPTION 'Access denied';
    END IF;

    RETURN QUERY
    SELECT
        gp.id,
        gp.latitude,
        gp.longitude,
        gp.accuracy,
        gp.captured_at
    FROM gps_points gp
    WHERE gp.shift_id = p_shift_id
    ORDER BY gp.captured_at ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

**Request (Flutter)**:
```dart
final response = await supabase.rpc('get_shift_gps_points', params: {
  'p_shift_id': shiftId,
});
```

**Response**:
```json
[
  {
    "id": "gps-uuid-1",
    "latitude": 37.7749,
    "longitude": -122.4194,
    "accuracy": 10.5,
    "captured_at": "2026-01-09T08:05:00Z"
  },
  {
    "id": "gps-uuid-2",
    "latitude": 37.7750,
    "longitude": -122.4195,
    "accuracy": 8.2,
    "captured_at": "2026-01-09T08:10:00Z"
  }
]
```

---

### Statistics Functions

#### Get Employee Statistics

```sql
CREATE OR REPLACE FUNCTION get_employee_statistics(
    p_employee_id UUID,
    p_start_date TIMESTAMPTZ DEFAULT NULL,
    p_end_date TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
    total_shifts INT,
    total_seconds BIGINT,
    avg_duration_seconds INT,
    earliest_shift TIMESTAMPTZ,
    latest_shift TIMESTAMPTZ,
    total_gps_points BIGINT
) AS $$
BEGIN
    -- Verify caller has access
    IF NOT (
        p_employee_id = auth.uid()
        OR EXISTS (
            SELECT 1 FROM employee_supervisors
            WHERE manager_id = auth.uid()
            AND employee_id = p_employee_id
            AND (effective_to IS NULL OR effective_to >= CURRENT_DATE)
        )
    ) THEN
        RAISE EXCEPTION 'Access denied';
    END IF;

    RETURN QUERY
    SELECT
        COUNT(s.id)::INT as total_shifts,
        COALESCE(
            EXTRACT(EPOCH FROM SUM(COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at))::BIGINT,
            0
        ) as total_seconds,
        CASE
            WHEN COUNT(s.id) > 0 THEN
                (EXTRACT(EPOCH FROM SUM(COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at)) / COUNT(s.id))::INT
            ELSE 0
        END as avg_duration_seconds,
        MIN(s.clocked_in_at) as earliest_shift,
        MAX(s.clocked_in_at) as latest_shift,
        (SELECT COUNT(*) FROM gps_points gp
         INNER JOIN shifts sh ON gp.shift_id = sh.id
         WHERE sh.employee_id = p_employee_id
         AND (p_start_date IS NULL OR sh.clocked_in_at >= p_start_date)
         AND (p_end_date IS NULL OR sh.clocked_in_at <= p_end_date)) as total_gps_points
    FROM shifts s
    WHERE s.employee_id = p_employee_id
    AND s.status = 'completed'
    AND (p_start_date IS NULL OR s.clocked_in_at >= p_start_date)
    AND (p_end_date IS NULL OR s.clocked_in_at <= p_end_date);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

**Request (Flutter)**:
```dart
final response = await supabase.rpc('get_employee_statistics', params: {
  'p_employee_id': employeeId,
  'p_start_date': startDate?.toUtc().toIso8601String(),
  'p_end_date': endDate?.toUtc().toIso8601String(),
});
```

**Response**:
```json
{
  "total_shifts": 45,
  "total_seconds": 324000,
  "avg_duration_seconds": 7200,
  "earliest_shift": "2026-01-01T08:00:00Z",
  "latest_shift": "2026-01-09T08:00:00Z",
  "total_gps_points": 5400
}
```

---

#### Get Team Statistics (Manager View)

```sql
CREATE OR REPLACE FUNCTION get_team_statistics(
    p_start_date TIMESTAMPTZ DEFAULT NULL,
    p_end_date TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
    total_employees INT,
    total_shifts INT,
    total_seconds BIGINT,
    avg_duration_seconds INT,
    avg_shifts_per_employee DECIMAL
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        (SELECT COUNT(DISTINCT es.employee_id)::INT
         FROM employee_supervisors es
         WHERE es.manager_id = auth.uid()
         AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)) as total_employees,
        COUNT(s.id)::INT as total_shifts,
        COALESCE(
            EXTRACT(EPOCH FROM SUM(COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at))::BIGINT,
            0
        ) as total_seconds,
        CASE
            WHEN COUNT(s.id) > 0 THEN
                (EXTRACT(EPOCH FROM SUM(COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at)) / COUNT(s.id))::INT
            ELSE 0
        END as avg_duration_seconds,
        CASE
            WHEN (SELECT COUNT(DISTINCT es2.employee_id)
                  FROM employee_supervisors es2
                  WHERE es2.manager_id = auth.uid()
                  AND (es2.effective_to IS NULL OR es2.effective_to >= CURRENT_DATE)) > 0
            THEN COUNT(s.id)::DECIMAL / (SELECT COUNT(DISTINCT es2.employee_id)
                  FROM employee_supervisors es2
                  WHERE es2.manager_id = auth.uid()
                  AND (es2.effective_to IS NULL OR es2.effective_to >= CURRENT_DATE))
            ELSE 0
        END as avg_shifts_per_employee
    FROM shifts s
    INNER JOIN employee_supervisors es ON es.employee_id = s.employee_id
    WHERE es.manager_id = auth.uid()
    AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
    AND s.status = 'completed'
    AND (p_start_date IS NULL OR s.clocked_in_at >= p_start_date)
    AND (p_end_date IS NULL OR s.clocked_in_at <= p_end_date);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

**Request (Flutter)**:
```dart
final response = await supabase.rpc('get_team_statistics', params: {
  'p_start_date': startDate?.toUtc().toIso8601String(),
  'p_end_date': endDate?.toUtc().toIso8601String(),
});
```

**Response**:
```json
{
  "total_employees": 12,
  "total_shifts": 180,
  "total_seconds": 1296000,
  "avg_duration_seconds": 7200,
  "avg_shifts_per_employee": 15.0
}
```

---

## Error Responses

All RPC functions return standard PostgreSQL errors wrapped by Supabase:

```json
{
  "code": "42501",
  "message": "Access denied",
  "details": null,
  "hint": null
}
```

### Common Error Codes

| Code | Meaning | HTTP Status |
|------|---------|-------------|
| 42501 | Permission denied (RLS violation) | 403 |
| P0001 | Custom exception (Access denied) | 400 |
| 22P02 | Invalid UUID format | 400 |
| 23503 | Foreign key violation | 400 |

---

## Rate Limits & Performance

### Recommended Query Limits

| Operation | Default Limit | Max Limit | Notes |
|-----------|---------------|-----------|-------|
| get_supervised_employees | N/A | 100 | Returns all supervised |
| get_employee_shifts | 50 | 200 | Paginated |
| get_shift_gps_points | N/A | 5000 | Full shift data |
| get_employee_statistics | N/A | N/A | Single row result |
| get_team_statistics | N/A | N/A | Single row result |

### Indexing Requirements

Required indexes are defined in the migration and include:
- `idx_shifts_employee_date` for efficient date range filtering
- `idx_employee_supervisors_manager` for quick manager lookups
- `idx_employee_supervisors_active` for active supervision queries
