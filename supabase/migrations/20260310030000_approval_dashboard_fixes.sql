-- Migration: Approval Dashboard Fixes
-- Spec: docs/superpowers/specs/2026-03-10-approval-dashboard-fixes-design.md
--
-- Changes:
-- 1. Add gps_health column to shifts
-- 2. Rewrite flag_gpsless_shifts (non-destructive flag + midnight close)
-- 3. Create merge_same_location_clusters function
-- 4. Add step 9 to detect_trips (call merge_same_location_clusters)
-- 5. Fix _get_day_approval_detail_base (clock events without location + gap detection + has_stale_gps)
-- 6. Data fix: rerun detect_trips for Celine March 9

-- ============================================================
-- 1. Add gps_health column to shifts
-- ============================================================
ALTER TABLE shifts ADD COLUMN IF NOT EXISTS gps_health TEXT DEFAULT 'ok';
COMMENT ON COLUMN shifts.gps_health IS 'GPS signal health: ok = normal, stale = no GPS points received for 10+ min while shift active';

-- ============================================================
-- 2. Rewrite flag_gpsless_shifts: flag instead of close + midnight close
-- ============================================================
CREATE OR REPLACE FUNCTION flag_gpsless_shifts()
RETURNS void AS $$
DECLARE
    v_shift RECORD;
    v_now_est TIMESTAMP;
    v_today_est DATE;
BEGIN
    -- Current time in EST
    v_now_est := now() AT TIME ZONE 'America/Toronto';
    v_today_est := v_now_est::DATE;

    -- Part A: Flag stale GPS (active shifts with 0 GPS after 10 min)
    -- Does NOT close the shift — just sets gps_health = 'stale'
    UPDATE shifts SET gps_health = 'stale'
    WHERE status = 'active'
      AND gps_health = 'ok'
      AND clocked_in_at < NOW() - INTERVAL '10 minutes'
      AND NOT EXISTS (
          SELECT 1 FROM gps_points gp WHERE gp.shift_id = shifts.id
      );

    -- Reset stale flag if GPS points have arrived since last check
    UPDATE shifts SET gps_health = 'ok'
    WHERE status = 'active'
      AND gps_health = 'stale'
      AND EXISTS (
          SELECT 1 FROM gps_points gp WHERE gp.shift_id = shifts.id
      );

    -- Part B: Midnight auto-close
    -- Close any active shift where the clock-in date (EST) is before today (EST)
    FOR v_shift IN
        SELECT s.id, s.employee_id, s.clocked_in_at
        FROM shifts s
        WHERE s.status = 'active'
          AND (s.clocked_in_at AT TIME ZONE 'America/Toronto')::DATE < v_today_est
    LOOP
        UPDATE shifts SET
            status = 'completed',
            clocked_out_at = (
                (v_shift.clocked_in_at AT TIME ZONE 'America/Toronto')::DATE + INTERVAL '23 hours 59 minutes 59 seconds'
            ) AT TIME ZONE 'America/Toronto',
            clock_out_reason = 'midnight_auto_close',
            gps_health = CASE
                WHEN EXISTS (SELECT 1 FROM gps_points gp WHERE gp.shift_id = v_shift.id)
                THEN 'ok' ELSE 'stale'
            END
        WHERE id = v_shift.id;

        -- Run trip/cluster detection for the closed shift
        PERFORM detect_trips(v_shift.id);

        RAISE NOTICE 'Midnight-closed shift % for employee %',
            v_shift.id, v_shift.employee_id;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 3. Create merge_same_location_clusters function
-- ============================================================
CREATE OR REPLACE FUNCTION merge_same_location_clusters(p_shift_id UUID)
RETURNS void AS $$
DECLARE
    v_merge RECORD;
    v_keep_id UUID;
    v_total_points INTEGER;
    v_total_gap_seconds INTEGER;
    v_total_gap_count INTEGER;
    v_did_merge BOOLEAN := FALSE;
