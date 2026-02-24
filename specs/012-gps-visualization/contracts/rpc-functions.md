# RPC Functions Contract: GPS Visualization

**Feature Branch**: `012-gps-visualization`
**Migration File**: `supabase/migrations/013_gps_visualization.sql`
**Date**: 2026-01-15

## Overview

This document specifies the PostgreSQL RPC functions required for historical GPS visualization. All functions use `SECURITY DEFINER` and implement the same authorization pattern as Spec 011.

---

## Function 1: get_historical_shift_trail

### Purpose
Retrieve complete GPS trail for a completed shift. Unlike `get_shift_gps_trail` (Spec 011) which only works for active shifts, this function works for completed shifts within the retention period.

### Signature

```sql
CREATE OR REPLACE FUNCTION get_historical_shift_trail(
  p_shift_id UUID
)
RETURNS TABLE (
  id UUID,
  latitude DECIMAL(10, 8),
  longitude DECIMAL(11, 8),
  accuracy DECIMAL(8, 2),
  captured_at TIMESTAMPTZ
)
```

### Parameters

| Name | Type | Required | Validation |
|------|------|----------|------------|
| p_shift_id | UUID | Yes | Must exist in shifts table |

### Return Columns

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | UUID | No | GPS point identifier |
| latitude | DECIMAL(10,8) | No | Latitude (-90 to 90) |
| longitude | DECIMAL(11,8) | No | Longitude (-180 to 180) |
| accuracy | DECIMAL(8,2) | Yes | GPS accuracy in meters |
| captured_at | TIMESTAMPTZ | No | Client capture timestamp |

### Authorization Rules

1. Get caller's role from `employee_profiles`
2. If role is `admin` or `super_admin`: authorized
3. Otherwise: check `employee_supervisors` for active supervision relationship
4. Return empty if unauthorized

### Business Rules

1. Shift must exist
2. Shift's `clocked_in_at` must be within last 90 days
3. Points ordered by `captured_at ASC`

### Example Usage

```typescript
const { data } = await supabase.rpc('get_historical_shift_trail', {
  p_shift_id: 'abc-123-def-456'
});
```

### SQL Implementation

