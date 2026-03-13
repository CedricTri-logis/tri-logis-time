-- Add device_os_version to get_monitored_team RPC
-- The column already exists in employee_profiles but was missing from the function return type

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
  clock_in_latitude NUMERIC,
  clock_in_longitude NUMERIC,
  clock_in_location_name TEXT,
  latest_latitude NUMERIC,
  latest_longitude NUMERIC,
  latest_accuracy NUMERIC,
  latest_captured_at TIMESTAMPTZ,
  last_shift_at TIMESTAMPTZ,
  device_app_version TEXT,
  device_model TEXT,
  device_platform TEXT,
  device_os_version TEXT,
  last_sign_in_at TIMESTAMPTZ,
  active_session_type TEXT,
  active_session_location TEXT,
  active_session_started_at TIMESTAMPTZ,
  is_on_lunch BOOLEAN,
  lunch_started_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_user_role TEXT;
BEGIN
  SELECT role INTO v_user_role FROM employee_profiles WHERE employee_profiles.id = v_user_id;

  RETURN QUERY
  SELECT DISTINCT
    ep.id,
    ep.full_name,
    ep.email,
    ep.employee_id,
    CASE
      WHEN s.id IS NOT NULL THEN 'on-shift'::TEXT
      WHEN ep.device_app_version IS NULL THEN 'never-installed'::TEXT
      ELSE 'off-shift'::TEXT
    END AS shift_status,
    s.id AS current_shift_id,
    s.clocked_in_at,
    (s.clock_in_location->>'latitude')::DECIMAL AS clock_in_latitude,
    (s.clock_in_location->>'longitude')::DECIMAL AS clock_in_longitude,
    matched_loc.name AS clock_in_location_name,
    gp.latitude AS latest_latitude,
    gp.longitude AS latest_longitude,
    gp.accuracy AS latest_accuracy,
    gp.captured_at AS latest_captured_at,
    COALESCE(s.clocked_in_at, last_completed.clocked_in_at) AS last_shift_at,
    ep.device_app_version,
    ep.device_model,
    ep.device_platform,
    ep.device_os_version,
    au.last_sign_in_at,
    ws_active.active_session_type AS active_session_type,
    ws_active.active_session_location AS active_session_location,
    ws_active.active_session_started_at AS active_session_started_at,
    (active_lunch.id IS NOT NULL) AS is_on_lunch,
    active_lunch.started_at AS lunch_started_at
  FROM employee_profiles ep
  LEFT JOIN auth.users au ON au.id = ep.id
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
  LEFT JOIN LATERAL (
    SELECT l.name
    FROM locations l
    WHERE l.is_active = true
      AND s.clock_in_location IS NOT NULL
      AND ST_DWithin(
        ST_SetSRID(ST_MakePoint(
          (s.clock_in_location->>'longitude')::DOUBLE PRECISION,
          (s.clock_in_location->>'latitude')::DOUBLE PRECISION
        ), 4326)::geography,
        ST_SetSRID(ST_MakePoint(l.longitude, l.latitude), 4326)::geography,
        l.radius_meters::DOUBLE PRECISION
      )
    ORDER BY ST_Distance(
      ST_SetSRID(ST_MakePoint(
        (s.clock_in_location->>'longitude')::DOUBLE PRECISION,
        (s.clock_in_location->>'latitude')::DOUBLE PRECISION
      ), 4326)::geography,
      ST_SetSRID(ST_MakePoint(l.longitude, l.latitude), 4326)::geography
    )
    LIMIT 1
  ) matched_loc ON s.id IS NOT NULL
  LEFT JOIN LATERAL (
    SELECT
        ws.activity_type::TEXT AS active_session_type,
        CASE
            WHEN ws.activity_type = 'cleaning' THEN
                st.studio_number || E' \u2014 ' || b.name
            WHEN ws.activity_type = 'maintenance' THEN
                CASE WHEN a.unit_number IS NOT NULL
                    THEN pb.name || E' \u2014 ' || a.unit_number
                    ELSE pb.name
                END
            WHEN ws.activity_type = 'admin' THEN 'Administration'
            ELSE ws.activity_type
        END AS active_session_location,
        ws.started_at AS active_session_started_at
    FROM work_sessions ws
    LEFT JOIN studios st ON st.id = ws.studio_id
    LEFT JOIN buildings b ON b.id = st.building_id
    LEFT JOIN property_buildings pb ON pb.id = ws.building_id
    LEFT JOIN apartments a ON a.id = ws.apartment_id
    WHERE ws.employee_id = ep.id AND ws.status = 'in_progress'
    ORDER BY ws.started_at DESC LIMIT 1
  ) ws_active ON true
  LEFT JOIN LATERAL (
    SELECT lb.id, lb.started_at
    FROM lunch_breaks lb
    WHERE lb.shift_id = s.id AND lb.ended_at IS NULL
    LIMIT 1
  ) active_lunch ON s.id IS NOT NULL
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
    AND (
      p_shift_status = 'all'
      OR (p_shift_status = 'on-shift' AND s.id IS NOT NULL)
      OR (p_shift_status = 'off-shift' AND s.id IS NULL AND ep.device_app_version IS NOT NULL)
      OR (p_shift_status = 'never-installed' AND ep.device_app_version IS NULL)
    )
  ORDER BY au.last_sign_in_at DESC NULLS LAST;
END;
$$;
