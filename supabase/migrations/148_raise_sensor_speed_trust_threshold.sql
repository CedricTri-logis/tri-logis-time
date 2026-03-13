-- Migration 148: Raise sensor speed trust threshold to 1.0 m/s
-- Some devices (Mario Leclerc) report tiny speeds (0.1-0.5 m/s) even when driving fast.
-- The 0.3 m/s threshold from migration 147 was still too low (Mario had max 0.39 m/s).
-- Real walking always shows max > 1.0 m/s (typical walking = 1.1-1.4 m/s).
-- Raising threshold to 1.0 m/s correctly separates broken sensors from real walkers.
--
-- Results after fix:
-- - Mario: 11/12 trips correctly "driving" (1 genuinely short 0.077 km stays "walking")
-- - Ginette: All 5 trips still correctly "walking"
-- - Overall: 621 driving, 215 walking, 1 unknown

CREATE OR REPLACE FUNCTION classify_trip_transport_mode(p_trip_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_max_speed_ms DECIMAL;
    v_point_count INTEGER;
    v_moving_count INTEGER;
    v_slow_moving_count INTEGER;
    v_slow_ratio DECIMAL;
    v_distance_km DECIMAL;
    v_duration_min INTEGER;
    v_avg_speed_kmh DECIMAL;
BEGIN
    -- Get trip distance/duration (needed for both paths)
    SELECT distance_km, duration_minutes
    INTO v_distance_km, v_duration_min
    FROM trips
    WHERE id = p_trip_id;

    -- Count points with sensor speed data
    SELECT
        COUNT(*) FILTER (WHERE gp.speed IS NOT NULL),
        MAX(gp.speed),
        COUNT(*) FILTER (WHERE gp.speed IS NOT NULL AND gp.speed > 0.3),
        COUNT(*) FILTER (WHERE gp.speed IS NOT NULL AND gp.speed > 0.3 AND gp.speed < 1.7)
    INTO v_point_count, v_max_speed_ms, v_moving_count, v_slow_moving_count
    FROM trip_gps_points tgp
    JOIN gps_points gp ON gp.id = tgp.gps_point_id
    WHERE tgp.trip_id = p_trip_id;

    -- === PRIMARY: Sensor speed classification ===
    -- Only trust sensor speed if max > 1.0 m/s (3.6 km/h).
    -- Some devices report tiny speeds (0.1-0.5 m/s) even when driving fast.
    -- Real walking always shows max > 1.0 m/s (typical walking = 1.1-1.4 m/s).
    IF v_point_count >= 2 AND v_max_speed_ms IS NOT NULL AND v_max_speed_ms > 1.0 THEN

        -- Clear driving: at least one point above 15 km/h (4.2 m/s)
        IF v_max_speed_ms > 4.2 THEN
            RETURN 'driving';
        END IF;

        -- Clear walking: never above 6 km/h (1.7 m/s)
        IF v_max_speed_ms < 1.7 THEN
            RETURN 'walking';
        END IF;

        -- Gray zone (6-15 km/h): check ratio of slow-moving points
        IF v_moving_count > 0 THEN
            v_slow_ratio := v_slow_moving_count::DECIMAL / v_moving_count;
            IF v_slow_ratio > 0.7 THEN
                RETURN 'walking';
            END IF;
        END IF;

        RETURN 'driving';
    END IF;

    -- === FALLBACK: Calculated speed ===
    -- Used when: no GPS points, no sensor speed, or sensor reports near-zero
    IF v_distance_km IS NULL OR v_duration_min IS NULL OR v_duration_min <= 0 THEN
        RETURN 'unknown';
    END IF;

    v_avg_speed_kmh := v_distance_km / (v_duration_min / 60.0);

    IF v_avg_speed_kmh > 10.0 THEN
        RETURN 'driving';
    END IF;

    IF v_avg_speed_kmh < 6.0 THEN
        RETURN 'walking';
    END IF;

    RETURN 'driving';
END;
$$;

-- Reclassify walking trips that have high calculated speed (likely misclassified)
UPDATE trips t
SET transport_mode = classify_trip_transport_mode(t.id)
WHERE t.transport_mode = 'walking'
  AND t.distance_km IS NOT NULL
  AND t.duration_minutes IS NOT NULL
  AND t.duration_minutes > 0
  AND (t.distance_km / (t.duration_minutes / 60.0)) > 8.0;