```sql
CREATE OR REPLACE FUNCTION get_historical_shift_trail(
  p_shift_id UUID
)
RETURNS TABLE (
  id UUID,
  latitude DECIMAL(10, 8),
  longitude DECIMAL(11, 8),
  accuracy DECIMAL(8, 2),
  captured_at TIMESTAMPTZ
) AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_user_role TEXT;
  v_shift_employee_id UUID;
  v_shift_clocked_in_at TIMESTAMPTZ;
BEGIN
  -- Get shift details
  SELECT shifts.employee_id, shifts.clocked_in_at
  INTO v_shift_employee_id, v_shift_clocked_in_at
  FROM shifts WHERE shifts.id = p_shift_id;

  -- If shift not found, return empty
  IF v_shift_employee_id IS NULL THEN
    RETURN;
  END IF;

  -- Check 90-day retention period
  IF v_shift_clocked_in_at < NOW() - INTERVAL '90 days' THEN
    RETURN;
  END IF;

  -- Get caller's role
  SELECT role INTO v_user_role
  FROM employee_profiles
  WHERE employee_profiles.id = v_user_id;

  -- Check authorization
  IF v_user_role NOT IN ('admin', 'super_admin') THEN
    IF NOT EXISTS (
      SELECT 1 FROM employee_supervisors
      WHERE manager_id = v_user_id
        AND employee_supervisors.employee_id = v_shift_employee_id
        AND effective_to IS NULL
    ) THEN
      RETURN;
    END IF;
  END IF;

  RETURN QUERY
  SELECT gp.id, gp.latitude, gp.longitude, gp.accuracy, gp.captured_at
  FROM gps_points gp
  WHERE gp.shift_id = p_shift_id
  ORDER BY gp.captured_at ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

---

## Function 2: get_employee_shift_history

### Purpose
Retrieve completed shifts for an employee within a date range, including summary statistics for history list view.

### Signature

```sql
CREATE OR REPLACE FUNCTION get_employee_shift_history(
  p_employee_id UUID,
  p_start_date DATE,
  p_end_date DATE
)
RETURNS TABLE (
  id UUID,
  employee_id UUID,
  employee_name TEXT,
  clocked_in_at TIMESTAMPTZ,
  clocked_out_at TIMESTAMPTZ,
  duration_minutes INTEGER,
  gps_point_count BIGINT,
  total_distance_km DECIMAL(10, 3),
  clock_in_latitude DECIMAL(10, 8),
  clock_in_longitude DECIMAL(11, 8),
  clock_out_latitude DECIMAL(10, 8),
  clock_out_longitude DECIMAL(11, 8)
)
```

### Parameters

| Name | Type | Required | Validation |
|------|------|----------|------------|
| p_employee_id | UUID | Yes | Must exist in employee_profiles |
| p_start_date | DATE | Yes | Must be within 90 days of today |
| p_end_date | DATE | Yes | Must be >= p_start_date |

### Return Columns

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | UUID | No | Shift identifier |
| employee_id | UUID | No | Employee identifier |
| employee_name | TEXT | Yes | Employee full name |
| clocked_in_at | TIMESTAMPTZ | No | Shift start time |
| clocked_out_at | TIMESTAMPTZ | No | Shift end time |
| duration_minutes | INTEGER | No | Duration in minutes |
| gps_point_count | BIGINT | No | Number of GPS points |
| total_distance_km | DECIMAL | Yes | Calculated total distance |
| clock_in_latitude | DECIMAL | Yes | Start location lat |
| clock_in_longitude | DECIMAL | Yes | Start location lon |
| clock_out_latitude | DECIMAL | Yes | End location lat |
| clock_out_longitude | DECIMAL | Yes | End location lon |

### Authorization Rules

Same as Function 1 (supervisor or admin/super_admin)

### Business Rules

1. Only returns completed shifts (status = 'completed')
2. Shifts within p_start_date to p_end_date (inclusive)
3. Date range must be within 90-day retention period
4. Ordered by clocked_in_at DESC (most recent first)

### SQL Implementation

```sql
CREATE OR REPLACE FUNCTION get_employee_shift_history(
  p_employee_id UUID,
  p_start_date DATE,
  p_end_date DATE
)
RETURNS TABLE (
  id UUID,
  employee_id UUID,
  employee_name TEXT,
  clocked_in_at TIMESTAMPTZ,
  clocked_out_at TIMESTAMPTZ,
  duration_minutes INTEGER,
  gps_point_count BIGINT,
  total_distance_km DECIMAL(10, 3),
  clock_in_latitude DECIMAL(10, 8),
  clock_in_longitude DECIMAL(11, 8),
  clock_out_latitude DECIMAL(10, 8),
  clock_out_longitude DECIMAL(11, 8)
) AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_user_role TEXT;
BEGIN
  -- Validate date range is within retention period
  IF p_start_date < (CURRENT_DATE - INTERVAL '90 days')::DATE THEN
    RETURN;
  END IF;

  -- Get caller's role
  SELECT role INTO v_user_role
  FROM employee_profiles
  WHERE employee_profiles.id = v_user_id;

  -- Check authorization
  IF v_user_role NOT IN ('admin', 'super_admin') THEN
    IF NOT EXISTS (
      SELECT 1 FROM employee_supervisors
      WHERE manager_id = v_user_id
        AND employee_supervisors.employee_id = p_employee_id
        AND effective_to IS NULL
    ) THEN
      RETURN;
    END IF;
  END IF;

  RETURN QUERY
  SELECT
    s.id,
    s.employee_id,
    ep.full_name AS employee_name,
    s.clocked_in_at,
    s.clocked_out_at,
    EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at))::INTEGER / 60 AS duration_minutes,
    (SELECT COUNT(*) FROM gps_points WHERE gps_points.shift_id = s.id) AS gps_point_count,
    NULL::DECIMAL(10, 3) AS total_distance_km, -- Calculated client-side
    (s.clock_in_location->>'latitude')::DECIMAL(10, 8) AS clock_in_latitude,
    (s.clock_in_location->>'longitude')::DECIMAL(11, 8) AS clock_in_longitude,
    (s.clock_out_location->>'latitude')::DECIMAL(10, 8) AS clock_out_latitude,
    (s.clock_out_location->>'longitude')::DECIMAL(11, 8) AS clock_out_longitude
  FROM shifts s
  JOIN employee_profiles ep ON ep.id = s.employee_id
  WHERE s.employee_id = p_employee_id
    AND s.status = 'completed'
    AND s.clocked_in_at::DATE >= p_start_date
    AND s.clocked_in_at::DATE <= p_end_date
  ORDER BY s.clocked_in_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

