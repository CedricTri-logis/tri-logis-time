-- GPS Clock-In Tracker: Shift Monitoring Feature
-- Migration: 012_shift_monitoring
-- Date: 2026-01-15
-- Feature: Real-time shift monitoring for supervisors

-- =============================================================================
-- PART 1: get_monitored_team RPC Function
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1.1 Returns supervised employees with current shift status and latest GPS
-- For managers: returns employees where caller is supervisor
-- For admin/super_admin: returns all employees
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_monitored_team(
  p_search TEXT DEFAULT NULL,
  p_shift_status TEXT DEFAULT 'all'
)
RETURNS TABLE (
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
) AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_user_role TEXT;
BEGIN
  -- Get caller's role
  SELECT role INTO v_user_role FROM employee_profiles WHERE employee_profiles.id = v_user_id;

  RETURN QUERY
  SELECT DISTINCT
    ep.id,
    ep.full_name,
    ep.employee_id,
    CASE WHEN s.id IS NOT NULL THEN 'on-shift'::TEXT ELSE 'off-shift'::TEXT END AS shift_status,
    s.id AS current_shift_id,
    s.clocked_in_at,
    (s.clock_in_location->>'latitude')::DECIMAL AS clock_in_latitude,
    (s.clock_in_location->>'longitude')::DECIMAL AS clock_in_longitude,
    gp.latitude AS latest_latitude,
    gp.longitude AS latest_longitude,
    gp.accuracy AS latest_accuracy,
    gp.captured_at AS latest_captured_at
  FROM employee_profiles ep
  LEFT JOIN LATERAL (
    SELECT shifts.id, shifts.clocked_in_at, shifts.clock_in_location
    FROM shifts
    WHERE shifts.employee_id = ep.id AND shifts.status = 'active'
    LIMIT 1
  ) s ON true
  LEFT JOIN LATERAL (
    SELECT gps_points.latitude, gps_points.longitude, gps_points.accuracy, gps_points.captured_at
    FROM gps_points
    WHERE gps_points.shift_id = s.id
    ORDER BY gps_points.captured_at DESC
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

COMMENT ON FUNCTION get_monitored_team IS 'Returns supervised employees with current shift status and latest GPS location for monitoring dashboard';

-- =============================================================================
-- PART 2: get_shift_detail RPC Function
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 2.1 Returns detailed shift information including GPS point count
-- Authorization: caller must supervise the employee OR be admin/super_admin
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_shift_detail(
  p_shift_id UUID
)
RETURNS TABLE (
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
) AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_user_role TEXT;
  v_shift_employee_id UUID;
BEGIN
  -- Get shift's employee
  SELECT shifts.employee_id INTO v_shift_employee_id
  FROM shifts WHERE shifts.id = p_shift_id;

  -- If shift not found, return empty
  IF v_shift_employee_id IS NULL THEN
    RETURN;
  END IF;

  -- Get caller's role
  SELECT role INTO v_user_role FROM employee_profiles WHERE employee_profiles.id = v_user_id;

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
  SELECT
    s.id,
    s.employee_id,
    ep.full_name AS employee_name,
    s.status,
    s.clocked_in_at,
    s.clocked_out_at,
    (s.clock_in_location->>'latitude')::DECIMAL AS clock_in_latitude,
    (s.clock_in_location->>'longitude')::DECIMAL AS clock_in_longitude,
    s.clock_in_accuracy,
    (s.clock_out_location->>'latitude')::DECIMAL AS clock_out_latitude,
    (s.clock_out_location->>'longitude')::DECIMAL AS clock_out_longitude,
    s.clock_out_accuracy,
    (SELECT COUNT(*) FROM gps_points WHERE gps_points.shift_id = s.id) AS gps_point_count
  FROM shifts s
  JOIN employee_profiles ep ON ep.id = s.employee_id
  WHERE s.id = p_shift_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION get_shift_detail IS 'Returns detailed shift information with GPS point count for shift detail view';

-- =============================================================================
-- PART 3: get_shift_gps_trail RPC Function
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 3.1 Returns GPS points for a specific shift as a trail
-- Authorization: caller must supervise employee OR be admin/super_admin
-- Restriction: Only returns data for active shifts (per spec FR-007)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_shift_gps_trail(
  p_shift_id UUID
)
RETURNS TABLE (
  id UUID,
  latitude DECIMAL,
  longitude DECIMAL,
  accuracy DECIMAL,
  captured_at TIMESTAMPTZ
) AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_user_role TEXT;
  v_shift_employee_id UUID;
  v_shift_status TEXT;
BEGIN
  -- Get shift details
  SELECT shifts.employee_id, shifts.status
  INTO v_shift_employee_id, v_shift_status
  FROM shifts WHERE shifts.id = p_shift_id;

  -- If shift not found, return empty
  IF v_shift_employee_id IS NULL THEN
    RETURN;
  END IF;

  -- Only return trail for active shifts (per spec FR-007)
  IF v_shift_status != 'active' THEN
    RETURN;
  END IF;

  -- Get caller's role
  SELECT role INTO v_user_role FROM employee_profiles WHERE employee_profiles.id = v_user_id;

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

COMMENT ON FUNCTION get_shift_gps_trail IS 'Returns GPS trail points for active shifts only (completed shifts return empty per spec FR-007)';

-- =============================================================================
-- PART 4: get_employee_current_shift RPC Function
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 4.1 Returns current shift for a specific employee (for detail page)
-- Authorization: caller must supervise employee OR be admin/super_admin
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_employee_current_shift(
  p_employee_id UUID
)
RETURNS TABLE (
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
) AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_user_role TEXT;
BEGIN
  -- Get caller's role
  SELECT role INTO v_user_role FROM employee_profiles WHERE employee_profiles.id = v_user_id;

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
    s.id AS shift_id,
    s.clocked_in_at,
    (s.clock_in_location->>'latitude')::DECIMAL AS clock_in_latitude,
    (s.clock_in_location->>'longitude')::DECIMAL AS clock_in_longitude,
    s.clock_in_accuracy,
    (SELECT COUNT(*) FROM gps_points WHERE gps_points.shift_id = s.id) AS gps_point_count,
    gp.latitude AS latest_latitude,
    gp.longitude AS latest_longitude,
    gp.accuracy AS latest_accuracy,
    gp.captured_at AS latest_captured_at
  FROM shifts s
  LEFT JOIN LATERAL (
    SELECT gps_points.latitude, gps_points.longitude, gps_points.accuracy, gps_points.captured_at
    FROM gps_points
    WHERE gps_points.shift_id = s.id
    ORDER BY gps_points.captured_at DESC
    LIMIT 1
  ) gp ON true
  WHERE s.employee_id = p_employee_id
    AND s.status = 'active';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION get_employee_current_shift IS 'Returns current active shift for an employee with latest GPS location';

-- =============================================================================
-- PART 5: Grant Permissions
-- =============================================================================

GRANT EXECUTE ON FUNCTION get_monitored_team TO authenticated;
GRANT EXECUTE ON FUNCTION get_shift_detail TO authenticated;
GRANT EXECUTE ON FUNCTION get_shift_gps_trail TO authenticated;
GRANT EXECUTE ON FUNCTION get_employee_current_shift TO authenticated;
