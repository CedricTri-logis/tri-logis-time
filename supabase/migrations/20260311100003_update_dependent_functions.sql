-- Migration: Update dependent functions to read from work_sessions
-- Task 4 of 20: Unified work_sessions integration
--
-- Updates these functions to use work_sessions alongside (or instead of) legacy tables:
--   1. auto_close_sessions_on_shift_complete (trigger)
--   2. server_close_all_sessions
--   3. _get_project_sessions
--   4. get_team_active_status
--   5. get_monitored_team
--   6. compute_cluster_effective_types

-- ============================================================
-- 1. auto_close_sessions_on_shift_complete
--    Adds work_sessions closure BEFORE existing cleaning/maintenance closures.
--    Keeps Phase 1 legacy closures verbatim for backward compatibility.
-- ============================================================
CREATE OR REPLACE FUNCTION auto_close_sessions_on_shift_complete()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_session RECORD;
  v_rec RECORD;
  v_duration NUMERIC;
  v_flags RECORD;
  v_is_flagged BOOLEAN;
  v_flag_reason TEXT;
BEGIN
  -- Only fire when shift transitions TO completed
  IF NEW.status = 'completed' AND (OLD.status IS DISTINCT FROM 'completed') THEN

    -- ===== NEW: Close work_sessions (unified table) =====
    FOR v_rec IN
      SELECT ws.id, ws.started_at, ws.activity_type, ws.studio_id, s.studio_type
      FROM work_sessions ws
      LEFT JOIN studios s ON s.id = ws.studio_id
      WHERE ws.shift_id = NEW.id AND ws.status = 'in_progress'
    LOOP
      v_duration := EXTRACT(EPOCH FROM (COALESCE(NEW.clocked_out_at, NOW()) - v_rec.started_at)) / 60.0;
      v_is_flagged := false;
      v_flag_reason := NULL;
      IF v_rec.activity_type = 'cleaning' AND v_rec.studio_type IS NOT NULL THEN
        SELECT cf.is_flagged, cf.flag_reason
        INTO v_is_flagged, v_flag_reason
        FROM _compute_cleaning_flags(v_rec.studio_type::studio_type, v_duration) cf;
      END IF;
      UPDATE work_sessions SET
        status = 'auto_closed',
        completed_at = COALESCE(NEW.clocked_out_at, NOW()),
        duration_minutes = ROUND(v_duration, 2),
        is_flagged = v_is_flagged,
        flag_reason = v_flag_reason,
        updated_at = NOW()
      WHERE id = v_rec.id;
    END LOOP;

    -- ===== Phase 1 legacy: Auto-close cleaning sessions =====
    FOR v_session IN
      SELECT cs.id, cs.started_at, s.studio_type
      FROM cleaning_sessions cs
      JOIN studios s ON cs.studio_id = s.id
      WHERE cs.shift_id = NEW.id
        AND cs.employee_id = NEW.employee_id
        AND cs.status = 'in_progress'
    LOOP
      v_duration := EXTRACT(EPOCH FROM (COALESCE(NEW.clocked_out_at, NOW()) - v_session.started_at)) / 60.0;
      SELECT * INTO v_flags FROM _compute_cleaning_flags(v_session.studio_type, v_duration);

      UPDATE cleaning_sessions
      SET status = 'auto_closed',
          completed_at = COALESCE(NEW.clocked_out_at, NOW()),
          duration_minutes = ROUND(v_duration, 2),
          is_flagged = v_flags.is_flagged,
          flag_reason = v_flags.flag_reason,
          updated_at = NOW()
      WHERE id = v_session.id;
    END LOOP;

    -- ===== Phase 1 legacy: Auto-close maintenance sessions =====
    UPDATE maintenance_sessions
    SET status = 'auto_closed',
        completed_at = COALESCE(NEW.clocked_out_at, NOW()),
        duration_minutes = ROUND(EXTRACT(EPOCH FROM (COALESCE(NEW.clocked_out_at, NOW()) - started_at)) / 60.0, 2),
        updated_at = NOW()
    WHERE shift_id = NEW.id
      AND employee_id = NEW.employee_id
      AND status = 'in_progress';

  END IF;

  RETURN NEW;
END;
$function$;


