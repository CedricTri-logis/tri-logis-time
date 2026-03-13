-- Migration 147: Fix zero sensor speed fallback
-- Some Android devices (e.g. Mario Leclerc's phone) report speed = 0.0 on GPS points
-- even when driving 30+ km/h. The sensor-based classification saw max speed = 0 → walking.
-- Fix: only trust sensor speed if max > 0.3 m/s, otherwise fall back to calculated speed.
-- NOTE: Superseded by migration 148 which raises the threshold to 1.0 m/s.

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
    SELECT distance_km, duration_minutes
    INTO v_distance_km, v_duration_min
    FROM trips
    WHERE id = p_trip_id;

    SELECT
        COUNT(*) FILTER (WHERE gp.speed IS NOT NULL),
        MAX(gp.speed),
        COUNT(*) FILTER (WHERE gp.speed IS NOT NULL AND gp.speed > 0.3),
        COUNT(*) FILTER (WHERE gp.speed IS NOT NULL AND gp.speed > 0.3 AND gp.speed < 1.7)
    INTO v_point_count, v_max_speed_ms, v_moving_count, v_slow_moving_count
    FROM trip_gps_points tgp
    JOIN gps_points gp ON gp.id = tgp.gps_point_id
    WHERE tgp.trip_id = p_trip_id;

    -- Only trust sensor speed if max > 0.3 m/s
    IF v_point_count >= 2 AND v_max_speed_ms IS NOT NULL AND v_max_speed_ms > 0.3 THEN
        IF v_max_speed_ms > 4.2 THEN
            RETURN 'driving';
        END IF;

        IF v_max_speed_ms < 1.7 THEN
            RETURN 'walking';
        END IF;

        IF v_moving_count > 0 THEN
            v_slow_ratio := v_slow_moving_count::DECIMAL / v_moving_count;
            IF v_slow_ratio > 0.7 THEN
                RETURN 'walking';
            END IF;
        END IF;

        RETURN 'driving';
    END IF;

    -- FALLBACK: Calculated speed
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
