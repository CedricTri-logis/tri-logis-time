# RPC Functions: Shift Monitoring

**Feature Branch**: `011-shift-monitoring`
**Created**: 2026-01-15

## Overview

New PostgreSQL RPC functions for shift monitoring data access. These extend existing patterns from employee management and dashboard features.

---

## get_monitored_team

Returns supervised employees with current shift status and latest GPS location.

### Signature

```sql
get_monitored_team(
  p_search TEXT DEFAULT NULL,
  p_shift_status TEXT DEFAULT 'all'
) RETURNS TABLE (
  id UUID,
  full_name TEXT,
  employee_id TEXT,
  shift_status TEXT,
  current_shift_id UUID,
  clocked_in_at TIMESTAMPTZ,
  clock_in_latitude DECIMAL,
  clock_in_longitude DECIMAL,
  latest_latitude DECIMAL,
  latest_longitude DECIMAL,
  latest_accuracy DECIMAL,
  latest_captured_at TIMESTAMPTZ
)
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| p_search | TEXT | No | Search term for employee name or ID |
| p_shift_status | TEXT | No | Filter: 'all', 'on-shift', 'off-shift' (default: 'all') |

### Response Fields

| Field | Type | Description |
|-------|------|-------------|
| id | UUID | Employee profile ID |
| full_name | TEXT | Employee display name |
| employee_id | TEXT | Company employee ID |
| shift_status | TEXT | 'on-shift' or 'off-shift' |
| current_shift_id | UUID | Active shift ID (null if off-shift) |
| clocked_in_at | TIMESTAMPTZ | Active shift start time |
| clock_in_latitude | DECIMAL | Latitude at clock-in |
| clock_in_longitude | DECIMAL | Longitude at clock-in |
| latest_latitude | DECIMAL | Most recent GPS latitude |
| latest_longitude | DECIMAL | Most recent GPS longitude |
| latest_accuracy | DECIMAL | GPS accuracy in meters |
| latest_captured_at | TIMESTAMPTZ | Timestamp of latest GPS point |

### Access Control

- **Managers**: Returns employees where caller is supervisor (via employee_supervisors)
- **Admin/Super Admin**: Returns all employees
- Uses `auth.uid()` to identify caller

### Example Usage

```typescript
const { data, error } = await supabase.rpc('get_monitored_team', {
  p_search: 'john',
  p_shift_status: 'on-shift'
})
```

### Implementation Notes

```sql
CREATE OR REPLACE FUNCTION get_monitored_team(
  p_search TEXT DEFAULT NULL,
  p_shift_status TEXT DEFAULT 'all'
)
RETURNS TABLE (...) AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_user_role TEXT;
BEGIN
  -- Get caller's role
  SELECT role INTO v_user_role FROM employee_profiles WHERE id = v_user_id;

  RETURN QUERY
  SELECT DISTINCT
    ep.id,
    ep.full_name,
    ep.employee_id,
    CASE WHEN s.id IS NOT NULL THEN 'on-shift' ELSE 'off-shift' END,
    s.id AS current_shift_id,
    s.clocked_in_at,
    (s.clock_in_location->>'latitude')::DECIMAL,
    (s.clock_in_location->>'longitude')::DECIMAL,
    gp.latitude,
    gp.longitude,
    gp.accuracy,
    gp.captured_at
  FROM employee_profiles ep
  LEFT JOIN LATERAL (
    SELECT * FROM shifts
    WHERE shifts.employee_id = ep.id AND shifts.status = 'active'
    LIMIT 1
  ) s ON true
  LEFT JOIN LATERAL (
    SELECT * FROM gps_points
    WHERE gps_points.shift_id = s.id
    ORDER BY captured_at DESC
    LIMIT 1
  ) gp ON true
  WHERE
    ep.status = 'active'
    AND (
      v_user_role IN ('admin', 'super_admin')
      OR EXISTS (
        SELECT 1 FROM employee_supervisors es
        WHERE es.manager_id = v_user_id
          AND es.employee_id = ep.id
          AND es.effective_to IS NULL
      )
    )
    AND (p_search IS NULL OR (
      ep.full_name ILIKE '%' || p_search || '%'
      OR ep.employee_id ILIKE '%' || p_search || '%'
    ))
    AND (p_shift_status = 'all' OR (
      (p_shift_status = 'on-shift' AND s.id IS NOT NULL)
      OR (p_shift_status = 'off-shift' AND s.id IS NULL)
    ))
  ORDER BY ep.full_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

---

## get_shift_detail

Returns detailed shift information including GPS point count.

### Signature