-- ============================================================
-- 2. server_close_all_sessions
--    Adds work_sessions closure BEFORE existing closures.
--    Returns work_sessions_closed count in the result JSON.
-- ============================================================
CREATE OR REPLACE FUNCTION server_close_all_sessions(p_employee_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_work_count INT;
  v_cleaning_closed INT;
  v_maintenance_closed INT;
  v_shifts_closed INT;
  v_lunch_closed INT;
BEGIN
  -- Step 0: Close work_sessions (unified table)
  UPDATE work_sessions
  SET status = 'auto_closed',
      completed_at = now(),
      duration_minutes = ROUND(EXTRACT(EPOCH FROM (now() - started_at)) / 60.0, 2),
      updated_at = now()
  WHERE employee_id = p_employee_id
    AND status = 'in_progress';
  GET DIAGNOSTICS v_work_count = ROW_COUNT;

  -- Step 1: Close active cleaning sessions (Phase 1 legacy)
  UPDATE cleaning_sessions
  SET status = 'auto_closed',
      completed_at = now(),
      duration_minutes = ROUND(EXTRACT(EPOCH FROM (now() - started_at)) / 60.0, 2)
  WHERE employee_id = p_employee_id
    AND status = 'in_progress';
  GET DIAGNOSTICS v_cleaning_closed = ROW_COUNT;

  -- Step 2: Close active maintenance sessions (Phase 1 legacy)
  UPDATE maintenance_sessions
  SET status = 'auto_closed',
      completed_at = now(),
      duration_minutes = ROUND(EXTRACT(EPOCH FROM (now() - started_at)) / 60.0, 2)
  WHERE employee_id = p_employee_id
    AND status = 'in_progress';
  GET DIAGNOSTICS v_maintenance_closed = ROW_COUNT;

  -- Step 3: Close active lunch breaks
  UPDATE lunch_breaks
  SET ended_at = now()
  WHERE employee_id = p_employee_id
    AND ended_at IS NULL;
  GET DIAGNOSTICS v_lunch_closed = ROW_COUNT;

  -- Step 4: Close active shifts (AFTER sessions so trigger finds nothing to double-process)
  UPDATE shifts
  SET status = 'completed',
      clocked_out_at = now(),
      clock_out_reason = 'server_auto_close'
  WHERE employee_id = p_employee_id
    AND status = 'active';
  GET DIAGNOSTICS v_shifts_closed = ROW_COUNT;

  RETURN jsonb_build_object(
    'success', true,
    'shifts_closed', v_shifts_closed,
    'work_sessions_closed', v_work_count,
    'cleaning_closed', v_cleaning_closed,
    'maintenance_closed', v_maintenance_closed,
    'lunch_closed', v_lunch_closed
  );
END;
$function$;


-- ============================================================
-- 3. _get_project_sessions
--    Replace UNION ALL of cleaning_sessions + maintenance_sessions
--    with a single SELECT from work_sessions.
-- ============================================================
CREATE OR REPLACE FUNCTION _get_project_sessions(p_employee_id UUID, p_date DATE)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_ps JSONB;
BEGIN
    WITH raw_sessions AS (
        -- Unified work_sessions table
        SELECT
            ws.activity_type::TEXT AS session_type,
            ws.id AS session_id,
            ws.started_at,
            COALESCE(ws.completed_at, now()) AS ended_at,
            COALESCE(pb.name, b.name) AS building_name,
            COALESCE(a.unit_number, s.studio_number) AS unit_label,
            COALESCE(s.studio_type::TEXT, a.apartment_category) AS unit_type,
            ws.status::TEXT AS session_status,
            COALESCE(pb.location_id, b.location_id) AS location_id
        FROM work_sessions ws
        LEFT JOIN studios s ON s.id = ws.studio_id
        LEFT JOIN buildings b ON b.id = s.building_id
        LEFT JOIN property_buildings pb ON pb.id = ws.building_id
        LEFT JOIN apartments a ON a.id = ws.apartment_id
        WHERE ws.employee_id = p_employee_id
          AND ws.started_at >= p_date::TIMESTAMPTZ
          AND ws.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ

        UNION ALL

        -- Phase 1 legacy: cleaning_sessions (in case not yet migrated)
        SELECT
            'cleaning'::TEXT AS session_type,
            cs.id AS session_id,
            cs.started_at,
            COALESCE(cs.completed_at, now()) AS ended_at,
            b.name AS building_name,
            s.studio_number AS unit_label,
            s.studio_type::TEXT AS unit_type,
            cs.status::TEXT AS session_status,
            b.location_id
        FROM cleaning_sessions cs
        JOIN studios s ON s.id = cs.studio_id
        JOIN buildings b ON b.id = s.building_id
        WHERE cs.employee_id = p_employee_id
          AND cs.started_at >= p_date::TIMESTAMPTZ
          AND cs.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
          -- Exclude if already in work_sessions (via sync trigger)
          AND NOT EXISTS (
              SELECT 1 FROM work_sessions ws2
              WHERE ws2.employee_id = cs.employee_id
                AND ws2.studio_id = cs.studio_id
                AND ws2.started_at = cs.started_at
          )

        UNION ALL

        -- Phase 1 legacy: maintenance_sessions (in case not yet migrated)
        SELECT
            'maintenance'::TEXT,
            ms.id,
            ms.started_at,
            COALESCE(ms.completed_at, now()),
            pb.name,
            a.unit_number,
            COALESCE(a.apartment_category, 'building')::TEXT,
            ms.status::TEXT,
            pb.location_id
        FROM maintenance_sessions ms
        JOIN property_buildings pb ON pb.id = ms.building_id
        LEFT JOIN apartments a ON a.id = ms.apartment_id
        WHERE ms.employee_id = p_employee_id
          AND ms.started_at >= p_date::TIMESTAMPTZ
          AND ms.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
          -- Exclude if already in work_sessions (via sync trigger)
          AND NOT EXISTS (
              SELECT 1 FROM work_sessions ws2
              WHERE ws2.employee_id = ms.employee_id
                AND ws2.building_id = ms.building_id
                AND ws2.started_at = ms.started_at
          )
    ),
    ordered_sessions AS (
        SELECT *,
            LEAD(started_at) OVER (ORDER BY started_at) AS next_start
        FROM raw_sessions
    ),
    trimmed AS (
        SELECT
            session_type, session_id, started_at,
            CASE
                WHEN next_start IS NOT NULL AND next_start < ended_at
                THEN next_start
                ELSE ended_at
            END AS ended_at,
            building_name, unit_label, unit_type, session_status, location_id
        FROM ordered_sessions
    )
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'session_type', t.session_type,
            'session_id', t.session_id,
            'started_at', t.started_at,
            'ended_at', t.ended_at,
            'duration_minutes', ROUND(EXTRACT(EPOCH FROM (t.ended_at - t.started_at)) / 60.0, 2),
            'building_name', t.building_name,
            'unit_label', t.unit_label,
            'unit_type', t.unit_type,
            'session_status', t.session_status,
            'location_id', t.location_id
        )
        ORDER BY t.started_at ASC
    ), '[]'::JSONB)
    INTO v_ps
    FROM trimmed t
    WHERE t.ended_at > t.started_at;

    RETURN v_ps;
