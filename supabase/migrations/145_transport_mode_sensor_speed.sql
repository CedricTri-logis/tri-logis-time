-- Migration 145: Use GPS sensor speed for transport mode classification
-- Instead of calculated distance/time, use the device's speed field (m/s)
-- which is available on 99.9% of GPS points since Feb 2026.

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
    -- Fallback vars (for pre-Feb 2026 data without sensor speed)
    v_distance_km DECIMAL;
    v_duration_min INTEGER;
    v_avg_speed_kmh DECIMAL;
BEGIN
    -- Count points with sensor speed data
    SELECT
        COUNT(*) FILTER (WHERE gp.speed IS NOT NULL),
        MAX(gp.speed),
        COUNT(*) FILTER (WHERE gp.speed IS NOT NULL AND gp.speed > 0.3),   -- moving (> ~1 km/h)
        COUNT(*) FILTER (WHERE gp.speed IS NOT NULL AND gp.speed > 0.3 AND gp.speed < 1.7)  -- slow moving (1-6 km/h)
    INTO v_point_count, v_max_speed_ms, v_moving_count, v_slow_moving_count
    FROM trip_gps_points tgp
    JOIN gps_points gp ON gp.id = tgp.gps_point_id
    WHERE tgp.trip_id = p_trip_id;

    -- === PRIMARY: Sensor speed classification ===
    IF v_point_count >= 2 AND v_max_speed_ms IS NOT NULL THEN

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

    -- === FALLBACK: Calculated speed (pre-Feb 2026 data) ===
    SELECT distance_km, duration_minutes
    INTO v_distance_km, v_duration_min
    FROM trips
    WHERE id = p_trip_id;

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

-- Reclassify misclassified trips (driving but max sensor speed < 6 km/h)
UPDATE trips t
SET transport_mode = classify_trip_transport_mode(t.id)
WHERE t.transport_mode = 'driving'
  AND EXISTS (
    SELECT 1 FROM trip_gps_points tgp
    JOIN gps_points gp ON gp.id = tgp.gps_point_id
    WHERE tgp.trip_id = t.id
    AND gp.speed IS NOT NULL
  )
  AND NOT EXISTS (
    SELECT 1 FROM trip_gps_points tgp
    JOIN gps_points gp ON gp.id = tgp.gps_point_id
    WHERE tgp.trip_id = t.id
    AND gp.speed > 1.67
  );