---

## Function 3: get_multi_shift_trails

### Purpose
Retrieve GPS trails for multiple shifts in a single query, with shift identification for multi-shift map visualization.

### Signature

```sql
CREATE OR REPLACE FUNCTION get_multi_shift_trails(
  p_shift_ids UUID[]
)
RETURNS TABLE (
  id UUID,
  shift_id UUID,
  shift_date DATE,
  latitude DECIMAL(10, 8),
  longitude DECIMAL(11, 8),
  accuracy DECIMAL(8, 2),
  captured_at TIMESTAMPTZ
)
```

### Parameters

| Name | Type | Required | Validation |
|------|------|----------|------------|
| p_shift_ids | UUID[] | Yes | Array of 1-10 valid shift IDs |

### Return Columns

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | UUID | No | GPS point identifier |
| shift_id | UUID | No | Parent shift identifier |
| shift_date | DATE | No | Date of the shift |
| latitude | DECIMAL(10,8) | No | Latitude coordinate |
| longitude | DECIMAL(11,8) | No | Longitude coordinate |
| accuracy | DECIMAL(8,2) | Yes | GPS accuracy in meters |
| captured_at | TIMESTAMPTZ | No | Capture timestamp |

### Authorization Rules

1. All shifts in array must belong to supervised employees
2. If any shift is unauthorized, it is excluded from results (not an error)

### Business Rules

1. Maximum 10 shifts per request
2. All shifts must be within 90-day retention period
3. Points ordered by shift_id, then captured_at ASC

### SQL Implementation