BEGIN
    -- Find pairs of consecutive clusters at the same location with no trip between them
    FOR v_merge IN
        WITH ordered AS (
            SELECT
                sc.id,
                sc.matched_location_id,
                sc.started_at,
                sc.ended_at,
                sc.duration_seconds,
                sc.gps_point_count,
                sc.gps_gap_seconds,
                sc.gps_gap_count,
                ROW_NUMBER() OVER (ORDER BY sc.started_at) AS rn
            FROM stationary_clusters sc
            WHERE sc.shift_id = p_shift_id
              AND sc.matched_location_id IS NOT NULL
        ),
        pairs AS (
            SELECT
                c1.id AS id1, c2.id AS id2,
                c1.matched_location_id,
                c1.started_at AS start1, c1.ended_at AS end1,
                c2.started_at AS start2, c2.ended_at AS end2,
                c1.gps_point_count AS points1, c2.gps_point_count AS points2,
                COALESCE(c1.gps_gap_seconds, 0) AS gap_sec1,
                COALESCE(c2.gps_gap_seconds, 0) AS gap_sec2,
                COALESCE(c1.gps_gap_count, 0) AS gap_cnt1,
                COALESCE(c2.gps_gap_count, 0) AS gap_cnt2,
                EXTRACT(EPOCH FROM (c2.started_at - c1.ended_at))::INTEGER AS between_gap_sec
            FROM ordered c1
            JOIN ordered c2 ON c2.rn = c1.rn + 1
            WHERE c1.matched_location_id = c2.matched_location_id
              AND NOT EXISTS (
                  SELECT 1 FROM trips t
                  WHERE t.shift_id = p_shift_id
                    AND t.started_at >= c1.ended_at - INTERVAL '30 seconds'
                    AND t.ended_at <= c2.started_at + INTERVAL '30 seconds'
              )
        )
        SELECT * FROM pairs
        ORDER BY start1
    LOOP
        v_keep_id := v_merge.id1;
        v_total_points := COALESCE(v_merge.points1, 0) + COALESCE(v_merge.points2, 0);
        v_total_gap_seconds := v_merge.gap_sec1 + v_merge.gap_sec2 + GREATEST(v_merge.between_gap_sec, 0);
        v_total_gap_count := v_merge.gap_cnt1 + v_merge.gap_cnt2 + 1;

        -- Extend the kept cluster to span both
        UPDATE stationary_clusters SET
            ended_at = v_merge.end2,
            duration_seconds = EXTRACT(EPOCH FROM (v_merge.end2 - started_at))::INTEGER,
            gps_point_count = v_total_points,
            gps_gap_seconds = v_total_gap_seconds,
            gps_gap_count = v_total_gap_count
        WHERE id = v_keep_id;

        -- Move GPS points from absorbed cluster
        UPDATE gps_points SET stationary_cluster_id = v_keep_id
        WHERE stationary_cluster_id = v_merge.id2;

        -- Update trip references
        UPDATE trips SET start_cluster_id = v_keep_id WHERE start_cluster_id = v_merge.id2;
        UPDATE trips SET end_cluster_id = v_keep_id WHERE end_cluster_id = v_merge.id2;

        -- Delete self-referencing trips (start=end same cluster after merge)
        DELETE FROM trip_gps_points WHERE trip_id IN (
            SELECT id FROM trips
            WHERE start_cluster_id = v_keep_id AND end_cluster_id = v_keep_id
        );
        DELETE FROM trips
        WHERE start_cluster_id = v_keep_id AND end_cluster_id = v_keep_id;

        -- Delete the absorbed cluster
        DELETE FROM stationary_clusters WHERE id = v_merge.id2;

        v_did_merge := TRUE;
        RAISE NOTICE 'Merged cluster % into % (same location)', v_merge.id2, v_keep_id;
    END LOOP;

    -- Recurse if merges happened (chain of 3+ consecutive same-location clusters)
    IF v_did_merge THEN
        PERFORM merge_same_location_clusters(p_shift_id);
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 4. Add step 9 to detect_trips: merge same-location clusters
-- Uses dynamic SQL to patch the existing function without rewriting all 800 lines.
-- ============================================================
DO $$
DECLARE
    v_old_src TEXT;
    v_new_src TEXT;
    v_full_def TEXT;
