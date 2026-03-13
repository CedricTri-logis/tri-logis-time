-- =============================================================================
-- Restore clock events without GPS + gap detection in get_day_approval_detail
-- =============================================================================
-- Fixes 3 issues:
--
-- 1. DISABLE flag_gpsless_shifts cron: shifts should remain active until
--    manual clock-out. GPS points can arrive later via offline sync.
--
-- 2. SHOW clock-in/clock-out events even when clock_in/out_location IS NULL:
--    If GPS was unavailable at clock time, the event still happened. Show it
--    with needs_review status instead of hiding it entirely.
--
-- 3. RESTORE gap detection lost in migration 147: Gaps between clock-in →
--    first activity, last activity → clock-out, and between consecutive
--    activities (> 5 min) are shown as "Temps non suivi" needs_review rows.
--    Includes lunch breaks as covered periods (not counted as gaps).
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Disable the flag-gpsless-shifts cron job
-- ─────────────────────────────────────────────────────────────────────────────
SELECT cron.unschedule('flag-gpsless-shifts');

-- ─────────────────────────────────────────────────────────────────────────────
-- 2+3. Rewrite get_day_approval_detail with clock events + gap detection
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_day_approval_detail(
    p_employee_id UUID,
    p_date DATE
)
RETURNS JSONB AS $$
DECLARE
    v_result JSONB;
    v_activities JSONB;
    v_project_sessions JSONB;
    v_day_approval RECORD;
    v_total_shift_minutes INTEGER;
    v_approved_minutes INTEGER := 0;
    v_rejected_minutes INTEGER := 0;
    v_needs_review_count INTEGER := 0;
    v_has_active_shift BOOLEAN := FALSE;
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

    -- If already approved, fall through to activity building
    IF v_day_approval.status = 'approved' THEN
        NULL;
    END IF;

    -- Calculate total shift minutes for completed shifts on this day
    SELECT COALESCE(SUM(
        EXTRACT(EPOCH FROM (COALESCE(clocked_out_at, now()) - clocked_in_at)) / 60
    )::INTEGER, 0)
    INTO v_total_shift_minutes
    FROM shifts
    WHERE employee_id = p_employee_id
      AND clocked_in_at::DATE = p_date
      AND status = 'completed';

    -- =====================================================================
    -- Build classified activity list
    -- Pipeline: stops → stop_classified → trips → clocks → lunch →
    --           gap detection → all_activity_data → classified
    -- =====================================================================
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
            NULL::TEXT AS end_location_type
        FROM stationary_clusters sc
        LEFT JOIN locations l ON l.id = sc.matched_location_id
        WHERE sc.employee_id = p_employee_id
          AND sc.started_at >= p_date::TIMESTAMPTZ
          AND sc.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
          AND sc.duration_seconds >= 180
    ),
    stop_classified AS (
        SELECT
            sd.*,
            ao.override_status,
            ao.reason AS override_reason,
            COALESCE(ao.override_status, sd.auto_status) AS final_status
        FROM stop_data sd
        LEFT JOIN day_approvals da
            ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides ao
            ON ao.day_approval_id = da.id
           AND ao.activity_type = 'stop'
           AND ao.activity_id = sd.activity_id
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
                WHEN t.has_gps_gap = TRUE THEN 'needs_review'
                WHEN t.duration_minutes > 60 THEN 'needs_review'
                WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'rejected'
                WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'approved'
                ELSE 'needs_review'
            END AS auto_status,
            CASE
                WHEN t.has_gps_gap = TRUE THEN 'Données GPS incomplètes'
                WHEN t.duration_minutes > 60 THEN 'Trajet anormalement long (>' || t.duration_minutes || ' min)'
                WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'Trajet vers/depuis lieu non autorisé'
                WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'Déplacement professionnel'
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
            COALESCE(el.location_type, arr_loc.location_type)::TEXT AS end_location_type
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
        LEFT JOIN LATERAL (
            SELECT sc_dep.final_status
            FROM stop_classified sc_dep
            WHERE sc_dep.ended_at BETWEEN t.started_at - INTERVAL '2 minutes' AND t.started_at + INTERVAL '2 minutes'
            ORDER BY ABS(EXTRACT(EPOCH FROM (sc_dep.ended_at - t.started_at)))
            LIMIT 1
        ) dep_stop ON TRUE
        LEFT JOIN LATERAL (
            SELECT sc_arr.final_status
            FROM stop_classified sc_arr
            WHERE sc_arr.started_at BETWEEN t.ended_at - INTERVAL '2 minutes' AND t.ended_at + INTERVAL '2 minutes'
            ORDER BY ABS(EXTRACT(EPOCH FROM (sc_arr.started_at - t.ended_at)))
            LIMIT 1
        ) arr_stop ON TRUE
        WHERE t.employee_id = p_employee_id
          AND t.started_at >= p_date::TIMESTAMPTZ
          AND t.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
    ),
    clock_data AS (
        -- CLOCK IN (no longer requires clock_in_location IS NOT NULL)
        SELECT
            'clock_in'::TEXT AS activity_type,
            s.id AS activity_id,
            s.id AS shift_id,
            s.clocked_in_at AS started_at,
            s.clocked_in_at AS ended_at,
            0 AS duration_minutes,
            ci_loc.id AS matched_location_id,
            ci_loc.name AS location_name,
            ci_loc.location_type::TEXT AS location_type,
            (s.clock_in_location->>'latitude')::DECIMAL AS latitude,
            (s.clock_in_location->>'longitude')::DECIMAL AS longitude,
            NULL::INTEGER AS gps_gap_seconds,
            NULL::INTEGER AS gps_gap_count,
            CASE
                WHEN ci_loc.location_type IN ('office', 'building') THEN 'approved'
                WHEN ci_loc.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                WHEN ci_loc.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN s.clock_in_location IS NULL THEN 'needs_review'
                WHEN ci_loc.id IS NULL THEN 'rejected'
                ELSE 'rejected'
            END AS auto_status,
            CASE
                WHEN ci_loc.location_type IN ('office', 'building') THEN 'Clock-in sur lieu de travail'
                WHEN ci_loc.location_type = 'vendor' THEN 'Clock-in chez fournisseur (à vérifier)'
                WHEN ci_loc.location_type = 'gaz' THEN 'Clock-in station-service (à vérifier)'
                WHEN ci_loc.location_type = 'home' THEN 'Clock-in depuis le domicile'
                WHEN ci_loc.location_type IN ('cafe_restaurant', 'other') THEN 'Clock-in hors lieu de travail'
                WHEN s.clock_in_location IS NULL THEN 'Clock-in sans données GPS'
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
            NULL::TEXT AS end_location_type
        FROM shifts s
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

        UNION ALL

        -- CLOCK OUT (no longer requires clock_out_location IS NOT NULL)
        SELECT
            'clock_out'::TEXT,
            s.id,
            s.id AS shift_id,
            s.clocked_out_at,
            s.clocked_out_at,
            0 AS duration_minutes,
            co_loc.id AS matched_location_id,
            co_loc.name AS location_name,
            co_loc.location_type::TEXT AS location_type,
            (s.clock_out_location->>'latitude')::DECIMAL,
            (s.clock_out_location->>'longitude')::DECIMAL,
            NULL::INTEGER, NULL::INTEGER,
            CASE
                WHEN co_loc.location_type IN ('office', 'building') THEN 'approved'
                WHEN co_loc.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                WHEN co_loc.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN s.clock_out_location IS NULL THEN 'needs_review'
                WHEN co_loc.id IS NULL THEN 'rejected'
                ELSE 'rejected'
            END,
            CASE
                WHEN co_loc.location_type IN ('office', 'building') THEN 'Clock-out sur lieu de travail'
                WHEN co_loc.location_type = 'vendor' THEN 'Clock-out chez fournisseur (à vérifier)'
                WHEN co_loc.location_type = 'gaz' THEN 'Clock-out station-service (à vérifier)'
                WHEN co_loc.location_type = 'home' THEN 'Clock-out au domicile'
                WHEN co_loc.location_type IN ('cafe_restaurant', 'other') THEN 'Clock-out hors lieu de travail'
                WHEN s.clock_out_location IS NULL THEN 'Clock-out sans données GPS'
                WHEN co_loc.id IS NULL THEN 'Clock-out lieu non autorisé'
                ELSE 'Clock-out lieu non autorisé'
            END,
            NULL::DECIMAL, NULL::TEXT, NULL::BOOLEAN,
            NULL::UUID, NULL::TEXT, NULL::TEXT,
            NULL::UUID, NULL::TEXT, NULL::TEXT
        FROM shifts s
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
          AND s.clocked_out_at::DATE = p_date
          AND s.status = 'completed'
          AND s.clocked_out_at IS NOT NULL
    ),

    -- LUNCH BREAKS
    lunch_data AS (
        SELECT
            'lunch'::TEXT AS activity_type,
            lb.id AS activity_id,
            lb.shift_id,
            lb.started_at,
            lb.ended_at,
            EXTRACT(EPOCH FROM (lb.ended_at - lb.started_at))::INTEGER / 60 AS duration_minutes,
            NULL::UUID AS matched_location_id,
            NULL::TEXT AS location_name,
            NULL::TEXT AS location_type,
            NULL::DECIMAL AS latitude,
            NULL::DECIMAL AS longitude,
            0::INTEGER AS gps_gap_seconds,
            0::INTEGER AS gps_gap_count,
            'approved'::TEXT AS auto_status,
            'Pause diner'::TEXT AS auto_reason,
            NULL::DECIMAL AS distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type
        FROM lunch_breaks lb
        WHERE lb.employee_id = p_employee_id
          AND lb.ended_at IS NOT NULL
          AND lb.started_at >= p_date::TIMESTAMPTZ
          AND lb.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
    ),

    -- ─────────────────────────────────────────────────────────────────────
    -- GAP DETECTION: find untracked periods > 5 min within shifts
    -- ─────────────────────────────────────────────────────────────────────
    -- Real activities that cover time (stops, trips, lunches)
    real_activities AS (
        SELECT sd.shift_id, sd.started_at, sd.ended_at
        FROM stop_data sd
        UNION ALL
        SELECT td.shift_id, td.started_at, td.ended_at
        FROM trip_data td
        UNION ALL
        SELECT lb.shift_id, lb.started_at, lb.ended_at
        FROM lunch_breaks lb
        WHERE lb.employee_id = p_employee_id
          AND lb.ended_at IS NOT NULL
          AND lb.started_at >= p_date::TIMESTAMPTZ
          AND lb.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
    ),
    -- Shift boundaries (completed shifts with clock-out)
    shift_boundaries AS (
        SELECT s.id AS shift_id, s.clocked_in_at, s.clocked_out_at
        FROM shifts s
        WHERE s.employee_id = p_employee_id
          AND s.clocked_in_at::DATE = p_date
          AND s.status = 'completed'
          AND s.clocked_out_at IS NOT NULL
    ),
    -- All events: clock-in(0), activity-end(1), activity-start(2), clock-out(3)
    shift_events AS (
        SELECT sb.shift_id, sb.clocked_in_at AS event_time, 0 AS event_order
        FROM shift_boundaries sb
        UNION ALL
        SELECT ra.shift_id, ra.ended_at, 1
        FROM real_activities ra
        UNION ALL
        SELECT ra.shift_id, ra.started_at, 2
        FROM real_activities ra
        UNION ALL
        SELECT sb.shift_id, sb.clocked_out_at, 3
        FROM shift_boundaries sb
    ),
    ordered_events AS (
        SELECT
            shift_id, event_time, event_order,
            ROW_NUMBER() OVER (PARTITION BY shift_id ORDER BY event_time, event_order) AS rn
        FROM shift_events
    ),
    -- Find gaps > 5 min between consecutive boundary/activity edges
    gap_pairs AS (
        SELECT
            e1.shift_id,
            e1.event_time AS gap_started_at,
            e2.event_time AS gap_ended_at,
            EXTRACT(EPOCH FROM (e2.event_time - e1.event_time))::INTEGER AS gap_seconds
        FROM ordered_events e1
        JOIN ordered_events e2 ON e1.shift_id = e2.shift_id AND e2.rn = e1.rn + 1
        WHERE e1.event_order IN (0, 1)   -- after clock-in or after activity-end
          AND e2.event_order IN (2, 3)   -- before activity-start or before clock-out
          AND EXTRACT(EPOCH FROM (e2.event_time - e1.event_time)) > 300
    ),
    -- Entire shift is a gap (0 GPS activities)
    empty_shift_gaps AS (
        SELECT
            sb.shift_id,
            sb.clocked_in_at AS gap_started_at,
            sb.clocked_out_at AS gap_ended_at,
            EXTRACT(EPOCH FROM (sb.clocked_out_at - sb.clocked_in_at))::INTEGER AS gap_seconds
        FROM shift_boundaries sb
        WHERE NOT EXISTS (SELECT 1 FROM real_activities ra WHERE ra.shift_id = sb.shift_id)
          AND NOT EXISTS (SELECT 1 FROM gap_pairs gp WHERE gp.shift_id = sb.shift_id)
          AND EXTRACT(EPOCH FROM (sb.clocked_out_at - sb.clocked_in_at)) > 300
    ),
    all_gaps AS (
        SELECT * FROM gap_pairs
        UNION ALL
        SELECT * FROM empty_shift_gaps
    ),
    gap_activities AS (
        SELECT
            'gap'::TEXT AS activity_type,
            md5(p_employee_id::TEXT || '/gap/' || g.gap_started_at::TEXT || '/' || g.gap_ended_at::TEXT)::UUID AS activity_id,
            g.shift_id,
            g.gap_started_at AS started_at,
            g.gap_ended_at AS ended_at,
            (g.gap_seconds / 60)::INTEGER AS duration_minutes,
            NULL::UUID AS matched_location_id,
            NULL::TEXT AS location_name,
            NULL::TEXT AS location_type,
            NULL::DECIMAL AS latitude,
            NULL::DECIMAL AS longitude,
            0::INTEGER AS gps_gap_seconds,
            0::INTEGER AS gps_gap_count,
            'needs_review'::TEXT AS auto_status,
            'Temps non suivi'::TEXT AS auto_reason,
            NULL::DECIMAL AS distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type
        FROM all_gaps g
    ),

    -- ─────────────────────────────────────────────────────────────────────
    -- CLASSIFIED: merge all activity types with overrides
    -- ─────────────────────────────────────────────────────────────────────
    classified AS (
        -- Stops (already have override merged in stop_classified)
        SELECT
            sc.activity_type, sc.activity_id, sc.shift_id,
            sc.started_at, sc.ended_at, sc.duration_minutes,
            sc.matched_location_id, sc.location_name, sc.location_type,
            sc.latitude, sc.longitude, sc.gps_gap_seconds, sc.gps_gap_count,
            sc.auto_status, sc.auto_reason,
            sc.override_status, sc.override_reason, sc.final_status,
            sc.distance_km, sc.transport_mode, sc.has_gps_gap,
            sc.start_location_id, sc.start_location_name, sc.start_location_type,
            sc.end_location_id, sc.end_location_name, sc.end_location_type
        FROM stop_classified sc

        UNION ALL

        -- Trips with overrides
        SELECT
            td.activity_type, td.activity_id, td.shift_id,
            td.started_at, td.ended_at, td.duration_minutes,
            td.matched_location_id, td.location_name, td.location_type,
            td.latitude, td.longitude, td.gps_gap_seconds, td.gps_gap_count,
            td.auto_status, td.auto_reason,
            tao.override_status,
            tao.reason AS override_reason,
            COALESCE(tao.override_status, td.auto_status) AS final_status,
            td.distance_km, td.transport_mode, td.has_gps_gap,
            td.start_location_id, td.start_location_name, td.start_location_type,
            td.end_location_id, td.end_location_name, td.end_location_type
        FROM trip_data td
        LEFT JOIN day_approvals da
            ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides tao
            ON tao.day_approval_id = da.id
           AND tao.activity_type = 'trip'
           AND tao.activity_id = td.activity_id

        UNION ALL

        -- Clock events with overrides
        SELECT
            cd.activity_type, cd.activity_id, cd.shift_id,
            cd.started_at, cd.ended_at, cd.duration_minutes,
            cd.matched_location_id, cd.location_name, cd.location_type,
            cd.latitude, cd.longitude, cd.gps_gap_seconds, cd.gps_gap_count,
            cd.auto_status, cd.auto_reason,
            cao.override_status,
            cao.reason AS override_reason,
            COALESCE(cao.override_status, cd.auto_status) AS final_status,
            cd.distance_km, cd.transport_mode, cd.has_gps_gap,
            cd.start_location_id, cd.start_location_name, cd.start_location_type,
            cd.end_location_id, cd.end_location_name, cd.end_location_type
        FROM clock_data cd
        LEFT JOIN day_approvals da
            ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides cao
            ON cao.day_approval_id = da.id
           AND cao.activity_type = cd.activity_type
           AND cao.activity_id = cd.activity_id

        UNION ALL

        -- Lunch breaks with overrides
        SELECT
            ld.activity_type, ld.activity_id, ld.shift_id,
            ld.started_at, ld.ended_at, ld.duration_minutes,
            ld.matched_location_id, ld.location_name, ld.location_type,
            ld.latitude, ld.longitude, ld.gps_gap_seconds, ld.gps_gap_count,
            ld.auto_status, ld.auto_reason,
            lao.override_status,
            lao.reason AS override_reason,
            COALESCE(lao.override_status, ld.auto_status) AS final_status,
            ld.distance_km, ld.transport_mode, ld.has_gps_gap,
            ld.start_location_id, ld.start_location_name, ld.start_location_type,
            ld.end_location_id, ld.end_location_name, ld.end_location_type
        FROM lunch_data ld
        LEFT JOIN day_approvals da
            ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides lao
            ON lao.day_approval_id = da.id
           AND lao.activity_type = 'lunch'
           AND lao.activity_id = ld.activity_id

        UNION ALL

        -- Gap activities with overrides
        SELECT
            ga.activity_type, ga.activity_id, ga.shift_id,
            ga.started_at, ga.ended_at, ga.duration_minutes,
            ga.matched_location_id, ga.location_name, ga.location_type,
            ga.latitude, ga.longitude, ga.gps_gap_seconds, ga.gps_gap_count,
            ga.auto_status, ga.auto_reason,
            gao.override_status,
            gao.reason AS override_reason,
            COALESCE(gao.override_status, ga.auto_status) AS final_status,
            ga.distance_km, ga.transport_mode, ga.has_gps_gap,
            ga.start_location_id, ga.start_location_name, ga.start_location_type,
            ga.end_location_id, ga.end_location_name, ga.end_location_type
        FROM gap_activities ga
        LEFT JOIN day_approvals da
            ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides gao
            ON gao.day_approval_id = da.id
           AND gao.activity_type = 'gap'
           AND gao.activity_id = ga.activity_id

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
            'gps_gap_count', c.gps_gap_count
        )
        ORDER BY c.started_at ASC
    )
    INTO v_activities
    FROM classified c;

    -- =====================================================================
    -- Project sessions (cleaning + maintenance) with location_id
    -- =====================================================================
    WITH all_project_sessions AS (
        SELECT
            'cleaning'::TEXT AS session_type,
            cs.id AS session_id,
            cs.started_at,
            COALESCE(cs.completed_at, now()) AS ended_at,
            COALESCE(cs.duration_minutes,
                EXTRACT(EPOCH FROM (COALESCE(cs.completed_at, now()) - cs.started_at)) / 60
            )::NUMERIC(10,2) AS duration_minutes,
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

        UNION ALL

        SELECT
            'maintenance'::TEXT AS session_type,
            ms.id AS session_id,
            ms.started_at,
            COALESCE(ms.completed_at, now()) AS ended_at,
            COALESCE(ms.duration_minutes,
                EXTRACT(EPOCH FROM (COALESCE(ms.completed_at, now()) - ms.started_at)) / 60
            )::NUMERIC(10,2) AS duration_minutes,
            pb.name AS building_name,
            a.unit_number AS unit_label,
            COALESCE(a.apartment_category, 'building')::TEXT AS unit_type,
            ms.status::TEXT AS session_status,
            pb.location_id
        FROM maintenance_sessions ms
        JOIN property_buildings pb ON pb.id = ms.building_id
        LEFT JOIN apartments a ON a.id = ms.apartment_id
        WHERE ms.employee_id = p_employee_id
          AND ms.started_at >= p_date::TIMESTAMPTZ
          AND ms.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
    )
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'session_type', ps.session_type,
            'session_id', ps.session_id,
            'started_at', ps.started_at,
            'ended_at', ps.ended_at,
            'duration_minutes', ps.duration_minutes,
            'building_name', ps.building_name,
            'unit_label', ps.unit_label,
            'unit_type', ps.unit_type,
            'session_status', ps.session_status,
            'location_id', ps.location_id
        )
        ORDER BY ps.started_at ASC
    ), '[]'::JSONB)
    INTO v_project_sessions
    FROM all_project_sessions ps;

    -- =====================================================================
    -- Summary: approved/rejected minutes + needs_review count
    -- Excludes lunch from approved_minutes (subtracted from total instead)
    -- Excludes clock events that overlap with a stop (±60s) from review count
    -- =====================================================================
    SELECT
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (
            WHERE a->>'final_status' = 'approved' AND a->>'activity_type' != 'lunch'
        ), 0),
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (
            WHERE a->>'final_status' = 'rejected'
        ), 0),
        COALESCE(COUNT(*) FILTER (WHERE
            a->>'final_status' = 'needs_review'
            AND NOT (
                a->>'activity_type' IN ('clock_in', 'clock_out')
                AND EXISTS (
                    SELECT 1 FROM jsonb_array_elements(COALESCE(v_activities, '[]'::JSONB)) s
                    WHERE s->>'activity_type' = 'stop'
                      AND (a->>'started_at')::TIMESTAMPTZ >= ((s->>'started_at')::TIMESTAMPTZ - INTERVAL '60 seconds')
                      AND (a->>'started_at')::TIMESTAMPTZ <= ((s->>'ended_at')::TIMESTAMPTZ + INTERVAL '60 seconds')
                )
            )
        ), 0)
    INTO v_approved_minutes, v_rejected_minutes, v_needs_review_count
    FROM jsonb_array_elements(COALESCE(v_activities, '[]'::JSONB)) a;

    -- If day is already approved, use frozen values
    IF v_day_approval.status = 'approved' THEN
        v_approved_minutes := v_day_approval.approved_minutes;
        v_rejected_minutes := v_day_approval.rejected_minutes;
        v_needs_review_count := 0;
    END IF;

    -- Build result
    v_result := jsonb_build_object(
        'employee_id', p_employee_id,
        'date', p_date,
        'has_active_shift', v_has_active_shift,
        'approval_status', COALESCE(v_day_approval.status, 'pending'),
        'approved_by', v_day_approval.approved_by,
        'approved_at', v_day_approval.approved_at,
        'notes', v_day_approval.notes,
        'activities', COALESCE(v_activities, '[]'::JSONB),
        'project_sessions', v_project_sessions,
        'summary', jsonb_build_object(
            'total_shift_minutes', v_total_shift_minutes,
            'approved_minutes', v_approved_minutes,
            'rejected_minutes', v_rejected_minutes,
            'needs_review_count', v_needs_review_count
        )
    );

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