END;
$function$;


-- ============================================================
-- 4. get_team_active_status
--    Replace two LATERAL subqueries (active_cleaning + active_maintenance)
--    with a single LATERAL on work_sessions in BOTH branches.
-- ============================================================
CREATE OR REPLACE FUNCTION get_team_active_status()
RETURNS TABLE(
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
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_today_start TIMESTAMPTZ;
    v_month_start TIMESTAMPTZ;
    v_caller_role TEXT;
BEGIN
    v_today_start := date_trunc('day', NOW());
    v_month_start := date_trunc('month', NOW());

    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

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
            ws_active.active_session_type as active_session_type,
            ws_active.active_session_location as active_session_location,
            ws_active.active_session_started_at as active_session_started_at
        FROM employee_profiles ep
        LEFT JOIN LATERAL (
            SELECT true as is_active, s.clocked_in_at, s.id as shift_id
            FROM shifts s
            WHERE s.employee_id = ep.id AND s.status = 'active'
            LIMIT 1
        ) active_shift ON true
        LEFT JOIN LATERAL (
            SELECT gp.captured_at
            FROM gps_points gp
            WHERE gp.shift_id = active_shift.shift_id
            ORDER BY gp.captured_at DESC
            LIMIT 1
        ) latest_gps ON active_shift.shift_id IS NOT NULL
        LEFT JOIN LATERAL (
            SELECT
                ws.activity_type::TEXT AS active_session_type,
                CASE
                    WHEN ws.activity_type = 'cleaning' THEN
                        s.studio_number || ' — ' || b.name
                    WHEN ws.activity_type = 'maintenance' THEN
                        CASE WHEN a.unit_number IS NOT NULL
                            THEN pb.name || ' — ' || a.unit_number
                            ELSE pb.name
                        END
                    WHEN ws.activity_type = 'admin' THEN 'Administration'
                    ELSE ws.activity_type
                END AS active_session_location,
                ws.started_at AS active_session_started_at
            FROM work_sessions ws
            LEFT JOIN studios s ON s.id = ws.studio_id
            LEFT JOIN buildings b ON b.id = s.building_id
            LEFT JOIN property_buildings pb ON pb.id = ws.building_id
            LEFT JOIN apartments a ON a.id = ws.apartment_id
            WHERE ws.employee_id = ep.id AND ws.status = 'in_progress'
            ORDER BY ws.started_at DESC LIMIT 1
        ) ws_active ON true
        LEFT JOIN LATERAL (
            SELECT COALESCE(EXTRACT(EPOCH FROM SUM(COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at))::INT, 0) as total_seconds
            FROM shifts s
            WHERE s.employee_id = ep.id AND s.clocked_in_at >= v_today_start
        ) today_stats ON true
        LEFT JOIN LATERAL (
            SELECT COUNT(*) FILTER (WHERE s.status = 'completed')::INT as shift_count,
                   COALESCE(EXTRACT(EPOCH FROM SUM(CASE WHEN s.status = 'completed' THEN s.clocked_out_at - s.clocked_in_at ELSE INTERVAL '0' END))::INT, 0) as total_seconds
            FROM shifts s
            WHERE s.employee_id = ep.id AND s.clocked_in_at >= v_month_start
        ) month_stats ON true
        WHERE ep.id != (SELECT auth.uid())
        ORDER BY COALESCE(active_shift.is_active, false) DESC, COALESCE(ep.full_name, ep.email);
    ELSE
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
            ws_active.active_session_type as active_session_type,
            ws_active.active_session_location as active_session_location,
            ws_active.active_session_started_at as active_session_started_at
        FROM employee_profiles ep
        INNER JOIN employee_supervisors es ON es.employee_id = ep.id
        LEFT JOIN LATERAL (
            SELECT true as is_active, s.clocked_in_at, s.id as shift_id
            FROM shifts s
            WHERE s.employee_id = ep.id AND s.status = 'active'
            LIMIT 1
        ) active_shift ON true
        LEFT JOIN LATERAL (
            SELECT gp.captured_at
            FROM gps_points gp
            WHERE gp.shift_id = active_shift.shift_id
            ORDER BY gp.captured_at DESC
            LIMIT 1
        ) latest_gps ON active_shift.shift_id IS NOT NULL
        LEFT JOIN LATERAL (
            SELECT
                ws.activity_type::TEXT AS active_session_type,
                CASE
                    WHEN ws.activity_type = 'cleaning' THEN
                        s.studio_number || ' — ' || b.name
                    WHEN ws.activity_type = 'maintenance' THEN
                        CASE WHEN a.unit_number IS NOT NULL
                            THEN pb.name || ' — ' || a.unit_number
                            ELSE pb.name
                        END
                    WHEN ws.activity_type = 'admin' THEN 'Administration'
                    ELSE ws.activity_type
                END AS active_session_location,
                ws.started_at AS active_session_started_at
            FROM work_sessions ws
            LEFT JOIN studios s ON s.id = ws.studio_id
            LEFT JOIN buildings b ON b.id = s.building_id
            LEFT JOIN property_buildings pb ON pb.id = ws.building_id
            LEFT JOIN apartments a ON a.id = ws.apartment_id
            WHERE ws.employee_id = ep.id AND ws.status = 'in_progress'
            ORDER BY ws.started_at DESC LIMIT 1
        ) ws_active ON true
        LEFT JOIN LATERAL (
            SELECT COALESCE(EXTRACT(EPOCH FROM SUM(COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at))::INT, 0) as total_seconds
            FROM shifts s
            WHERE s.employee_id = ep.id AND s.clocked_in_at >= v_today_start
        ) today_stats ON true
        LEFT JOIN LATERAL (
            SELECT COUNT(*) FILTER (WHERE s.status = 'completed')::INT as shift_count,
                   COALESCE(EXTRACT(EPOCH FROM SUM(CASE WHEN s.status = 'completed' THEN s.clocked_out_at - s.clocked_in_at ELSE INTERVAL '0' END))::INT, 0) as total_seconds
            FROM shifts s
            WHERE s.employee_id = ep.id AND s.clocked_in_at >= v_month_start
        ) month_stats ON true
        WHERE es.manager_id = (SELECT auth.uid())
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
        ORDER BY COALESCE(active_shift.is_active, false) DESC, COALESCE(ep.full_name, ep.email);
    END IF;
END;
$function$;


-- ============================================================
-- 5. get_monitored_team
--    Replace two LATERAL subqueries (ac + am) with single LATERAL on work_sessions.
--    Preserves is_on_lunch and lunch_started_at columns.
-- ============================================================
CREATE OR REPLACE FUNCTION get_monitored_team(
    p_search TEXT DEFAULT NULL,
    p_shift_status TEXT DEFAULT 'all'
)
RETURNS TABLE(
    id UUID,
    full_name TEXT,
    email TEXT,
    employee_id TEXT,
    shift_status TEXT,
    current_shift_id UUID,
    clocked_in_at TIMESTAMPTZ,
    clock_in_latitude NUMERIC,
    clock_in_longitude NUMERIC,
    latest_latitude NUMERIC,
    latest_longitude NUMERIC,
    latest_accuracy NUMERIC,
    latest_captured_at TIMESTAMPTZ,
    last_shift_at TIMESTAMPTZ,
    device_app_version TEXT,
    device_model TEXT,
    device_platform TEXT,
    last_sign_in_at TIMESTAMPTZ,
    active_session_type TEXT,
    active_session_location TEXT,
    active_session_started_at TIMESTAMPTZ,
    is_on_lunch BOOLEAN,
    lunch_started_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
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
    gp.latitude AS latest_latitude,
    gp.longitude AS latest_longitude,
    gp.accuracy AS latest_accuracy,
    gp.captured_at AS latest_captured_at,
    COALESCE(s.clocked_in_at, last_completed.clocked_in_at) AS last_shift_at,
    ep.device_app_version,
    ep.device_model,
    ep.device_platform,
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
    SELECT
        ws.activity_type::TEXT AS active_session_type,
        CASE
            WHEN ws.activity_type = 'cleaning' THEN
                st.studio_number || ' — ' || b.name
            WHEN ws.activity_type = 'maintenance' THEN
                CASE WHEN a.unit_number IS NOT NULL
                    THEN pb.name || ' — ' || a.unit_number
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
$function$;


-- ============================================================
-- 6. compute_cluster_effective_types
--    Replace two separate EXISTS on cleaning_sessions + maintenance_sessions
--    with a single EXISTS on work_sessions.
--    Keeps the same CASE priority order; only changes the source tables.
-- ============================================================
CREATE OR REPLACE FUNCTION compute_cluster_effective_types(p_shift_id UUID, p_employee_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
BEGIN
    UPDATE stationary_clusters sc
    SET effective_location_type = CASE
        -- Priority 1: Active work session (cleaning or maintenance) at linked location
        WHEN EXISTS (
            SELECT 1 FROM work_sessions ws
            LEFT JOIN studios s ON s.id = ws.studio_id
            LEFT JOIN buildings b ON b.id = s.building_id
            LEFT JOIN property_buildings pb ON pb.id = ws.building_id
            WHERE COALESCE(pb.location_id, b.location_id) = sc.matched_location_id
              AND ws.employee_id = p_employee_id
              AND ws.shift_id = p_shift_id
              AND ws.started_at < sc.ended_at
              AND (ws.completed_at > sc.started_at OR ws.completed_at IS NULL)
        ) THEN 'building'
        -- Priority 1b (Phase 1 legacy): cleaning_sessions fallback
        WHEN EXISTS (
            SELECT 1 FROM cleaning_sessions cs
            JOIN studios s ON s.id = cs.studio_id
            JOIN buildings b ON b.id = s.building_id
            WHERE b.location_id = sc.matched_location_id
              AND cs.employee_id = p_employee_id
              AND cs.shift_id = p_shift_id
              AND cs.started_at < sc.ended_at
              AND (cs.completed_at > sc.started_at OR cs.completed_at IS NULL)
        ) THEN 'building'
        -- Priority 1c (Phase 1 legacy): maintenance_sessions fallback
        WHEN EXISTS (
            SELECT 1 FROM maintenance_sessions ms
            JOIN property_buildings pb ON pb.id = ms.building_id
            WHERE pb.location_id = sc.matched_location_id
              AND ms.employee_id = p_employee_id
              AND ms.shift_id = p_shift_id
              AND ms.started_at < sc.ended_at
              AND (ms.completed_at > sc.started_at OR ms.completed_at IS NULL)
        ) THEN 'building'
        -- Priority 2: Employee home association
        WHEN EXISTS (
            SELECT 1 FROM locations l
            JOIN employee_home_locations ehl ON ehl.location_id = l.id
            WHERE l.id = sc.matched_location_id
              AND l.is_employee_home = true
              AND ehl.employee_id = p_employee_id
        ) THEN 'home'
        -- Priority 3: Office flag
        WHEN EXISTS (
            SELECT 1 FROM locations l
            WHERE l.id = sc.matched_location_id
              AND l.is_also_office = true
        ) THEN 'office'
        -- Priority 4: Default location type
        ELSE (
            SELECT l.location_type::TEXT FROM locations l
            WHERE l.id = sc.matched_location_id
        )
    END
    WHERE sc.shift_id = p_shift_id
      AND sc.matched_location_id IS NOT NULL;
END;
$function$;