BEGIN
    -- Get current function body
    SELECT prosrc INTO v_old_src
    FROM pg_proc WHERE proname = 'detect_trips' AND pronargs = 1;

    -- Check if already patched
    IF v_old_src LIKE '%merge_same_location_clusters%' THEN
        RAISE NOTICE 'detect_trips already has merge_same_location_clusters — skipping';
        RETURN;
    END IF;

    -- Add step 9 after compute_gps_gaps, before the final END;
    v_new_src := regexp_replace(
        v_old_src,
        E'(PERFORM compute_gps_gaps\\(p_shift_id\\);)',
        E'\\1\n\n    -- =========================================================================\n    -- 9. Post-processing: merge consecutive same-location clusters\n    -- =========================================================================\n    IF v_create_clusters THEN\n        PERFORM merge_same_location_clusters(p_shift_id);\n    END IF;'
    );

    -- Get full function definition (CREATE OR REPLACE ...)
    SELECT pg_get_functiondef(oid) INTO v_full_def
    FROM pg_proc WHERE proname = 'detect_trips' AND pronargs = 1;

    -- Replace old body with new body
    v_full_def := replace(v_full_def, v_old_src, v_new_src);

    -- Execute the modified function definition
    EXECUTE v_full_def;

    RAISE NOTICE 'detect_trips patched with step 9 (merge_same_location_clusters)';
END;
$$;

-- ============================================================
-- 5. Fix _get_day_approval_detail_base:
--    A) Clock events visible even without GPS location
--    B) Restore gap detection (lost in migration 147)
--    C) Add has_stale_gps to result
-- ============================================================
CREATE OR REPLACE FUNCTION _get_day_approval_detail_base(p_employee_id UUID, p_date DATE)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_result JSONB;
    v_activities JSONB;
    v_day_approval RECORD;
    v_total_shift_minutes INTEGER;
    v_lunch_minutes INTEGER := 0;
    v_approved_minutes INTEGER := 0;
    v_rejected_minutes INTEGER := 0;
    v_needs_review_count INTEGER := 0;
    v_has_active_shift BOOLEAN := FALSE;
    v_has_stale_gps BOOLEAN := FALSE;
