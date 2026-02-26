-- =============================================================================
-- Migration 048: Transport Mode Detection (driving vs walking)
-- =============================================================================
-- Adds transport_mode column to trips table and modifies trip detection
-- to also capture walking trips. Only driving trips are reimbursable.
-- =============================================================================

-- 1. Add transport_mode column
ALTER TABLE trips
  ADD COLUMN IF NOT EXISTS transport_mode TEXT NOT NULL DEFAULT 'driving'
  CHECK (transport_mode IN ('driving', 'walking', 'unknown'));

CREATE INDEX IF NOT EXISTS idx_trips_transport_mode ON trips(transport_mode);

-- 2. Backfill: all existing trips were detected at vehicle speed → 'driving'
UPDATE trips SET transport_mode = 'driving' WHERE transport_mode = 'unknown';

-- =============================================================================
-- 3. classify_trip_transport_mode: Classify using calculated speeds (haversine)
-- =============================================================================
-- Logic:
--   1. Trip average speed (distance/duration) as primary indicator
--      > 10 km/h → driving (impossible on foot for a full trip)
--      < 4 km/h  → walking
--   2. Grey zone (4–10 km/h): calculate inter-point speeds via haversine
--      If >80% of segments < 5 km/h AND distance < 1 km → walking
--      Otherwise → driving (city driving with stops)
-- =============================================================================
CREATE OR REPLACE FUNCTION classify_trip_transport_mode(p_trip_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_distance_km DECIMAL;
    v_duration_min INTEGER;
    v_avg_speed_kmh DECIMAL;
    v_total_segments INTEGER;
    v_slow_segments INTEGER;
    v_slow_ratio DECIMAL;
BEGIN
    -- Get trip-level average speed (most robust indicator)
    SELECT distance_km, duration_minutes
    INTO v_distance_km, v_duration_min
    FROM trips
    WHERE id = p_trip_id;

    IF v_distance_km IS NULL OR v_duration_min IS NULL OR v_duration_min <= 0 THEN
        RETURN 'unknown';
    END IF;

    v_avg_speed_kmh := v_distance_km / (v_duration_min / 60.0);

    -- Clear-cut cases based on trip average speed
    IF v_avg_speed_kmh > 10.0 THEN
        RETURN 'driving';
    END IF;

    IF v_avg_speed_kmh < 4.0 THEN
        RETURN 'walking';
    END IF;

    -- Grey zone (4–10 km/h): use inter-point calculated speeds
    -- Calculate speed between consecutive GPS points via haversine
    SELECT
        COUNT(*),
        COUNT(*) FILTER (WHERE segment_speed_kmh < 5.0)
    INTO v_total_segments, v_slow_segments
    FROM (
        SELECT
            haversine_km(prev_lat, prev_lon, cur_lat, cur_lon)
            / NULLIF(EXTRACT(EPOCH FROM (cur_time - prev_time)) / 3600.0, 0) AS segment_speed_kmh
        FROM (
            SELECT
                gp.latitude AS cur_lat,
                gp.longitude AS cur_lon,
                gp.captured_at AS cur_time,
                LAG(gp.latitude) OVER (ORDER BY tgp.sequence_order) AS prev_lat,
                LAG(gp.longitude) OVER (ORDER BY tgp.sequence_order) AS prev_lon,
                LAG(gp.captured_at) OVER (ORDER BY tgp.sequence_order) AS prev_time
            FROM trip_gps_points tgp
            JOIN gps_points gp ON gp.id = tgp.gps_point_id
            WHERE tgp.trip_id = p_trip_id
        ) pts
        WHERE prev_lat IS NOT NULL
          AND EXTRACT(EPOCH FROM (cur_time - prev_time)) > 0
    ) segments
    WHERE segment_speed_kmh IS NOT NULL
      AND segment_speed_kmh < 200; -- filter GPS glitches

    IF v_total_segments IS NULL OR v_total_segments < 2 THEN
        -- Not enough data, use avg speed as tiebreaker
        RETURN CASE WHEN v_avg_speed_kmh >= 6.0 THEN 'driving' ELSE 'walking' END;
    END IF;

    v_slow_ratio := v_slow_segments::DECIMAL / v_total_segments;

    -- If >80% of segments are slow AND short distance → walking
    IF v_slow_ratio > 0.8 AND v_distance_km < 1.0 THEN
        RETURN 'walking';
    END IF;

    -- Otherwise it's driving (city driving with stops)
    RETURN 'driving';
END;
$$;

-- =============================================================================
-- 4. Replace detect_trips with GPS accuracy filtering + active shift support
-- =============================================================================
-- Changes from original (migration 035):
-- - GPS accuracy noise floor: displacement < max(accuracy) → speed = 0
-- - GPS sensor speed cross-check: both < 0.5 m/s → speed = 0
-- - Movement threshold raised to 8 km/h (filters GPS drift)
-- - Stationary threshold raised to 3 km/h
-- - Active shifts: incremental detection (preserves matched trips)
-- - Transport mode classification after each trip
-- - Walking trips with < 100m displacement are deleted (GPS noise)
-- - See docs/trip-detection-algorithm.md for full documentation
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
    v_seq INTEGER;
    v_transport_mode TEXT;
    v_displacement DECIMAL;
    v_is_active BOOLEAN;
    v_cutoff_time TIMESTAMPTZ := NULL;
    v_noise_floor DECIMAL;
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
            END IF;

            IF v_speed >= v_movement_speed THEN
                -- Movement detected (walking or driving)
                v_stationary_since := NULL;

                IF NOT v_in_trip THEN
                    -- Start new trip
                    v_in_trip := TRUE;
                    v_trip_start_point := v_prev_point;
                    v_trip_distance := 0;
                    v_trip_point_count := 1;
                    v_trip_low_accuracy := 0;
                    v_trip_points := ARRAY[v_prev_point.id];

                    IF v_prev_point.accuracy IS NOT NULL AND v_prev_point.accuracy > 50 THEN
                        v_trip_low_accuracy := v_trip_low_accuracy + 1;
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
-- 5. Update get_mileage_summary: only driving trips are reimbursable
-- =============================================================================
CREATE OR REPLACE FUNCTION get_mileage_summary(
    p_employee_id UUID,
    p_period_start DATE,
    p_period_end DATE
)
RETURNS TABLE (
    total_distance_km DECIMAL(10, 3),
    business_distance_km DECIMAL(10, 3),
    personal_distance_km DECIMAL(10, 3),
    trip_count INTEGER,
    business_trip_count INTEGER,
    personal_trip_count INTEGER,
    estimated_reimbursement DECIMAL(10, 2),
    rate_per_km_used DECIMAL(5, 4),
    rate_source TEXT,
    ytd_business_km DECIMAL(10, 3)
) AS $$
DECLARE
    v_total_km DECIMAL := 0;
    v_business_km DECIMAL := 0;
    v_personal_km DECIMAL := 0;
    v_trip_count INTEGER := 0;
    v_biz_trip_count INTEGER := 0;
    v_personal_trip_count INTEGER := 0;
    v_ytd_km DECIMAL := 0;
    v_rate RECORD;
    v_reimbursement DECIMAL := 0;
    v_km_at_base DECIMAL;
    v_km_at_reduced DECIMAL;
BEGIN
    -- Aggregate trips for the period
    -- business_distance_km = only driving + business trips (reimbursable)
    SELECT
        COALESCE(SUM(t.distance_km), 0),
        COALESCE(SUM(CASE WHEN t.classification = 'business' AND t.transport_mode = 'driving' THEN t.distance_km ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN t.classification = 'personal' THEN t.distance_km ELSE 0 END), 0),
        COUNT(*)::INTEGER,
        COUNT(*) FILTER (WHERE t.classification = 'business' AND t.transport_mode = 'driving')::INTEGER,
        COUNT(*) FILTER (WHERE t.classification = 'personal')::INTEGER
    INTO v_total_km, v_business_km, v_personal_km, v_trip_count, v_biz_trip_count, v_personal_trip_count
    FROM trips t
    WHERE t.employee_id = p_employee_id
      AND t.started_at >= p_period_start::TIMESTAMPTZ
      AND t.started_at < (p_period_end + INTERVAL '1 day')::TIMESTAMPTZ;

    -- Calculate YTD business km (only driving trips)
    SELECT COALESCE(SUM(t.distance_km), 0)
    INTO v_ytd_km
    FROM trips t
    WHERE t.employee_id = p_employee_id
      AND t.classification = 'business'
      AND t.transport_mode = 'driving'
      AND t.started_at >= date_trunc('year', p_period_end::TIMESTAMPTZ)
      AND t.started_at < (p_period_end + INTERVAL '1 day')::TIMESTAMPTZ;

    -- Look up current rate
    SELECT r.*
    INTO v_rate
    FROM reimbursement_rates r
    WHERE r.effective_from <= p_period_end
      AND (r.effective_to IS NULL OR r.effective_to >= p_period_end)
    ORDER BY r.effective_from DESC
    LIMIT 1;

    IF v_rate IS NULL THEN
        SELECT r.*
        INTO v_rate
        FROM reimbursement_rates r
        ORDER BY r.effective_from DESC
        LIMIT 1;
    END IF;

    -- Calculate tiered reimbursement (driving business km only)
    IF v_rate IS NOT NULL THEN
        IF v_rate.threshold_km IS NOT NULL AND v_rate.rate_after_threshold IS NOT NULL THEN
            v_km_at_base := GREATEST(0, LEAST(v_business_km, v_rate.threshold_km - (v_ytd_km - v_business_km)));
            v_km_at_reduced := GREATEST(0, v_business_km - v_km_at_base);
            v_reimbursement := ROUND(
                (v_km_at_base * v_rate.rate_per_km) + (v_km_at_reduced * v_rate.rate_after_threshold),
                2
            );
        ELSE
            v_reimbursement := ROUND(v_business_km * v_rate.rate_per_km, 2);
        END IF;
    END IF;

    RETURN QUERY SELECT
        v_total_km,
        v_business_km,
        v_personal_km,
        v_trip_count,
        v_biz_trip_count,
        v_personal_trip_count,
        v_reimbursement,
        COALESCE(v_rate.rate_per_km, 0::DECIMAL(5,4)),
        COALESCE(v_rate.rate_source, 'none'::TEXT),
        v_ytd_km;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
