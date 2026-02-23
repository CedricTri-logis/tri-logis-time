-- Add last shift date and device info to get_monitored_team RPC
-- Shows last shift date, app version, and phone model in monitoring list

-- Drop existing function first (return type changed)
DROP FUNCTION IF EXISTS get_monitored_team(TEXT, TEXT);

CREATE OR REPLACE FUNCTION get_monitored_team(
  p_search TEXT DEFAULT NULL,
  p_shift_status TEXT DEFAULT 'all'
)
RETURNS TABLE (
  id UUID,
  full_name TEXT,
  email TEXT,
  employee_id TEXT,
  shift_status TEXT,
  current_shift_id UUID,
  clocked_in_at TIMESTAMPTZ,
  clock_in_latitude DECIMAL,
  clock_in_longitude DECIMAL,
  latest_latitude DECIMAL,
  latest_longitude DECIMAL,
  latest_accuracy DECIMAL,
  latest_captured_at TIMESTAMPTZ,
  last_shift_at TIMESTAMPTZ,
  device_app_version TEXT,
  device_model TEXT,
  device_platform TEXT
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
    ep.email,
    ep.employee_id,
    CASE WHEN s.id IS NOT NULL THEN 'on-shift'::TEXT ELSE 'off-shift'::TEXT END AS shift_status,
    s.id AS current_shift_id,
    s.clocked_in_at,
    (s.clock_in_location->>'latitude')::DECIMAL AS clock_in_latitude,
    (s.clock_in_location->>'longitude')::DECIMAL AS clock_in_longitude,
    gp.latitude AS latest_latitude,
    gp.longitude AS latest_longitude,
    gp.accuracy AS latest_accuracy,
    gp.captured_at AS latest_captured_at,
    COALESCE(s.clocked_in_at, last_completed.clocked_in_at) AS last_shift_at,
    ep.device_app_version,
    ep.device_model,
    ep.device_platform
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
  LEFT JOIN LATERAL (
    SELECT shifts.clocked_in_at
    FROM shifts
    WHERE shifts.employee_id = ep.id AND shifts.status = 'completed'
    ORDER BY shifts.clocked_in_at DESC
    LIMIT 1
  ) last_completed ON s.id IS NULL
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
      OR ep.email ILIKE '%' || p_search || '%'
    ))
    AND (p_shift_status = 'all' OR (
      (p_shift_status = 'on-shift' AND s.id IS NOT NULL)
      OR (p_shift_status = 'off-shift' AND s.id IS NULL)
    ))
  ORDER BY ep.full_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION get_monitored_team TO authenticated;