```sql
get_shift_detail(
  p_shift_id UUID
) RETURNS TABLE (
  id UUID,
  employee_id UUID,
  employee_name TEXT,
  status TEXT,
  clocked_in_at TIMESTAMPTZ,
  clocked_out_at TIMESTAMPTZ,
  clock_in_latitude DECIMAL,
  clock_in_longitude DECIMAL,
  clock_in_accuracy DECIMAL,
  clock_out_latitude DECIMAL,
  clock_out_longitude DECIMAL,
  clock_out_accuracy DECIMAL,
  gps_point_count BIGINT
)
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| p_shift_id | UUID | Yes | Shift ID to retrieve |

### Response Fields

| Field | Type | Description |
|-------|------|-------------|
| id | UUID | Shift ID |
| employee_id | UUID | Employee profile ID |
| employee_name | TEXT | Employee full name |
| status | TEXT | 'active' or 'completed' |
| clocked_in_at | TIMESTAMPTZ | Shift start time |
| clocked_out_at | TIMESTAMPTZ | Shift end time (null if active) |
| clock_in_latitude | DECIMAL | Latitude at clock-in |
| clock_in_longitude | DECIMAL | Longitude at clock-in |
| clock_in_accuracy | DECIMAL | GPS accuracy at clock-in |
| clock_out_latitude | DECIMAL | Latitude at clock-out |
| clock_out_longitude | DECIMAL | Longitude at clock-out |
| clock_out_accuracy | DECIMAL | GPS accuracy at clock-out |
| gps_point_count | BIGINT | Total GPS points for this shift |

### Access Control

- Caller must supervise the employee OR be admin/super_admin
- Returns empty if unauthorized

### Example Usage

```typescript
const { data, error } = await supabase.rpc('get_shift_detail', {
  p_shift_id: 'uuid-here'
})
```

---

## get_shift_gps_trail

Returns GPS points for a specific shift as a trail.

### Signature

```sql
get_shift_gps_trail(
  p_shift_id UUID
) RETURNS TABLE (
  id UUID,
  latitude DECIMAL,
  longitude DECIMAL,
  accuracy DECIMAL,
  captured_at TIMESTAMPTZ
)
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| p_shift_id | UUID | Yes | Shift ID to get GPS trail for |

### Response Fields

| Field | Type | Description |
|-------|------|-------------|
| id | UUID | GPS point ID |
| latitude | DECIMAL | GPS latitude |
| longitude | DECIMAL | GPS longitude |
| accuracy | DECIMAL | GPS accuracy in meters |
| captured_at | TIMESTAMPTZ | Point capture timestamp |

### Access Control

- Caller must supervise the employee OR be admin/super_admin
- **Additional restriction**: Only returns data for active shifts (per spec FR-007)
- Returns empty for completed shifts or if unauthorized

### Example Usage

```typescript
const { data, error } = await supabase.rpc('get_shift_gps_trail', {
  p_shift_id: 'uuid-here'
})
```

### Implementation Notes

```sql
CREATE OR REPLACE FUNCTION get_shift_gps_trail(
  p_shift_id UUID
)
RETURNS TABLE (...) AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_user_role TEXT;
  v_shift_employee_id UUID;
  v_shift_status TEXT;
BEGIN
  -- Get shift details
  SELECT employee_id, status INTO v_shift_employee_id, v_shift_status
  FROM shifts WHERE id = p_shift_id;

  -- Only return trail for active shifts (per spec)
  IF v_shift_status != 'active' THEN
    RETURN;
  END IF;

  -- Get caller's role
  SELECT role INTO v_user_role FROM employee_profiles WHERE id = v_user_id;

  -- Check authorization
  IF v_user_role NOT IN ('admin', 'super_admin') THEN
    IF NOT EXISTS (
      SELECT 1 FROM employee_supervisors
      WHERE manager_id = v_user_id
        AND employee_id = v_shift_employee_id
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

## get_employee_current_shift

Returns current shift for a specific employee (for detail page).

### Signature

```sql
get_employee_current_shift(
  p_employee_id UUID
) RETURNS TABLE (
  shift_id UUID,
  clocked_in_at TIMESTAMPTZ,
  clock_in_latitude DECIMAL,
  clock_in_longitude DECIMAL,
  clock_in_accuracy DECIMAL,
  gps_point_count BIGINT,
  latest_latitude DECIMAL,
  latest_longitude DECIMAL,
  latest_accuracy DECIMAL,
  latest_captured_at TIMESTAMPTZ
)
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| p_employee_id | UUID | Yes | Employee to get current shift for |

### Access Control

- Caller must supervise the employee OR be admin/super_admin
- Returns empty if unauthorized or no active shift

### Example Usage

```typescript
const { data, error } = await supabase.rpc('get_employee_current_shift', {
  p_employee_id: 'uuid-here'
})
```

---

## Error Handling

All functions return empty result sets (not errors) when:
- User is not authorized to view the data
- Requested resource does not exist
- Filters result in no matches

This follows the pattern of RLS policies where unauthorized access silently returns no data.

## Security Considerations

- All functions use `SECURITY DEFINER` with explicit authorization checks
- Role checks performed via `auth.uid()` and `employee_profiles.role`
- Supervisor relationships verified via `employee_supervisors` table
- GPS trail restricted to active shifts only (privacy protection)
