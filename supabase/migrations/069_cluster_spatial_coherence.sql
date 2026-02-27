-- =============================================================================
-- 069: Add spatial coherence check to detect_trips cluster accumulation
-- =============================================================================
-- Fixes a bug where slow walking (~1 m/s, below the 8 km/h trip-start
-- threshold) between two locations causes stopped points at the new location
-- to be added to the SAME cluster as the origin. The centroid ends up between
-- the two real locations where nobody ever was.
--
-- Changes (over 061):
--   1. New variables for spatial coherence tracking (v_cluster_max_drift,
--      v_unclaimed_point_ids, v_running_centroid_*, v_drift_distance,
--      v_split_trip_*)
--   2. Pre-trip cluster accumulation now checks spatial coherence: when a
--      stopped GPS point is >50m (adjusted for accuracy) from the cluster's
--      running centroid, the cluster is finalized, a trip is created from
--      unclaimed intermediate points, and a new cluster begins.
--   3. Unclaimed point tracking: non-stopped, non-trip points with speed
--      below movement threshold are collected for potential split trips.
--   4. Unclaimed points reset on trip start (cluster reset block).
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
    v_speed DECIMAL;
    v_dist DECIMAL;
    v_dist_meters DECIMAL;
    v_time_delta DECIMAL;
    v_in_trip BOOLEAN := FALSE;
    v_trip_start_point RECORD;
    v_trip_end_point RECORD;
    v_trip_distance DECIMAL := 0;
    v_trip_point_count INTEGER := 0;
    v_trip_low_accuracy INTEGER := 0;
    v_trip_points UUID[] := '{}';
    v_trip_id UUID;
    v_stationary_since TIMESTAMPTZ := NULL;
    v_correction_factor CONSTANT DECIMAL := 1.3;
    v_min_distance_km CONSTANT DECIMAL := 0.2;
    v_min_distance_driving CONSTANT DECIMAL := 0.5;
    v_movement_speed CONSTANT DECIMAL := 8.0;
    v_stationary_speed CONSTANT DECIMAL := 3.0;
    v_max_speed CONSTANT DECIMAL := 200.0;
    v_max_accuracy CONSTANT DECIMAL := 200.0;
    v_stationary_gap_minutes CONSTANT INTEGER := 3;
    v_gps_gap_minutes CONSTANT INTEGER := 15;
    v_min_displacement_walking CONSTANT DECIMAL := 0.1;
    v_sensor_stationary CONSTANT DECIMAL := 0.5;
    v_seq INTEGER;
    v_transport_mode TEXT;
    v_displacement DECIMAL;
    v_is_active BOOLEAN;
    v_cutoff_time TIMESTAMPTZ := NULL;
    v_noise_floor DECIMAL;
    v_last_stationary_point RECORD;
    v_has_last_stationary BOOLEAN := FALSE;
    v_prev_trip_end_location_id UUID := NULL;
    v_prev_trip_end_lat DECIMAL;
    v_prev_trip_end_lng DECIMAL;
    v_stationary_center_lat DECIMAL := NULL;
    v_stationary_center_lng DECIMAL := NULL;
    v_sensor_stop_threshold CONSTANT DECIMAL := 0.28;
    v_spatial_radius_km CONSTANT DECIMAL := 0.05;
    v_point_is_stopped BOOLEAN;
    -- Cluster tracking (061)
    v_cluster_lats DECIMAL[] := '{}';
    v_cluster_lngs DECIMAL[] := '{}';
    v_cluster_accs DECIMAL[] := '{}';
    v_cluster_point_ids UUID[] := '{}';
    v_cluster_started_at TIMESTAMPTZ := NULL;
    v_cluster_id UUID := NULL;
    v_has_active_cluster BOOLEAN := FALSE;
    v_centroid_lat DECIMAL;
    v_centroid_lng DECIMAL;
    v_centroid_acc DECIMAL;
    v_prev_cluster_id UUID := NULL;
    v_create_clusters BOOLEAN;
    -- Effective trip coordinates (cluster centroid when available)
    v_eff_start_lat DECIMAL;
    v_eff_start_lng DECIMAL;
    v_eff_start_acc DECIMAL;
    v_eff_end_lat DECIMAL;
    v_eff_end_lng DECIMAL;
    v_eff_end_acc DECIMAL;
    -- Spatial coherence (064)
    v_cluster_max_drift CONSTANT DECIMAL := 50.0;  -- meters
    v_unclaimed_point_ids UUID[] := '{}';
    v_running_centroid_lat DECIMAL;
    v_running_centroid_lng DECIMAL;
    v_drift_distance DECIMAL;
    v_split_trip_id UUID;
    v_split_trip_distance DECIMAL;
    v_split_trip_start RECORD;
    v_split_trip_end RECORD;
    v_split_point_count INTEGER;
    v_split_low_accuracy INTEGER;
