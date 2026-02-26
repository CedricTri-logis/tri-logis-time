-- Migration: Include clock_in_location in GPS trail results
-- Problem: The dashboard shows GPS points from gps_points table only,
-- but the clock-in GPS point is stored in shifts.clock_in_location (JSONB).
-- When the background service fails to start, the clock-in point never
-- gets synced to gps_points, so the dashboard shows zero points.
--
-- Fix: UNION the clock_in_location from shifts into the trail query,
-- so the clock-in point always appears even if sync failed.

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
  -- Include the clock-in location from the shifts table as the first point.
  -- This ensures at least one point is always visible even if background
  -- tracking never started or sync failed.
  SELECT
    p_shift_id AS id,
    (s.clock_in_location->>'latitude')::DECIMAL(10, 8) AS latitude,
    (s.clock_in_location->>'longitude')::DECIMAL(11, 8) AS longitude,
    s.clock_in_accuracy AS accuracy,
    s.clocked_in_at AS captured_at
  FROM shifts s
  WHERE s.id = p_shift_id
    AND s.clock_in_location IS NOT NULL
    AND s.clock_in_location->>'latitude' IS NOT NULL
    -- Exclude if an identical gps_point already exists at clock-in time
    -- (avoids duplicate if the app successfully synced the clock-in point)
    AND NOT EXISTS (
      SELECT 1 FROM gps_points gp
      WHERE gp.shift_id = p_shift_id
        AND gp.captured_at <= s.clocked_in_at + INTERVAL '5 seconds'
        AND gp.captured_at >= s.clocked_in_at - INTERVAL '5 seconds'
    )

  UNION ALL

  -- All GPS points from background tracking
  SELECT gp.id, gp.latitude, gp.longitude, gp.accuracy, gp.captured_at
  FROM gps_points gp
  WHERE gp.shift_id = p_shift_id

  ORDER BY captured_at ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
