-- Migration 054: get_cluster_occurrences RPC
-- Returns individual trip endpoints near a cluster centroid for drill-down
-- Includes GPS accuracy from first/last trip point and stop duration from adjacent trips

DROP FUNCTION IF EXISTS get_cluster_occurrences(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION);

CREATE OR REPLACE FUNCTION get_cluster_occurrences(
  p_centroid_lat DOUBLE PRECISION,
  p_centroid_lng DOUBLE PRECISION,
  p_radius_meters DOUBLE PRECISION DEFAULT 150
)
RETURNS TABLE (
  trip_id UUID,
  employee_name TEXT,
  endpoint_type TEXT,
  latitude DOUBLE PRECISION,
  longitude DOUBLE PRECISION,
  seen_at TIMESTAMPTZ,
  address TEXT,
  gps_accuracy DOUBLE PRECISION,
  stop_duration_minutes DOUBLE PRECISION
) AS $$
BEGIN
  RETURN QUERY
  WITH trip_windows AS (
    SELECT t.*,
      LAG(t.ended_at) OVER (PARTITION BY t.employee_id ORDER BY t.started_at) AS prev_ended_at,
      LEAD(t.started_at) OVER (PARTITION BY t.employee_id ORDER BY t.started_at) AS next_started_at
    FROM trips t
  )
  SELECT sub.trip_id, sub.employee_name, sub.endpoint_type,
         sub.latitude, sub.longitude, sub.seen_at, sub.address,
         sub.gps_accuracy, sub.stop_duration_minutes
  FROM (
    -- Unmatched starts near centroid
    SELECT tw.id AS trip_id, ep.full_name AS employee_name, 'start'::TEXT AS endpoint_type,
           tw.start_latitude::DOUBLE PRECISION AS latitude, tw.start_longitude::DOUBLE PRECISION AS longitude,
           tw.started_at AS seen_at, tw.start_address AS address,
           (SELECT gp.accuracy::DOUBLE PRECISION FROM trip_gps_points tgp
            JOIN gps_points gp ON gp.id = tgp.gps_point_id
            WHERE tgp.trip_id = tw.id
            ORDER BY tgp.sequence_order ASC LIMIT 1) AS gps_accuracy,
           (EXTRACT(EPOCH FROM (tw.started_at - tw.prev_ended_at)) / 60.0)::DOUBLE PRECISION AS stop_duration_minutes
    FROM trip_windows tw
    JOIN employee_profiles ep ON ep.id = tw.employee_id
    WHERE tw.start_location_id IS NULL
      AND ST_DWithin(
        ST_SetSRID(ST_MakePoint(tw.start_longitude, tw.start_latitude), 4326)::geography,
        ST_SetSRID(ST_MakePoint(p_centroid_lng, p_centroid_lat), 4326)::geography,
        p_radius_meters
      )
    UNION ALL
    -- Unmatched ends near centroid
    SELECT tw.id, ep.full_name, 'end'::TEXT,
           tw.end_latitude::DOUBLE PRECISION, tw.end_longitude::DOUBLE PRECISION,
           tw.ended_at, tw.end_address,
           (SELECT gp.accuracy::DOUBLE PRECISION FROM trip_gps_points tgp
            JOIN gps_points gp ON gp.id = tgp.gps_point_id
            WHERE tgp.trip_id = tw.id
            ORDER BY tgp.sequence_order DESC LIMIT 1) AS gps_accuracy,
           (EXTRACT(EPOCH FROM (tw.next_started_at - tw.ended_at)) / 60.0)::DOUBLE PRECISION AS stop_duration_minutes
    FROM trip_windows tw
    JOIN employee_profiles ep ON ep.id = tw.employee_id
    WHERE tw.end_location_id IS NULL
      AND ST_DWithin(
        ST_SetSRID(ST_MakePoint(tw.end_longitude, tw.end_latitude), 4326)::geography,
        ST_SetSRID(ST_MakePoint(p_centroid_lng, p_centroid_lat), 4326)::geography,
        p_radius_meters
      )
  ) sub
  ORDER BY sub.seen_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
