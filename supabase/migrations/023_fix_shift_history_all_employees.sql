-- Fix get_employee_shift_history:
-- 1. Support NULL p_employee_id (all employees mode) - "All Employees" dropdown was broken
-- 2. Add employee_email to return columns

DROP FUNCTION IF EXISTS get_employee_shift_history(UUID, DATE, DATE);

CREATE FUNCTION get_employee_shift_history(
  p_employee_id UUID DEFAULT NULL,
  p_start_date DATE DEFAULT (CURRENT_DATE - INTERVAL '7 days')::DATE,
  p_end_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
  id UUID,
  employee_id UUID,
  employee_name TEXT,
  employee_email TEXT,
  clocked_in_at TIMESTAMPTZ,
  clocked_out_at TIMESTAMPTZ,
  duration_minutes INT,
  gps_point_count INT,
  total_distance_km NUMERIC,
  clock_in_latitude NUMERIC,
  clock_in_longitude NUMERIC,
  clock_out_latitude NUMERIC,
  clock_out_longitude NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_user_role TEXT;
BEGIN
  SELECT ep.role INTO v_user_role FROM employee_profiles ep WHERE ep.id = v_user_id;

  IF p_employee_id IS NOT NULL THEN
    IF p_employee_id = v_user_id THEN
      NULL;
    ELSIF v_user_role = 'admin' THEN
      NULL;
    ELSIF v_user_role = 'manager' THEN
      IF NOT EXISTS (
        SELECT 1 FROM employee_supervisors es
        WHERE es.manager_id = v_user_id
          AND es.employee_id = p_employee_id
          AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
      ) THEN
        RETURN;
      END IF;
    ELSE
      RETURN;
    END IF;

    RETURN QUERY
    SELECT
      s.id, s.employee_id, ep.full_name, ep.email,
      s.clocked_in_at, s.clocked_out_at,
      (EXTRACT(EPOCH FROM (COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at))::INT / 60),
      (SELECT COUNT(*)::INT FROM gps_points gp WHERE gp.shift_id = s.id),
      0::NUMERIC,
      (s.clock_in_location->>'latitude')::NUMERIC,
      (s.clock_in_location->>'longitude')::NUMERIC,
      (s.clock_out_location->>'latitude')::NUMERIC,
      (s.clock_out_location->>'longitude')::NUMERIC
    FROM shifts s
    JOIN employee_profiles ep ON ep.id = s.employee_id
    WHERE s.employee_id = p_employee_id
      AND s.clocked_in_at >= p_start_date
      AND s.clocked_in_at < (p_end_date + INTERVAL '1 day')
      AND s.status = 'completed'
    ORDER BY s.clocked_in_at DESC;

  ELSE
    IF v_user_role = 'admin' THEN
      RETURN QUERY
      SELECT
        s.id, s.employee_id, ep.full_name, ep.email,
        s.clocked_in_at, s.clocked_out_at,
        (EXTRACT(EPOCH FROM (COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at))::INT / 60),
        (SELECT COUNT(*)::INT FROM gps_points gp WHERE gp.shift_id = s.id),
        0::NUMERIC,
        (s.clock_in_location->>'latitude')::NUMERIC,
        (s.clock_in_location->>'longitude')::NUMERIC,
        (s.clock_out_location->>'latitude')::NUMERIC,
        (s.clock_out_location->>'longitude')::NUMERIC
      FROM shifts s
      JOIN employee_profiles ep ON ep.id = s.employee_id
      WHERE s.clocked_in_at >= p_start_date
        AND s.clocked_in_at < (p_end_date + INTERVAL '1 day')
        AND s.status = 'completed'
      ORDER BY s.clocked_in_at DESC;

    ELSIF v_user_role = 'manager' THEN
      RETURN QUERY
      SELECT
        s.id, s.employee_id, ep.full_name, ep.email,
        s.clocked_in_at, s.clocked_out_at,
        (EXTRACT(EPOCH FROM (COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at))::INT / 60),
        (SELECT COUNT(*)::INT FROM gps_points gp WHERE gp.shift_id = s.id),
        0::NUMERIC,
        (s.clock_in_location->>'latitude')::NUMERIC,
        (s.clock_in_location->>'longitude')::NUMERIC,
        (s.clock_out_location->>'latitude')::NUMERIC,
        (s.clock_out_location->>'longitude')::NUMERIC
      FROM shifts s
      JOIN employee_profiles ep ON ep.id = s.employee_id
      INNER JOIN employee_supervisors es ON es.employee_id = s.employee_id
      WHERE es.manager_id = v_user_id
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
        AND s.clocked_in_at >= p_start_date
        AND s.clocked_in_at < (p_end_date + INTERVAL '1 day')
        AND s.status = 'completed'
      ORDER BY s.clocked_in_at DESC;

    ELSE
      RETURN QUERY
      SELECT
        s.id, s.employee_id, ep.full_name, ep.email,
        s.clocked_in_at, s.clocked_out_at,
        (EXTRACT(EPOCH FROM (COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at))::INT / 60),
        (SELECT COUNT(*)::INT FROM gps_points gp WHERE gp.shift_id = s.id),
        0::NUMERIC,
        (s.clock_in_location->>'latitude')::NUMERIC,
        (s.clock_in_location->>'longitude')::NUMERIC,
        (s.clock_out_location->>'latitude')::NUMERIC,
        (s.clock_out_location->>'longitude')::NUMERIC
      FROM shifts s
      JOIN employee_profiles ep ON ep.id = s.employee_id
      WHERE s.employee_id = v_user_id
        AND s.clocked_in_at >= p_start_date
        AND s.clocked_in_at < (p_end_date + INTERVAL '1 day')
        AND s.status = 'completed'
      ORDER BY s.clocked_in_at DESC;
    END IF;
  END IF;
END;
$$;