BEGIN
    SELECT EXISTS(
        SELECT 1 FROM shifts
        WHERE employee_id = p_employee_id
          AND clocked_in_at::DATE = p_date
          AND status = 'active'
    ) INTO v_has_active_shift;

    -- Check for stale GPS
    SELECT EXISTS(
        SELECT 1 FROM shifts
        WHERE employee_id = p_employee_id
          AND clocked_in_at::DATE = p_date
          AND gps_health = 'stale'
    ) INTO v_has_stale_gps;

    SELECT * INTO v_day_approval
    FROM day_approvals
    WHERE employee_id = p_employee_id AND date = p_date;

    IF v_day_approval.status = 'approved' THEN
        NULL;
    END IF;

    SELECT COALESCE(SUM(
        EXTRACT(EPOCH FROM (COALESCE(clocked_out_at, now()) - clocked_in_at)) / 60
    )::INTEGER, 0)
    INTO v_total_shift_minutes
    FROM shifts
    WHERE employee_id = p_employee_id
      AND clocked_in_at::DATE = p_date
      AND status = 'completed';

    -- Calculate lunch minutes for this day
    SELECT COALESCE(SUM(
        EXTRACT(EPOCH FROM (lb.ended_at - lb.started_at)) / 60
    )::INTEGER, 0)
    INTO v_lunch_minutes
    FROM lunch_breaks lb
    WHERE lb.employee_id = p_employee_id
      AND lb.started_at::DATE = p_date
      AND lb.ended_at IS NOT NULL;

    -- Subtract lunch from total shift minutes
    v_total_shift_minutes := GREATEST(v_total_shift_minutes - v_lunch_minutes, 0);

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
        LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'stop' AND ao.activity_id = sd.activity_id
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
                WHEN t.has_gps_gap = TRUE THEN
                    CASE
                        WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'rejected'
                        WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'approved'
                        WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL THEN dep_stop.final_status
                        WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL THEN arr_stop.final_status
                        ELSE 'needs_review'
                    END
                WHEN t.duration_minutes > 60 THEN 'needs_review'
                WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'rejected'
                WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'approved'
                WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL THEN dep_stop.final_status
                WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL THEN arr_stop.final_status
                ELSE 'needs_review'
            END AS auto_status,
            CASE
                WHEN t.has_gps_gap = TRUE THEN
                    CASE
                        WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'Trajet vers/depuis lieu non autorisé'
                        WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'Déplacement professionnel'
                        WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL THEN
                            CASE WHEN dep_stop.final_status = 'approved' THEN 'Déplacement professionnel' ELSE 'Trajet vers/depuis lieu non autorisé' END
                        WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL THEN
                            CASE WHEN arr_stop.final_status = 'approved' THEN 'Déplacement professionnel' ELSE 'Trajet vers/depuis lieu non autorisé' END
                        ELSE 'Données GPS incomplètes'
                    END
                WHEN t.duration_minutes > 60 THEN 'Trajet anormalement long (>' || t.duration_minutes || ' min)'
                WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'Trajet vers/depuis lieu non autorisé'
                WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'Déplacement professionnel'
                WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL THEN
                    CASE WHEN dep_stop.final_status = 'approved' THEN 'Déplacement professionnel' ELSE 'Trajet vers/depuis lieu non autorisé' END
                WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL THEN
                    CASE WHEN arr_stop.final_status = 'approved' THEN 'Déplacement professionnel' ELSE 'Trajet vers/depuis lieu non autorisé' END
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
    -- *** CHANGE A+B: Clock events — removed clock_in/out_location IS NOT NULL filters ***
    clock_data AS (
        SELECT
            'clock_in'::TEXT AS activity_type,
            s.id AS activity_id,
            s.id AS shift_id,
            s.clocked_in_at AS started_at,
            s.clocked_in_at AS ended_at,
            0 AS duration_minutes,
            ci_loc.id AS matched_location_id,
            COALESCE(ci_loc.name, 'Lieu inconnu') AS location_name,
            COALESCE(ci_loc.location_type::TEXT, 'unknown') AS location_type,
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
                WHEN s.clock_in_location IS NULL THEN 'Clock-in sans position GPS'
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

        SELECT
            'clock_out'::TEXT,
            s.id,
            s.id AS shift_id,
            s.clocked_out_at,
            s.clocked_out_at,
            0 AS duration_minutes,
            co_loc.id AS matched_location_id,
            COALESCE(co_loc.name, 'Lieu inconnu') AS location_name,
            COALESCE(co_loc.location_type::TEXT, 'unknown') AS location_type,
            (s.clock_out_location->>'latitude')::DECIMAL,
            (s.clock_out_location->>'longitude')::DECIMAL,
            NULL::INTEGER,
            NULL::INTEGER,
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
                WHEN s.clock_out_location IS NULL THEN 'Clock-out sans position GPS'
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
            NULL::TEXT
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
    -- Lunch breaks as activities
    lunch_data AS (
        SELECT
            'lunch'::TEXT AS activity_type,
            lb.id AS activity_id,
            lb.shift_id,
            lb.started_at,
            lb.ended_at,
            (EXTRACT(EPOCH FROM (lb.ended_at - lb.started_at)) / 60)::INTEGER AS duration_minutes,
            NULL::UUID AS matched_location_id,
            NULL::TEXT AS location_name,
            NULL::TEXT AS location_type,
            NULL::DECIMAL AS latitude,
            NULL::DECIMAL AS longitude,
            NULL::INTEGER AS gps_gap_seconds,
            NULL::INTEGER AS gps_gap_count,
            'approved'::TEXT AS auto_status,
            'Pause dîner'::TEXT AS auto_reason,
            NULL::TEXT AS override_status,
            NULL::TEXT AS override_reason,
            'approved'::TEXT AS final_status,
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
          AND lb.started_at::DATE = p_date
          AND lb.ended_at IS NOT NULL
    ),
    -- *** CHANGE C: Restore gap detection (lost in migration 147) ***
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
          AND lb.started_at::DATE = p_date
    ),
    shift_boundaries AS (
        SELECT s.id AS shift_id, s.clocked_in_at, s.clocked_out_at
        FROM shifts s
        WHERE s.employee_id = p_employee_id
          AND s.clocked_in_at::DATE = p_date
          AND s.status = 'completed'
          AND s.clocked_out_at IS NOT NULL
    ),
    shift_events AS (
        SELECT sb.shift_id, sb.clocked_in_at AS event_time, 0 AS event_order
        FROM shift_boundaries sb
        UNION ALL
        SELECT ra.shift_id, ra.started_at, 2
        FROM real_activities ra
        UNION ALL
        SELECT ra.shift_id, ra.ended_at, 1
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
    gap_pairs AS (
        SELECT
            e1.shift_id,
            e1.event_time AS gap_started_at,
            e2.event_time AS gap_ended_at,
            EXTRACT(EPOCH FROM (e2.event_time - e1.event_time))::INTEGER AS gap_seconds
        FROM ordered_events e1
        JOIN ordered_events e2 ON e1.shift_id = e2.shift_id AND e2.rn = e1.rn + 1
        WHERE e1.event_order IN (0, 1)
          AND e2.event_order IN (2, 3)
          AND EXTRACT(EPOCH FROM (e2.event_time - e1.event_time)) > 300
    ),
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
    gap_data AS (
        SELECT
            'gap'::TEXT AS activity_type,
            md5(p_employee_id::TEXT || '/gap/' || g.gap_started_at::TEXT || '/' || g.gap_ended_at::TEXT)::UUID AS activity_id,
            g.shift_id,
            g.gap_started_at AS started_at,
            g.gap_ended_at AS ended_at,
            (g.gap_seconds / 60)::INTEGER AS duration_minutes,
            -- Inherit location from adjacent stop
            COALESCE(
                (SELECT sc.matched_location_id FROM stop_data sc
                 WHERE sc.ended_at BETWEEN g.gap_started_at - INTERVAL '60 seconds' AND g.gap_started_at + INTERVAL '60 seconds'
                 ORDER BY ABS(EXTRACT(EPOCH FROM (sc.ended_at - g.gap_started_at))) LIMIT 1),
                (SELECT sc.matched_location_id FROM stop_data sc
                 WHERE sc.started_at BETWEEN g.gap_ended_at - INTERVAL '60 seconds' AND g.gap_ended_at + INTERVAL '60 seconds'
                 ORDER BY ABS(EXTRACT(EPOCH FROM (sc.started_at - g.gap_ended_at))) LIMIT 1)
            ) AS matched_location_id,
            COALESCE(
                (SELECT l.name FROM stop_data sc JOIN locations l ON l.id = sc.matched_location_id
                 WHERE sc.ended_at BETWEEN g.gap_started_at - INTERVAL '60 seconds' AND g.gap_started_at + INTERVAL '60 seconds'
                 ORDER BY ABS(EXTRACT(EPOCH FROM (sc.ended_at - g.gap_started_at))) LIMIT 1),
                (SELECT l.name FROM stop_data sc JOIN locations l ON l.id = sc.matched_location_id
                 WHERE sc.started_at BETWEEN g.gap_ended_at - INTERVAL '60 seconds' AND g.gap_ended_at + INTERVAL '60 seconds'
                 ORDER BY ABS(EXTRACT(EPOCH FROM (sc.started_at - g.gap_ended_at))) LIMIT 1)
            ) AS location_name,
            COALESCE(
                (SELECT l.location_type::TEXT FROM stop_data sc JOIN locations l ON l.id = sc.matched_location_id
                 WHERE sc.ended_at BETWEEN g.gap_started_at - INTERVAL '60 seconds' AND g.gap_started_at + INTERVAL '60 seconds'
                 ORDER BY ABS(EXTRACT(EPOCH FROM (sc.ended_at - g.gap_started_at))) LIMIT 1),
                (SELECT l.location_type::TEXT FROM stop_data sc JOIN locations l ON l.id = sc.matched_location_id
                 WHERE sc.started_at BETWEEN g.gap_ended_at - INTERVAL '60 seconds' AND g.gap_ended_at + INTERVAL '60 seconds'
                 ORDER BY ABS(EXTRACT(EPOCH FROM (sc.started_at - g.gap_ended_at))) LIMIT 1)
            ) AS location_type,
            NULL::DECIMAL AS latitude,
            NULL::DECIMAL AS longitude,
            0::INTEGER AS gps_gap_seconds,
            0::INTEGER AS gps_gap_count,
            'needs_review'::TEXT AS auto_status,
            'Temps non suivi'::TEXT AS auto_reason,
            NULL::DECIMAL AS distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            -- start/end location for frontend mergeSameLocationGaps
            COALESCE(
                (SELECT sc.matched_location_id FROM stop_data sc
                 WHERE sc.ended_at BETWEEN g.gap_started_at - INTERVAL '60 seconds' AND g.gap_started_at + INTERVAL '60 seconds'
                 ORDER BY ABS(EXTRACT(EPOCH FROM (sc.ended_at - g.gap_started_at))) LIMIT 1)
            ) AS start_location_id,
            COALESCE(
                (SELECT l.name FROM stop_data sc JOIN locations l ON l.id = sc.matched_location_id
                 WHERE sc.ended_at BETWEEN g.gap_started_at - INTERVAL '60 seconds' AND g.gap_started_at + INTERVAL '60 seconds'
                 ORDER BY ABS(EXTRACT(EPOCH FROM (sc.ended_at - g.gap_started_at))) LIMIT 1)
            ) AS start_location_name,
            COALESCE(
                (SELECT l.location_type::TEXT FROM stop_data sc JOIN locations l ON l.id = sc.matched_location_id
                 WHERE sc.ended_at BETWEEN g.gap_started_at - INTERVAL '60 seconds' AND g.gap_started_at + INTERVAL '60 seconds'
                 ORDER BY ABS(EXTRACT(EPOCH FROM (sc.ended_at - g.gap_started_at))) LIMIT 1)
            ) AS start_location_type,
            COALESCE(
                (SELECT sc.matched_location_id FROM stop_data sc
                 WHERE sc.started_at BETWEEN g.gap_ended_at - INTERVAL '60 seconds' AND g.gap_ended_at + INTERVAL '60 seconds'
                 ORDER BY ABS(EXTRACT(EPOCH FROM (sc.started_at - g.gap_ended_at))) LIMIT 1)
            ) AS end_location_id,
            COALESCE(
                (SELECT l.name FROM stop_data sc JOIN locations l ON l.id = sc.matched_location_id
                 WHERE sc.started_at BETWEEN g.gap_ended_at - INTERVAL '60 seconds' AND g.gap_ended_at + INTERVAL '60 seconds'
                 ORDER BY ABS(EXTRACT(EPOCH FROM (sc.started_at - g.gap_ended_at))) LIMIT 1)
            ) AS end_location_name,
            COALESCE(
                (SELECT l.location_type::TEXT FROM stop_data sc JOIN locations l ON l.id = sc.matched_location_id
                 WHERE sc.started_at BETWEEN g.gap_ended_at - INTERVAL '60 seconds' AND g.gap_ended_at + INTERVAL '60 seconds'
                 ORDER BY ABS(EXTRACT(EPOCH FROM (sc.started_at - g.gap_ended_at))) LIMIT 1)
            ) AS end_location_type
        FROM all_gaps g
    ),
    classified AS (
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
            td.end_location_id, td.end_location_name, td.end_location_type
        FROM trip_data td
        LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides tao ON tao.day_approval_id = da.id
            AND tao.activity_type = 'trip' AND tao.activity_id = td.activity_id

        UNION ALL

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
            cd.end_location_id, cd.end_location_name, cd.end_location_type
        FROM clock_data cd
        LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides cao ON cao.day_approval_id = da.id
            AND cao.activity_type = cd.activity_type AND cao.activity_id = cd.activity_id

        UNION ALL

        SELECT
            ld.activity_type, ld.activity_id, ld.shift_id,
            ld.started_at, ld.ended_at, ld.duration_minutes,
            ld.matched_location_id, ld.location_name, ld.location_type,
            ld.latitude, ld.longitude, ld.gps_gap_seconds, ld.gps_gap_count,
            ld.auto_status, ld.auto_reason,
            ld.override_status, ld.override_reason, ld.final_status,
            ld.distance_km, ld.transport_mode, ld.has_gps_gap,
            ld.start_location_id, ld.start_location_name, ld.start_location_type,
            ld.end_location_id, ld.end_location_name, ld.end_location_type
        FROM lunch_data ld

        UNION ALL

        -- *** CHANGE D: Gap activities ***
        SELECT
            gd.activity_type, gd.activity_id, gd.shift_id,
            gd.started_at, gd.ended_at, gd.duration_minutes,
            gd.matched_location_id, gd.location_name, gd.location_type,
            gd.latitude, gd.longitude, gd.gps_gap_seconds, gd.gps_gap_count,
            gd.auto_status, gd.auto_reason,
            gao.override_status, gao.reason AS override_reason,
            COALESCE(gao.override_status, gd.auto_status) AS final_status,
            gd.distance_km, gd.transport_mode, gd.has_gps_gap,
            gd.start_location_id, gd.start_location_name, gd.start_location_type,
            gd.end_location_id, gd.end_location_name, gd.end_location_type
        FROM gap_data gd
        LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides gao ON gao.day_approval_id = da.id
            AND gao.activity_type = 'gap' AND gao.activity_id = gd.activity_id

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

    -- Compute summary — exclude lunch from approved_minutes
    SELECT
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (WHERE a->>'final_status' = 'approved' AND a->>'activity_type' != 'lunch'), 0),
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (WHERE a->>'final_status' = 'rejected'), 0),
        COALESCE(COUNT(*) FILTER (WHERE a->>'final_status' = 'needs_review'
            AND NOT (
                a->>'activity_type' IN ('clock_in', 'clock_out', 'lunch')
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

    IF v_day_approval.status = 'approved' THEN
        v_approved_minutes := v_day_approval.approved_minutes;
        v_rejected_minutes := v_day_approval.rejected_minutes;
        v_needs_review_count := 0;
    END IF;

    v_result := jsonb_build_object(
        'employee_id', p_employee_id,
        'date', p_date,
        'has_active_shift', v_has_active_shift,
        'has_stale_gps', v_has_stale_gps,
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
            'lunch_minutes', v_lunch_minutes
        )
    );

    RETURN v_result;
END;
$function$;

-- ============================================================
-- 6. Data fix: rerun detect_trips for Celine March 9 shifts
-- ============================================================
DO $$
DECLARE
    v_shift_id UUID;
BEGIN
    FOR v_shift_id IN
        SELECT id FROM shifts
        WHERE employee_id = '25336644-fb83-4017-9cfd-e8155195fd10'
          AND clocked_in_at::DATE = '2026-03-09'
    LOOP
        -- Clean existing detection data
        DELETE FROM trip_gps_points WHERE trip_id IN (
            SELECT id FROM trips WHERE shift_id = v_shift_id
        );
        DELETE FROM trips WHERE shift_id = v_shift_id;
        UPDATE gps_points SET stationary_cluster_id = NULL WHERE shift_id = v_shift_id;
        DELETE FROM stationary_clusters WHERE shift_id = v_shift_id;

        -- Re-run detection (now includes step 9 merge)
        PERFORM detect_trips(v_shift_id);

        RAISE NOTICE 'Re-ran detect_trips for shift %', v_shift_id;
    END LOOP;
END;
$$;