BEGIN
    -- Validate shift exists
    SELECT s.id, s.employee_id, s.status
    INTO v_shift
    FROM shifts s
    WHERE s.id = p_shift_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Shift not found: %', p_shift_id;
    END IF;

    v_employee_id := v_shift.employee_id;
    v_is_active := (v_shift.status = 'active');

    IF v_is_active THEN
        -- Active shift: preserve matched/failed/anomalous trips, only delete pending ones
        DELETE FROM trips
        WHERE shift_id = p_shift_id
          AND match_status IN ('pending', 'processing');

        -- Find cutoff: latest GPS point in any preserved trip
        SELECT MAX(gp.captured_at) INTO v_cutoff_time
        FROM trips t
        JOIN trip_gps_points tgp ON tgp.trip_id = t.id
        JOIN gps_points gp ON gp.id = tgp.gps_point_id
        WHERE t.shift_id = p_shift_id;
    ELSE
        -- Completed shift: full re-detection
        DELETE FROM trips WHERE shift_id = p_shift_id;
    END IF;

    -- Only create clusters for completed shifts (full re-detection)
    v_create_clusters := NOT v_is_active;
    IF v_create_clusters THEN
        DELETE FROM stationary_clusters WHERE shift_id = p_shift_id;
    END IF;

    -- Process GPS points (after cutoff if incremental)
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

        IF v_prev_point IS NOT NULL THEN
            -- Calculate distance and speed
            v_dist := haversine_km(
                v_prev_point.latitude, v_prev_point.longitude,
                v_point.latitude, v_point.longitude
            );
            v_time_delta := EXTRACT(EPOCH FROM (v_point.captured_at - v_prev_point.captured_at)) / 3600.0;

            -- Skip if time delta is zero
            IF v_time_delta <= 0 THEN
                v_prev_point := v_point;
                CONTINUE;
            END IF;

            v_speed := v_dist / v_time_delta;
            v_dist_meters := v_dist * 1000.0;

            -- FILTER 1: GPS accuracy noise floor
            v_noise_floor := GREATEST(
                COALESCE(v_prev_point.accuracy, 10),
                COALESCE(v_point.accuracy, 10)
            );
            IF v_dist_meters < v_noise_floor THEN
                v_speed := 0;
            END IF;

            -- FILTER 2: GPS sensor speed cross-check
            IF v_prev_point.speed IS NOT NULL AND v_point.speed IS NOT NULL
               AND v_prev_point.speed < v_sensor_stationary AND v_point.speed < v_sensor_stationary THEN
                v_speed := 0;
            END IF;

            -- Determine if point is stopped using sensor speed + spatial radius (053)
            v_point_is_stopped := FALSE;
            IF v_point.speed IS NOT NULL AND v_point.speed < v_sensor_stop_threshold THEN
                v_point_is_stopped := TRUE;
            ELSIF v_stationary_center_lat IS NOT NULL
                  AND v_point.speed IS NOT NULL AND v_point.speed < 3.0
                  AND haversine_km(v_stationary_center_lat, v_stationary_center_lng,
                                   v_point.latitude, v_point.longitude) < v_spatial_radius_km THEN
                v_point_is_stopped := TRUE;
            END IF;

            -- Track last truly stationary point (departure origin for next trip)
            IF v_point_is_stopped AND NOT v_in_trip THEN
                IF NOT v_has_last_stationary THEN
                    v_last_stationary_point := v_prev_point;
                    v_has_last_stationary := TRUE;
                ELSIF haversine_km(v_last_stationary_point.latitude, v_last_stationary_point.longitude,
                                   v_prev_point.latitude, v_prev_point.longitude) * 1000.0 < 30 THEN
                    v_last_stationary_point := v_prev_point;
                END IF;

                -- Accumulate into cluster with spatial coherence check (064)
                IF v_create_clusters THEN
                    -- Check spatial coherence: is this stopped point too far from cluster?
                    IF array_length(v_cluster_lats, 1) >= 3 THEN
                        -- Unweighted centroid is sufficient for coarse 50m drift check
                        SELECT AVG(lat), AVG(lng)
                        INTO v_running_centroid_lat, v_running_centroid_lng
                        FROM unnest(v_cluster_lats, v_cluster_lngs) AS t(lat, lng);

                        v_drift_distance := haversine_km(
                            v_running_centroid_lat, v_running_centroid_lng,
                            v_point.latitude, v_point.longitude
                        ) * 1000.0;

                        IF GREATEST(v_drift_distance - COALESCE(v_point.accuracy, 20.0), 0) > v_cluster_max_drift THEN
                            -- ==========================================================
                            -- SPLIT: Finalize current cluster, create trip, start new one
                            -- ==========================================================

                            -- 1. Finalize current cluster (same logic as pre-trip finalization)
                            SELECT
                                SUM(lat / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                                SUM(lng / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                                1.0 / SQRT(SUM(1.0 / GREATEST(acc * acc, 1)))
                            INTO v_centroid_lat, v_centroid_lng, v_centroid_acc
                            FROM unnest(v_cluster_lats, v_cluster_lngs, v_cluster_accs) AS t(lat, lng, acc);

                            IF v_has_active_cluster THEN
                                UPDATE stationary_clusters SET
                                    centroid_latitude = v_centroid_lat,
                                    centroid_longitude = v_centroid_lng,
                                    centroid_accuracy = v_centroid_acc,
                                    ended_at = v_prev_point.captured_at,
                                    duration_seconds = EXTRACT(EPOCH FROM (v_prev_point.captured_at - v_cluster_started_at))::INTEGER,
                                    gps_point_count = array_length(v_cluster_point_ids, 1),
                                    matched_location_id = match_trip_to_location(v_centroid_lat, v_centroid_lng, COALESCE(v_centroid_acc, 0))
                                WHERE id = v_cluster_id;
                                UPDATE gps_points SET stationary_cluster_id = v_cluster_id
                                WHERE id = ANY(v_cluster_point_ids) AND stationary_cluster_id IS NULL;
                                v_prev_cluster_id := v_cluster_id;
                            ELSIF v_cluster_started_at IS NOT NULL
                                  AND EXTRACT(EPOCH FROM (v_prev_point.captured_at - v_cluster_started_at)) >= v_stationary_gap_minutes * 60 THEN
                                INSERT INTO stationary_clusters (
                                    shift_id, employee_id,
                                    centroid_latitude, centroid_longitude, centroid_accuracy,
                                    started_at, ended_at, duration_seconds, gps_point_count,
                                    matched_location_id
                                ) VALUES (
                                    p_shift_id, v_employee_id,
                                    v_centroid_lat, v_centroid_lng, v_centroid_acc,
                                    v_cluster_started_at, v_prev_point.captured_at,
                                    EXTRACT(EPOCH FROM (v_prev_point.captured_at - v_cluster_started_at))::INTEGER,
                                    array_length(v_cluster_point_ids, 1),
                                    match_trip_to_location(v_centroid_lat, v_centroid_lng, COALESCE(v_centroid_acc, 0))
                                )
                                RETURNING id INTO v_cluster_id;
                                UPDATE gps_points SET stationary_cluster_id = v_cluster_id
                                WHERE id = ANY(v_cluster_point_ids);
                                v_prev_cluster_id := v_cluster_id;
                            END IF;

                            -- 2. Create trip from unclaimed points (if enough)
                            IF array_length(v_unclaimed_point_ids, 1) >= 2 THEN
                                v_eff_start_lat := COALESCE(v_centroid_lat, v_prev_point.latitude);
                                v_eff_start_lng := COALESCE(v_centroid_lng, v_prev_point.longitude);
                                v_eff_start_acc := COALESCE(v_centroid_acc, v_prev_point.accuracy, 0);
                                v_eff_end_lat := v_point.latitude;
                                v_eff_end_lng := v_point.longitude;
                                v_eff_end_acc := COALESCE(v_point.accuracy, 0);

                                v_split_trip_distance := haversine_km(
                                    v_eff_start_lat, v_eff_start_lng,
                                    v_eff_end_lat, v_eff_end_lng
                                ) * v_correction_factor;
                                v_split_point_count := array_length(v_unclaimed_point_ids, 1);
                                v_split_low_accuracy := 0;

                                SELECT gp.captured_at INTO v_split_trip_start
                                FROM gps_points gp WHERE gp.id = v_unclaimed_point_ids[1];
                                SELECT gp.captured_at INTO v_split_trip_end
                                FROM gps_points gp WHERE gp.id = v_unclaimed_point_ids[v_split_point_count];

                                IF v_split_trip_distance >= v_min_distance_km AND v_split_point_count >= 2 THEN
                                    v_split_trip_id := gen_random_uuid();
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
                                        v_split_trip_id, p_shift_id, v_employee_id,
                                        v_split_trip_start.captured_at,
                                        v_split_trip_end.captured_at,
                                        v_eff_start_lat, v_eff_start_lng,
                                        v_eff_end_lat, v_eff_end_lng,
                                        ROUND(v_split_trip_distance, 3),
                                        GREATEST(1, EXTRACT(EPOCH FROM (v_split_trip_end.captured_at - v_split_trip_start.captured_at)) / 60)::INTEGER,
                                        'business', 0.50,
                                        v_split_point_count, v_split_low_accuracy,
                                        'auto', 'unknown',
                                        v_prev_cluster_id, NULL
                                    );

                                    FOR i IN 1..v_split_point_count LOOP
                                        INSERT INTO trip_gps_points (trip_id, gps_point_id, sequence_order)
                                        VALUES (v_split_trip_id, v_unclaimed_point_ids[i], i)
                                        ON CONFLICT DO NOTHING;
                                    END LOOP;

                                    v_transport_mode := classify_trip_transport_mode(v_split_trip_id);
                                    v_displacement := haversine_km(
                                        v_eff_start_lat, v_eff_start_lng,
                                        v_eff_end_lat, v_eff_end_lng
                                    );

                                    IF v_transport_mode = 'walking' AND v_displacement < v_min_displacement_walking THEN
                                        DELETE FROM trip_gps_points WHERE trip_id = v_split_trip_id;
                                        DELETE FROM trips WHERE id = v_split_trip_id;
                                        v_split_trip_id := NULL;
                                    ELSIF v_transport_mode = 'driving' AND v_split_trip_distance < v_min_distance_driving THEN
                                        DELETE FROM trip_gps_points WHERE trip_id = v_split_trip_id;
                                        DELETE FROM trips WHERE id = v_split_trip_id;
                                        v_split_trip_id := NULL;
                                    ELSE
                                        UPDATE trips SET transport_mode = v_transport_mode WHERE id = v_split_trip_id;
                                        UPDATE trips SET
                                            start_location_id = match_trip_to_location(v_eff_start_lat, v_eff_start_lng, v_eff_start_acc),
                                            end_location_id = match_trip_to_location(v_eff_end_lat, v_eff_end_lng, v_eff_end_acc)
                                        WHERE id = v_split_trip_id;

                                        -- Update trip continuity for next trip's start-location optimization
                                        SELECT end_location_id INTO v_prev_trip_end_location_id FROM trips WHERE id = v_split_trip_id;
                                        v_prev_trip_end_lat := v_eff_end_lat;
                                        v_prev_trip_end_lng := v_eff_end_lng;

                                        RETURN QUERY SELECT
                                            v_split_trip_id,
                                            v_split_trip_start.captured_at,
                                            v_split_trip_end.captured_at,
                                            v_eff_start_lat::DECIMAL(10,8),
                                            v_eff_start_lng::DECIMAL(11,8),
                                            v_eff_end_lat::DECIMAL(10,8),
                                            v_eff_end_lng::DECIMAL(11,8),
                                            ROUND(v_split_trip_distance, 3),
                                            GREATEST(1, EXTRACT(EPOCH FROM (v_split_trip_end.captured_at - v_split_trip_start.captured_at)) / 60)::INTEGER,
                                            0.50::DECIMAL(3,2),
                                            v_split_point_count;
                                    END IF;
                                END IF;
                            END IF;

                            -- 3. Reset cluster state for new cluster
                            v_cluster_lats := '{}';
                            v_cluster_lngs := '{}';
                            v_cluster_accs := '{}';
                            v_cluster_point_ids := '{}';
                            v_cluster_started_at := NULL;
                            v_cluster_id := NULL;
                            v_has_active_cluster := FALSE;
                            v_unclaimed_point_ids := '{}';
                        END IF;
                    END IF;

                    -- Normal accumulation (point passes coherence check or cluster too small)
                    v_cluster_lats := v_cluster_lats || v_point.latitude;
                    v_cluster_lngs := v_cluster_lngs || v_point.longitude;
                    v_cluster_accs := v_cluster_accs || COALESCE(v_point.accuracy, 20.0);
                    v_cluster_point_ids := v_cluster_point_ids || v_point.id;
                    IF v_cluster_started_at IS NULL THEN
                        v_cluster_started_at := v_point.captured_at;
                    END IF;
                    IF v_has_active_cluster THEN
                        UPDATE gps_points SET stationary_cluster_id = v_cluster_id WHERE id = v_point.id;
                    END IF;

                    -- Reset unclaimed: this stopped point joined the cluster successfully
                    v_unclaimed_point_ids := '{}';
                END IF;
            END IF;

            -- Skip impossible speeds (GPS glitch)
            IF v_speed > v_max_speed THEN
                v_prev_point := v_point;
                CONTINUE;
            END IF;

            -- =================================================================
            -- PATH 1: GPS gap (>15 min between points) — end current trip
            -- =================================================================
            IF EXTRACT(EPOCH FROM (v_point.captured_at - v_prev_point.captured_at)) / 60.0 > v_gps_gap_minutes AND v_in_trip THEN
                -- Compute effective start coordinates (use cluster centroid if available)
                v_eff_start_lat := v_trip_start_point.latitude;
                v_eff_start_lng := v_trip_start_point.longitude;
                v_eff_start_acc := COALESCE(v_trip_start_point.accuracy, 0);
                IF v_create_clusters AND v_prev_cluster_id IS NOT NULL THEN
                    SELECT centroid_latitude, centroid_longitude, COALESCE(centroid_accuracy, 0)
                    INTO v_eff_start_lat, v_eff_start_lng, v_eff_start_acc
                    FROM stationary_clusters WHERE id = v_prev_cluster_id;
                END IF;

                -- Compute effective end coordinates
                v_eff_end_lat := v_trip_end_point.latitude;
                v_eff_end_lng := v_trip_end_point.longitude;
                v_eff_end_acc := COALESCE(v_trip_end_point.accuracy, 0);

                v_trip_distance := v_trip_distance * v_correction_factor;
                IF v_trip_distance >= v_min_distance_km AND v_trip_point_count >= 2 THEN
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
                        v_trip_start_point.captured_at, v_trip_end_point.captured_at,
                        v_eff_start_lat, v_eff_start_lng,
                        v_eff_end_lat, v_eff_end_lng,
                        ROUND(v_trip_distance, 3),
                        GREATEST(1, EXTRACT(EPOCH FROM (v_trip_end_point.captured_at - v_trip_start_point.captured_at)) / 60)::INTEGER,
                        'business',
                        ROUND(GREATEST(0, 1.0 - (v_trip_low_accuracy::DECIMAL / GREATEST(v_trip_point_count, 1))), 2),
                        v_trip_point_count,
                        v_trip_low_accuracy,
                        'auto',
                        'unknown',
                        v_prev_cluster_id,
                        NULL
                    );

                    -- Insert junction records
                    v_seq := 0;
                    FOR i IN 1..array_length(v_trip_points, 1) LOOP
                        v_seq := v_seq + 1;
                        INSERT INTO trip_gps_points (trip_id, gps_point_id, sequence_order)
                        VALUES (v_trip_id, v_trip_points[i], v_seq)
                        ON CONFLICT DO NOTHING;
                    END LOOP;

                    -- Classify transport mode from sensor speeds
                    v_transport_mode := classify_trip_transport_mode(v_trip_id);

                    -- Validate mode-specific constraints
                    v_displacement := haversine_km(
                        v_eff_start_lat, v_eff_start_lng,
                        v_eff_end_lat, v_eff_end_lng
                    );

                    IF v_transport_mode = 'walking' AND v_displacement < v_min_displacement_walking THEN
                        DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                        DELETE FROM trips WHERE id = v_trip_id;
                    ELSIF v_transport_mode = 'driving' AND v_trip_distance < v_min_distance_driving THEN
                        DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                        DELETE FROM trips WHERE id = v_trip_id;
                    ELSE
                        UPDATE trips SET transport_mode = v_transport_mode WHERE id = v_trip_id;

                        -- Location matching using effective coordinates
                        UPDATE trips SET
                            start_location_id = CASE
                                WHEN v_prev_trip_end_location_id IS NOT NULL
                                     AND haversine_km(v_eff_start_lat, v_eff_start_lng,
                                                      v_prev_trip_end_lat, v_prev_trip_end_lng) * 1000.0 < 100
                                THEN v_prev_trip_end_location_id
                                ELSE match_trip_to_location(v_eff_start_lat, v_eff_start_lng, v_eff_start_acc)
                            END,
                            end_location_id = match_trip_to_location(v_eff_end_lat, v_eff_end_lng, v_eff_end_acc)
                        WHERE id = v_trip_id;

                        -- Track for next trip's continuity
                        SELECT end_location_id INTO v_prev_trip_end_location_id FROM trips WHERE id = v_trip_id;
                        v_prev_trip_end_lat := v_eff_end_lat;
                        v_prev_trip_end_lng := v_eff_end_lng;

                        RETURN QUERY
                        SELECT
                            v_trip_id,
                            v_trip_start_point.captured_at,
                            v_trip_end_point.captured_at,
                            v_eff_start_lat::DECIMAL(10,8),
                            v_eff_start_lng::DECIMAL(11,8),
                            v_eff_end_lat::DECIMAL(10,8),
                            v_eff_end_lng::DECIMAL(11,8),
                            ROUND(v_trip_distance, 3),
                            GREATEST(1, EXTRACT(EPOCH FROM (v_trip_end_point.captured_at - v_trip_start_point.captured_at)) / 60)::INTEGER,
                            ROUND(GREATEST(0, 1.0 - (v_trip_low_accuracy::DECIMAL / GREATEST(v_trip_point_count, 1))), 2),
                            v_trip_point_count;
                    END IF;
                END IF;

                -- Reset trip state
                v_in_trip := FALSE;
                v_trip_distance := 0;
                v_trip_point_count := 0;
                v_trip_low_accuracy := 0;
                v_trip_points := '{}';
                v_stationary_since := NULL;
                v_stationary_center_lat := NULL;
                v_stationary_center_lng := NULL;
                v_has_last_stationary := FALSE;
            END IF;

            -- =================================================================
            -- Main movement/stationary detection using sensor speed stop detection
            -- =================================================================
            IF v_speed >= v_movement_speed AND NOT v_point_is_stopped THEN
                -- Fast movement: start or continue trip
                v_stationary_since := NULL;
                v_stationary_center_lat := NULL;
                v_stationary_center_lng := NULL;

                IF NOT v_in_trip THEN
                    -- Finalize pre-trip cluster (061)
                    IF v_create_clusters AND (v_has_active_cluster OR array_length(v_cluster_point_ids, 1) > 0) THEN
                        -- Compute centroid
                        IF array_length(v_cluster_lats, 1) > 0 THEN
                            SELECT
                                SUM(lat / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                                SUM(lng / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                                1.0 / SQRT(SUM(1.0 / GREATEST(acc * acc, 1)))
                            INTO v_centroid_lat, v_centroid_lng, v_centroid_acc
                            FROM unnest(v_cluster_lats, v_cluster_lngs, v_cluster_accs) AS t(lat, lng, acc);
                        END IF;

                        IF v_has_active_cluster THEN
                            -- Update existing cluster with final centroid
                            UPDATE stationary_clusters SET
                                centroid_latitude = v_centroid_lat,
                                centroid_longitude = v_centroid_lng,
                                centroid_accuracy = v_centroid_acc,
                                ended_at = v_prev_point.captured_at,
                                duration_seconds = EXTRACT(EPOCH FROM (v_prev_point.captured_at - v_cluster_started_at))::INTEGER,
                                gps_point_count = array_length(v_cluster_point_ids, 1),
                                matched_location_id = match_trip_to_location(v_centroid_lat, v_centroid_lng, COALESCE(v_centroid_acc, 0))
                            WHERE id = v_cluster_id;
                            -- Tag any untagged points
                            UPDATE gps_points SET stationary_cluster_id = v_cluster_id
                            WHERE id = ANY(v_cluster_point_ids) AND stationary_cluster_id IS NULL;
                            v_prev_cluster_id := v_cluster_id;
                        ELSIF v_cluster_started_at IS NOT NULL
                              AND EXTRACT(EPOCH FROM (v_prev_point.captured_at - v_cluster_started_at)) >= v_stationary_gap_minutes * 60 THEN
                            -- Create new cluster (meets 3-min threshold)
                            INSERT INTO stationary_clusters (
                                shift_id, employee_id,
                                centroid_latitude, centroid_longitude, centroid_accuracy,
                                started_at, ended_at, duration_seconds, gps_point_count,
                                matched_location_id
                            ) VALUES (
                                p_shift_id, v_employee_id,
                                v_centroid_lat, v_centroid_lng, v_centroid_acc,
                                v_cluster_started_at, v_prev_point.captured_at,
                                EXTRACT(EPOCH FROM (v_prev_point.captured_at - v_cluster_started_at))::INTEGER,
                                array_length(v_cluster_point_ids, 1),
                                match_trip_to_location(v_centroid_lat, v_centroid_lng, COALESCE(v_centroid_acc, 0))
                            )
                            RETURNING id INTO v_cluster_id;
                            UPDATE gps_points SET stationary_cluster_id = v_cluster_id
                            WHERE id = ANY(v_cluster_point_ids);
                            v_prev_cluster_id := v_cluster_id;
                        END IF;
                        -- Reset cluster state
                        v_cluster_lats := '{}';
                        v_cluster_lngs := '{}';
                        v_cluster_accs := '{}';
                        v_cluster_point_ids := '{}';
                        v_cluster_started_at := NULL;
                        v_cluster_id := NULL;
                        v_has_active_cluster := FALSE;
                        v_unclaimed_point_ids := '{}';  -- Reset unclaimed on trip start (064)
                    END IF;

                    -- Start new trip from the last stationary point (departure origin)
                    v_in_trip := TRUE;
                    IF v_has_last_stationary THEN
                        v_trip_start_point := v_last_stationary_point;
                    ELSE
                        v_trip_start_point := v_prev_point;
                    END IF;
                    v_trip_distance := 0;
                    v_trip_point_count := 1;
                    v_trip_low_accuracy := 0;
                    v_trip_points := ARRAY[v_trip_start_point.id];

                    IF v_trip_start_point.accuracy IS NOT NULL AND v_trip_start_point.accuracy > 50 THEN
                        v_trip_low_accuracy := v_trip_low_accuracy + 1;
                    END IF;

                    -- Add intermediate points between stationary and current
                    IF v_has_last_stationary THEN
                        IF v_prev_point.id != v_last_stationary_point.id THEN
                            v_trip_points := v_trip_points || v_prev_point.id;
                            v_trip_point_count := v_trip_point_count + 1;
                        END IF;
                    END IF;
                END IF;

                -- Add distance
                v_trip_distance := v_trip_distance + v_dist;
                v_trip_point_count := v_trip_point_count + 1;
                v_trip_points := v_trip_points || v_point.id;
                v_trip_end_point := v_point;

                IF v_point.accuracy IS NOT NULL AND v_point.accuracy > 50 THEN
                    v_trip_low_accuracy := v_trip_low_accuracy + 1;
                END IF;

            ELSIF v_in_trip AND v_point_is_stopped THEN
                -- =============================================================
                -- PATH 2: Stopped while in a trip
                -- =============================================================
                IF v_stationary_since IS NULL THEN
                    v_stationary_since := v_point.captured_at;
                    v_stationary_center_lat := v_point.latitude;
                    v_stationary_center_lng := v_point.longitude;
                    -- Use first stationary point as trip endpoint (where the car actually stopped)
                    v_trip_end_point := v_point;
                END IF;

                -- Include stationary point in trip (but do NOT add distance)
                v_trip_point_count := v_trip_point_count + 1;
                v_trip_points := v_trip_points || v_point.id;
                IF v_point.accuracy IS NOT NULL AND v_point.accuracy > 50 THEN
                    v_trip_low_accuracy := v_trip_low_accuracy + 1;
                END IF;

                -- Accumulate into cluster (061)
                IF v_create_clusters THEN
                    v_cluster_lats := v_cluster_lats || v_point.latitude;
                    v_cluster_lngs := v_cluster_lngs || v_point.longitude;
                    v_cluster_accs := v_cluster_accs || COALESCE(v_point.accuracy, 20.0);
                    v_cluster_point_ids := v_cluster_point_ids || v_point.id;
                    IF v_cluster_started_at IS NULL THEN
                        v_cluster_started_at := v_point.captured_at;
                    END IF;
                END IF;

                -- Check if stop duration exceeds cutoff -> end trip
                IF EXTRACT(EPOCH FROM (v_point.captured_at - v_stationary_since)) / 60.0 >= v_stationary_gap_minutes THEN
                    -- Create end cluster from accumulated stopped points (061)
                    IF v_create_clusters AND NOT v_has_active_cluster AND array_length(v_cluster_lats, 1) > 0 THEN
                        SELECT
                            SUM(lat / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                            SUM(lng / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                            1.0 / SQRT(SUM(1.0 / GREATEST(acc * acc, 1)))
                        INTO v_centroid_lat, v_centroid_lng, v_centroid_acc
                        FROM unnest(v_cluster_lats, v_cluster_lngs, v_cluster_accs) AS t(lat, lng, acc);

                        INSERT INTO stationary_clusters (
                            shift_id, employee_id,
                            centroid_latitude, centroid_longitude, centroid_accuracy,
                            started_at, ended_at, duration_seconds, gps_point_count,
                            matched_location_id
                        ) VALUES (
                            p_shift_id, v_employee_id,
                            v_centroid_lat, v_centroid_lng, v_centroid_acc,
                            v_cluster_started_at, v_point.captured_at,
                            EXTRACT(EPOCH FROM (v_point.captured_at - v_cluster_started_at))::INTEGER,
                            array_length(v_cluster_point_ids, 1),
                            match_trip_to_location(v_centroid_lat, v_centroid_lng, COALESCE(v_centroid_acc, 0))
                        )
                        RETURNING id INTO v_cluster_id;
                        v_has_active_cluster := TRUE;
                        UPDATE gps_points SET stationary_cluster_id = v_cluster_id
                        WHERE id = ANY(v_cluster_point_ids);
                    END IF;

                    -- Compute effective start coordinates (061)
                    v_eff_start_lat := v_trip_start_point.latitude;
                    v_eff_start_lng := v_trip_start_point.longitude;
                    v_eff_start_acc := COALESCE(v_trip_start_point.accuracy, 0);
                    IF v_create_clusters AND v_prev_cluster_id IS NOT NULL THEN
                        SELECT centroid_latitude, centroid_longitude, COALESCE(centroid_accuracy, 0)
                        INTO v_eff_start_lat, v_eff_start_lng, v_eff_start_acc
                        FROM stationary_clusters WHERE id = v_prev_cluster_id;
                    END IF;

                    -- Compute effective end coordinates (061)
                    v_eff_end_lat := v_trip_end_point.latitude;
                    v_eff_end_lng := v_trip_end_point.longitude;
                    v_eff_end_acc := COALESCE(v_trip_end_point.accuracy, 0);
                    IF v_create_clusters AND v_has_active_cluster THEN
                        v_eff_end_lat := v_centroid_lat;
                        v_eff_end_lng := v_centroid_lng;
                        v_eff_end_acc := COALESCE(v_centroid_acc, 0);
                    END IF;

                    -- End trip
                    v_trip_distance := v_trip_distance * v_correction_factor;
                    IF v_trip_distance >= v_min_distance_km AND v_trip_point_count >= 2 THEN
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
                            v_trip_start_point.captured_at, v_trip_end_point.captured_at,
                            v_eff_start_lat, v_eff_start_lng,
                            v_eff_end_lat, v_eff_end_lng,
                            ROUND(v_trip_distance, 3),
                            GREATEST(1, EXTRACT(EPOCH FROM (v_trip_end_point.captured_at - v_trip_start_point.captured_at)) / 60)::INTEGER,
                            'business',
                            ROUND(GREATEST(0, 1.0 - (v_trip_low_accuracy::DECIMAL / GREATEST(v_trip_point_count, 1))), 2),
                            v_trip_point_count,
                            v_trip_low_accuracy,
                            'auto',
                            'unknown',
                            v_prev_cluster_id,
                            CASE WHEN v_has_active_cluster THEN v_cluster_id ELSE NULL END
                        );

                        v_seq := 0;
                        FOR i IN 1..array_length(v_trip_points, 1) LOOP
                            v_seq := v_seq + 1;
                            INSERT INTO trip_gps_points (trip_id, gps_point_id, sequence_order)
                            VALUES (v_trip_id, v_trip_points[i], v_seq)
                            ON CONFLICT DO NOTHING;
                        END LOOP;

                        -- Classify transport mode
                        v_transport_mode := classify_trip_transport_mode(v_trip_id);
                        v_displacement := haversine_km(
                            v_eff_start_lat, v_eff_start_lng,
                            v_eff_end_lat, v_eff_end_lng
                        );

                        IF v_transport_mode = 'walking' AND v_displacement < v_min_displacement_walking THEN
                            DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                            DELETE FROM trips WHERE id = v_trip_id;
                        ELSIF v_transport_mode = 'driving' AND v_trip_distance < v_min_distance_driving THEN
                            DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                            DELETE FROM trips WHERE id = v_trip_id;
                        ELSE
                            UPDATE trips SET transport_mode = v_transport_mode WHERE id = v_trip_id;

                            -- Location matching using effective coordinates (061)
                            UPDATE trips SET
                                start_location_id = CASE
                                    WHEN v_prev_trip_end_location_id IS NOT NULL
                                         AND haversine_km(v_eff_start_lat, v_eff_start_lng,
                                                          v_prev_trip_end_lat, v_prev_trip_end_lng) * 1000.0 < 100
                                    THEN v_prev_trip_end_location_id
                                    ELSE match_trip_to_location(v_eff_start_lat, v_eff_start_lng, v_eff_start_acc)
                                END,
                                end_location_id = match_trip_to_location(v_eff_end_lat, v_eff_end_lng, v_eff_end_acc)
                            WHERE id = v_trip_id;

                            -- Track for next trip's continuity
                            SELECT end_location_id INTO v_prev_trip_end_location_id FROM trips WHERE id = v_trip_id;
                            v_prev_trip_end_lat := v_eff_end_lat;
                            v_prev_trip_end_lng := v_eff_end_lng;

                            RETURN QUERY
                            SELECT
                                v_trip_id,
                                v_trip_start_point.captured_at,
                                v_trip_end_point.captured_at,
                                v_eff_start_lat::DECIMAL(10,8),
                                v_eff_start_lng::DECIMAL(11,8),
                                v_eff_end_lat::DECIMAL(10,8),
                                v_eff_end_lng::DECIMAL(11,8),
                                ROUND(v_trip_distance, 3),
                                GREATEST(1, EXTRACT(EPOCH FROM (v_trip_end_point.captured_at - v_trip_start_point.captured_at)) / 60)::INTEGER,
                                ROUND(GREATEST(0, 1.0 - (v_trip_low_accuracy::DECIMAL / GREATEST(v_trip_point_count, 1))), 2),
                                v_trip_point_count;
                        END IF;
                    END IF;

                    -- Reset trip state (cluster variables NOT reset here)
                    v_in_trip := FALSE;
                    v_trip_distance := 0;
                    v_trip_point_count := 0;
                    v_trip_low_accuracy := 0;
                    v_trip_points := '{}';
                    v_stationary_since := NULL;
                    v_stationary_center_lat := NULL;
                    v_stationary_center_lng := NULL;
                    v_has_last_stationary := FALSE;
                END IF;

            ELSIF v_in_trip THEN
                -- Medium speed, not stopped: continue trip
                v_trip_distance := v_trip_distance + v_dist;
                v_trip_point_count := v_trip_point_count + 1;
                v_trip_points := v_trip_points || v_point.id;
                v_trip_end_point := v_point;
                v_stationary_since := NULL;
                v_stationary_center_lat := NULL;
                v_stationary_center_lng := NULL;
            END IF;

            -- Track unclaimed points: NOT stopped, NOT in trip, speed below movement (064)
            IF v_create_clusters AND NOT v_in_trip AND NOT v_point_is_stopped
               AND v_speed < v_movement_speed AND array_length(v_cluster_lats, 1) > 0 THEN
                v_unclaimed_point_ids := v_unclaimed_point_ids || v_point.id;
            END IF;
        END IF;

        v_prev_point := v_point;
    END LOOP;

    -- =================================================================
    -- PATH 3: End of data — close trip if shift is completed
    -- =================================================================
    IF v_in_trip AND v_trip_point_count >= 2 AND NOT v_is_active THEN
        -- If there's an active cluster being accumulated, finalize it (061)
        IF v_create_clusters AND NOT v_has_active_cluster AND array_length(v_cluster_lats, 1) > 0
           AND v_cluster_started_at IS NOT NULL
           AND EXTRACT(EPOCH FROM (v_prev_point.captured_at - v_cluster_started_at)) >= v_stationary_gap_minutes * 60 THEN
            SELECT
                SUM(lat / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                SUM(lng / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                1.0 / SQRT(SUM(1.0 / GREATEST(acc * acc, 1)))
            INTO v_centroid_lat, v_centroid_lng, v_centroid_acc
            FROM unnest(v_cluster_lats, v_cluster_lngs, v_cluster_accs) AS t(lat, lng, acc);

            INSERT INTO stationary_clusters (
                shift_id, employee_id,
                centroid_latitude, centroid_longitude, centroid_accuracy,
                started_at, ended_at, duration_seconds, gps_point_count,
                matched_location_id
            ) VALUES (
                p_shift_id, v_employee_id,
                v_centroid_lat, v_centroid_lng, v_centroid_acc,
                v_cluster_started_at, v_prev_point.captured_at,
                EXTRACT(EPOCH FROM (v_prev_point.captured_at - v_cluster_started_at))::INTEGER,
                array_length(v_cluster_point_ids, 1),
                match_trip_to_location(v_centroid_lat, v_centroid_lng, COALESCE(v_centroid_acc, 0))
            )
            RETURNING id INTO v_cluster_id;
            v_has_active_cluster := TRUE;
            UPDATE gps_points SET stationary_cluster_id = v_cluster_id
            WHERE id = ANY(v_cluster_point_ids);
        END IF;

        -- Compute effective start coordinates (061)
        v_eff_start_lat := v_trip_start_point.latitude;
        v_eff_start_lng := v_trip_start_point.longitude;
        v_eff_start_acc := COALESCE(v_trip_start_point.accuracy, 0);
        IF v_create_clusters AND v_prev_cluster_id IS NOT NULL THEN
            SELECT centroid_latitude, centroid_longitude, COALESCE(centroid_accuracy, 0)
            INTO v_eff_start_lat, v_eff_start_lng, v_eff_start_acc
            FROM stationary_clusters WHERE id = v_prev_cluster_id;
        END IF;

        -- Compute effective end coordinates (061)
        v_eff_end_lat := v_trip_end_point.latitude;
        v_eff_end_lng := v_trip_end_point.longitude;
        v_eff_end_acc := COALESCE(v_trip_end_point.accuracy, 0);
        IF v_create_clusters AND v_has_active_cluster THEN
            v_eff_end_lat := v_centroid_lat;
            v_eff_end_lng := v_centroid_lng;
            v_eff_end_acc := COALESCE(v_centroid_acc, 0);
        END IF;

        v_trip_distance := v_trip_distance * v_correction_factor;
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
                v_trip_start_point.captured_at, v_trip_end_point.captured_at,
                v_eff_start_lat, v_eff_start_lng,
                v_eff_end_lat, v_eff_end_lng,
                ROUND(v_trip_distance, 3),
                GREATEST(1, EXTRACT(EPOCH FROM (v_trip_end_point.captured_at - v_trip_start_point.captured_at)) / 60)::INTEGER,
                'business',
                ROUND(GREATEST(0, 1.0 - (v_trip_low_accuracy::DECIMAL / GREATEST(v_trip_point_count, 1))), 2),
                v_trip_point_count,
                v_trip_low_accuracy,
                'auto',
                'unknown',
                v_prev_cluster_id,
                CASE WHEN v_has_active_cluster THEN v_cluster_id ELSE NULL END
            );

            v_seq := 0;
            FOR i IN 1..array_length(v_trip_points, 1) LOOP
                v_seq := v_seq + 1;
                INSERT INTO trip_gps_points (trip_id, gps_point_id, sequence_order)
                VALUES (v_trip_id, v_trip_points[i], v_seq)
                ON CONFLICT DO NOTHING;
            END LOOP;

            -- Classify transport mode
            v_transport_mode := classify_trip_transport_mode(v_trip_id);
            v_displacement := haversine_km(
                v_eff_start_lat, v_eff_start_lng,
                v_eff_end_lat, v_eff_end_lng
            );

            IF v_transport_mode = 'walking' AND v_displacement < v_min_displacement_walking THEN
                DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                DELETE FROM trips WHERE id = v_trip_id;
            ELSIF v_transport_mode = 'driving' AND v_trip_distance < v_min_distance_driving THEN
                DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                DELETE FROM trips WHERE id = v_trip_id;
            ELSE
                UPDATE trips SET transport_mode = v_transport_mode WHERE id = v_trip_id;

                -- Location matching using effective coordinates (061)
                UPDATE trips SET
                    start_location_id = CASE
                        WHEN v_prev_trip_end_location_id IS NOT NULL
                             AND haversine_km(v_eff_start_lat, v_eff_start_lng,
                                              v_prev_trip_end_lat, v_prev_trip_end_lng) * 1000.0 < 100
                        THEN v_prev_trip_end_location_id
                        ELSE match_trip_to_location(v_eff_start_lat, v_eff_start_lng, v_eff_start_acc)
                    END,
                    end_location_id = match_trip_to_location(v_eff_end_lat, v_eff_end_lng, v_eff_end_acc)
                WHERE id = v_trip_id;

                -- Track for next trip's continuity
                SELECT end_location_id INTO v_prev_trip_end_location_id FROM trips WHERE id = v_trip_id;
                v_prev_trip_end_lat := v_eff_end_lat;
                v_prev_trip_end_lng := v_eff_end_lng;

                RETURN QUERY
                SELECT
                    v_trip_id,
                    v_trip_start_point.captured_at,
                    v_trip_end_point.captured_at,
                    v_eff_start_lat::DECIMAL(10,8),
                    v_eff_start_lng::DECIMAL(11,8),
                    v_eff_end_lat::DECIMAL(10,8),
                    v_eff_end_lng::DECIMAL(11,8),
                    ROUND(v_trip_distance, 3),
                    GREATEST(1, EXTRACT(EPOCH FROM (v_trip_end_point.captured_at - v_trip_start_point.captured_at)) / 60)::INTEGER,
                    ROUND(GREATEST(0, 1.0 - (v_trip_low_accuracy::DECIMAL / GREATEST(v_trip_point_count, 1))), 2),
                    v_trip_point_count;
            END IF;
        END IF;
    END IF;

    -- =================================================================
    -- Finalize any pending cluster at end of shift (061)
    -- =================================================================
    IF v_create_clusters AND (v_has_active_cluster OR array_length(v_cluster_point_ids, 1) > 0) THEN
        IF array_length(v_cluster_lats, 1) > 0 THEN
            SELECT
                SUM(lat / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                SUM(lng / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                1.0 / SQRT(SUM(1.0 / GREATEST(acc * acc, 1)))
            INTO v_centroid_lat, v_centroid_lng, v_centroid_acc
            FROM unnest(v_cluster_lats, v_cluster_lngs, v_cluster_accs) AS t(lat, lng, acc);
        END IF;

        IF v_has_active_cluster THEN
            UPDATE stationary_clusters SET
                centroid_latitude = v_centroid_lat,
                centroid_longitude = v_centroid_lng,
                centroid_accuracy = v_centroid_acc,
                ended_at = v_prev_point.captured_at,
                duration_seconds = EXTRACT(EPOCH FROM (v_prev_point.captured_at - v_cluster_started_at))::INTEGER,
                gps_point_count = array_length(v_cluster_point_ids, 1),
                matched_location_id = match_trip_to_location(v_centroid_lat, v_centroid_lng, COALESCE(v_centroid_acc, 0))
            WHERE id = v_cluster_id;
            UPDATE gps_points SET stationary_cluster_id = v_cluster_id
            WHERE id = ANY(v_cluster_point_ids) AND stationary_cluster_id IS NULL;
        ELSIF v_cluster_started_at IS NOT NULL
              AND v_prev_point IS NOT NULL
              AND EXTRACT(EPOCH FROM (v_prev_point.captured_at - v_cluster_started_at)) >= v_stationary_gap_minutes * 60 THEN
            INSERT INTO stationary_clusters (
                shift_id, employee_id,
                centroid_latitude, centroid_longitude, centroid_accuracy,
                started_at, ended_at, duration_seconds, gps_point_count,
                matched_location_id
            ) VALUES (
                p_shift_id, v_employee_id,
                v_centroid_lat, v_centroid_lng, v_centroid_acc,
                v_cluster_started_at, v_prev_point.captured_at,
                EXTRACT(EPOCH FROM (v_prev_point.captured_at - v_cluster_started_at))::INTEGER,
                array_length(v_cluster_point_ids, 1),
                match_trip_to_location(v_centroid_lat, v_centroid_lng, COALESCE(v_centroid_acc, 0))
            )
            RETURNING id INTO v_cluster_id;
            UPDATE gps_points SET stationary_cluster_id = v_cluster_id
            WHERE id = ANY(v_cluster_point_ids);
        END IF;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
