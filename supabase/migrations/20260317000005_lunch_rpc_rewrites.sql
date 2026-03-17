-- ============================================================
-- Rewrite 4 RPCs for lunch shift-split model
--
-- Context: lunch_breaks table replaced by shift segments with
-- is_lunch=true and shared work_body_id. All references to
-- lunch_breaks are replaced with queries on shifts.
--
-- 1. save_activity_override: reject lunch overrides
-- 2. get_monitored_team: use s.is_lunch instead of lunch_breaks
-- 3. get_weekly_approval_summary: replace lunch_breaks refs
-- 4. _get_day_approval_detail_base: full rewrite for shift-split
-- ============================================================

-- ============================================================
-- 1. save_activity_override — add lunch guard
-- ============================================================
CREATE OR REPLACE FUNCTION save_activity_override(
    p_employee_id UUID,
    p_date DATE,
    p_activity_type TEXT,
    p_activity_id UUID,
    p_status TEXT,
    p_reason TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
    v_day_approval_id UUID;
    v_result JSONB;
BEGIN
    -- Lunch activities cannot be overridden
    IF p_activity_type = 'lunch' THEN
        RAISE EXCEPTION 'Lunch activities cannot be overridden';
    END IF;

    -- Auth check
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can save overrides';
    END IF;

    -- Validate override status
    IF p_status NOT IN ('approved', 'rejected') THEN
        RAISE EXCEPTION 'Override status must be approved or rejected';
    END IF;

    -- Validate activity type (now includes stop_segment + lunch types)
    IF p_activity_type NOT IN ('trip', 'stop', 'clock_in', 'clock_out', 'gap', 'lunch_start', 'lunch_end', 'lunch', 'stop_segment') THEN
        RAISE EXCEPTION 'Invalid activity type: %', p_activity_type;
    END IF;

    -- Get or create day_approval
    INSERT INTO day_approvals (employee_id, date, status)
    VALUES (p_employee_id, p_date, 'pending')
    ON CONFLICT (employee_id, date) DO NOTHING;

    SELECT id INTO v_day_approval_id
    FROM day_approvals
    WHERE employee_id = p_employee_id AND date = p_date;

    -- Cannot override on approved days
    IF (SELECT status FROM day_approvals WHERE id = v_day_approval_id) = 'approved' THEN
        RAISE EXCEPTION 'Cannot modify overrides on an approved day';
    END IF;

    -- Upsert override
    INSERT INTO activity_overrides (day_approval_id, activity_type, activity_id, override_status, reason, created_by)
    VALUES (v_day_approval_id, p_activity_type, p_activity_id, p_status, p_reason, v_caller)
    ON CONFLICT (day_approval_id, activity_type, activity_id)
    DO UPDATE SET
        override_status = EXCLUDED.override_status,
        reason = EXCLUDED.reason,
        created_by = EXCLUDED.created_by,
        created_at = now();

    -- Return updated day detail
    SELECT get_day_approval_detail(p_employee_id, p_date) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- ============================================================
-- 2. get_monitored_team — replace lunch_breaks with is_lunch
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
    -- When on lunch, show the original clock-in from the first work segment
    COALESCE(s_orig.clocked_in_at, s.clocked_in_at) AS clocked_in_at,
    COALESCE(
      (s_orig.clock_in_location->>'latitude')::DECIMAL,
      (s.clock_in_location->>'latitude')::DECIMAL
    ) AS clock_in_latitude,
    COALESCE(
      (s_orig.clock_in_location->>'longitude')::DECIMAL,
      (s.clock_in_location->>'longitude')::DECIMAL
    ) AS clock_in_longitude,
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
    COALESCE(s.is_lunch, false) AS is_on_lunch,
    CASE WHEN s.is_lunch THEN s.clocked_in_at ELSE NULL END AS lunch_started_at
  FROM employee_profiles ep
  LEFT JOIN auth.users au ON au.id = ep.id
  -- Active shift (could be a lunch segment)
  LEFT JOIN LATERAL (
    SELECT shifts.id, shifts.clocked_in_at, shifts.clock_in_location, shifts.is_lunch, shifts.work_body_id
    FROM shifts
    WHERE shifts.employee_id = ep.id AND shifts.status = 'active'
    LIMIT 1
  ) s ON true
  -- Original work segment (first segment with same work_body_id, when on lunch)
  LEFT JOIN LATERAL (
    SELECT shifts.clocked_in_at, shifts.clock_in_location
    FROM shifts
    WHERE s.is_lunch = true
      AND s.work_body_id IS NOT NULL
      AND shifts.work_body_id = s.work_body_id
      AND shifts.is_lunch = false
    ORDER BY shifts.clocked_in_at ASC
    LIMIT 1
  ) s_orig ON s.is_lunch = true
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
  -- Location matching uses COALESCE'd location (original when on lunch)
  LEFT JOIN LATERAL (
    SELECT l.name
    FROM locations l
    WHERE l.is_active = true
      AND COALESCE(s_orig.clock_in_location, s.clock_in_location) IS NOT NULL
      AND ST_DWithin(
        ST_SetSRID(ST_MakePoint(
          (COALESCE(s_orig.clock_in_location, s.clock_in_location)->>'longitude')::DOUBLE PRECISION,
          (COALESCE(s_orig.clock_in_location, s.clock_in_location)->>'latitude')::DOUBLE PRECISION
        ), 4326)::geography,
        ST_SetSRID(ST_MakePoint(l.longitude, l.latitude), 4326)::geography,
        l.radius_meters::DOUBLE PRECISION
      )
    ORDER BY ST_Distance(
      ST_SetSRID(ST_MakePoint(
        (COALESCE(s_orig.clock_in_location, s.clock_in_location)->>'longitude')::DOUBLE PRECISION,
        (COALESCE(s_orig.clock_in_location, s.clock_in_location)->>'latitude')::DOUBLE PRECISION
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


-- ============================================================
-- 3. get_weekly_approval_summary — replace lunch_breaks refs
-- ============================================================
CREATE OR REPLACE FUNCTION get_weekly_approval_summary(
    p_week_start DATE
)
RETURNS JSONB AS $$
DECLARE
    v_week_end DATE := p_week_start + INTERVAL '6 days';
    v_result JSONB;
BEGIN
    IF EXTRACT(ISODOW FROM p_week_start) != 1 THEN
        RAISE EXCEPTION 'p_week_start must be a Monday, got %', p_week_start;
    END IF;

    WITH employee_list AS (
        SELECT ep.id AS employee_id, ep.full_name AS employee_name
        FROM employee_profiles ep
        WHERE ep.status = 'active'
        ORDER BY ep.full_name
    ),
    -- Shift duration excludes lunch segments
    day_shifts AS (
        SELECT
            s.employee_id,
            s.clocked_in_at::DATE AS shift_date,
            SUM(EXTRACT(EPOCH FROM (COALESCE(est.effective_clocked_out_at, s.clocked_out_at) - est.effective_clocked_in_at)) / 60)::INTEGER AS total_shift_minutes,
            bool_or(s.status = 'active') AS has_active_shift
        FROM shifts s
        CROSS JOIN LATERAL effective_shift_times(s.id) est
        WHERE s.clocked_in_at::DATE BETWEEN p_week_start AND v_week_end
          AND NOT s.is_lunch
          AND s.employee_id IN (SELECT employee_id FROM employee_list)
        GROUP BY s.employee_id, s.clocked_in_at::DATE
    ),
    -- Lunch minutes from lunch shift segments
    day_lunch AS (
        SELECT
            s.employee_id,
            (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date AS lunch_date,
            COALESCE(SUM(EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at))::INTEGER / 60), 0) AS lunch_minutes
        FROM shifts s
        WHERE s.is_lunch = true AND s.clocked_out_at IS NOT NULL
          AND (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date BETWEEN p_week_start AND v_week_end
          AND s.employee_id IN (SELECT employee_id FROM employee_list)
        GROUP BY s.employee_id, (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date
    ),
    day_calls_lagged AS (
        SELECT
            employee_id,
            clocked_in_at::DATE AS call_date,
            clocked_in_at,
            clocked_out_at,
            LAG(clocked_in_at) OVER w AS prev_clocked_in_at,
            LAG(clocked_out_at) OVER w AS prev_clocked_out_at
        FROM shifts
        WHERE shift_type = 'call'
          AND status = 'completed'
          AND clocked_in_at::DATE BETWEEN p_week_start AND v_week_end
          AND employee_id IN (SELECT employee_id FROM employee_list)
          AND is_lunch = false
        WINDOW w AS (PARTITION BY employee_id, clocked_in_at::DATE ORDER BY clocked_in_at)
    ),
    day_calls AS (
        SELECT
            employee_id, call_date, clocked_in_at, clocked_out_at,
            SUM(CASE
                WHEN prev_clocked_in_at IS NULL THEN 1
                WHEN clocked_in_at >= GREATEST(prev_clocked_in_at + INTERVAL '3 hours', prev_clocked_out_at) THEN 1
                ELSE 0
            END) OVER (PARTITION BY employee_id, call_date ORDER BY clocked_in_at) AS group_id
        FROM day_calls_lagged
    ),
    day_call_groups AS (
        SELECT
            employee_id, call_date, group_id,
            COUNT(*) AS shifts_in_group,
            GREATEST(EXTRACT(EPOCH FROM (MAX(clocked_out_at) - MIN(clocked_in_at))) / 60, 180)::INTEGER AS group_billed_minutes,
            GREATEST(0, 180 - EXTRACT(EPOCH FROM (MAX(clocked_out_at) - MIN(clocked_in_at))) / 60)::INTEGER AS group_bonus_minutes
        FROM day_calls
        GROUP BY employee_id, call_date, group_id
    ),
    day_call_totals AS (
        SELECT
            employee_id, call_date,
            SUM(shifts_in_group)::INTEGER AS call_count,
            SUM(group_billed_minutes)::INTEGER AS call_billed_minutes,
            SUM(group_bonus_minutes)::INTEGER AS call_bonus_minutes
        FROM day_call_groups
        GROUP BY employee_id, call_date
    ),
    existing_approvals AS (
        SELECT da.employee_id, da.date, da.status, da.approved_minutes, da.rejected_minutes
        FROM day_approvals da
        WHERE da.date BETWEEN p_week_start AND v_week_end
          AND da.employee_id IN (SELECT employee_id FROM employee_list)
    ),
    live_stop_classification AS (
        SELECT
            sc.employee_id,
            sc.started_at::DATE AS activity_date,
            sc.id AS activity_id,
            sc.started_at,
            sc.ended_at,
            (sc.duration_seconds / 60)::INTEGER AS duration_minutes,
            COALESCE(ao.override_status,
                CASE
                    WHEN l.location_type IN ('office', 'building') THEN 'approved'
                    WHEN l.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                    WHEN l.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                    ELSE 'rejected'
                END
            ) AS final_status
        FROM stationary_clusters sc
        LEFT JOIN locations l ON l.id = sc.matched_location_id
        LEFT JOIN day_approvals da ON da.employee_id = sc.employee_id AND da.date = sc.started_at::DATE
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'stop' AND ao.activity_id = sc.id
        WHERE sc.started_at::DATE BETWEEN p_week_start AND v_week_end
          AND sc.employee_id IN (SELECT employee_id FROM employee_list)
          AND sc.duration_seconds >= 180
          -- Exclude stops from lunch segments
          AND NOT EXISTS (SELECT 1 FROM shifts sl WHERE sl.id = sc.shift_id AND sl.is_lunch = true)
    ),
    live_segment_classification AS (
        SELECT
            sc.employee_id,
            cs.starts_at::DATE AS activity_date,
            cs.id AS activity_id,
            cs.starts_at AS started_at,
            cs.ends_at AS ended_at,
            EXTRACT(EPOCH FROM (cs.ends_at - cs.starts_at))::INTEGER / 60 AS duration_minutes,
            COALESCE(ao.override_status,
                CASE
                    WHEN l.location_type IN ('office', 'building') THEN 'approved'
                    WHEN l.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                    WHEN l.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                    ELSE 'rejected'
                END
            ) AS final_status
        FROM cluster_segments cs
        JOIN stationary_clusters sc ON sc.id = cs.stationary_cluster_id
        LEFT JOIN locations l ON l.id = sc.matched_location_id
        LEFT JOIN day_approvals da ON da.employee_id = sc.employee_id AND da.date = cs.starts_at::DATE
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'stop_segment' AND ao.activity_id = cs.id
        WHERE cs.starts_at::DATE BETWEEN p_week_start AND v_week_end
          AND sc.employee_id IN (SELECT employee_id FROM employee_list)
          -- Exclude segments from lunch segments
          AND NOT EXISTS (SELECT 1 FROM shifts sl WHERE sl.id = sc.shift_id AND sl.is_lunch = true)
    ),
    -- Union: non-segmented stops + segments
    live_all_stops AS (
        SELECT * FROM live_stop_classification
        WHERE activity_id NOT IN (SELECT DISTINCT stationary_cluster_id FROM cluster_segments)
        UNION ALL
        SELECT * FROM live_segment_classification
    ),
    live_trip_classification AS (
        SELECT
            t.employee_id,
            t.started_at::DATE AS activity_date,
            t.started_at,
            t.ended_at,
            t.duration_minutes,
            COALESCE(ao.override_status,
                CASE
                    -- Trip on a lunch segment -> rejected
                    WHEN lunch_adj.id IS NOT NULL THEN 'rejected'
                    WHEN t.has_gps_gap = TRUE THEN
                        CASE
                            WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'rejected'
                            WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'approved'
                            WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL
                                 AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.started_at > t.started_at) THEN 'rejected'
                            WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL
                                 AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.ended_at < t.ended_at) THEN 'rejected'
                            WHEN dep_stop.final_status IS NULL OR arr_stop.final_status IS NULL THEN 'needs_review'
                            ELSE 'needs_review'
                        END
                    WHEN t.duration_minutes > 60 THEN 'needs_review'
                    WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'rejected'
                    WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'approved'
                    WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL
                         AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.started_at > t.started_at) THEN 'rejected'
                    WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL
                         AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.ended_at < t.ended_at) THEN 'rejected'
                    WHEN dep_stop.final_status IS NULL OR arr_stop.final_status IS NULL THEN 'needs_review'
                    ELSE 'needs_review'
                END
            ) AS final_status
        FROM trips t
        LEFT JOIN LATERAL (
            SELECT ls.final_status
            FROM live_all_stops ls
            WHERE ls.employee_id = t.employee_id
              AND ls.ended_at BETWEEN t.started_at - INTERVAL '2 minutes' AND t.started_at + INTERVAL '2 minutes'
            ORDER BY ABS(EXTRACT(EPOCH FROM (ls.ended_at - t.started_at)))
            LIMIT 1
        ) dep_stop ON TRUE
        LEFT JOIN LATERAL (
            SELECT ls.final_status
            FROM live_all_stops ls
            WHERE ls.employee_id = t.employee_id
              AND ls.started_at BETWEEN t.ended_at - INTERVAL '2 minutes' AND t.ended_at + INTERVAL '2 minutes'
            ORDER BY ABS(EXTRACT(EPOCH FROM (ls.started_at - t.ended_at)))
            LIMIT 1
        ) arr_stop ON TRUE
        -- Check if trip is on a lunch segment
        LEFT JOIN LATERAL (
            SELECT sl.id
            FROM shifts sl
            WHERE sl.id = t.shift_id AND sl.is_lunch = true
            LIMIT 1
        ) lunch_adj ON TRUE
        LEFT JOIN day_approvals da ON da.employee_id = t.employee_id AND da.date = t.started_at::DATE
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'trip' AND ao.activity_id = t.id
        WHERE t.started_at::DATE BETWEEN p_week_start AND v_week_end
          AND t.employee_id IN (SELECT employee_id FROM employee_list)
    ),
    live_activity_classification AS (
        SELECT employee_id, activity_date, duration_minutes, final_status
        FROM live_all_stops
        UNION ALL
        SELECT employee_id, activity_date, duration_minutes, final_status
        FROM live_trip_classification
    ),
    live_day_totals AS (
        SELECT
            employee_id, activity_date,
            COALESCE(SUM(duration_minutes) FILTER (WHERE final_status = 'approved'), 0)::INTEGER AS live_approved,
            COALESCE(SUM(duration_minutes) FILTER (WHERE final_status = 'rejected'), 0)::INTEGER AS live_rejected,
            COALESCE(COUNT(*) FILTER (WHERE final_status = 'needs_review'), 0)::INTEGER AS live_needs_review_count
        FROM live_activity_classification
        GROUP BY employee_id, activity_date
    ),
    -- Gap detection with effective times (exclude lunch segments from shift_boundaries)
    shift_boundaries AS (
        SELECT
            s.id AS shift_id,
            s.employee_id,
            s.clocked_in_at::DATE AS shift_date,
            est.effective_clocked_in_at AS clocked_in_at,
            est.effective_clocked_out_at AS clocked_out_at
        FROM shifts s
        CROSS JOIN LATERAL effective_shift_times(s.id) est
        WHERE s.status = 'completed'
          AND s.clocked_in_at::DATE BETWEEN p_week_start AND v_week_end
          AND s.employee_id IN (SELECT employee_id FROM employee_list)
          AND est.effective_clocked_out_at IS NOT NULL
          AND NOT s.is_lunch
    ),
    activity_events AS (
        SELECT sb.shift_id, sb.employee_id, sb.shift_date,
            GREATEST(sc.started_at, sb.clocked_in_at) AS evt_start,
            LEAST(sc.ended_at, sb.clocked_out_at) AS evt_end
        FROM shift_boundaries sb
        JOIN stationary_clusters sc ON sc.employee_id = sb.employee_id
           AND sc.started_at >= sb.clocked_in_at - INTERVAL '1 minute'
           AND sc.started_at < sb.clocked_out_at AND sc.ended_at > sb.clocked_in_at
           AND sc.duration_seconds >= 180
        UNION ALL
        SELECT sb.shift_id, sb.employee_id, sb.shift_date,
            GREATEST(t.started_at, sb.clocked_in_at) AS evt_start,
            LEAST(t.ended_at, sb.clocked_out_at) AS evt_end
        FROM shift_boundaries sb
        JOIN trips t ON t.employee_id = sb.employee_id
           AND t.started_at >= sb.clocked_in_at - INTERVAL '1 minute'
           AND t.started_at < sb.clocked_out_at AND t.ended_at > sb.clocked_in_at
        UNION ALL
        -- Lunch segments as coverage events (use shifts with is_lunch via work_body_id)
        SELECT sb.shift_id, sb.employee_id, sb.shift_date,
            GREATEST(s_lunch.clocked_in_at, sb.clocked_in_at) AS evt_start,
            LEAST(s_lunch.clocked_out_at, sb.clocked_out_at) AS evt_end
        FROM shift_boundaries sb
        JOIN shifts s_lunch ON s_lunch.employee_id = sb.employee_id
           AND s_lunch.work_body_id = (SELECT work_body_id FROM shifts WHERE id = sb.shift_id)
           AND s_lunch.is_lunch = true AND s_lunch.clocked_out_at IS NOT NULL
    ),
    coverage_sorted AS (
        SELECT shift_id, employee_id, shift_date, evt_start, evt_end,
               ROW_NUMBER() OVER (PARTITION BY shift_id ORDER BY evt_start, evt_end DESC) AS rn
        FROM activity_events
    ),
    coverage_with_max AS (
        SELECT cs.*,
               MAX(evt_end) OVER (PARTITION BY shift_id ORDER BY rn ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_max_end
        FROM coverage_sorted cs
    ),
    coverage_islands AS (
        SELECT shift_id, employee_id, shift_date, evt_start, evt_end,
               SUM(CASE WHEN rn = 1 OR evt_start > prev_max_end THEN 1 ELSE 0 END)
                   OVER (PARTITION BY shift_id ORDER BY rn) AS island_id
        FROM coverage_with_max
    ),
    coverage_spans AS (
        SELECT shift_id, employee_id, shift_date, island_id,
               MIN(evt_start) AS span_start, MAX(evt_end) AS span_end
        FROM coverage_islands
        GROUP BY shift_id, employee_id, shift_date, island_id
    ),
    spans_numbered AS (
        SELECT shift_id, employee_id, shift_date, span_start, span_end,
               ROW_NUMBER() OVER (PARTITION BY shift_id ORDER BY span_start) AS span_rn,
               COUNT(*) OVER (PARTITION BY shift_id) AS span_count
        FROM coverage_spans
    ),
    gap_candidates AS (
        SELECT sb.employee_id, sb.shift_date, sb.clocked_in_at AS gap_start, sn.span_start AS gap_end
        FROM shift_boundaries sb JOIN spans_numbered sn ON sn.shift_id = sb.shift_id AND sn.span_rn = 1
        UNION ALL
        SELECT sn1.employee_id, sn1.shift_date, sn1.span_end AS gap_start, sn2.span_start AS gap_end
        FROM spans_numbered sn1 JOIN spans_numbered sn2 ON sn2.shift_id = sn1.shift_id AND sn2.span_rn = sn1.span_rn + 1
        UNION ALL
        SELECT sb.employee_id, sb.shift_date, sn.span_end AS gap_start, sb.clocked_out_at AS gap_end
        FROM shift_boundaries sb JOIN spans_numbered sn ON sn.shift_id = sb.shift_id AND sn.span_rn = sn.span_count
        UNION ALL
        SELECT sb.employee_id, sb.shift_date, sb.clocked_in_at AS gap_start, sb.clocked_out_at AS gap_end
        FROM shift_boundaries sb WHERE NOT EXISTS (SELECT 1 FROM activity_events ae WHERE ae.shift_id = sb.shift_id)
    ),
    day_coverage_gap_totals AS (
        SELECT employee_id, shift_date,
            COALESCE(SUM(EXTRACT(EPOCH FROM (gap_end - gap_start)) / 60)::INTEGER, 0) AS coverage_gap_minutes
        FROM gap_candidates
        WHERE EXTRACT(EPOCH FROM (gap_end - gap_start)) > 300
        GROUP BY employee_id, shift_date
    ),
    activity_quality_gaps AS (
        SELECT sb.employee_id, sb.shift_date,
            COALESCE(SUM(sc.gps_gap_seconds), 0) AS stop_gap_seconds
        FROM shift_boundaries sb
        JOIN stationary_clusters sc ON sc.employee_id = sb.employee_id
           AND sc.started_at >= sb.clocked_in_at - INTERVAL '1 minute'
           AND sc.started_at < sb.clocked_out_at AND sc.ended_at > sb.clocked_in_at
           AND sc.duration_seconds >= 180 AND sc.gps_gap_seconds > 0
        GROUP BY sb.employee_id, sb.shift_date
    ),
    trip_quality_gaps AS (
        SELECT sb.employee_id, sb.shift_date,
            COALESCE(SUM(t.gps_gap_seconds), 0) AS trip_gap_seconds
        FROM shift_boundaries sb
        JOIN trips t ON t.employee_id = sb.employee_id
           AND t.started_at >= sb.clocked_in_at - INTERVAL '1 minute'
           AND t.started_at < sb.clocked_out_at AND t.ended_at > sb.clocked_in_at
           AND t.gps_gap_seconds > 0
        GROUP BY sb.employee_id, sb.shift_date
    ),
    day_gap_totals AS (
        SELECT
            COALESCE(cg.employee_id, aq.employee_id, tq.employee_id) AS employee_id,
            COALESCE(cg.shift_date, aq.shift_date, tq.shift_date) AS shift_date,
            COALESCE(cg.coverage_gap_minutes, 0) + (COALESCE(aq.stop_gap_seconds, 0) / 60) + (COALESCE(tq.trip_gap_seconds, 0) / 60) AS gap_minutes
        FROM day_coverage_gap_totals cg
        FULL OUTER JOIN activity_quality_gaps aq ON aq.employee_id = cg.employee_id AND aq.shift_date = cg.shift_date
        FULL OUTER JOIN trip_quality_gaps tq ON tq.employee_id = COALESCE(cg.employee_id, aq.employee_id)
           AND tq.shift_date = COALESCE(cg.shift_date, aq.shift_date)
    ),
    pending_day_stats AS (
        SELECT
            ds.employee_id, ds.shift_date, ds.total_shift_minutes, ds.has_active_shift,
            ea.status AS approval_status, ea.approved_minutes AS frozen_approved, ea.rejected_minutes AS frozen_rejected,
            ldt.live_approved, ldt.live_rejected, ldt.live_needs_review_count,
            COALESCE(dl.lunch_minutes, 0) AS lunch_minutes,
            COALESCE(dct.call_count, 0) AS call_count,
            COALESCE(dct.call_billed_minutes, 0) AS call_billed_minutes,
            COALESCE(dct.call_bonus_minutes, 0) AS call_bonus_minutes,
            COALESCE(dgt.gap_minutes, 0) AS gap_minutes
        FROM day_shifts ds
        LEFT JOIN existing_approvals ea ON ea.employee_id = ds.employee_id AND ea.date = ds.shift_date
        LEFT JOIN live_day_totals ldt ON ldt.employee_id = ds.employee_id AND ldt.activity_date = ds.shift_date
        LEFT JOIN day_lunch dl ON dl.employee_id = ds.employee_id AND dl.lunch_date = ds.shift_date
        LEFT JOIN day_call_totals dct ON dct.employee_id = ds.employee_id AND dct.call_date = ds.shift_date
        LEFT JOIN day_gap_totals dgt ON dgt.employee_id = ds.employee_id AND dgt.shift_date = ds.shift_date
    )
    SELECT jsonb_agg(
        jsonb_build_object(
            'employee_id', el.employee_id,
            'employee_name', el.employee_name,
            'days', (
                SELECT COALESCE(jsonb_agg(
                    jsonb_build_object(
                        'date', d::DATE,
                        'has_shifts', (pds.total_shift_minutes IS NOT NULL),
                        'has_active_shift', COALESCE(pds.has_active_shift, FALSE),
                        'status', CASE
                            WHEN pds.total_shift_minutes IS NULL THEN 'no_shift'
                            WHEN pds.has_active_shift THEN 'active'
                            WHEN pds.approval_status = 'approved' THEN 'approved'
                            WHEN COALESCE(pds.live_needs_review_count, 0) > 0 THEN 'needs_review'
                            ELSE 'pending'
                        END,
                        -- Lunch already excluded from total_shift_minutes (day_shifts filters NOT is_lunch)
                        'total_shift_minutes', COALESCE(pds.total_shift_minutes, 0),
                        'approved_minutes', LEAST(
                            CASE
                                WHEN pds.approval_status = 'approved' THEN pds.frozen_approved
                                ELSE COALESCE(pds.live_approved, 0)
                            END,
                            COALESCE(pds.total_shift_minutes, 0)
                        ),
                        'rejected_minutes', CASE
                            WHEN pds.approval_status = 'approved' THEN pds.frozen_rejected
                            ELSE COALESCE(pds.live_rejected, 0)
                        END,
                        'needs_review_count', CASE
                            WHEN pds.approval_status = 'approved' THEN 0
                            ELSE COALESCE(pds.live_needs_review_count, 0)
                        END,
                        'lunch_minutes', COALESCE(pds.lunch_minutes, 0),
                        'call_count', COALESCE(pds.call_count, 0),
                        'call_billed_minutes', COALESCE(pds.call_billed_minutes, 0),
                        'call_bonus_minutes', COALESCE(pds.call_bonus_minutes, 0),
                        'gap_minutes', COALESCE(pds.gap_minutes, 0)
                    )
                    ORDER BY d::DATE
                ), '[]'::JSONB)
                FROM generate_series(p_week_start, v_week_end, INTERVAL '1 day') d
                LEFT JOIN pending_day_stats pds
                    ON pds.employee_id = el.employee_id AND pds.shift_date = d::DATE
            )
        )
        ORDER BY el.employee_name
    )
    INTO v_result
    FROM employee_list el;

    RETURN COALESCE(v_result, '[]'::JSONB);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================================
-- 4. _get_day_approval_detail_base — full rewrite for shift-split
-- ============================================================
CREATE OR REPLACE FUNCTION _get_day_approval_detail_base(
    p_employee_id UUID,
    p_date DATE
)
RETURNS JSONB AS $$
DECLARE
    v_result JSONB;
    v_activities JSONB;
    v_gaps JSONB;
    v_day_approval RECORD;
    v_total_shift_minutes INTEGER;
    v_lunch_minutes INTEGER := 0;
    v_approved_minutes INTEGER := 0;
    v_rejected_minutes INTEGER := 0;
    v_needs_review_count INTEGER := 0;
    v_has_active_shift BOOLEAN := FALSE;
    v_call_count INTEGER := 0;
    v_call_billed_minutes INTEGER := 0;
    v_call_bonus_minutes INTEGER := 0;
BEGIN
    -- Check for active shifts on this day
    SELECT EXISTS(
        SELECT 1 FROM shifts
        WHERE employee_id = p_employee_id
          AND clocked_in_at::DATE = p_date
          AND status = 'active'
    ) INTO v_has_active_shift;

    -- Get existing day_approval if any
    SELECT * INTO v_day_approval
    FROM day_approvals
    WHERE employee_id = p_employee_id AND date = p_date;

    -- If already approved, return frozen data
    IF v_day_approval.status = 'approved' THEN
        NULL; -- Fall through to activity building
    END IF;

    -- Calculate total shift minutes using effective times (exclude lunch segments)
    SELECT COALESCE(SUM(
        EXTRACT(EPOCH FROM (COALESCE(est.effective_clocked_out_at, now()) - est.effective_clocked_in_at)) / 60
    )::INTEGER, 0)
    INTO v_total_shift_minutes
    FROM shifts s
    CROSS JOIN LATERAL effective_shift_times(s.id) est
    WHERE s.employee_id = p_employee_id
      AND s.clocked_in_at::DATE = p_date
      AND s.status = 'completed'
      AND NOT s.is_lunch;

    -- Calculate lunch minutes from lunch shift segments
    SELECT COALESCE(SUM(
        EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at)) / 60
    )::INTEGER, 0)
    INTO v_lunch_minutes
    FROM shifts s
    WHERE s.employee_id = p_employee_id
      AND s.is_lunch = true
      AND (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date = p_date
      AND s.clocked_out_at IS NOT NULL;

    -- NOTE: No lunch subtraction needed — lunch is already excluded from v_total_shift_minutes

    -- Calculate call billing with grouping logic (Article 58 LNT)
    WITH call_shifts_ordered AS (
        SELECT
            id,
            clocked_in_at,
            clocked_out_at,
            ROW_NUMBER() OVER (ORDER BY clocked_in_at) AS rn
        FROM shifts
        WHERE employee_id = p_employee_id
          AND clocked_in_at::DATE = p_date
          AND shift_type = 'call'
          AND status = 'completed'
          AND is_lunch = false
    ),
    call_with_groups AS (
        SELECT
            cs.*,
            SUM(CASE
                WHEN cs.rn = 1 THEN 1
                WHEN cs.clocked_in_at >= (
                    SELECT GREATEST(
                        prev.clocked_in_at + INTERVAL '3 hours',
                        COALESCE(prev.clocked_out_at, prev.clocked_in_at + INTERVAL '3 hours')
                    )
                    FROM call_shifts_ordered prev
                    WHERE prev.rn = cs.rn - 1
                ) THEN 1
                ELSE 0
            END) OVER (ORDER BY cs.rn) AS group_id
        FROM call_shifts_ordered cs
    ),
    call_group_billing AS (
        SELECT
            group_id,
            COUNT(*) AS shifts_in_group,
            GREATEST(
                EXTRACT(EPOCH FROM (MAX(clocked_out_at) - MIN(clocked_in_at))) / 60,
                180
            )::INTEGER AS group_billed_minutes,
            GREATEST(0, 180 - EXTRACT(EPOCH FROM (MAX(clocked_out_at) - MIN(clocked_in_at))) / 60)::INTEGER AS group_bonus_minutes
        FROM call_with_groups
        GROUP BY group_id
    )
    SELECT
        COALESCE(SUM(shifts_in_group), 0)::INTEGER,
        COALESCE(SUM(group_billed_minutes), 0)::INTEGER,
        COALESCE(SUM(group_bonus_minutes), 0)::INTEGER
    INTO v_call_count, v_call_billed_minutes, v_call_bonus_minutes
    FROM call_group_billing;

    -- Build classified activity list
    WITH stop_data AS (
        SELECT
            'stop'::TEXT AS activity_type,
            sc.id AS activity_id,
            sc.shift_id,
            sc.started_at,
            sc.ended_at,
            (sc.duration_seconds / 60)::INTEGER AS duration_minutes,
            sc.matched_location_id,
            l.name AS location_name,
            l.location_type::TEXT AS location_type,
            sc.centroid_latitude AS latitude,
            sc.centroid_longitude AS longitude,
            sc.gps_gap_seconds,
            sc.gps_gap_count,
            CASE
                WHEN l.location_type IN ('office', 'building') THEN 'approved'
                WHEN l.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                WHEN l.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                ELSE 'rejected'
            END AS auto_status,
            CASE
                WHEN l.location_type = 'office' THEN 'Lieu de travail (bureau)'
                WHEN l.location_type = 'building' THEN 'Lieu de travail (immeuble)'
                WHEN l.location_type = 'vendor' THEN 'Fournisseur (à vérifier)'
                WHEN l.location_type = 'gaz' THEN 'Station-service (à vérifier)'
                WHEN l.location_type = 'home' THEN 'Domicile'
                WHEN l.location_type = 'cafe_restaurant' THEN 'Café / Restaurant'
                WHEN l.location_type = 'other' THEN 'Lieu non-professionnel'
                ELSE 'Lieu non autorisé (inconnu)'
            END AS auto_reason,
            NULL::DECIMAL AS distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type,
            NULL::TEXT AS shift_type,
            NULL::TEXT AS shift_type_source
        FROM stationary_clusters sc
        LEFT JOIN locations l ON l.id = sc.matched_location_id
        WHERE sc.employee_id = p_employee_id
          AND sc.started_at >= p_date::TIMESTAMPTZ
          AND sc.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
          AND sc.duration_seconds >= 180
          -- Exclude stops from lunch segments
          AND NOT EXISTS (SELECT 1 FROM shifts sl WHERE sl.id = sc.shift_id AND sl.is_lunch = true)
    ),
    stop_classified AS (
        SELECT
            sd.*,
            ao.override_status,
            ao.reason AS override_reason,
            COALESCE(ao.override_status, sd.auto_status) AS final_status,
            FALSE AS is_edited,
            NULL::TIMESTAMPTZ AS original_value
        FROM stop_data sd
        LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'stop' AND ao.activity_id = sd.activity_id
    ),
    -- Segment data for segmented clusters (exclude lunch segments)
    segment_data AS (
        SELECT
            'stop_segment'::TEXT AS activity_type,
            cs.id AS activity_id,
            sc.shift_id,
            cs.starts_at AS started_at,
            cs.ends_at AS ended_at,
            EXTRACT(EPOCH FROM (cs.ends_at - cs.starts_at))::INTEGER / 60 AS duration_minutes,
            sc.matched_location_id,
            l.name AS location_name,
            l.location_type::TEXT AS location_type,
            sc.centroid_latitude AS latitude,
            sc.centroid_longitude AS longitude,
            sc.gps_gap_seconds,
            sc.gps_gap_count,
            CASE
                WHEN l.location_type IN ('office', 'building') THEN 'approved'
                WHEN l.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                WHEN l.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                ELSE 'rejected'
            END AS auto_status,
            CASE
                WHEN l.location_type = 'office' THEN 'Lieu de travail (bureau)'
                WHEN l.location_type = 'building' THEN 'Lieu de travail (immeuble)'
                WHEN l.location_type = 'vendor' THEN 'Fournisseur (à vérifier)'
                WHEN l.location_type = 'gaz' THEN 'Station-service (à vérifier)'
                WHEN l.location_type = 'home' THEN 'Domicile'
                WHEN l.location_type = 'cafe_restaurant' THEN 'Café / Restaurant'
                WHEN l.location_type = 'other' THEN 'Lieu non-professionnel'
                ELSE 'Lieu non autorisé (inconnu)'
            END AS auto_reason,
            NULL::DECIMAL AS distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type,
            NULL::TEXT AS shift_type,
            NULL::TEXT AS shift_type_source,
            ao.override_status,
            ao.reason AS override_reason,
            COALESCE(ao.override_status, CASE
                WHEN l.location_type IN ('office', 'building') THEN 'approved'
                WHEN l.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                WHEN l.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                ELSE 'rejected'
            END) AS final_status,
            FALSE AS is_edited,
            NULL::TIMESTAMPTZ AS original_value
        FROM cluster_segments cs
        JOIN stationary_clusters sc ON sc.id = cs.stationary_cluster_id
        LEFT JOIN locations l ON l.id = sc.matched_location_id
        LEFT JOIN day_approvals da ON da.employee_id = sc.employee_id
            AND da.date = to_business_date(cs.starts_at)
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'stop_segment'
            AND ao.activity_id = cs.id
        WHERE sc.employee_id = p_employee_id
          AND cs.starts_at >= p_date::TIMESTAMPTZ
          AND cs.starts_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
          -- Exclude segments from lunch shifts
          AND NOT EXISTS (SELECT 1 FROM shifts sl WHERE sl.id = sc.shift_id AND sl.is_lunch = true)
    ),
    -- Union: non-segmented stops + segments
    all_stops AS (
        SELECT * FROM stop_classified
        WHERE activity_id NOT IN (SELECT DISTINCT stationary_cluster_id FROM cluster_segments)
        UNION ALL
        SELECT * FROM segment_data
    ),
    trip_data AS (
        SELECT
            'trip'::TEXT AS activity_type,
            t.id AS activity_id,
            t.shift_id,
            t.started_at,
            t.ended_at,
            t.duration_minutes,
            NULL::UUID AS matched_location_id,
            NULL::TEXT AS location_name,
            NULL::TEXT AS location_type,
            t.start_latitude AS latitude,
            t.start_longitude AS longitude,
            t.gps_gap_seconds,
            t.gps_gap_count,
            CASE
                -- GPS gap handling
                WHEN t.has_gps_gap = TRUE THEN
                    CASE
                        WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'rejected'
                        WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'approved'
                        -- R3: Commute (last trip, known->NULL)
                        WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL
                             AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.started_at > t.started_at) THEN 'rejected'
                        -- R3: Commute (first trip, NULL->known)
                        WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL
                             AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.ended_at < t.ended_at) THEN 'rejected'
                        -- R3: One endpoint unknown (not commute) -> needs_review
                        WHEN dep_stop.final_status IS NULL OR arr_stop.final_status IS NULL THEN 'needs_review'
                        ELSE 'needs_review'
                    END
                WHEN t.duration_minutes > 60 THEN 'needs_review'
                -- Both endpoints approved -> approved (known->known)
                WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'rejected'
                WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'approved'
                -- R3: Commute (last trip, known->NULL)
                WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL
                     AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.started_at > t.started_at) THEN 'rejected'
                -- R3: Commute (first trip, NULL->known)
                WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL
                     AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.ended_at < t.ended_at) THEN 'rejected'
                -- R3: One endpoint unknown (not commute) -> needs_review
                WHEN dep_stop.final_status IS NULL OR arr_stop.final_status IS NULL THEN 'needs_review'
                ELSE 'needs_review'
            END AS auto_status,
            CASE
                -- GPS gap handling
                WHEN t.has_gps_gap = TRUE THEN
                    CASE
                        WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'Trajet vers/depuis lieu non autorisé'
                        WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'Déplacement professionnel'
                        WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL
                             AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.started_at > t.started_at) THEN 'Trajet de commute'
                        WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL
                             AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.ended_at < t.ended_at) THEN 'Trajet de commute'
                        WHEN dep_stop.final_status IS NULL OR arr_stop.final_status IS NULL THEN 'Destination inconnue'
                        ELSE 'Données GPS incomplètes'
                    END
                WHEN t.duration_minutes > 60 THEN 'Trajet anormalement long (>' || t.duration_minutes || ' min)'
                WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'Trajet vers/depuis lieu non autorisé'
                WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'Déplacement professionnel'
                WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL
                     AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.started_at > t.started_at) THEN 'Trajet de commute'
                WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL
                     AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.ended_at < t.ended_at) THEN 'Trajet de commute'
                WHEN dep_stop.final_status IS NULL OR arr_stop.final_status IS NULL THEN 'Destination inconnue'
                ELSE 'À vérifier'
            END AS auto_reason,
            t.distance_km,
            t.transport_mode::TEXT,
            t.has_gps_gap,
            COALESCE(t.start_location_id, dep_cluster.matched_location_id) AS start_location_id,
            COALESCE(sl.name, dep_loc.name)::TEXT AS start_location_name,
            COALESCE(sl.location_type, dep_loc.location_type)::TEXT AS start_location_type,
            COALESCE(t.end_location_id, arr_cluster.matched_location_id) AS end_location_id,
            COALESCE(el.name, arr_loc.name)::TEXT AS end_location_name,
            COALESCE(el.location_type, arr_loc.location_type)::TEXT AS end_location_type,
            NULL::TEXT AS shift_type,
            NULL::TEXT AS shift_type_source
        FROM trips t
        LEFT JOIN locations sl ON sl.id = t.start_location_id
        LEFT JOIN locations el ON el.id = t.end_location_id
        LEFT JOIN LATERAL (
            SELECT sc2.matched_location_id
            FROM stationary_clusters sc2
            WHERE sc2.employee_id = p_employee_id
              AND sc2.ended_at = t.started_at
            LIMIT 1
        ) dep_cluster ON t.start_location_id IS NULL
        LEFT JOIN locations dep_loc ON dep_loc.id = dep_cluster.matched_location_id
        LEFT JOIN LATERAL (
            SELECT sc3.matched_location_id
            FROM stationary_clusters sc3
            WHERE sc3.employee_id = p_employee_id
              AND sc3.started_at = t.ended_at
            LIMIT 1
        ) arr_cluster ON t.end_location_id IS NULL
        LEFT JOIN locations arr_loc ON arr_loc.id = arr_cluster.matched_location_id
        -- Adjacent stop status uses all_stops (includes segments)
        LEFT JOIN LATERAL (
            SELECT sc_dep.final_status
            FROM all_stops sc_dep
            WHERE sc_dep.ended_at BETWEEN t.started_at - INTERVAL '2 minutes' AND t.started_at + INTERVAL '2 minutes'
            ORDER BY ABS(EXTRACT(EPOCH FROM (sc_dep.ended_at - t.started_at)))
            LIMIT 1
        ) dep_stop ON TRUE
        LEFT JOIN LATERAL (
            SELECT sc_arr.final_status
            FROM all_stops sc_arr
            WHERE sc_arr.started_at BETWEEN t.ended_at - INTERVAL '2 minutes' AND t.ended_at + INTERVAL '2 minutes'
            ORDER BY ABS(EXTRACT(EPOCH FROM (sc_arr.started_at - t.ended_at)))
            LIMIT 1
        ) arr_stop ON TRUE
        WHERE t.employee_id = p_employee_id
          AND t.started_at >= p_date::TIMESTAMPTZ
          AND t.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
          -- Exclude trips from lunch segments
          AND NOT EXISTS (SELECT 1 FROM shifts sl WHERE sl.id = t.shift_id AND sl.is_lunch = true)
    ),
    -- Clock data with effective times and edit indicators
    clock_data AS (
        -- Clock-in events: only first segment (not post-lunch)
        SELECT
            'clock_in'::TEXT AS activity_type,
            s.id AS activity_id,
            s.id AS shift_id,
            est.effective_clocked_in_at AS started_at,
            est.effective_clocked_in_at AS ended_at,
            0 AS duration_minutes,
            ci_loc.id AS matched_location_id,
            ci_loc.name AS location_name,
            ci_loc.location_type::TEXT AS location_type,
            (s.clock_in_location->>'latitude')::DECIMAL AS latitude,
            (s.clock_in_location->>'longitude')::DECIMAL AS longitude,
            NULL::INTEGER AS gps_gap_seconds,
            NULL::INTEGER AS gps_gap_count,
            CASE
                WHEN s.clock_in_location IS NULL THEN 'needs_review'
                WHEN ci_loc.location_type IN ('office', 'building') THEN 'approved'
                WHEN ci_loc.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                WHEN ci_loc.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN ci_loc.id IS NULL THEN 'rejected'
                ELSE 'rejected'
            END AS auto_status,
            CASE
                WHEN s.clock_in_location IS NULL THEN 'Clock-in sans GPS'
                WHEN ci_loc.location_type IN ('office', 'building') THEN 'Clock-in sur lieu de travail'
                WHEN ci_loc.location_type = 'vendor' THEN 'Clock-in chez fournisseur (à vérifier)'
                WHEN ci_loc.location_type = 'gaz' THEN 'Clock-in station-service (à vérifier)'
                WHEN ci_loc.location_type = 'home' THEN 'Clock-in depuis le domicile'
                WHEN ci_loc.location_type IN ('cafe_restaurant', 'other') THEN 'Clock-in hors lieu de travail'
                WHEN ci_loc.id IS NULL THEN 'Clock-in lieu non autorisé'
                ELSE 'Clock-in lieu non autorisé'
            END AS auto_reason,
            NULL::DECIMAL AS distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type,
            s.shift_type::TEXT AS shift_type,
            s.shift_type_source::TEXT AS shift_type_source,
            est.clock_in_edited AS is_edited,
            CASE WHEN est.clock_in_edited THEN s.clocked_in_at ELSE NULL END AS original_value
        FROM shifts s
        CROSS JOIN LATERAL effective_shift_times(s.id) est
        LEFT JOIN LATERAL (
            SELECT l.id, l.name, l.location_type
            FROM locations l
            WHERE l.is_active = TRUE
              AND s.clock_in_location IS NOT NULL
              AND ST_DWithin(
                  l.location::geography,
                  ST_SetSRID(ST_MakePoint(
                      (s.clock_in_location->>'longitude')::DOUBLE PRECISION,
                      (s.clock_in_location->>'latitude')::DOUBLE PRECISION
                  ), 4326)::geography,
                  GREATEST(l.radius_meters, COALESCE(s.clock_in_accuracy, 0))
              )
            ORDER BY ST_Distance(
                l.location::geography,
                ST_SetSRID(ST_MakePoint(
                    (s.clock_in_location->>'longitude')::DOUBLE PRECISION,
                    (s.clock_in_location->>'latitude')::DOUBLE PRECISION
                ), 4326)::geography
            )
            LIMIT 1
        ) ci_loc ON TRUE
        WHERE s.employee_id = p_employee_id
          AND s.clocked_in_at::DATE = p_date
          AND s.status = 'completed'
          AND NOT s.is_lunch
          -- Only show clock-in from the first segment (not post-lunch resumptions)
          AND (s.work_body_id IS NULL OR s.clocked_in_at = (
            SELECT MIN(s2.clocked_in_at) FROM shifts s2 WHERE s2.work_body_id = s.work_body_id
          ))

        UNION ALL

        -- Clock-out events: only from non-lunch, non-lunch-split segments
        SELECT
            'clock_out'::TEXT,
            s.id,
            s.id AS shift_id,
            est.effective_clocked_out_at,
            est.effective_clocked_out_at,
            0 AS duration_minutes,
            co_loc.id AS matched_location_id,
            co_loc.name AS location_name,
            co_loc.location_type::TEXT AS location_type,
            (s.clock_out_location->>'latitude')::DECIMAL,
            (s.clock_out_location->>'longitude')::DECIMAL,
            NULL::INTEGER,
            NULL::INTEGER,
            CASE
                WHEN s.clock_out_location IS NULL AND s.clock_out_reason = 'midnight_auto_close' THEN 'needs_review'
                WHEN s.clock_out_location IS NULL THEN 'needs_review'
                WHEN co_loc.location_type IN ('office', 'building') THEN 'approved'
                WHEN co_loc.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                WHEN co_loc.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN co_loc.id IS NULL THEN 'rejected'
                ELSE 'rejected'
            END,
            CASE
                WHEN s.clock_out_reason = 'midnight_auto_close' THEN 'Clock-out automatique (minuit)'
                WHEN s.clock_out_location IS NULL THEN 'Clock-out sans GPS'
                WHEN co_loc.location_type IN ('office', 'building') THEN 'Clock-out sur lieu de travail'
                WHEN co_loc.location_type = 'vendor' THEN 'Clock-out chez fournisseur (à vérifier)'
                WHEN co_loc.location_type = 'gaz' THEN 'Clock-out station-service (à vérifier)'
                WHEN co_loc.location_type = 'home' THEN 'Clock-out au domicile'
                WHEN co_loc.location_type IN ('cafe_restaurant', 'other') THEN 'Clock-out hors lieu de travail'
                WHEN co_loc.id IS NULL THEN 'Clock-out lieu non autorisé'
                ELSE 'Clock-out lieu non autorisé'
            END,
            NULL::DECIMAL,
            NULL::TEXT,
            NULL::BOOLEAN,
            NULL::UUID,
            NULL::TEXT,
            NULL::TEXT,
            NULL::UUID,
            NULL::TEXT,
            NULL::TEXT,
            s.shift_type::TEXT,
            s.shift_type_source::TEXT,
            est.clock_out_edited AS is_edited,
            CASE WHEN est.clock_out_edited THEN s.clocked_out_at ELSE NULL END AS original_value
        FROM shifts s
        CROSS JOIN LATERAL effective_shift_times(s.id) est
        LEFT JOIN LATERAL (
            SELECT l.id, l.name, l.location_type
            FROM locations l
            WHERE l.is_active = TRUE
              AND s.clock_out_location IS NOT NULL
              AND ST_DWithin(
                  l.location::geography,
                  ST_SetSRID(ST_MakePoint(
                      (s.clock_out_location->>'longitude')::DOUBLE PRECISION,
                      (s.clock_out_location->>'latitude')::DOUBLE PRECISION
                  ), 4326)::geography,
                  GREATEST(l.radius_meters, COALESCE(s.clock_out_accuracy, 0))
              )
            ORDER BY ST_Distance(
                l.location::geography,
                ST_SetSRID(ST_MakePoint(
                    (s.clock_out_location->>'longitude')::DOUBLE PRECISION,
                    (s.clock_out_location->>'latitude')::DOUBLE PRECISION
                ), 4326)::geography
            )
            LIMIT 1
        ) co_loc ON TRUE
        WHERE s.employee_id = p_employee_id
          AND s.clocked_in_at::DATE = p_date
          AND s.status = 'completed'
          AND s.clocked_out_at IS NOT NULL
          AND NOT s.is_lunch
          -- Exclude clock-outs that are lunch splits (reason = 'lunch' or 'lunch_end')
          AND COALESCE(s.clock_out_reason, '') NOT IN ('lunch', 'lunch_end')
    ),
    -- Lunch data: from lunch shift segments with children
    lunch_data AS (
        SELECT
            'lunch'::TEXT AS activity_type,
            s.id AS activity_id,
            s.id AS shift_id,
            s.clocked_in_at AS started_at,
            s.clocked_out_at AS ended_at,
            (EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at)) / 60)::INTEGER AS duration_minutes,
            NULL::UUID AS matched_location_id,
            NULL::TEXT AS location_name,
            NULL::TEXT AS location_type,
            NULL::DECIMAL AS latitude,
            NULL::DECIMAL AS longitude,
            NULL::INTEGER AS gps_gap_seconds,
            NULL::INTEGER AS gps_gap_count,
            'rejected'::TEXT AS auto_status,
            'Pause dîner (non payée)'::TEXT AS auto_reason,
            NULL::TEXT AS override_status,
            NULL::TEXT AS override_reason,
            'rejected'::TEXT AS final_status,
            NULL::DECIMAL AS distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type,
            NULL::TEXT AS shift_type,
            NULL::TEXT AS shift_type_source,
            FALSE AS is_edited,
            NULL::TIMESTAMPTZ AS original_value,
            -- Children: stops and trips during lunch
            (SELECT jsonb_agg(child ORDER BY child->>'started_at')
             FROM (
               SELECT jsonb_build_object(
                 'activity_id', sc.id,
                 'activity_type', 'stop',
                 'started_at', sc.started_at,
                 'ended_at', sc.ended_at,
                 'duration_minutes', sc.duration_seconds / 60,
                 'auto_status', 'rejected',
                 'auto_reason', 'Pendant la pause dîner',
                 'location_name', l.name,
                 'location_type', l.location_type::TEXT,
                 'latitude', sc.centroid_latitude,
                 'longitude', sc.centroid_longitude
               ) AS child
               FROM stationary_clusters sc
               LEFT JOIN locations l ON l.id = sc.matched_location_id
               WHERE sc.shift_id = s.id AND sc.duration_seconds >= 180
               UNION ALL
               SELECT jsonb_build_object(
                 'activity_id', t.id,
                 'activity_type', 'trip',
                 'started_at', t.started_at,
                 'ended_at', t.ended_at,
                 'duration_minutes', t.duration_minutes,
                 'distance_km', COALESCE(t.road_distance_km, t.distance_km),
                 'auto_status', 'rejected',
                 'auto_reason', 'Pendant la pause dîner',
                 'transport_mode', t.transport_mode::TEXT,
                 'start_location_name', sl2.name,
                 'end_location_name', el2.name
               ) AS child
               FROM trips t
               LEFT JOIN locations sl2 ON sl2.id = t.start_location_id
               LEFT JOIN locations el2 ON el2.id = t.end_location_id
               WHERE t.shift_id = s.id
             ) sub
            ) AS children
        FROM shifts s
        WHERE s.employee_id = p_employee_id
          AND s.is_lunch = true
          AND (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date = p_date
          AND s.clocked_out_at IS NOT NULL
    ),
    classified AS (
        -- Stops (non-segmented + segments)
        SELECT
            sc.activity_type, sc.activity_id, sc.shift_id,
            sc.started_at, sc.ended_at, sc.duration_minutes,
            sc.matched_location_id, sc.location_name, sc.location_type,
            sc.latitude, sc.longitude, sc.gps_gap_seconds, sc.gps_gap_count,
            sc.auto_status, sc.auto_reason,
            sc.override_status, sc.override_reason, sc.final_status,
            sc.distance_km, sc.transport_mode, sc.has_gps_gap,
            sc.start_location_id, sc.start_location_name, sc.start_location_type,
            sc.end_location_id, sc.end_location_name, sc.end_location_type,
            sc.shift_type, sc.shift_type_source,
            sc.is_edited, sc.original_value,
            NULL::JSONB AS children
        FROM all_stops sc

        UNION ALL

        -- Trips
        SELECT
            td.activity_type, td.activity_id, td.shift_id,
            td.started_at, td.ended_at, td.duration_minutes,
            td.matched_location_id, td.location_name, td.location_type,
            td.latitude, td.longitude, td.gps_gap_seconds, td.gps_gap_count,
            td.auto_status, td.auto_reason,
            tao.override_status, tao.reason AS override_reason,
            COALESCE(tao.override_status, td.auto_status) AS final_status,
            td.distance_km, td.transport_mode, td.has_gps_gap,
            td.start_location_id, td.start_location_name, td.start_location_type,
            td.end_location_id, td.end_location_name, td.end_location_type,
            td.shift_type, td.shift_type_source,
            FALSE AS is_edited, NULL::TIMESTAMPTZ AS original_value,
            NULL::JSONB AS children
        FROM trip_data td
        LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides tao ON tao.day_approval_id = da.id
            AND tao.activity_type = 'trip' AND tao.activity_id = td.activity_id

        UNION ALL

        -- Clock events
        SELECT
            cd.activity_type, cd.activity_id, cd.shift_id,
            cd.started_at, cd.ended_at, cd.duration_minutes,
            cd.matched_location_id, cd.location_name, cd.location_type,
            cd.latitude, cd.longitude, cd.gps_gap_seconds, cd.gps_gap_count,
            cd.auto_status, cd.auto_reason,
            cao.override_status, cao.reason AS override_reason,
            COALESCE(cao.override_status, cd.auto_status) AS final_status,
            cd.distance_km, cd.transport_mode, cd.has_gps_gap,
            cd.start_location_id, cd.start_location_name, cd.start_location_type,
            cd.end_location_id, cd.end_location_name, cd.end_location_type,
            cd.shift_type, cd.shift_type_source,
            cd.is_edited, cd.original_value,
            NULL::JSONB AS children
        FROM clock_data cd
        LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides cao ON cao.day_approval_id = da.id
            AND cao.activity_type = cd.activity_type AND cao.activity_id = cd.activity_id

        UNION ALL

        -- Lunch
        SELECT
            ld.activity_type, ld.activity_id, ld.shift_id,
            ld.started_at, ld.ended_at, ld.duration_minutes,
            ld.matched_location_id, ld.location_name, ld.location_type,
            ld.latitude, ld.longitude, ld.gps_gap_seconds, ld.gps_gap_count,
            ld.auto_status, ld.auto_reason,
            ld.override_status, ld.override_reason, ld.final_status,
            ld.distance_km, ld.transport_mode, ld.has_gps_gap,
            ld.start_location_id, ld.start_location_name, ld.start_location_type,
            ld.end_location_id, ld.end_location_name, ld.end_location_type,
            ld.shift_type, ld.shift_type_source,
            ld.is_edited, ld.original_value,
            ld.children
        FROM lunch_data ld

        ORDER BY started_at ASC
    )
    SELECT jsonb_agg(
        jsonb_build_object(
            'activity_type', c.activity_type,
            'activity_id', c.activity_id,
            'shift_id', c.shift_id,
            'started_at', c.started_at,
            'ended_at', c.ended_at,
            'duration_minutes', c.duration_minutes,
            'auto_status', c.auto_status,
            'auto_reason', c.auto_reason,
            'override_status', c.override_status,
            'override_reason', c.override_reason,
            'final_status', c.final_status,
            'matched_location_id', c.matched_location_id,
            'location_name', c.location_name,
            'location_type', c.location_type,
            'latitude', c.latitude,
            'longitude', c.longitude,
            'distance_km', c.distance_km,
            'transport_mode', c.transport_mode,
            'has_gps_gap', c.has_gps_gap,
            'start_location_id', c.start_location_id,
            'start_location_name', c.start_location_name,
            'start_location_type', c.start_location_type,
            'end_location_id', c.end_location_id,
            'end_location_name', c.end_location_name,
            'end_location_type', c.end_location_type,
            'gps_gap_seconds', c.gps_gap_seconds,
            'gps_gap_count', c.gps_gap_count,
            'shift_type', c.shift_type,
            'shift_type_source', c.shift_type_source,
            'is_edited', c.is_edited,
            'original_value', c.original_value,
            'children', c.children
        )
        ORDER BY c.started_at ASC
    )
    INTO v_activities
    FROM classified c;

    -- =====================================================================
    -- Gap detection: find >5min periods within completed shifts with no activity
    -- Excludes lunch segments from shift_boundaries
    -- =====================================================================
    WITH shift_boundaries AS (
        SELECT
            s.id AS shift_id,
            est.effective_clocked_in_at AS clocked_in_at,
            est.effective_clocked_out_at AS clocked_out_at
        FROM shifts s
        CROSS JOIN LATERAL effective_shift_times(s.id) est
        WHERE s.employee_id = p_employee_id
          AND s.clocked_in_at::DATE = p_date
          AND s.status = 'completed'
          AND est.effective_clocked_out_at IS NOT NULL
          AND NOT s.is_lunch
    ),
    activity_evts AS (
        -- Stops (1-min tolerance)
        SELECT
            sb.shift_id,
            GREATEST(sc.started_at, sb.clocked_in_at) AS evt_start,
            LEAST(sc.ended_at, sb.clocked_out_at) AS evt_end
        FROM shift_boundaries sb
        JOIN stationary_clusters sc
            ON sc.employee_id = p_employee_id
           AND sc.started_at >= sb.clocked_in_at - INTERVAL '1 minute'
           AND sc.started_at < sb.clocked_out_at
           AND sc.ended_at > sb.clocked_in_at
           AND sc.duration_seconds >= 180

        UNION ALL

        -- Trips (1-min tolerance)
        SELECT
            sb.shift_id,
            GREATEST(t.started_at, sb.clocked_in_at) AS evt_start,
            LEAST(t.ended_at, sb.clocked_out_at) AS evt_end
        FROM shift_boundaries sb
        JOIN trips t
            ON t.employee_id = p_employee_id
           AND t.started_at >= sb.clocked_in_at - INTERVAL '1 minute'
           AND t.started_at < sb.clocked_out_at
           AND t.ended_at > sb.clocked_in_at

        UNION ALL

        -- Lunch segments as coverage events (via work_body_id)
        SELECT
            sb.shift_id,
            GREATEST(s_lunch.clocked_in_at, sb.clocked_in_at) AS evt_start,
            LEAST(s_lunch.clocked_out_at, sb.clocked_out_at) AS evt_end
        FROM shift_boundaries sb
        JOIN shifts s_lunch ON s_lunch.employee_id = p_employee_id
           AND s_lunch.work_body_id = (SELECT work_body_id FROM shifts WHERE id = sb.shift_id)
           AND s_lunch.is_lunch = true AND s_lunch.clocked_out_at IS NOT NULL
    ),
    coverage_sorted AS (
        SELECT shift_id, evt_start, evt_end,
               ROW_NUMBER() OVER (PARTITION BY shift_id ORDER BY evt_start, evt_end DESC) AS rn
        FROM activity_evts
    ),
    coverage_with_max AS (
        SELECT cs.*,
               MAX(evt_end) OVER (PARTITION BY shift_id ORDER BY rn ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_max_end
        FROM coverage_sorted cs
    ),
    coverage_islands AS (
        SELECT shift_id, evt_start, evt_end,
               SUM(CASE WHEN rn = 1 OR evt_start > prev_max_end THEN 1 ELSE 0 END)
                   OVER (PARTITION BY shift_id ORDER BY rn) AS island_id
        FROM coverage_with_max
    ),
    coverage_spans AS (
        SELECT shift_id, island_id, MIN(evt_start) AS span_start, MAX(evt_end) AS span_end
        FROM coverage_islands
        GROUP BY shift_id, island_id
    ),
    spans_numbered AS (
        SELECT shift_id, span_start, span_end,
               ROW_NUMBER() OVER (PARTITION BY shift_id ORDER BY span_start) AS span_rn,
               COUNT(*) OVER (PARTITION BY shift_id) AS span_count
        FROM coverage_spans
    ),
    gap_candidates AS (
        -- Gap before first activity
        SELECT sb.shift_id, sb.clocked_in_at AS gap_start, sn.span_start AS gap_end
        FROM shift_boundaries sb
        JOIN spans_numbered sn ON sn.shift_id = sb.shift_id AND sn.span_rn = 1

        UNION ALL

        -- Gaps between spans
        SELECT sn1.shift_id, sn1.span_end AS gap_start, sn2.span_start AS gap_end
        FROM spans_numbered sn1
        JOIN spans_numbered sn2 ON sn2.shift_id = sn1.shift_id AND sn2.span_rn = sn1.span_rn + 1

        UNION ALL

        -- Gap after last activity
        SELECT sb.shift_id, sn.span_end AS gap_start, sb.clocked_out_at AS gap_end
        FROM shift_boundaries sb
        JOIN spans_numbered sn ON sn.shift_id = sb.shift_id AND sn.span_rn = sn.span_count

        UNION ALL

        -- Shifts with NO activities
        SELECT sb.shift_id, sb.clocked_in_at AS gap_start, sb.clocked_out_at AS gap_end
        FROM shift_boundaries sb
        WHERE NOT EXISTS (SELECT 1 FROM activity_evts ae WHERE ae.shift_id = sb.shift_id)
    )
    SELECT jsonb_agg(
        jsonb_build_object(
            'activity_type', 'gap',
            'activity_id', md5(p_employee_id::TEXT || '/gap/' || gc.gap_start::TEXT || '/' || gc.gap_end::TEXT)::UUID,
            'shift_id', gc.shift_id,
            'started_at', gc.gap_start,
            'ended_at', gc.gap_end,
            'duration_minutes', (EXTRACT(EPOCH FROM (gc.gap_end - gc.gap_start)) / 60)::INTEGER,
            'auto_status', 'needs_review',
            'auto_reason', 'Temps non suivi',
            'override_status', COALESCE(ao.override_status, NULL),
            'override_reason', COALESCE(ao.reason, NULL),
            'final_status', COALESCE(ao.override_status, 'needs_review'),
            'matched_location_id', NULL,
            'location_name', NULL,
            'location_type', NULL,
            'latitude', NULL,
            'longitude', NULL,
            'distance_km', NULL,
            'transport_mode', NULL,
            'has_gps_gap', TRUE,
            'start_location_id', NULL,
            'start_location_name', NULL,
            'start_location_type', NULL,
            'end_location_id', NULL,
            'end_location_name', NULL,
            'end_location_type', NULL,
            'gps_gap_seconds', (EXTRACT(EPOCH FROM (gc.gap_end - gc.gap_start)))::INTEGER,
            'gps_gap_count', 1,
            'shift_type', NULL,
            'shift_type_source', NULL,
            'is_edited', FALSE,
            'original_value', NULL,
            'children', NULL
        )
    )
    INTO v_gaps
    FROM gap_candidates gc
    LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
    LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
        AND ao.activity_type = 'gap'
        AND ao.activity_id = md5(p_employee_id::TEXT || '/gap/' || gc.gap_start::TEXT || '/' || gc.gap_end::TEXT)::UUID
    WHERE EXTRACT(EPOCH FROM (gc.gap_end - gc.gap_start)) > 300;

    -- Merge gaps into activities and re-sort
    IF v_gaps IS NOT NULL THEN
        SELECT jsonb_agg(elem ORDER BY elem->>'started_at' ASC)
        INTO v_activities
        FROM (
            SELECT jsonb_array_elements(COALESCE(v_activities, '[]'::JSONB)) AS elem
            UNION ALL
            SELECT jsonb_array_elements(v_gaps) AS elem
        ) combined;
    END IF;

    -- Compute summary -- needs_review_count includes stop_segment
    SELECT
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (WHERE a->>'final_status' = 'approved' AND a->>'activity_type' NOT IN ('lunch', 'gap')), 0),
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (WHERE a->>'final_status' = 'rejected' AND a->>'activity_type' NOT IN ('gap', 'lunch')), 0),
        COALESCE(COUNT(*) FILTER (WHERE a->>'final_status' = 'needs_review'
            AND NOT (
                a->>'activity_type' IN ('clock_in', 'clock_out', 'lunch')
                AND EXISTS (
                    SELECT 1 FROM jsonb_array_elements(COALESCE(v_activities, '[]'::JSONB)) s
                    WHERE s->>'activity_type' IN ('stop', 'stop_segment')
                      AND (a->>'started_at')::TIMESTAMPTZ >= ((s->>'started_at')::TIMESTAMPTZ - INTERVAL '60 seconds')
                      AND (a->>'started_at')::TIMESTAMPTZ <= ((s->>'ended_at')::TIMESTAMPTZ + INTERVAL '60 seconds')
                )
            )
        ), 0)
    INTO v_approved_minutes, v_rejected_minutes, v_needs_review_count
    FROM jsonb_array_elements(COALESCE(v_activities, '[]'::JSONB)) a;

    -- If day is already approved, use frozen totals
    IF v_day_approval.status = 'approved' THEN
        v_approved_minutes := v_day_approval.approved_minutes;
        v_rejected_minutes := v_day_approval.rejected_minutes;
        v_needs_review_count := 0;
    END IF;

    -- Cap approved minutes at shift duration (activities can extend beyond shift boundaries)
    v_approved_minutes := LEAST(v_approved_minutes, v_total_shift_minutes);

    v_result := jsonb_build_object(
        'employee_id', p_employee_id,
        'date', p_date,
        'has_active_shift', v_has_active_shift,
        'approval_status', COALESCE(v_day_approval.status, 'pending'),
        'approved_by', v_day_approval.approved_by,
        'approved_at', v_day_approval.approved_at,
        'notes', v_day_approval.notes,
        'activities', COALESCE(v_activities, '[]'::JSONB),
        'summary', jsonb_build_object(
            'total_shift_minutes', v_total_shift_minutes,
            'approved_minutes', v_approved_minutes,
            'rejected_minutes', v_rejected_minutes,
            'needs_review_count', v_needs_review_count,
            'lunch_minutes', v_lunch_minutes,
            'call_count', v_call_count,
            'call_billed_minutes', v_call_billed_minutes,
            'call_bonus_minutes', v_call_bonus_minutes
        )
    );

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
