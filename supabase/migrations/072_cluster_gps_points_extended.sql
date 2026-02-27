-- Extend get_cluster_gps_points to return all available GPS data
-- (speed, heading, altitude, activity_type, is_mocked)

-- Must drop first because return type is changing
DROP FUNCTION IF EXISTS get_cluster_gps_points(UUID);

CREATE OR REPLACE FUNCTION get_cluster_gps_points(
    p_cluster_id UUID
)
RETURNS TABLE (
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    accuracy DOUBLE PRECISION,
    received_at TIMESTAMPTZ,
    speed DOUBLE PRECISION,
    speed_accuracy DOUBLE PRECISION,
    heading DOUBLE PRECISION,
    altitude DOUBLE PRECISION,
    altitude_accuracy DOUBLE PRECISION,
    activity_type TEXT,
    is_mocked BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        gp.latitude::DOUBLE PRECISION,
        gp.longitude::DOUBLE PRECISION,
        gp.accuracy::DOUBLE PRECISION,
        gp.received_at,
        gp.speed::DOUBLE PRECISION,
        gp.speed_accuracy::DOUBLE PRECISION,
        gp.heading::DOUBLE PRECISION,
        gp.altitude::DOUBLE PRECISION,
        gp.altitude_accuracy::DOUBLE PRECISION,
        gp.activity_type,
        gp.is_mocked
    FROM gps_points gp
    WHERE gp.employee_id = (SELECT sc.employee_id FROM stationary_clusters sc WHERE sc.id = p_cluster_id)
      AND gp.received_at BETWEEN
          (SELECT sc.started_at FROM stationary_clusters sc WHERE sc.id = p_cluster_id)
          AND (SELECT sc.ended_at FROM stationary_clusters sc WHERE sc.id = p_cluster_id)
    ORDER BY gp.received_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
