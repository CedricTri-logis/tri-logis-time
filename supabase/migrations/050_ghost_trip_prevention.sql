-- =============================================================================
-- Migration 050: Ghost Trip Prevention
-- =============================================================================
-- Adds server-side filters to reject phantom trips caused by GPS multipath/drift.
-- Three filters:
--   1. Driving displacement check (50m minimum net displacement)
--   2. Straightness ratio check (10% minimum for short trips ≤10 points)
--   3. Activity recognition point-level filter (suppress movement when device says STILL)
-- Also adds activity_type column to gps_points for activity recognition data.
-- =============================================================================

-- 1. Add activity_type column to gps_points
ALTER TABLE gps_points ADD COLUMN IF NOT EXISTS activity_type TEXT;

-- 2. Update sync_gps_points RPC to accept activity_type
CREATE OR REPLACE FUNCTION sync_gps_points(p_points JSONB)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID;
    v_point JSONB;
    v_inserted INTEGER := 0;
    v_duplicates INTEGER := 0;
    v_errors INTEGER := 0;
    v_failed_ids JSONB := '[]'::JSONB;
    v_client_id TEXT;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Not authenticated');
    END IF;

    FOR v_point IN SELECT * FROM jsonb_array_elements(p_points)
    LOOP
        v_client_id := v_point->>'client_id';
        BEGIN
            INSERT INTO gps_points (
                client_id, shift_id, employee_id,
                latitude, longitude, accuracy,
                captured_at, device_id,
                speed, speed_accuracy,
                heading, heading_accuracy,
                altitude, altitude_accuracy,
                is_mocked,
                activity_type
            )
            VALUES (
                (v_client_id)::UUID,
                (v_point->>'shift_id')::UUID,
                v_user_id,
                (v_point->>'latitude')::DECIMAL,
                (v_point->>'longitude')::DECIMAL,
                (v_point->>'accuracy')::DECIMAL,
                (v_point->>'captured_at')::TIMESTAMPTZ,
                v_point->>'device_id',
                (v_point->>'speed')::DECIMAL,
                (v_point->>'speed_accuracy')::DECIMAL,
                (v_point->>'heading')::DECIMAL,
                (v_point->>'heading_accuracy')::DECIMAL,
                (v_point->>'altitude')::DECIMAL,
                (v_point->>'altitude_accuracy')::DECIMAL,
                (v_point->>'is_mocked')::BOOLEAN,
                v_point->>'activity_type'
            );
            v_inserted := v_inserted + 1;
        EXCEPTION WHEN unique_violation THEN
            v_duplicates := v_duplicates + 1;
        WHEN OTHERS THEN
            v_errors := v_errors + 1;
            v_failed_ids := v_failed_ids || to_jsonb(v_client_id);
        END;
    END LOOP;

    RETURN jsonb_build_object(
        'status', 'success',
        'inserted', v_inserted,
        'duplicates', v_duplicates,
        'errors', v_errors,
        'failed_ids', v_failed_ids
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================================================================
-- 3. Updated detect_trips with ghost trip prevention filters
-- =============================================================================
-- New filters added to migration 048 version:
--   - FILTER 3: Activity recognition — suppress movement when device says STILL
--   - Driving displacement check: 50m net displacement minimum for driving trips
--   - Straightness ratio check: 10% minimum displacement/distance for ≤10 point trips
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
    v_movement_speed CONSTANT DECIMAL := 8.0;          -- km/h — raised from 3 to filter GPS drift
    v_stationary_speed CONSTANT DECIMAL := 3.0;         -- km/h — raised from 2
    v_max_speed CONSTANT DECIMAL := 200.0;
    v_max_accuracy CONSTANT DECIMAL := 200.0;
    v_stationary_gap_minutes CONSTANT INTEGER := 3;
    v_gps_gap_minutes CONSTANT INTEGER := 15;
    v_min_displacement_walking CONSTANT DECIMAL := 0.1;
    v_sensor_stationary CONSTANT DECIMAL := 0.5;        -- m/s — GPS sensor speed below this = stationary
    -- Ghost trip prevention constants (050)
    v_min_displacement_driving CONSTANT DECIMAL := 0.05;   -- 50m net displacement required for driving
    v_min_displacement_ratio   CONSTANT DECIMAL := 0.10;   -- 10% straightness index minimum
    v_max_low_ratio_points     CONSTANT INTEGER := 10;      -- ratio check only for ≤10 GPS points
    v_seq INTEGER;
    v_transport_mode TEXT;
    v_displacement DECIMAL;
    v_is_active BOOLEAN;
    v_cutoff_time TIMESTAMPTZ := NULL;
    v_noise_floor DECIMAL;
    v_last_stationary_point RECORD;  -- last truly stationary point (departure origin)
    v_has_last_stationary BOOLEAN := FALSE;
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

    -- Process GPS points (after cutoff if incremental)
    v_prev_point := NULL;

    FOR v_point IN
        SELECT
            gp.id,
            gp.latitude,
            gp.longitude,
            gp.accuracy,
            gp.speed,
            gp.captured_at,
            gp.activity_type
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
            -- If displacement < max(accuracy of both points), it's GPS drift not real movement
            v_noise_floor := GREATEST(
                COALESCE(v_prev_point.accuracy, 10),
                COALESCE(v_point.accuracy, 10)
            );
            IF v_dist_meters < v_noise_floor THEN
                v_speed := 0;
            END IF;

            -- FILTER 2: GPS sensor speed cross-check
            -- If both points report near-zero sensor speed, person is stationary
            IF v_prev_point.speed IS NOT NULL AND v_point.speed IS NOT NULL
               AND v_prev_point.speed < v_sensor_stationary AND v_point.speed < v_sensor_stationary THEN
                v_speed := 0;
            END IF;

            -- FILTER 3: Activity recognition — if device says STILL, suppress movement
            -- Fail-open: NULL activity_type (older app versions) is not suppressed
            IF v_point.activity_type = 'still' THEN
                v_speed := 0;
            END IF;

            -- Track last truly stationary point (departure origin for next trip)
            -- Only update if still near the original stationary position (<30m)
            -- to avoid drifting the departure point as the person starts slow movement
            IF v_speed = 0 AND NOT v_in_trip THEN
                IF NOT v_has_last_stationary THEN
                    v_last_stationary_point := v_prev_point;
                    v_has_last_stationary := TRUE;
                ELSIF haversine_km(v_last_stationary_point.latitude, v_last_stationary_point.longitude,
                                   v_prev_point.latitude, v_prev_point.longitude) * 1000.0 < 30 THEN
                    v_last_stationary_point := v_prev_point;
                END IF;
            END IF;

            -- Skip impossible speeds (GPS glitch)
            IF v_speed > v_max_speed THEN
                v_prev_point := v_point;
                CONTINUE;
            END IF;

            -- Check for GPS gap (>15 min between points)
            IF EXTRACT(EPOCH FROM (v_point.captured_at - v_prev_point.captured_at)) / 60.0 > v_gps_gap_minutes AND v_in_trip THEN
                -- End current trip due to GPS gap
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
                        detection_method, transport_mode
                    ) VALUES (
                        v_trip_id, p_shift_id, v_employee_id,
                        v_trip_start_point.captured_at, v_trip_end_point.captured_at,
                        v_trip_start_point.latitude, v_trip_start_point.longitude,
                        v_trip_end_point.latitude, v_trip_end_point.longitude,
                        ROUND(v_trip_distance, 3),
                        GREATEST(1, EXTRACT(EPOCH FROM (v_trip_end_point.captured_at - v_trip_start_point.captured_at)) / 60)::INTEGER,
                        'business',
                        ROUND(GREATEST(0, 1.0 - (v_trip_low_accuracy::DECIMAL / GREATEST(v_trip_point_count, 1))), 2),
                        v_trip_point_count,
                        v_trip_low_accuracy,
                        'auto',
                        'unknown'
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
                        v_trip_start_point.latitude, v_trip_start_point.longitude,
                        v_trip_end_point.latitude, v_trip_end_point.longitude
                    );

                    IF v_transport_mode = 'walking' AND v_displacement < v_min_displacement_walking THEN
                        -- Walking trip with < 100m displacement = GPS noise
                        DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                        DELETE FROM trips WHERE id = v_trip_id;
                    ELSIF v_transport_mode = 'driving' AND v_trip_distance < v_min_distance_driving THEN
                        -- Driving trip too short
                        DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                        DELETE FROM trips WHERE id = v_trip_id;
                    -- Ghost trip prevention: driving displacement check (050)
                    ELSIF v_transport_mode = 'driving' AND v_displacement < v_min_displacement_driving THEN
                        -- Driving trip with < 50m net displacement = GPS multipath ghost
                        DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                        DELETE FROM trips WHERE id = v_trip_id;
                    -- Ghost trip prevention: straightness ratio check (050)
                    ELSIF v_trip_point_count <= v_max_low_ratio_points
                        AND (v_displacement / GREATEST(v_trip_distance, 0.001)) < v_min_displacement_ratio THEN
                        -- Short trip with very low displacement/distance ratio = circular GPS drift
                        DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                        DELETE FROM trips WHERE id = v_trip_id;
                    ELSE
                        UPDATE trips SET transport_mode = v_transport_mode WHERE id = v_trip_id;

                        RETURN QUERY
                        SELECT
                            v_trip_id,
                            v_trip_start_point.captured_at,
                            v_trip_end_point.captured_at,
                            v_trip_start_point.latitude,
                            v_trip_start_point.longitude,
                            v_trip_end_point.latitude,
                            v_trip_end_point.longitude,
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
                v_has_last_stationary := FALSE;
            END IF;

            IF v_speed >= v_movement_speed THEN
                -- Movement detected (walking or driving)
                v_stationary_since := NULL;

                IF NOT v_in_trip THEN
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
                    IF v_has_last_stationary AND v_prev_point.id != v_last_stationary_point.id THEN
                        v_trip_points := v_trip_points || v_prev_point.id;
                        v_trip_point_count := v_trip_point_count + 1;
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

            ELSIF v_speed >= v_stationary_speed AND v_in_trip THEN
                -- Slow movement while in a trip — include (transitional)
                v_trip_distance := v_trip_distance + v_dist;
                v_trip_point_count := v_trip_point_count + 1;
                v_trip_points := v_trip_points || v_point.id;
                v_trip_end_point := v_point;
                v_stationary_since := NULL;

            ELSIF v_speed < v_stationary_speed AND v_in_trip THEN
                -- Stationary while in trip
                IF v_stationary_since IS NULL THEN
                    v_stationary_since := v_point.captured_at;
                END IF;

                -- Check if stationary for long enough to end trip
                IF EXTRACT(EPOCH FROM (v_point.captured_at - v_stationary_since)) / 60.0 >= v_stationary_gap_minutes THEN
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
                            detection_method, transport_mode
                        ) VALUES (
                            v_trip_id, p_shift_id, v_employee_id,
                            v_trip_start_point.captured_at, v_trip_end_point.captured_at,
                            v_trip_start_point.latitude, v_trip_start_point.longitude,
                            v_trip_end_point.latitude, v_trip_end_point.longitude,
                            ROUND(v_trip_distance, 3),
                            GREATEST(1, EXTRACT(EPOCH FROM (v_trip_end_point.captured_at - v_trip_start_point.captured_at)) / 60)::INTEGER,
                            'business',
                            ROUND(GREATEST(0, 1.0 - (v_trip_low_accuracy::DECIMAL / GREATEST(v_trip_point_count, 1))), 2),
                            v_trip_point_count,
                            v_trip_low_accuracy,
                            'auto',
                            'unknown'
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
                            v_trip_start_point.latitude, v_trip_start_point.longitude,
                            v_trip_end_point.latitude, v_trip_end_point.longitude
                        );

                        IF v_transport_mode = 'walking' AND v_displacement < v_min_displacement_walking THEN
                            DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                            DELETE FROM trips WHERE id = v_trip_id;
                        ELSIF v_transport_mode = 'driving' AND v_trip_distance < v_min_distance_driving THEN
                            DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                            DELETE FROM trips WHERE id = v_trip_id;
                        -- Ghost trip prevention: driving displacement check (050)
                        ELSIF v_transport_mode = 'driving' AND v_displacement < v_min_displacement_driving THEN
                            DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                            DELETE FROM trips WHERE id = v_trip_id;
                        -- Ghost trip prevention: straightness ratio check (050)
                        ELSIF v_trip_point_count <= v_max_low_ratio_points
                            AND (v_displacement / GREATEST(v_trip_distance, 0.001)) < v_min_displacement_ratio THEN
                            DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                            DELETE FROM trips WHERE id = v_trip_id;
                        ELSE
                            UPDATE trips SET transport_mode = v_transport_mode WHERE id = v_trip_id;

                            RETURN QUERY
                            SELECT
                                v_trip_id,
                                v_trip_start_point.captured_at,
                                v_trip_end_point.captured_at,
                                v_trip_start_point.latitude,
                                v_trip_start_point.longitude,
                                v_trip_end_point.latitude,
                                v_trip_end_point.longitude,
                                ROUND(v_trip_distance, 3),
                                GREATEST(1, EXTRACT(EPOCH FROM (v_trip_end_point.captured_at - v_trip_start_point.captured_at)) / 60)::INTEGER,
                                ROUND(GREATEST(0, 1.0 - (v_trip_low_accuracy::DECIMAL / GREATEST(v_trip_point_count, 1))), 2),
                                v_trip_point_count;
                        END IF;
                    END IF;

                    -- Reset
                    v_in_trip := FALSE;
                    v_trip_distance := 0;
                    v_trip_point_count := 0;
                    v_trip_low_accuracy := 0;
                    v_trip_points := '{}';
                    v_stationary_since := NULL;
                    v_has_last_stationary := FALSE;
                END IF;
            END IF;
        END IF;

        v_prev_point := v_point;
    END LOOP;

    -- If still in a trip at end of data:
    -- Completed shift → close the trip (shift is done, trip must be done too)
    -- Active shift → don't close (person might still be moving)
    IF v_in_trip AND v_trip_point_count >= 2 AND NOT v_is_active THEN
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
                detection_method, transport_mode
            ) VALUES (
                v_trip_id, p_shift_id, v_employee_id,
                v_trip_start_point.captured_at, v_trip_end_point.captured_at,
                v_trip_start_point.latitude, v_trip_start_point.longitude,
                v_trip_end_point.latitude, v_trip_end_point.longitude,
                ROUND(v_trip_distance, 3),
                GREATEST(1, EXTRACT(EPOCH FROM (v_trip_end_point.captured_at - v_trip_start_point.captured_at)) / 60)::INTEGER,
                'business',
                ROUND(GREATEST(0, 1.0 - (v_trip_low_accuracy::DECIMAL / GREATEST(v_trip_point_count, 1))), 2),
                v_trip_point_count,
                v_trip_low_accuracy,
                'auto',
                'unknown'
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
                v_trip_start_point.latitude, v_trip_start_point.longitude,
                v_trip_end_point.latitude, v_trip_end_point.longitude
            );

            IF v_transport_mode = 'walking' AND v_displacement < v_min_displacement_walking THEN
                DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                DELETE FROM trips WHERE id = v_trip_id;
            ELSIF v_transport_mode = 'driving' AND v_trip_distance < v_min_distance_driving THEN
                DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                DELETE FROM trips WHERE id = v_trip_id;
            -- Ghost trip prevention: driving displacement check (050)
            ELSIF v_transport_mode = 'driving' AND v_displacement < v_min_displacement_driving THEN
                DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                DELETE FROM trips WHERE id = v_trip_id;
            -- Ghost trip prevention: straightness ratio check (050)
            ELSIF v_trip_point_count <= v_max_low_ratio_points
                AND (v_displacement / GREATEST(v_trip_distance, 0.001)) < v_min_displacement_ratio THEN
                DELETE FROM trip_gps_points WHERE trip_id = v_trip_id;
                DELETE FROM trips WHERE id = v_trip_id;
            ELSE
                UPDATE trips SET transport_mode = v_transport_mode WHERE id = v_trip_id;

                RETURN QUERY
                SELECT
                    v_trip_id,
                    v_trip_start_point.captured_at,
                    v_trip_end_point.captured_at,
                    v_trip_start_point.latitude,
                    v_trip_start_point.longitude,
                    v_trip_end_point.latitude,
                    v_trip_end_point.longitude,
                    ROUND(v_trip_distance, 3),
                    GREATEST(1, EXTRACT(EPOCH FROM (v_trip_end_point.captured_at - v_trip_start_point.captured_at)) / 60)::INTEGER,
                    ROUND(GREATEST(0, 1.0 - (v_trip_low_accuracy::DECIMAL / GREATEST(v_trip_point_count, 1))), 2),
                    v_trip_point_count;
            END IF;
        END IF;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================================================================
-- 4. Delete ghost trip 85311b67 and its trip_gps_points
-- =============================================================================
DELETE FROM trip_gps_points WHERE trip_id = '85311b67-a3e1-4085-a54b-ab6f5b27e77a';
DELETE FROM trips WHERE id = '85311b67-a3e1-4085-a54b-ab6f5b27e77a';
