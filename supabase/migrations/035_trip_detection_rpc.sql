-- =============================================================================
-- 035: Mileage Tracking - Trip Detection & Mileage Summary RPCs
-- Feature: 017-mileage-tracking
-- =============================================================================

-- =============================================================================
-- Haversine distance helper (returns km)
-- =============================================================================
CREATE OR REPLACE FUNCTION haversine_km(
    lat1 DECIMAL, lon1 DECIMAL,
    lat2 DECIMAL, lon2 DECIMAL
) RETURNS DECIMAL AS $$
DECLARE
    r CONSTANT DECIMAL := 6371.0; -- Earth radius in km
    dlat DECIMAL;
    dlon DECIMAL;
    a DECIMAL;
    c DECIMAL;
BEGIN
    dlat := radians(lat2 - lat1);
    dlon := radians(lon2 - lon1);
    a := sin(dlat / 2) * sin(dlat / 2) +
         cos(radians(lat1)) * cos(radians(lat2)) *
         sin(dlon / 2) * sin(dlon / 2);
    c := 2 * atan2(sqrt(a), sqrt(1 - a));
    RETURN r * c;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- =============================================================================
-- detect_trips: Analyze GPS points for a shift and detect vehicle trips
-- Idempotent: deletes existing trips for the shift before re-detecting
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
DECLARE
    v_shift RECORD;
    v_employee_id UUID;
    v_point RECORD;
    v_prev_point RECORD;
    v_speed DECIMAL;
    v_dist DECIMAL;
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
    v_min_distance_km CONSTANT DECIMAL := 0.5;
    v_vehicle_speed CONSTANT DECIMAL := 15.0; -- km/h
    v_stationary_speed CONSTANT DECIMAL := 5.0; -- km/h
    v_max_speed CONSTANT DECIMAL := 200.0; -- km/h
    v_max_accuracy CONSTANT DECIMAL := 200.0; -- meters
    v_stationary_gap_minutes CONSTANT INTEGER := 3;
    v_gps_gap_minutes CONSTANT INTEGER := 15;
    v_seq INTEGER;
BEGIN
    -- Validate shift exists and is completed
    SELECT s.id, s.employee_id, s.status
    INTO v_shift
    FROM shifts s
    WHERE s.id = p_shift_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Shift not found: %', p_shift_id;
    END IF;

    IF v_shift.status = 'active' THEN
        RAISE EXCEPTION 'Shift is still active. Clock out before detecting trips.';
    END IF;

    v_employee_id := v_shift.employee_id;

    -- Delete existing trips for this shift (idempotent re-detection)
    DELETE FROM trips WHERE shift_id = p_shift_id;

    -- Process GPS points
    v_prev_point := NULL;

    FOR v_point IN
        SELECT
            gp.id,
            gp.latitude,
            gp.longitude,
            gp.accuracy,
            gp.captured_at
        FROM gps_points gp
        WHERE gp.shift_id = p_shift_id
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
                        detection_method
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
                        'auto'
                    );

                    -- Insert junction records
                    v_seq := 0;
                    FOR i IN 1..array_length(v_trip_points, 1) LOOP
                        v_seq := v_seq + 1;
                        INSERT INTO trip_gps_points (trip_id, gps_point_id, sequence_order)
                        VALUES (v_trip_id, v_trip_points[i], v_seq)
                        ON CONFLICT DO NOTHING;
                    END LOOP;

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

                -- Reset trip state
                v_in_trip := FALSE;
                v_trip_distance := 0;
                v_trip_point_count := 0;
                v_trip_low_accuracy := 0;
                v_trip_points := '{}';
                v_stationary_since := NULL;
            END IF;

            IF v_speed >= v_vehicle_speed THEN
                -- Vehicle speed detected
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
                -- Walking speed while in a trip — include in trip (transitional)
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
                            detection_method
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
                            'auto'
                        );

                        v_seq := 0;
                        FOR i IN 1..array_length(v_trip_points, 1) LOOP
                            v_seq := v_seq + 1;
                            INSERT INTO trip_gps_points (trip_id, gps_point_id, sequence_order)
                            VALUES (v_trip_id, v_trip_points[i], v_seq)
                            ON CONFLICT DO NOTHING;
                        END LOOP;

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

    -- If still in a trip at end of shift, close it
    IF v_in_trip AND v_trip_point_count >= 2 THEN
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
                detection_method
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
                'auto'
            );

            v_seq := 0;
            FOR i IN 1..array_length(v_trip_points, 1) LOOP
                v_seq := v_seq + 1;
                INSERT INTO trip_gps_points (trip_id, gps_point_id, sequence_order)
                VALUES (v_trip_id, v_trip_points[i], v_seq)
                ON CONFLICT DO NOTHING;
            END LOOP;

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
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================================================================
-- get_mileage_summary: Aggregated mileage stats with CRA tiered reimbursement
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
    SELECT
        COALESCE(SUM(t.distance_km), 0),
        COALESCE(SUM(CASE WHEN t.classification = 'business' THEN t.distance_km ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN t.classification = 'personal' THEN t.distance_km ELSE 0 END), 0),
        COUNT(*)::INTEGER,
        COUNT(*) FILTER (WHERE t.classification = 'business')::INTEGER,
        COUNT(*) FILTER (WHERE t.classification = 'personal')::INTEGER
    INTO v_total_km, v_business_km, v_personal_km, v_trip_count, v_biz_trip_count, v_personal_trip_count
    FROM trips t
    WHERE t.employee_id = p_employee_id
      AND t.started_at >= p_period_start::TIMESTAMPTZ
      AND t.started_at < (p_period_end + INTERVAL '1 day')::TIMESTAMPTZ;

    -- Calculate YTD business km (Jan 1 of period_end year to period_end)
    SELECT COALESCE(SUM(t.distance_km), 0)
    INTO v_ytd_km
    FROM trips t
    WHERE t.employee_id = p_employee_id
      AND t.classification = 'business'
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
        -- Fallback: use most recent rate
        SELECT r.*
        INTO v_rate
        FROM reimbursement_rates r
        ORDER BY r.effective_from DESC
        LIMIT 1;
    END IF;

    -- Calculate tiered reimbursement
    IF v_rate IS NOT NULL THEN
        IF v_rate.threshold_km IS NOT NULL AND v_rate.rate_after_threshold IS NOT NULL THEN
            -- YTD km before this period (for tier calculation)
            v_km_at_base := GREATEST(0, LEAST(v_business_km, v_rate.threshold_km - (v_ytd_km - v_business_km)));
            v_km_at_reduced := GREATEST(0, v_business_km - v_km_at_base);
            v_reimbursement := ROUND(
                (v_km_at_base * v_rate.rate_per_km) + (v_km_at_reduced * v_rate.rate_after_threshold),
                2
            );
        ELSE
            -- Flat rate
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