```sql
CREATE OR REPLACE FUNCTION get_multi_shift_trails(
  p_shift_ids UUID[]
)
RETURNS TABLE (
  id UUID,
  shift_id UUID,
  shift_date DATE,
  latitude DECIMAL(10, 8),
  longitude DECIMAL(11, 8),
  accuracy DECIMAL(8, 2),
  captured_at TIMESTAMPTZ
) AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_user_role TEXT;
  v_authorized_shift_ids UUID[];
BEGIN
  -- Limit to 10 shifts
  IF array_length(p_shift_ids, 1) > 10 THEN
    RAISE EXCEPTION 'Maximum 10 shifts allowed per request';
  END IF;

  -- Get caller's role
  SELECT role INTO v_user_role
  FROM employee_profiles
  WHERE employee_profiles.id = v_user_id;

  -- Build list of authorized shift IDs
  IF v_user_role IN ('admin', 'super_admin') THEN
    -- Admin: all shifts within retention period
    SELECT array_agg(s.id) INTO v_authorized_shift_ids
    FROM shifts s
    WHERE s.id = ANY(p_shift_ids)
      AND s.clocked_in_at >= NOW() - INTERVAL '90 days';
  ELSE
    -- Supervisor: only supervised employee shifts
    SELECT array_agg(s.id) INTO v_authorized_shift_ids
    FROM shifts s
    WHERE s.id = ANY(p_shift_ids)
      AND s.clocked_in_at >= NOW() - INTERVAL '90 days'
      AND EXISTS (
        SELECT 1 FROM employee_supervisors es
        WHERE es.manager_id = v_user_id
          AND es.employee_id = s.employee_id
          AND es.effective_to IS NULL
      );
  END IF;

  -- Return empty if no authorized shifts
  IF v_authorized_shift_ids IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    gp.id,
    gp.shift_id,
    s.clocked_in_at::DATE AS shift_date,
    gp.latitude,
    gp.longitude,
    gp.accuracy,
    gp.captured_at
  FROM gps_points gp
  JOIN shifts s ON s.id = gp.shift_id
  WHERE gp.shift_id = ANY(v_authorized_shift_ids)
  ORDER BY gp.shift_id, gp.captured_at ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

---

## Function 4: get_supervised_employees_list

### Purpose
Get list of employees supervised by the caller for the shift history filter dropdown.

### Signature

```sql
CREATE OR REPLACE FUNCTION get_supervised_employees_list()
RETURNS TABLE (
  id UUID,
  full_name TEXT,
  employee_id TEXT
)
```

### Parameters

None (uses caller's auth.uid())

### Return Columns

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | UUID | No | Employee identifier |
| full_name | TEXT | Yes | Employee full name |
| employee_id | TEXT | Yes | Employee ID code |

### SQL Implementation

```sql
CREATE OR REPLACE FUNCTION get_supervised_employees_list()
RETURNS TABLE (
  id UUID,
  full_name TEXT,
  employee_id TEXT
) AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_user_role TEXT;
BEGIN
  -- Get caller's role
  SELECT role INTO v_user_role
  FROM employee_profiles
  WHERE employee_profiles.id = v_user_id;

  IF v_user_role IN ('admin', 'super_admin') THEN
    -- Admin: all active employees
    RETURN QUERY
    SELECT ep.id, ep.full_name, ep.employee_id
    FROM employee_profiles ep
    WHERE ep.status = 'active'
    ORDER BY ep.full_name;
  ELSE
    -- Supervisor: only supervised employees
    RETURN QUERY
    SELECT ep.id, ep.full_name, ep.employee_id
    FROM employee_profiles ep
    JOIN employee_supervisors es ON es.employee_id = ep.id
    WHERE es.manager_id = v_user_id
      AND es.effective_to IS NULL
      AND ep.status = 'active'
    ORDER BY ep.full_name;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

---

## Permissions

```sql
-- Grant execute permissions to authenticated users
GRANT EXECUTE ON FUNCTION get_historical_shift_trail TO authenticated;
GRANT EXECUTE ON FUNCTION get_employee_shift_history TO authenticated;
GRANT EXECUTE ON FUNCTION get_multi_shift_trails TO authenticated;
GRANT EXECUTE ON FUNCTION get_supervised_employees_list TO authenticated;
```

---

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Unauthorized shift access | Returns empty result set |
| Shift outside retention period | Returns empty result set |
| Invalid UUID parameter | PostgreSQL error (caught by client) |
| Too many shifts in array | RAISE EXCEPTION with message |

---

## Testing Queries

```sql
-- Test get_historical_shift_trail
SELECT * FROM get_historical_shift_trail('shift-uuid-here');

-- Test get_employee_shift_history
SELECT * FROM get_employee_shift_history(
  'employee-uuid-here',
  CURRENT_DATE - INTERVAL '7 days',
  CURRENT_DATE
);

-- Test get_multi_shift_trails
SELECT * FROM get_multi_shift_trails(
  ARRAY['shift-1-uuid', 'shift-2-uuid']::UUID[]
);

-- Test get_supervised_employees_list
SELECT * FROM get_supervised_employees_list();
```
