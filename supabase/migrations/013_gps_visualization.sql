-- Migration: GPS Visualization RPC Functions
-- Spec: 012-gps-visualization
-- Purpose: Historical GPS data access for the manager dashboard

-- Function 1: get_historical_shift_trail
-- Retrieve GPS trail for a completed shift within 90-day retention period
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

-- Function 2: get_employee_shift_history
-- Retrieve completed shifts for an employee with summary statistics
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

-- Function 3: get_multi_shift_trails
-- Retrieve GPS trails for multiple shifts at once (max 10)
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

-- Function 4: get_supervised_employees_list
-- Get list of employees supervised by caller for dropdown
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

-- Grant execute permissions to authenticated users
GRANT EXECUTE ON FUNCTION get_historical_shift_trail TO authenticated;
GRANT EXECUTE ON FUNCTION get_employee_shift_history TO authenticated;
GRANT EXECUTE ON FUNCTION get_multi_shift_trails TO authenticated;
GRANT EXECUTE ON FUNCTION get_supervised_employees_list TO authenticated;
