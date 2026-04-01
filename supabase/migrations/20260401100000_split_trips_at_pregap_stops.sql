-- =============================================================================
-- Split trips at pre-gap stops
--
-- When GPS dies while an employee is stationary (e.g., inside a building),
-- the trip detector creates a single long trip with a GPS gap. This function
-- detects stationary points just before the gap, creates a stationary_cluster,
-- and splits the trip into: shortened_trip -> cluster -> new_trip (if needed).
--
-- Rule: speed < 1.0 m/s (3.6 km/h) AND accuracy < 20m for last 2 points
--       before a gap > 5 min.
-- =============================================================================

-- =========================================================================
-- Part 1: The split function
-- =========================================================================
CREATE OR REPLACE FUNCTION split_trips_at_pregap_stops(p_shift_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, extensions
AS $$
DECLARE
    v_employee_id     UUID;
    v_trip            RECORD;
    v_gap             RECORD;
    v_point           RECORD;
    v_cluster_point_ids UUID[];
    v_cluster_lats    DOUBLE PRECISION[];
    v_cluster_lngs    DOUBLE PRECISION[];
    v_cluster_accs    DOUBLE PRECISION[];
    v_sum_lat_w       DOUBLE PRECISION;
    v_sum_lng_w       DOUBLE PRECISION;
    v_sum_w           DOUBLE PRECISION;
    v_sum_inv_acc_sq  DOUBLE PRECISION;
    v_centroid_lat    DOUBLE PRECISION;
    v_centroid_lng    DOUBLE PRECISION;
    v_centroid_acc    DOUBLE PRECISION;
    v_cluster_id      UUID;
    v_cluster_started_at TIMESTAMPTZ;
    v_cluster_ended_at   TIMESTAMPTZ;
    v_matched_location_id UUID;
    v_new_trip_id     UUID;
    v_orig_end_at     TIMESTAMPTZ;
    v_orig_end_lat    DOUBLE PRECISION;
    v_orig_end_lng    DOUBLE PRECISION;
    v_orig_end_cluster_id UUID;
    v_orig_end_location_id UUID;
    v_has_moving_after BOOLEAN;
    v_first_after_gap RECORD;
    v_last_point_new  RECORD;
    v_new_distance    DOUBLE PRECISION;
    v_new_duration    INTEGER;
    v_orig_distance   DOUBLE PRECISION;
    v_orig_duration   INTEGER;
    v_post_gap_point_ids UUID[];
    v_check_pt1       RECORD;
    v_check_pt2       RECORD;
    v_gap_seconds     INTEGER;
BEGIN
    SELECT employee_id INTO v_employee_id FROM shifts WHERE id = p_shift_id;
    IF v_employee_id IS NULL THEN RETURN; END IF;

    FOR v_trip IN
        SELECT t.id, t.started_at, t.ended_at,
               t.start_latitude, t.start_longitude,
               t.end_latitude, t.end_longitude,
               t.start_cluster_id, t.end_cluster_id,
               t.start_location_id, t.end_location_id,
               t.gps_gap_seconds, t.gps_gap_count,
               t.classification, t.detection_method, t.transport_mode,
               t.gps_point_count
        FROM trips t
        WHERE t.shift_id = p_shift_id AND t.gps_gap_seconds > 300
        ORDER BY t.started_at
    LOOP
        -- Find the largest gap within this trip's GPS points
        SELECT * INTO v_gap FROM (
            SELECT
                tgp.gps_point_id AS before_point_id,
                gp.captured_at AS before_time,
                LEAD(tgp.gps_point_id) OVER (ORDER BY gp.captured_at) AS after_point_id,
                LEAD(gp.captured_at) OVER (ORDER BY gp.captured_at) AS after_time,
                EXTRACT(EPOCH FROM (
                    LEAD(gp.captured_at) OVER (ORDER BY gp.captured_at) - gp.captured_at
                ))::INTEGER AS gap_secs
            FROM trip_gps_points tgp
            JOIN gps_points gp ON gp.id = tgp.gps_point_id
            WHERE tgp.trip_id = v_trip.id
        ) sub
        WHERE sub.gap_secs > 300 AND sub.after_point_id IS NOT NULL
        ORDER BY sub.gap_secs DESC
        LIMIT 1;

        IF v_gap IS NULL THEN CONTINUE; END IF;
        v_gap_seconds := v_gap.gap_secs;

        -- Check last 2 points before gap: both must be stationary and accurate
        SELECT gp.id, gp.speed, gp.accuracy, gp.captured_at
        INTO v_check_pt1
        FROM trip_gps_points tgp JOIN gps_points gp ON gp.id = tgp.gps_point_id
        WHERE tgp.trip_id = v_trip.id AND gp.captured_at <= v_gap.before_time
        ORDER BY gp.captured_at DESC LIMIT 1;

        SELECT gp.id, gp.speed, gp.accuracy, gp.captured_at
        INTO v_check_pt2
        FROM trip_gps_points tgp JOIN gps_points gp ON gp.id = tgp.gps_point_id
        WHERE tgp.trip_id = v_trip.id AND gp.captured_at < v_check_pt1.captured_at
        ORDER BY gp.captured_at DESC LIMIT 1;

        IF v_check_pt1 IS NULL OR v_check_pt2 IS NULL THEN CONTINUE; END IF;
        IF COALESCE(v_check_pt1.speed, 0) >= 1.0 OR COALESCE(v_check_pt1.accuracy, 999) >= 20 THEN CONTINUE; END IF;
        IF COALESCE(v_check_pt2.speed, 0) >= 1.0 OR COALESCE(v_check_pt2.accuracy, 999) >= 20 THEN CONTINUE; END IF;

        -- Collect consecutive stationary points before gap (walking backwards)
        v_cluster_point_ids := ARRAY[]::UUID[];
        v_cluster_lats := ARRAY[]::DOUBLE PRECISION[];
        v_cluster_lngs := ARRAY[]::DOUBLE PRECISION[];
        v_cluster_accs := ARRAY[]::DOUBLE PRECISION[];
        v_sum_lat_w := 0; v_sum_lng_w := 0; v_sum_w := 0; v_sum_inv_acc_sq := 0;
        v_cluster_started_at := NULL;

        FOR v_point IN
            SELECT gp.id, gp.latitude, gp.longitude, gp.accuracy, gp.speed, gp.captured_at
            FROM trip_gps_points tgp JOIN gps_points gp ON gp.id = tgp.gps_point_id
            WHERE tgp.trip_id = v_trip.id AND gp.captured_at <= v_gap.before_time
            ORDER BY gp.captured_at DESC
        LOOP
            IF COALESCE(v_point.speed, 0) >= 1.0 OR COALESCE(v_point.accuracy, 999) >= 20 THEN EXIT; END IF;
            v_cluster_point_ids := v_point.id || v_cluster_point_ids;
            v_cluster_lats := v_point.latitude || v_cluster_lats;
            v_cluster_lngs := v_point.longitude || v_cluster_lngs;
            v_cluster_accs := v_point.accuracy || v_cluster_accs;
            v_sum_lat_w := v_sum_lat_w + (v_point.latitude / GREATEST(v_point.accuracy, 1));
            v_sum_lng_w := v_sum_lng_w + (v_point.longitude / GREATEST(v_point.accuracy, 1));
            v_sum_w := v_sum_w + (1.0 / GREATEST(v_point.accuracy, 1));
            v_sum_inv_acc_sq := v_sum_inv_acc_sq + (1.0 / GREATEST(v_point.accuracy * v_point.accuracy, 1));
            v_cluster_started_at := v_point.captured_at;
        END LOOP;

        IF array_length(v_cluster_point_ids, 1) < 2 THEN CONTINUE; END IF;

        -- Compute accuracy-weighted centroid
        v_centroid_lat := v_sum_lat_w / v_sum_w;
        v_centroid_lng := v_sum_lng_w / v_sum_w;
        v_centroid_acc := 1.0 / SQRT(v_sum_inv_acc_sq);
        v_cluster_ended_at := v_gap.after_time;

        -- Match location
        v_matched_location_id := COALESCE(
            match_trip_to_location(v_centroid_lat::NUMERIC, v_centroid_lng::NUMERIC, COALESCE(v_centroid_acc, 0)::NUMERIC),
            match_cluster_by_point_voting(v_cluster_lats, v_cluster_lngs, v_cluster_accs)
        );

        -- Save original trip end info
        v_orig_end_at := v_trip.ended_at;
        v_orig_end_lat := v_trip.end_latitude;
        v_orig_end_lng := v_trip.end_longitude;
        v_orig_end_cluster_id := v_trip.end_cluster_id;
        v_orig_end_location_id := v_trip.end_location_id;

        -- Create stationary cluster (RETURNING id captures actual ID after deterministic trigger)
        INSERT INTO stationary_clusters (
            id, shift_id, employee_id,
            centroid_latitude, centroid_longitude, centroid_accuracy,
            started_at, ended_at, duration_seconds, gps_point_count,
            matched_location_id, gps_gap_seconds, gps_gap_count
        ) VALUES (
            gen_random_uuid(), p_shift_id, v_employee_id,
            v_centroid_lat, v_centroid_lng, v_centroid_acc,
            v_cluster_started_at, v_cluster_ended_at,
            EXTRACT(EPOCH FROM (v_cluster_ended_at - v_cluster_started_at))::INTEGER,
            array_length(v_cluster_point_ids, 1),
            v_matched_location_id, v_gap_seconds, 1
        ) RETURNING id INTO v_cluster_id;

        -- Tag GPS points with the cluster
        UPDATE gps_points SET stationary_cluster_id = v_cluster_id
        WHERE id = ANY(v_cluster_point_ids);

        -- Remove cluster points from trip
        DELETE FROM trip_gps_points
        WHERE trip_id = v_trip.id AND gps_point_id = ANY(v_cluster_point_ids);

        -- Collect and remove post-gap points from original trip
        SELECT array_agg(tgp.gps_point_id ORDER BY gp.captured_at)
        INTO v_post_gap_point_ids
        FROM trip_gps_points tgp JOIN gps_points gp ON gp.id = tgp.gps_point_id
        WHERE tgp.trip_id = v_trip.id AND gp.captured_at >= v_gap.after_time;

        IF v_post_gap_point_ids IS NOT NULL AND array_length(v_post_gap_point_ids, 1) > 0 THEN
            DELETE FROM trip_gps_points
            WHERE trip_id = v_trip.id AND gps_point_id = ANY(v_post_gap_point_ids);
        END IF;

        -- Recalculate original trip distance from remaining points
        SELECT COALESCE(SUM(sub.seg_dist), 0) * 1.3 INTO v_orig_distance
        FROM (
            SELECT haversine_km(gp.latitude, gp.longitude,
                LEAD(gp.latitude) OVER (ORDER BY gp.captured_at),
                LEAD(gp.longitude) OVER (ORDER BY gp.captured_at)) AS seg_dist
            FROM trip_gps_points tgp JOIN gps_points gp ON gp.id = tgp.gps_point_id
            WHERE tgp.trip_id = v_trip.id
        ) sub WHERE sub.seg_dist IS NOT NULL;

        v_orig_duration := GREATEST(0, EXTRACT(EPOCH FROM (v_cluster_started_at - v_trip.started_at)) / 60)::INTEGER;

        -- Shorten original trip to end at cluster
        UPDATE trips SET
            ended_at = v_cluster_started_at,
            end_latitude = v_centroid_lat, end_longitude = v_centroid_lng,
            end_cluster_id = v_cluster_id, end_location_id = v_matched_location_id,
            distance_km = ROUND(v_orig_distance::NUMERIC, 3), duration_minutes = v_orig_duration,
            gps_gap_seconds = 0, gps_gap_count = 0, has_gps_gap = FALSE,
            gps_point_count = (SELECT COUNT(*) FROM trip_gps_points WHERE trip_id = v_trip.id)
        WHERE id = v_trip.id;

        -- Create post-gap trip if there are moving points and the gap doesn't end at original trip end
        v_has_moving_after := FALSE;
        IF v_post_gap_point_ids IS NOT NULL AND array_length(v_post_gap_point_ids, 1) > 0 THEN
            SELECT EXISTS (
                SELECT 1 FROM gps_points WHERE id = ANY(v_post_gap_point_ids) AND COALESCE(speed, 0) >= 2.22
            ) INTO v_has_moving_after;
        END IF;

        IF (v_has_moving_after OR v_orig_end_cluster_id IS NOT NULL) AND v_cluster_ended_at < v_orig_end_at THEN
            v_new_trip_id := gen_random_uuid();

            SELECT gp.latitude, gp.longitude, gp.captured_at INTO v_first_after_gap
            FROM gps_points gp WHERE gp.id = ANY(v_post_gap_point_ids)
            ORDER BY gp.captured_at LIMIT 1;

            SELECT gp.latitude, gp.longitude, gp.captured_at INTO v_last_point_new
            FROM gps_points gp WHERE gp.id = ANY(v_post_gap_point_ids)
            ORDER BY gp.captured_at DESC LIMIT 1;

            IF v_post_gap_point_ids IS NOT NULL AND array_length(v_post_gap_point_ids, 1) > 1 THEN
                SELECT COALESCE(SUM(sub.seg_dist), 0) * 1.3 INTO v_new_distance
                FROM (
                    SELECT haversine_km(gp.latitude, gp.longitude,
                        LEAD(gp.latitude) OVER (ORDER BY gp.captured_at),
                        LEAD(gp.longitude) OVER (ORDER BY gp.captured_at)) AS seg_dist
                    FROM gps_points gp WHERE gp.id = ANY(v_post_gap_point_ids)
                ) sub WHERE sub.seg_dist IS NOT NULL;
            ELSE
                v_new_distance := haversine_km(v_centroid_lat::NUMERIC, v_centroid_lng::NUMERIC,
                    COALESCE(v_orig_end_lat, v_centroid_lat)::NUMERIC, COALESCE(v_orig_end_lng, v_centroid_lng)::NUMERIC) * 1.3;
            END IF;

            v_new_duration := GREATEST(0, EXTRACT(EPOCH FROM (v_orig_end_at - v_cluster_ended_at)) / 60)::INTEGER;

            INSERT INTO trips (
                id, shift_id, employee_id, started_at, ended_at,
                start_latitude, start_longitude, end_latitude, end_longitude,
                distance_km, duration_minutes,
                classification, confidence_score, gps_point_count, low_accuracy_segments,
                detection_method, transport_mode,
                start_cluster_id, start_location_id, end_cluster_id, end_location_id,
                has_gps_gap, gps_gap_seconds, gps_gap_count
            ) VALUES (
                v_new_trip_id, p_shift_id, v_employee_id,
                v_cluster_ended_at, v_orig_end_at,
                COALESCE(v_first_after_gap.latitude, v_centroid_lat),
                COALESCE(v_first_after_gap.longitude, v_centroid_lng),
                COALESCE(v_last_point_new.latitude, v_orig_end_lat),
                COALESCE(v_last_point_new.longitude, v_orig_end_lng),
                ROUND(COALESCE(v_new_distance, 0)::NUMERIC, 3), v_new_duration,
                v_trip.classification, 0.00,
                COALESCE(array_length(v_post_gap_point_ids, 1), 0), 0,
                v_trip.detection_method, v_trip.transport_mode,
                v_cluster_id, v_matched_location_id,
                v_orig_end_cluster_id, v_orig_end_location_id,
                FALSE, 0, 0
            );

            IF v_post_gap_point_ids IS NOT NULL AND array_length(v_post_gap_point_ids, 1) > 0 THEN
                INSERT INTO trip_gps_points (trip_id, gps_point_id, sequence_order)
                SELECT v_new_trip_id, gp.id, ROW_NUMBER() OVER (ORDER BY gp.captured_at)
                FROM gps_points gp WHERE gp.id = ANY(v_post_gap_point_ids)
                ORDER BY gp.captured_at;
            END IF;
        END IF;

        -- Clean up zero-duration trips
        DELETE FROM trip_gps_points WHERE trip_id IN (
            SELECT id FROM trips WHERE shift_id = p_shift_id AND duration_minutes = 0
        );
        DELETE FROM trips WHERE shift_id = p_shift_id AND duration_minutes = 0;
    END LOOP;

    -- Recompute effective location types for new clusters
    PERFORM compute_cluster_effective_types(p_shift_id, v_employee_id);
    -- Note: compute_gps_gaps already ran in detect_trips before this function
END;
$$;

-- =========================================================================
-- Part 2: Inject into detect_trips as a post-processing step
-- =========================================================================
DO $$
DECLARE
    v_funcdef TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_funcdef
    FROM pg_proc
    WHERE proname = 'detect_trips'
      AND pronamespace = 'public'::regnamespace;

    IF v_funcdef IS NULL THEN
        RAISE EXCEPTION 'detect_trips function not found';
    END IF;

    -- Check if already injected
    IF v_funcdef LIKE '%split_trips_at_pregap_stops%' THEN
        RAISE NOTICE 'split_trips_at_pregap_stops already present in detect_trips -- skipping';
        RETURN;
    END IF;

    -- Inject after trim_trip_gps_boundaries (the last step before END)
    v_funcdef := replace(v_funcdef,
        E'PERFORM trim_trip_gps_boundaries(p_shift_id);\nEND;',
        E'PERFORM trim_trip_gps_boundaries(p_shift_id);\n\n    -- =========================================================================\n    -- 11. Post-processing: split trips at pre-gap stops\n    -- =========================================================================\n    PERFORM split_trips_at_pregap_stops(p_shift_id);\nEND;'
    );

    EXECUTE v_funcdef;
    RAISE NOTICE 'detect_trips updated: added split_trips_at_pregap_stops as step 11';
END;
$$;
