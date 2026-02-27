-- Migration 059: Add active session info to team RPCs
-- Shows if an on-shift employee is in a cleaning or maintenance session,
-- and which studio/building they are working in.

-- ============================================================
-- 1. Update get_team_active_status() with session info columns
-- ============================================================

DROP FUNCTION IF EXISTS get_team_active_status();

CREATE OR REPLACE FUNCTION get_team_active_status()
RETURNS TABLE (
    employee_id UUID,
    display_name TEXT,
    email TEXT,
    employee_number TEXT,
    is_active BOOLEAN,
    current_shift_started_at TIMESTAMPTZ,
    today_hours_seconds INT,
    monthly_hours_seconds INT,
    monthly_shift_count INT,
    latest_gps_captured_at TIMESTAMPTZ,
    active_session_type TEXT,
    active_session_location TEXT,
    active_session_started_at TIMESTAMPTZ
) AS $$
DECLARE
    v_today_start TIMESTAMPTZ;
    v_month_start TIMESTAMPTZ;
    v_caller_role TEXT;
BEGIN
    v_today_start := date_trunc('day', NOW());
    v_month_start := date_trunc('month', NOW());

    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Admin/super_admin gets status for ALL employees
    IF v_caller_role IN ('admin', 'super_admin') THEN
        RETURN QUERY
        SELECT
            ep.id as employee_id,
            COALESCE(ep.full_name, ep.email) as display_name,
            ep.email,
            ep.employee_id as employee_number,
            COALESCE(active_shift.is_active, false) as is_active,
            active_shift.clocked_in_at as current_shift_started_at,
            COALESCE(today_stats.total_seconds, 0) as today_hours_seconds,
            COALESCE(month_stats.total_seconds, 0) as monthly_hours_seconds,
            COALESCE(month_stats.shift_count, 0) as monthly_shift_count,
            latest_gps.captured_at as latest_gps_captured_at,
            COALESCE(active_cleaning.session_type, active_maintenance.session_type) as active_session_type,
            COALESCE(active_cleaning.session_location, active_maintenance.session_location) as active_session_location,
            COALESCE(active_cleaning.started_at, active_maintenance.started_at) as active_session_started_at
        FROM employee_profiles ep
        -- Active shift subquery
        LEFT JOIN LATERAL (
            SELECT
                true as is_active,
                s.clocked_in_at,
                s.id as shift_id
            FROM shifts s
            WHERE s.employee_id = ep.id AND s.status = 'active'
            LIMIT 1
        ) active_shift ON true
        -- Latest GPS point for active shift
        LEFT JOIN LATERAL (
            SELECT gp.captured_at
            FROM gps_points gp
            WHERE gp.shift_id = active_shift.shift_id
            ORDER BY gp.captured_at DESC
            LIMIT 1
        ) latest_gps ON active_shift.shift_id IS NOT NULL
        -- Active cleaning session
        LEFT JOIN LATERAL (
            SELECT
                'cleaning'::TEXT AS session_type,
                st.studio_number || ' — ' || b.name AS session_location,
                cs.started_at
            FROM cleaning_sessions cs
            JOIN studios st ON cs.studio_id = st.id
            JOIN buildings b ON st.building_id = b.id
            WHERE cs.employee_id = ep.id AND cs.status = 'in_progress'
            LIMIT 1
        ) active_cleaning ON true
        -- Active maintenance session
        LEFT JOIN LATERAL (
            SELECT
                'maintenance'::TEXT AS session_type,
                pb.name || COALESCE(' (Apt ' || a.unit_number || ')', '') AS session_location,
                ms.started_at
            FROM maintenance_sessions ms
            JOIN property_buildings pb ON ms.building_id = pb.id
            LEFT JOIN apartments a ON ms.apartment_id = a.id
            WHERE ms.employee_id = ep.id AND ms.status = 'in_progress'
            LIMIT 1
        ) active_maintenance ON true
        -- Today's shift stats
        LEFT JOIN LATERAL (
            SELECT
                COALESCE(
                    EXTRACT(EPOCH FROM SUM(
                        COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at
                    ))::INT, 0
                ) as total_seconds
            FROM shifts s
            WHERE s.employee_id = ep.id
            AND s.clocked_in_at >= v_today_start
        ) today_stats ON true
        -- Monthly stats
        LEFT JOIN LATERAL (
            SELECT
                COUNT(*) FILTER (WHERE s.status = 'completed')::INT as shift_count,
                COALESCE(
                    EXTRACT(EPOCH FROM SUM(
                        CASE WHEN s.status = 'completed'
                        THEN s.clocked_out_at - s.clocked_in_at
                        ELSE INTERVAL '0' END
                    ))::INT, 0
                ) as total_seconds
            FROM shifts s
            WHERE s.employee_id = ep.id
            AND s.clocked_in_at >= v_month_start
        ) month_stats ON true
        WHERE ep.id != (SELECT auth.uid())
        ORDER BY
            COALESCE(active_shift.is_active, false) DESC,
            COALESCE(ep.full_name, ep.email);
    ELSE
        -- Regular manager logic (supervised employees only)
        RETURN QUERY
        SELECT
            ep.id as employee_id,
            COALESCE(ep.full_name, ep.email) as display_name,
            ep.email,
            ep.employee_id as employee_number,
            COALESCE(active_shift.is_active, false) as is_active,
            active_shift.clocked_in_at as current_shift_started_at,
            COALESCE(today_stats.total_seconds, 0) as today_hours_seconds,
            COALESCE(month_stats.total_seconds, 0) as monthly_hours_seconds,
            COALESCE(month_stats.shift_count, 0) as monthly_shift_count,
            latest_gps.captured_at as latest_gps_captured_at,
            COALESCE(active_cleaning.session_type, active_maintenance.session_type) as active_session_type,
            COALESCE(active_cleaning.session_location, active_maintenance.session_location) as active_session_location,
            COALESCE(active_cleaning.started_at, active_maintenance.started_at) as active_session_started_at
        FROM employee_profiles ep
        INNER JOIN employee_supervisors es ON es.employee_id = ep.id
        -- Active shift subquery
        LEFT JOIN LATERAL (
            SELECT
                true as is_active,
                s.clocked_in_at,
                s.id as shift_id
            FROM shifts s
            WHERE s.employee_id = ep.id AND s.status = 'active'
            LIMIT 1
        ) active_shift ON true
        -- Latest GPS point for active shift
        LEFT JOIN LATERAL (
            SELECT gp.captured_at
            FROM gps_points gp
            WHERE gp.shift_id = active_shift.shift_id
            ORDER BY gp.captured_at DESC
            LIMIT 1
        ) latest_gps ON active_shift.shift_id IS NOT NULL
        -- Active cleaning session
        LEFT JOIN LATERAL (
            SELECT
                'cleaning'::TEXT AS session_type,
                st.studio_number || ' — ' || b.name AS session_location,
                cs.started_at
            FROM cleaning_sessions cs
            JOIN studios st ON cs.studio_id = st.id
            JOIN buildings b ON st.building_id = b.id
            WHERE cs.employee_id = ep.id AND cs.status = 'in_progress'
            LIMIT 1
        ) active_cleaning ON true
        -- Active maintenance session
        LEFT JOIN LATERAL (
            SELECT
                'maintenance'::TEXT AS session_type,
                pb.name || COALESCE(' (Apt ' || a.unit_number || ')', '') AS session_location,
                ms.started_at
            FROM maintenance_sessions ms
            JOIN property_buildings pb ON ms.building_id = pb.id
            LEFT JOIN apartments a ON ms.apartment_id = a.id
            WHERE ms.employee_id = ep.id AND ms.status = 'in_progress'
            LIMIT 1
        ) active_maintenance ON true
        -- Today's shift stats
        LEFT JOIN LATERAL (
            SELECT
                COALESCE(
                    EXTRACT(EPOCH FROM SUM(
                        COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at
                    ))::INT, 0
                ) as total_seconds
            FROM shifts s
            WHERE s.employee_id = ep.id
            AND s.clocked_in_at >= v_today_start
        ) today_stats ON true
        -- Monthly stats
        LEFT JOIN LATERAL (
            SELECT
                COUNT(*) FILTER (WHERE s.status = 'completed')::INT as shift_count,
                COALESCE(
                    EXTRACT(EPOCH FROM SUM(
                        CASE WHEN s.status = 'completed'
                        THEN s.clocked_out_at - s.clocked_in_at
                        ELSE INTERVAL '0' END
                    ))::INT, 0
                ) as total_seconds
            FROM shifts s
            WHERE s.employee_id = ep.id
            AND s.clocked_in_at >= v_month_start
        ) month_stats ON true
        WHERE es.manager_id = (SELECT auth.uid())
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
        ORDER BY
            COALESCE(active_shift.is_active, false) DESC,
            COALESCE(ep.full_name, ep.email);
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 2. Update get_monitored_team() with session info columns
-- ============================================================

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
  device_platform TEXT,
  last_sign_in_at TIMESTAMPTZ,
  active_session_type TEXT,
  active_session_location TEXT,
  active_session_started_at TIMESTAMPTZ
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
    CASE
      WHEN s.id IS NOT NULL THEN 'on-shift'::TEXT
      WHEN ep.device_app_version IS NULL THEN 'never-installed'::TEXT
      ELSE 'off-shift'::TEXT
    END AS shift_status,
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
    ep.device_platform,
    au.last_sign_in_at,
    COALESCE(ac.session_type, am.session_type) AS active_session_type,
    COALESCE(ac.session_location, am.session_location) AS active_session_location,
    COALESCE(ac.started_at, am.started_at) AS active_session_started_at
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
  -- Active cleaning session
  LEFT JOIN LATERAL (
    SELECT
      'cleaning'::TEXT AS session_type,
      st.studio_number || ' — ' || b.name AS session_location,
      cs.started_at
    FROM cleaning_sessions cs
    JOIN studios st ON cs.studio_id = st.id
    JOIN buildings b ON st.building_id = b.id
    WHERE cs.employee_id = ep.id AND cs.status = 'in_progress'
    LIMIT 1
  ) ac ON true
  -- Active maintenance session
  LEFT JOIN LATERAL (
    SELECT
      'maintenance'::TEXT AS session_type,
      pb.name || COALESCE(' (Apt ' || a.unit_number || ')', '') AS session_location,
      ms.started_at
    FROM maintenance_sessions ms
    JOIN property_buildings pb ON ms.building_id = pb.id
    LEFT JOIN apartments a ON ms.apartment_id = a.id
    WHERE ms.employee_id = ep.id AND ms.status = 'in_progress'
    LIMIT 1
  ) am ON true
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION get_monitored_team TO authenticated;
