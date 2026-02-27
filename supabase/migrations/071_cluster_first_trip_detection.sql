-- =============================================================================
-- 071: Cluster-first trip detection algorithm
-- =============================================================================
-- Replaces the trip-first state machine (speed thresholds, sensor stops) with
-- a cluster-first algorithm that detects stationary clusters spatially (50m
-- radius, 3+ min), then creates trips from the gaps between clusters.
--
-- Key changes:
--   1. REMOVED: v_movement_speed, v_sensor_stop_threshold, v_stationary_speed,
--      v_point_is_stopped, v_in_trip, v_stationary_since, split trip logic
--   2. NEW: Tentative cluster tracking (concurrent with current cluster),
--      transit buffer (v_transit_point_ids), cluster-to-cluster trip creation
--   3. All existing post-processing preserved: classify_trip_transport_mode(),
--      ghost trip filters, location matching, trip continuity
-- =============================================================================

CREATE OR REPLACE FUNCTION detect_trips(p_shift_id UUID)
RETURNS TABLE (
    trip_id UUID,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    start_latitude DECIMAL(10, 8),
    start_longitude DECIMAL(11, 8),
    end_latitude DECIMAL(10, 8),
    end_longitude DECIMAL(11, 8),
    distance_km DECIMAL(8, 3),
    duration_minutes INTEGER,
    confidence_score DECIMAL(3, 2),
    gps_point_count INTEGER
) AS $$
#variable_conflict use_column
DECLARE
    v_shift RECORD;
    v_employee_id UUID;
    v_point RECORD;
    v_prev_point RECORD;

    -- Constants
    v_cluster_radius_m     CONSTANT DECIMAL := 50.0;
    v_cluster_min_duration CONSTANT INTEGER := 3;       -- minutes
    v_max_accuracy         CONSTANT DECIMAL := 200.0;
    v_correction_factor    CONSTANT DECIMAL := 1.3;
    v_min_distance_km      CONSTANT DECIMAL := 0.2;
    v_min_distance_driving CONSTANT DECIMAL := 0.5;
    v_min_displacement_walking CONSTANT DECIMAL := 0.1; -- 100m
    v_gps_gap_minutes      CONSTANT INTEGER := 15;

    -- Current cluster state
    v_cluster_lats DECIMAL[] := '{}';
    v_cluster_lngs DECIMAL[] := '{}';
    v_cluster_accs DECIMAL[] := '{}';
    v_cluster_point_ids UUID[] := '{}';
    v_cluster_started_at TIMESTAMPTZ := NULL;
    v_cluster_last_at TIMESTAMPTZ := NULL;
    v_cluster_confirmed BOOLEAN := FALSE;
    v_cluster_centroid_lat DECIMAL;
    v_cluster_centroid_lng DECIMAL;
    v_cluster_centroid_acc DECIMAL;
    v_cluster_id UUID := NULL;
    v_has_db_cluster BOOLEAN := FALSE;

    -- Tentative cluster state
    v_tent_lats DECIMAL[] := '{}';
    v_tent_lngs DECIMAL[] := '{}';
    v_tent_accs DECIMAL[] := '{}';
    v_tent_point_ids UUID[] := '{}';
    v_tent_started_at TIMESTAMPTZ := NULL;
    v_tent_centroid_lat DECIMAL;
    v_tent_centroid_lng DECIMAL;
    v_has_tentative BOOLEAN := FALSE;

    -- Transit buffer
    v_transit_point_ids UUID[] := '{}';

    -- Trip tracking
    v_prev_cluster_id UUID := NULL;
    v_prev_trip_end_location_id UUID := NULL;
    v_prev_trip_end_lat DECIMAL;
    v_prev_trip_end_lng DECIMAL;

    -- Distance computations
    v_dist_to_cluster DECIMAL;
    v_dist_to_tent DECIMAL;

    -- For active shift incremental detection
    v_is_active BOOLEAN;
    v_create_clusters BOOLEAN;
    v_cutoff_time TIMESTAMPTZ := NULL;

    -- Trip creation variables
    v_trip_id UUID;
    v_trip_distance DECIMAL;
    v_trip_point_count INTEGER;
    v_trip_low_accuracy INTEGER;
    v_trip_started_at TIMESTAMPTZ;
    v_trip_ended_at TIMESTAMPTZ;
    v_trip_start_lat DECIMAL;
    v_trip_start_lng DECIMAL;
    v_trip_start_acc DECIMAL;
    v_trip_end_lat DECIMAL;
    v_trip_end_lng DECIMAL;
    v_trip_end_acc DECIMAL;
    v_transport_mode TEXT;
    v_displacement DECIMAL;
    v_straightness DECIMAL;
    v_new_cluster_id UUID;
    v_dep_centroid_lat DECIMAL;
    v_dep_centroid_lng DECIMAL;
    v_dep_centroid_acc DECIMAL;
    v_arr_centroid_lat DECIMAL;
    v_arr_centroid_lng DECIMAL;
    v_arr_centroid_acc DECIMAL;
    v_has_prev_point BOOLEAN := FALSE;
BEGIN
    -- =========================================================================
    -- 1. Validate shift and set up incremental mode
    -- =========================================================================
    SELECT s.id, s.employee_id, s.status
    INTO v_shift
    FROM shifts s
    WHERE s.id = p_shift_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Shift not found: %', p_shift_id;
    END IF;

    v_employee_id := v_shift.employee_id;
    v_is_active := (v_shift.status = 'active');

    -- =========================================================================
    -- 2. Delete existing data
    -- =========================================================================
    IF v_is_active THEN
        DELETE FROM trips
        WHERE shift_id = p_shift_id
          AND match_status IN ('pending', 'processing');

        SELECT MAX(gp.captured_at) INTO v_cutoff_time
        FROM trips t
        JOIN trip_gps_points tgp ON tgp.trip_id = t.id
        JOIN gps_points gp ON gp.id = tgp.gps_point_id
        WHERE t.shift_id = p_shift_id;
    ELSE
        DELETE FROM trips WHERE shift_id = p_shift_id;
    END IF;

    v_create_clusters := NOT v_is_active;
    IF v_create_clusters THEN
        DELETE FROM stationary_clusters WHERE shift_id = p_shift_id;
    END IF;

    -- =========================================================================
    -- 3. Main loop
    -- =========================================================================
    v_prev_point := NULL;

    FOR v_point IN
        SELECT
            gp.id,
            gp.latitude,
            gp.longitude,
            gp.accuracy,
            gp.speed,
            gp.captured_at
        FROM gps_points gp
        WHERE gp.shift_id = p_shift_id
          AND (v_cutoff_time IS NULL OR gp.captured_at > v_cutoff_time)
        ORDER BY gp.captured_at ASC
    LOOP
        -- Skip points with poor accuracy
        IF v_point.accuracy IS NOT NULL AND v_point.accuracy > v_max_accuracy THEN
            CONTINUE;
        END IF;

        -- =================================================================
        -- GPS gap check: if > 15 min since prev point AND we have a
        -- confirmed cluster, finalize it and discard tentative state
        -- =================================================================
        IF v_has_prev_point THEN
         IF EXTRACT(EPOCH FROM (v_point.captured_at - v_prev_point.captured_at)) / 60.0 > v_gps_gap_minutes THEN

            IF v_cluster_confirmed THEN
                -- Finalize the confirmed cluster
                IF v_create_clusters THEN
                    -- Compute final centroid
                    SELECT
                        SUM(lat / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                        SUM(lng / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                        1.0 / SQRT(SUM(1.0 / GREATEST(acc * acc, 1)))
                    INTO v_cluster_centroid_lat, v_cluster_centroid_lng, v_cluster_centroid_acc
                    FROM unnest(v_cluster_lats, v_cluster_lngs, v_cluster_accs) AS t(lat, lng, acc);

                    IF v_has_db_cluster THEN
                        UPDATE stationary_clusters SET
                            centroid_latitude = v_cluster_centroid_lat,
                            centroid_longitude = v_cluster_centroid_lng,
                            centroid_accuracy = v_cluster_centroid_acc,
                            ended_at = v_prev_point.captured_at,
                            duration_seconds = EXTRACT(EPOCH FROM (v_prev_point.captured_at - v_cluster_started_at))::INTEGER,
                            gps_point_count = array_length(v_cluster_point_ids, 1),
                            matched_location_id = match_trip_to_location(v_cluster_centroid_lat, v_cluster_centroid_lng, COALESCE(v_cluster_centroid_acc, 0))
                        WHERE id = v_cluster_id;
                        UPDATE gps_points SET stationary_cluster_id = v_cluster_id
                        WHERE id = ANY(v_cluster_point_ids) AND stationary_cluster_id IS NULL;
                    END IF;
                END IF;

                v_prev_cluster_id := v_cluster_id;
            END IF;

            -- Discard tentative cluster
            IF v_has_tentative THEN
                v_has_tentative := FALSE;
                v_tent_lats := '{}';
                v_tent_lngs := '{}';
                v_tent_accs := '{}';
                v_tent_point_ids := '{}';
            END IF;

            -- Reset current cluster for fresh start after gap
            v_cluster_lats := '{}';
            v_cluster_lngs := '{}';
            v_cluster_accs := '{}';
            v_cluster_point_ids := '{}';
            v_cluster_started_at := NULL;
            v_cluster_last_at := NULL;
            v_cluster_confirmed := FALSE;
            v_cluster_id := NULL;
            v_has_db_cluster := FALSE;
            v_transit_point_ids := '{}';
         END IF;
        END IF;

        -- =================================================================
        -- CORE ALGORITHM
        -- =================================================================

        -- Compute adjusted distance to current cluster centroid
        IF array_length(v_cluster_lats, 1) > 0 THEN
            SELECT
                SUM(lat / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                SUM(lng / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                1.0 / SQRT(SUM(1.0 / GREATEST(acc * acc, 1)))
            INTO v_cluster_centroid_lat, v_cluster_centroid_lng, v_cluster_centroid_acc
            FROM unnest(v_cluster_lats, v_cluster_lngs, v_cluster_accs) AS t(lat, lng, acc);

            v_dist_to_cluster := GREATEST(
                haversine_km(v_cluster_centroid_lat, v_cluster_centroid_lng,
                             v_point.latitude, v_point.longitude) * 1000.0
                - COALESCE(v_point.accuracy, 20.0),
                0
            );
        ELSE
            v_dist_to_cluster := 0;  -- First point, automatically in cluster
        END IF;

        IF v_dist_to_cluster <= v_cluster_radius_m THEN
            -- =============================================================
            -- POINT WITHIN CURRENT CLUSTER
            -- =============================================================
            v_cluster_lats := v_cluster_lats || v_point.latitude;
            v_cluster_lngs := v_cluster_lngs || v_point.longitude;
            v_cluster_accs := v_cluster_accs || COALESCE(v_point.accuracy, 20.0);
            v_cluster_point_ids := v_cluster_point_ids || v_point.id;
            IF v_cluster_started_at IS NULL THEN
                v_cluster_started_at := v_point.captured_at;
            END IF;
            v_cluster_last_at := v_point.captured_at;

            -- Check if cluster just became confirmed (duration >= 3 min)
            IF NOT v_cluster_confirmed
               AND EXTRACT(EPOCH FROM (v_point.captured_at - v_cluster_started_at)) / 60.0 >= v_cluster_min_duration THEN
                v_cluster_confirmed := TRUE;

                IF v_create_clusters THEN
                    -- Recompute centroid for persistence
                    SELECT
                        SUM(lat / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                        SUM(lng / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                        1.0 / SQRT(SUM(1.0 / GREATEST(acc * acc, 1)))
                    INTO v_cluster_centroid_lat, v_cluster_centroid_lng, v_cluster_centroid_acc
                    FROM unnest(v_cluster_lats, v_cluster_lngs, v_cluster_accs) AS t(lat, lng, acc);

                    INSERT INTO stationary_clusters (
                        shift_id, employee_id,
                        centroid_latitude, centroid_longitude, centroid_accuracy,
                        started_at, ended_at, duration_seconds, gps_point_count,
                        matched_location_id
                    ) VALUES (
                        p_shift_id, v_employee_id,
                        v_cluster_centroid_lat, v_cluster_centroid_lng, v_cluster_centroid_acc,
                        v_cluster_started_at, v_point.captured_at,
                        EXTRACT(EPOCH FROM (v_point.captured_at - v_cluster_started_at))::INTEGER,
                        array_length(v_cluster_point_ids, 1),
                        match_trip_to_location(v_cluster_centroid_lat, v_cluster_centroid_lng, COALESCE(v_cluster_centroid_acc, 0))
                    )
                    RETURNING id INTO v_cluster_id;
                    v_has_db_cluster := TRUE;

                    UPDATE gps_points SET stationary_cluster_id = v_cluster_id
                    WHERE id = ANY(v_cluster_point_ids);
                END IF;

            ELSIF v_cluster_confirmed AND v_has_db_cluster THEN
                -- Already confirmed and persisted: update cluster and tag this point
                IF v_create_clusters THEN
                    UPDATE stationary_clusters SET
                        centroid_latitude = v_cluster_centroid_lat,
                        centroid_longitude = v_cluster_centroid_lng,
                        centroid_accuracy = v_cluster_centroid_acc,
                        ended_at = v_point.captured_at,
                        duration_seconds = EXTRACT(EPOCH FROM (v_point.captured_at - v_cluster_started_at))::INTEGER,
                        gps_point_count = array_length(v_cluster_point_ids, 1),
                        matched_location_id = match_trip_to_location(v_cluster_centroid_lat, v_cluster_centroid_lng, COALESCE(v_cluster_centroid_acc, 0))
                    WHERE id = v_cluster_id;

                    UPDATE gps_points SET stationary_cluster_id = v_cluster_id
                    WHERE id = v_point.id AND stationary_cluster_id IS NULL;
                END IF;
            END IF;

            -- Discard tentative cluster if one exists (point returned to current cluster)
            IF v_has_tentative THEN
                -- Move tentative points to transit buffer
                v_transit_point_ids := v_transit_point_ids || v_tent_point_ids;
                v_has_tentative := FALSE;
                v_tent_lats := '{}';
                v_tent_lngs := '{}';
                v_tent_accs := '{}';
                v_tent_point_ids := '{}';
            END IF;

        ELSE
            -- =============================================================
            -- POINT BEYOND CURRENT CLUSTER (> 50m adjusted)
            -- =============================================================

            IF NOT v_has_tentative THEN
                -- Start tentative cluster with this point
                v_tent_lats := ARRAY[v_point.latitude];
                v_tent_lngs := ARRAY[v_point.longitude];
                v_tent_accs := ARRAY[COALESCE(v_point.accuracy, 20.0)];
                v_tent_point_ids := ARRAY[v_point.id];
                v_tent_started_at := v_point.captured_at;
                v_has_tentative := TRUE;

            ELSE
                -- Tentative exists: check distance to tentative centroid
                SELECT
                    SUM(lat / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                    SUM(lng / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1))
                INTO v_tent_centroid_lat, v_tent_centroid_lng
                FROM unnest(v_tent_lats, v_tent_lngs, v_tent_accs) AS t(lat, lng, acc);

                v_dist_to_tent := GREATEST(
                    haversine_km(v_tent_centroid_lat, v_tent_centroid_lng,
                                 v_point.latitude, v_point.longitude) * 1000.0
                    - COALESCE(v_point.accuracy, 20.0),
                    0
                );

                IF v_dist_to_tent <= v_cluster_radius_m THEN
                    -- Point within tentative cluster
                    v_tent_lats := v_tent_lats || v_point.latitude;
                    v_tent_lngs := v_tent_lngs || v_point.longitude;
                    v_tent_accs := v_tent_accs || COALESCE(v_point.accuracy, 20.0);
                    v_tent_point_ids := v_tent_point_ids || v_point.id;

                    -- Check if tentative just became confirmed (3 min)
                    IF EXTRACT(EPOCH FROM (v_point.captured_at - v_tent_started_at)) / 60.0 >= v_cluster_min_duration THEN
                        -- ★★★ NEW CLUSTER CONFIRMED ★★★
                        -- Finalize current cluster, create trip, promote tentative

                        -- A) Finalize current cluster
                        IF v_cluster_confirmed THEN
                            -- Compute departure centroid
                            SELECT
                                SUM(lat / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                                SUM(lng / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                                1.0 / SQRT(SUM(1.0 / GREATEST(acc * acc, 1)))
                            INTO v_dep_centroid_lat, v_dep_centroid_lng, v_dep_centroid_acc
                            FROM unnest(v_cluster_lats, v_cluster_lngs, v_cluster_accs) AS t(lat, lng, acc);

                            IF v_create_clusters AND v_has_db_cluster THEN
                                UPDATE stationary_clusters SET
                                    centroid_latitude = v_dep_centroid_lat,
                                    centroid_longitude = v_dep_centroid_lng,
                                    centroid_accuracy = v_dep_centroid_acc,
                                    ended_at = v_cluster_last_at,
                                    duration_seconds = EXTRACT(EPOCH FROM (v_cluster_last_at - v_cluster_started_at))::INTEGER,
                                    gps_point_count = array_length(v_cluster_point_ids, 1),
                                    matched_location_id = match_trip_to_location(v_dep_centroid_lat, v_dep_centroid_lng, COALESCE(v_dep_centroid_acc, 0))
                                WHERE id = v_cluster_id;
                                UPDATE gps_points SET stationary_cluster_id = v_cluster_id
                                WHERE id = ANY(v_cluster_point_ids) AND stationary_cluster_id IS NULL;
                            END IF;
                            v_prev_cluster_id := v_cluster_id;

                        ELSIF array_length(v_cluster_lats, 1) > 0
                              AND v_cluster_started_at IS NOT NULL
                              AND v_cluster_last_at IS NOT NULL
                              AND EXTRACT(EPOCH FROM (v_cluster_last_at - v_cluster_started_at)) >= v_cluster_min_duration * 60 THEN
                            -- Cluster reached 3 min but wasn't yet confirmed (edge case)
                            SELECT
                                SUM(lat / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                                SUM(lng / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                                1.0 / SQRT(SUM(1.0 / GREATEST(acc * acc, 1)))
                            INTO v_dep_centroid_lat, v_dep_centroid_lng, v_dep_centroid_acc
                            FROM unnest(v_cluster_lats, v_cluster_lngs, v_cluster_accs) AS t(lat, lng, acc);

                            IF v_create_clusters THEN
                                INSERT INTO stationary_clusters (
                                    shift_id, employee_id,
                                    centroid_latitude, centroid_longitude, centroid_accuracy,
                                    started_at, ended_at, duration_seconds, gps_point_count,
                                    matched_location_id
                                ) VALUES (
                                    p_shift_id, v_employee_id,
                                    v_dep_centroid_lat, v_dep_centroid_lng, v_dep_centroid_acc,
                                    v_cluster_started_at, v_cluster_last_at,
                                    EXTRACT(EPOCH FROM (v_cluster_last_at - v_cluster_started_at))::INTEGER,
                                    array_length(v_cluster_point_ids, 1),
                                    match_trip_to_location(v_dep_centroid_lat, v_dep_centroid_lng, COALESCE(v_dep_centroid_acc, 0))
                                )
                                RETURNING id INTO v_cluster_id;
                                UPDATE gps_points SET stationary_cluster_id = v_cluster_id
                                WHERE id = ANY(v_cluster_point_ids);
                            END IF;
                            v_prev_cluster_id := v_cluster_id;
                        ELSE
                            -- Current cluster too short — compute centroid anyway for trip coords
                            IF array_length(v_cluster_lats, 1) > 0 THEN
                                SELECT
                                    SUM(lat / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                                    SUM(lng / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                                    1.0 / SQRT(SUM(1.0 / GREATEST(acc * acc, 1)))
                                INTO v_dep_centroid_lat, v_dep_centroid_lng, v_dep_centroid_acc
                                FROM unnest(v_cluster_lats, v_cluster_lngs, v_cluster_accs) AS t(lat, lng, acc);
                            END IF;
                        END IF;

                        -- B) Compute arrival (tentative) centroid
                        SELECT
                            SUM(lat / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                            SUM(lng / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                            1.0 / SQRT(SUM(1.0 / GREATEST(acc * acc, 1)))
                        INTO v_arr_centroid_lat, v_arr_centroid_lng, v_arr_centroid_acc
                        FROM unnest(v_tent_lats, v_tent_lngs, v_tent_accs) AS t(lat, lng, acc);

                        -- C) Persist tentative as new cluster
                        IF v_create_clusters THEN
                            INSERT INTO stationary_clusters (
                                shift_id, employee_id,
                                centroid_latitude, centroid_longitude, centroid_accuracy,
                                started_at, ended_at, duration_seconds, gps_point_count,
                                matched_location_id
                            ) VALUES (
                                p_shift_id, v_employee_id,
                                v_arr_centroid_lat, v_arr_centroid_lng, v_arr_centroid_acc,
                                v_tent_started_at, v_point.captured_at,
                                EXTRACT(EPOCH FROM (v_point.captured_at - v_tent_started_at))::INTEGER,
                                array_length(v_tent_point_ids, 1),
                                match_trip_to_location(v_arr_centroid_lat, v_arr_centroid_lng, COALESCE(v_arr_centroid_acc, 0))
                            )
                            RETURNING id INTO v_new_cluster_id;

                            UPDATE gps_points SET stationary_cluster_id = v_new_cluster_id
                            WHERE id = ANY(v_tent_point_ids);
                        ELSE
                            v_new_cluster_id := gen_random_uuid();  -- In-memory ID for active shifts
                        END IF;

                        -- D) Create trip from departure cluster to arrival cluster
                        v_trip_start_lat := COALESCE(v_dep_centroid_lat, v_cluster_centroid_lat);
                        v_trip_start_lng := COALESCE(v_dep_centroid_lng, v_cluster_centroid_lng);
                        v_trip_start_acc := COALESCE(v_dep_centroid_acc, v_cluster_centroid_acc, 0);
                        v_trip_end_lat := v_arr_centroid_lat;
                        v_trip_end_lng := v_arr_centroid_lng;
                        v_trip_end_acc := COALESCE(v_arr_centroid_acc, 0);

                        v_trip_distance := haversine_km(
                            v_trip_start_lat, v_trip_start_lng,
                            v_trip_end_lat, v_trip_end_lng
                        ) * v_correction_factor;

                        v_trip_point_count := COALESCE(array_length(v_transit_point_ids, 1), 0);
                        v_trip_low_accuracy := 0;
                        IF v_trip_point_count > 0 THEN
                            SELECT COUNT(*) INTO v_trip_low_accuracy
                            FROM gps_points
                            WHERE id = ANY(v_transit_point_ids)
                              AND accuracy > 50;
                        END IF;

                        -- Trip timing: departure cluster end → arrival cluster start
                        v_trip_started_at := COALESCE(v_cluster_last_at, v_cluster_started_at);
                        v_trip_ended_at := v_tent_started_at;

                        -- Min distance check
                        IF v_trip_distance >= v_min_distance_km THEN
                            v_trip_id := gen_random_uuid();
                            INSERT INTO trips (
                                id, shift_id, employee_id,
                                started_at, ended_at,
                                start_latitude, start_longitude,
                                end_latitude, end_longitude,
                                distance_km, duration_minutes,
                                classification, confidence_score,
                                gps_point_count, low_accuracy_segments,
                                detection_method, transport_mode,
                                start_cluster_id, end_cluster_id
                            ) VALUES (
                                v_trip_id, p_shift_id, v_employee_id,
                                v_trip_started_at, v_trip_ended_at,
                                v_trip_start_lat, v_trip_start_lng,
                                v_trip_end_lat, v_trip_end_lng,
                                ROUND(v_trip_distance, 3),
                                GREATEST(1, EXTRACT(EPOCH FROM (v_trip_ended_at - v_trip_started_at)) / 60)::INTEGER,
                                'business',
                                ROUND(GREATEST(0, CASE WHEN v_trip_point_count > 0 THEN 1.0 - (v_trip_low_accuracy::DECIMAL / v_trip_point_count) ELSE 0.80 END), 2),
                                v_trip_point_count,
                                v_trip_low_accuracy,
                                'auto',
                                'unknown',
                                v_prev_cluster_id,
                                v_new_cluster_id
                            );

                            -- Insert trip GPS points (transit buffer)
                            IF v_trip_point_count > 0 THEN
                                FOR i IN 1..v_trip_point_count LOOP
                                    INSERT INTO trip_gps_points (trip_id, gps_point_id, sequence_order)
                                    VALUES (v_trip_id, v_transit_point_ids[i], i)
                                    ON CONFLICT DO NOTHING;
                                END LOOP;
                            END IF;

                            -- Post-processing: classify transport mode
                            v_transport_mode := classify_trip_transport_mode(v_trip_id);

                            -- Ghost trip filters
                            v_displacement := haversine_km(
                                v_trip_start_lat, v_trip_start_lng,
                                v_trip_end_lat, v_trip_end_lng
                            );

                            IF v_transport_mode = 'walking' AND v_displacement < v_min_displacement_walking THEN
                                DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                                DELETE FROM trips WHERE id = v_trip_id;
                            ELSIF v_transport_mode = 'driving' AND v_trip_distance < v_min_distance_driving THEN
                                DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                                DELETE FROM trips WHERE id = v_trip_id;
                            ELSIF v_transport_mode = 'driving' AND v_displacement < 0.05 THEN
                                DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                                DELETE FROM trips WHERE id = v_trip_id;
                            ELSIF v_transport_mode = 'driving' AND v_trip_point_count <= 10 AND v_trip_point_count > 0 THEN
                                v_straightness := v_displacement / NULLIF(v_trip_distance, 0);
                                IF v_straightness IS NOT NULL AND v_straightness < 0.10 THEN
                                    DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                                    DELETE FROM trips WHERE id = v_trip_id;
                                ELSE
                                    -- Trip passed all filters
                                    UPDATE trips SET transport_mode = v_transport_mode WHERE id = v_trip_id;

                                    -- Location matching
                                    UPDATE trips SET
                                        start_location_id = CASE
                                            WHEN v_prev_trip_end_location_id IS NOT NULL
                                                 AND haversine_km(v_trip_start_lat, v_trip_start_lng,
                                                                  v_prev_trip_end_lat, v_prev_trip_end_lng) * 1000.0 < 100
                                            THEN v_prev_trip_end_location_id
                                            ELSE match_trip_to_location(v_trip_start_lat, v_trip_start_lng, v_trip_start_acc)
                                        END,
                                        end_location_id = match_trip_to_location(v_trip_end_lat, v_trip_end_lng, v_trip_end_acc)
                                    WHERE id = v_trip_id;

                                    SELECT end_location_id INTO v_prev_trip_end_location_id FROM trips WHERE id = v_trip_id;
                                    v_prev_trip_end_lat := v_trip_end_lat;
                                    v_prev_trip_end_lng := v_trip_end_lng;

                                    RETURN QUERY SELECT
                                        v_trip_id,
                                        v_trip_started_at,
                                        v_trip_ended_at,
                                        v_trip_start_lat::DECIMAL(10,8),
                                        v_trip_start_lng::DECIMAL(11,8),
                                        v_trip_end_lat::DECIMAL(10,8),
                                        v_trip_end_lng::DECIMAL(11,8),
                                        ROUND(v_trip_distance, 3),
                                        GREATEST(1, EXTRACT(EPOCH FROM (v_trip_ended_at - v_trip_started_at)) / 60)::INTEGER,
                                        ROUND(GREATEST(0, CASE WHEN v_trip_point_count > 0 THEN 1.0 - (v_trip_low_accuracy::DECIMAL / v_trip_point_count) ELSE 0.80 END), 2),
                                        v_trip_point_count;
                                END IF;
                            ELSE
                                -- Trip passed all filters (non-driving or driving with >10 pts)
                                UPDATE trips SET transport_mode = v_transport_mode WHERE id = v_trip_id;

                                -- Location matching
                                UPDATE trips SET
                                    start_location_id = CASE
                                        WHEN v_prev_trip_end_location_id IS NOT NULL
                                             AND haversine_km(v_trip_start_lat, v_trip_start_lng,
                                                              v_prev_trip_end_lat, v_prev_trip_end_lng) * 1000.0 < 100
                                        THEN v_prev_trip_end_location_id
                                        ELSE match_trip_to_location(v_trip_start_lat, v_trip_start_lng, v_trip_start_acc)
                                    END,
                                    end_location_id = match_trip_to_location(v_trip_end_lat, v_trip_end_lng, v_trip_end_acc)
                                WHERE id = v_trip_id;

                                SELECT end_location_id INTO v_prev_trip_end_location_id FROM trips WHERE id = v_trip_id;
                                v_prev_trip_end_lat := v_trip_end_lat;
                                v_prev_trip_end_lng := v_trip_end_lng;

                                RETURN QUERY SELECT
                                    v_trip_id,
                                    v_trip_started_at,
                                    v_trip_ended_at,
                                    v_trip_start_lat::DECIMAL(10,8),
                                    v_trip_start_lng::DECIMAL(11,8),
                                    v_trip_end_lat::DECIMAL(10,8),
                                    v_trip_end_lng::DECIMAL(11,8),
                                    ROUND(v_trip_distance, 3),
                                    GREATEST(1, EXTRACT(EPOCH FROM (v_trip_ended_at - v_trip_started_at)) / 60)::INTEGER,
                                    ROUND(GREATEST(0, CASE WHEN v_trip_point_count > 0 THEN 1.0 - (v_trip_low_accuracy::DECIMAL / v_trip_point_count) ELSE 0.80 END), 2),
                                    v_trip_point_count;
                            END IF;
                        END IF;

                        -- E) Promote: tentative becomes current
                        v_cluster_lats := v_tent_lats;
                        v_cluster_lngs := v_tent_lngs;
                        v_cluster_accs := v_tent_accs;
                        v_cluster_point_ids := v_tent_point_ids;
                        v_cluster_started_at := v_tent_started_at;
                        v_cluster_last_at := v_point.captured_at;
                        v_cluster_confirmed := TRUE;
                        v_cluster_centroid_lat := v_arr_centroid_lat;
                        v_cluster_centroid_lng := v_arr_centroid_lng;
                        v_cluster_centroid_acc := v_arr_centroid_acc;
                        v_cluster_id := v_new_cluster_id;
                        v_has_db_cluster := v_create_clusters;

                        -- Reset tentative and transit
                        v_has_tentative := FALSE;
                        v_tent_lats := '{}';
                        v_tent_lngs := '{}';
                        v_tent_accs := '{}';
                        v_tent_point_ids := '{}';
                        v_transit_point_ids := '{}';
                    END IF;

                ELSE
                    -- Point beyond BOTH clusters → in transit
                    -- Move tentative points to transit buffer
                    v_transit_point_ids := v_transit_point_ids || v_tent_point_ids;
                    -- Also add this point to transit
                    v_transit_point_ids := v_transit_point_ids || v_point.id;

                    -- Start new tentative with this point
                    v_tent_lats := ARRAY[v_point.latitude];
                    v_tent_lngs := ARRAY[v_point.longitude];
                    v_tent_accs := ARRAY[COALESCE(v_point.accuracy, 20.0)];
                    v_tent_point_ids := ARRAY[v_point.id];
                    v_tent_started_at := v_point.captured_at;
                END IF;
            END IF;
        END IF;

        v_prev_point := v_point;
        v_has_prev_point := TRUE;
    END LOOP;

    -- =========================================================================
    -- 5. End of data: finalize last cluster
    -- =========================================================================
    IF NOT v_is_active THEN
        -- Finalize the current cluster if it qualifies
        IF v_cluster_confirmed OR (
            array_length(v_cluster_lats, 1) > 0
            AND v_cluster_started_at IS NOT NULL
            AND v_cluster_last_at IS NOT NULL
            AND EXTRACT(EPOCH FROM (v_cluster_last_at - v_cluster_started_at)) >= v_cluster_min_duration * 60
        ) THEN
            IF v_create_clusters THEN
                SELECT
                    SUM(lat / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                    SUM(lng / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                    1.0 / SQRT(SUM(1.0 / GREATEST(acc * acc, 1)))
                INTO v_cluster_centroid_lat, v_cluster_centroid_lng, v_cluster_centroid_acc
                FROM unnest(v_cluster_lats, v_cluster_lngs, v_cluster_accs) AS t(lat, lng, acc);

                IF v_has_db_cluster THEN
                    UPDATE stationary_clusters SET
                        centroid_latitude = v_cluster_centroid_lat,
                        centroid_longitude = v_cluster_centroid_lng,
                        centroid_accuracy = v_cluster_centroid_acc,
                        ended_at = v_cluster_last_at,
                        duration_seconds = EXTRACT(EPOCH FROM (v_cluster_last_at - v_cluster_started_at))::INTEGER,
                        gps_point_count = array_length(v_cluster_point_ids, 1),
                        matched_location_id = match_trip_to_location(v_cluster_centroid_lat, v_cluster_centroid_lng, COALESCE(v_cluster_centroid_acc, 0))
                    WHERE id = v_cluster_id;
                    UPDATE gps_points SET stationary_cluster_id = v_cluster_id
                    WHERE id = ANY(v_cluster_point_ids) AND stationary_cluster_id IS NULL;
                ELSE
                    INSERT INTO stationary_clusters (
                        shift_id, employee_id,
                        centroid_latitude, centroid_longitude, centroid_accuracy,
                        started_at, ended_at, duration_seconds, gps_point_count,
                        matched_location_id
                    ) VALUES (
                        p_shift_id, v_employee_id,
                        v_cluster_centroid_lat, v_cluster_centroid_lng, v_cluster_centroid_acc,
                        v_cluster_started_at, v_cluster_last_at,
                        EXTRACT(EPOCH FROM (v_cluster_last_at - v_cluster_started_at))::INTEGER,
                        array_length(v_cluster_point_ids, 1),
                        match_trip_to_location(v_cluster_centroid_lat, v_cluster_centroid_lng, COALESCE(v_cluster_centroid_acc, 0))
                    )
                    RETURNING id INTO v_cluster_id;
                    v_has_db_cluster := TRUE;
                    UPDATE gps_points SET stationary_cluster_id = v_cluster_id
                    WHERE id = ANY(v_cluster_point_ids);
                END IF;
            END IF;
        END IF;

        -- =====================================================================
        -- 6. Handle trailing transit (points after last confirmed cluster)
        -- =====================================================================
        -- If there are transit points + tentative points after the last cluster,
        -- create a trip from the last cluster to the last known position
        IF v_prev_cluster_id IS NOT NULL AND v_has_prev_point THEN
            -- Collect all trailing points (transit + tentative)
            IF v_has_tentative THEN
                v_transit_point_ids := v_transit_point_ids || v_tent_point_ids;
            END IF;

            v_trip_point_count := COALESCE(array_length(v_transit_point_ids, 1), 0);

            IF v_trip_point_count > 0 THEN
                -- Get departure cluster centroid
                SELECT centroid_latitude, centroid_longitude, COALESCE(centroid_accuracy, 0)
                INTO v_dep_centroid_lat, v_dep_centroid_lng, v_dep_centroid_acc
                FROM stationary_clusters WHERE id = v_prev_cluster_id;

                IF v_dep_centroid_lat IS NOT NULL THEN
                    -- Use last transit/tentative point as arrival
                    v_trip_end_lat := v_prev_point.latitude;
                    v_trip_end_lng := v_prev_point.longitude;
                    v_trip_end_acc := COALESCE(v_prev_point.accuracy, 0);

                    v_trip_distance := haversine_km(
                        v_dep_centroid_lat, v_dep_centroid_lng,
                        v_trip_end_lat, v_trip_end_lng
                    ) * v_correction_factor;

                    -- Get departure cluster end time for trip start
                    SELECT ended_at INTO v_trip_started_at
                    FROM stationary_clusters WHERE id = v_prev_cluster_id;
                    v_trip_ended_at := v_prev_point.captured_at;

                    v_trip_low_accuracy := 0;
                    SELECT COUNT(*) INTO v_trip_low_accuracy
                    FROM gps_points
                    WHERE id = ANY(v_transit_point_ids)
                      AND accuracy > 50;

                    IF v_trip_distance >= v_min_distance_km THEN
                        v_trip_id := gen_random_uuid();
                        INSERT INTO trips (
                            id, shift_id, employee_id,
                            started_at, ended_at,
                            start_latitude, start_longitude,
                            end_latitude, end_longitude,
                            distance_km, duration_minutes,
                            classification, confidence_score,
                            gps_point_count, low_accuracy_segments,
                            detection_method, transport_mode,
                            start_cluster_id, end_cluster_id
                        ) VALUES (
                            v_trip_id, p_shift_id, v_employee_id,
                            v_trip_started_at, v_trip_ended_at,
                            v_dep_centroid_lat, v_dep_centroid_lng,
                            v_trip_end_lat, v_trip_end_lng,
                            ROUND(v_trip_distance, 3),
                            GREATEST(1, EXTRACT(EPOCH FROM (v_trip_ended_at - v_trip_started_at)) / 60)::INTEGER,
                            'business',
                            ROUND(GREATEST(0, CASE WHEN v_trip_point_count > 0 THEN 1.0 - (v_trip_low_accuracy::DECIMAL / v_trip_point_count) ELSE 0.80 END), 2),
                            v_trip_point_count,
                            v_trip_low_accuracy,
                            'auto',
                            'unknown',
                            v_prev_cluster_id,
                            NULL
                        );

                        FOR i IN 1..v_trip_point_count LOOP
                            INSERT INTO trip_gps_points (trip_id, gps_point_id, sequence_order)
                            VALUES (v_trip_id, v_transit_point_ids[i], i)
                            ON CONFLICT DO NOTHING;
                        END LOOP;

                        -- Post-processing
                        v_transport_mode := classify_trip_transport_mode(v_trip_id);
                        v_displacement := haversine_km(
                            v_dep_centroid_lat, v_dep_centroid_lng,
                            v_trip_end_lat, v_trip_end_lng
                        );

                        IF v_transport_mode = 'walking' AND v_displacement < v_min_displacement_walking THEN
                            DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                            DELETE FROM trips WHERE id = v_trip_id;
                        ELSIF v_transport_mode = 'driving' AND v_trip_distance < v_min_distance_driving THEN
                            DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                            DELETE FROM trips WHERE id = v_trip_id;
                        ELSIF v_transport_mode = 'driving' AND v_displacement < 0.05 THEN
                            DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                            DELETE FROM trips WHERE id = v_trip_id;
                        ELSIF v_transport_mode = 'driving' AND v_trip_point_count <= 10 THEN
                            v_straightness := v_displacement / NULLIF(v_trip_distance, 0);
                            IF v_straightness IS NOT NULL AND v_straightness < 0.10 THEN
                                DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                                DELETE FROM trips WHERE id = v_trip_id;
                            ELSE
                                UPDATE trips SET transport_mode = v_transport_mode WHERE id = v_trip_id;
                                UPDATE trips SET
                                    start_location_id = CASE
                                        WHEN v_prev_trip_end_location_id IS NOT NULL
                                             AND haversine_km(v_dep_centroid_lat, v_dep_centroid_lng,
                                                              v_prev_trip_end_lat, v_prev_trip_end_lng) * 1000.0 < 100
                                        THEN v_prev_trip_end_location_id
                                        ELSE match_trip_to_location(v_dep_centroid_lat, v_dep_centroid_lng, v_dep_centroid_acc)
                                    END,
                                    end_location_id = match_trip_to_location(v_trip_end_lat, v_trip_end_lng, v_trip_end_acc)
                                WHERE id = v_trip_id;

                                RETURN QUERY SELECT
                                    v_trip_id, v_trip_started_at, v_trip_ended_at,
                                    v_dep_centroid_lat::DECIMAL(10,8), v_dep_centroid_lng::DECIMAL(11,8),
                                    v_trip_end_lat::DECIMAL(10,8), v_trip_end_lng::DECIMAL(11,8),
                                    ROUND(v_trip_distance, 3),
                                    GREATEST(1, EXTRACT(EPOCH FROM (v_trip_ended_at - v_trip_started_at)) / 60)::INTEGER,
                                    ROUND(GREATEST(0, CASE WHEN v_trip_point_count > 0 THEN 1.0 - (v_trip_low_accuracy::DECIMAL / v_trip_point_count) ELSE 0.80 END), 2),
                                    v_trip_point_count;
                            END IF;
                        ELSE
                            UPDATE trips SET transport_mode = v_transport_mode WHERE id = v_trip_id;
                            UPDATE trips SET
                                start_location_id = CASE
                                    WHEN v_prev_trip_end_location_id IS NOT NULL
                                         AND haversine_km(v_dep_centroid_lat, v_dep_centroid_lng,
                                                          v_prev_trip_end_lat, v_prev_trip_end_lng) * 1000.0 < 100
                                    THEN v_prev_trip_end_location_id
                                    ELSE match_trip_to_location(v_dep_centroid_lat, v_dep_centroid_lng, v_dep_centroid_acc)
                                END,
                                end_location_id = match_trip_to_location(v_trip_end_lat, v_trip_end_lng, v_trip_end_acc)
                            WHERE id = v_trip_id;

                            RETURN QUERY SELECT
                                v_trip_id, v_trip_started_at, v_trip_ended_at,
                                v_dep_centroid_lat::DECIMAL(10,8), v_dep_centroid_lng::DECIMAL(11,8),
                                v_trip_end_lat::DECIMAL(10,8), v_trip_end_lng::DECIMAL(11,8),
                                ROUND(v_trip_distance, 3),
                                GREATEST(1, EXTRACT(EPOCH FROM (v_trip_ended_at - v_trip_started_at)) / 60)::INTEGER,
                                ROUND(GREATEST(0, CASE WHEN v_trip_point_count > 0 THEN 1.0 - (v_trip_low_accuracy::DECIMAL / v_trip_point_count) ELSE 0.80 END), 2),
                                v_trip_point_count;
                        END IF;
                    END IF;
                END IF;
            END IF;
        END IF;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
