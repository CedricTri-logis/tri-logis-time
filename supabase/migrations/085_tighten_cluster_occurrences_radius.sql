-- =============================================================================
-- Migration 085: Tighten get_cluster_occurrences default radius from 100m to 35m
-- =============================================================================
-- Problem: DBSCAN eps=0.0003 (~30m) creates tight clusters, but the drill-down
-- RPC uses 100m radius by default. When multiple clusters exist within 100m of
-- each other, clicking one cluster returns occurrences from neighboring clusters
-- too, causing a count mismatch (e.g., cluster shows 3, drill-down returns 6).
--
-- Fix: Reduce default p_radius_meters from 100 to 35 to match DBSCAN eps (~30m)
-- with a small buffer.
-- =============================================================================

DROP FUNCTION IF EXISTS get_cluster_occurrences(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION);

CREATE OR REPLACE FUNCTION get_cluster_occurrences(
  p_centroid_lat DOUBLE PRECISION,
  p_centroid_lng DOUBLE PRECISION,
  p_radius_meters DOUBLE PRECISION DEFAULT 35  -- was 100; aligned with DBSCAN eps ~30m
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
    -- A. Unmatched trip starts near centroid
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
      AND NOT EXISTS (
          SELECT 1 FROM ignored_trip_endpoints ite
          WHERE ite.trip_id = tw.id AND ite.endpoint_type = 'start'
      )
      AND ST_DWithin(
        ST_SetSRID(ST_MakePoint(tw.start_longitude, tw.start_latitude), 4326)::geography,
        ST_SetSRID(ST_MakePoint(p_centroid_lng, p_centroid_lat), 4326)::geography,
        p_radius_meters
      )

    UNION ALL

    -- B. Unmatched trip ends near centroid
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
      AND NOT EXISTS (
          SELECT 1 FROM ignored_trip_endpoints ite
          WHERE ite.trip_id = tw.id AND ite.endpoint_type = 'end'
      )
      AND ST_DWithin(
        ST_SetSRID(ST_MakePoint(tw.end_longitude, tw.end_latitude), 4326)::geography,
        ST_SetSRID(ST_MakePoint(p_centroid_lng, p_centroid_lat), 4326)::geography,
        p_radius_meters
      )

    UNION ALL

    -- C. Clock-in locations near centroid (column-based filter)
    SELECT NULL::UUID AS trip_id, ep.full_name AS employee_name, 'clock_in'::TEXT AS endpoint_type,
           (s.clock_in_location->>'latitude')::DOUBLE PRECISION AS latitude,
           (s.clock_in_location->>'longitude')::DOUBLE PRECISION AS longitude,
           s.clocked_in_at AS seen_at,
           NULL::TEXT AS address,
           s.clock_in_accuracy::DOUBLE PRECISION AS gps_accuracy,
           NULL::DOUBLE PRECISION AS stop_duration_minutes
    FROM shifts s
    JOIN employee_profiles ep ON ep.id = s.employee_id
    WHERE s.clock_in_location IS NOT NULL
      AND s.clocked_in_at >= NOW() - INTERVAL '90 days'
      AND s.clock_in_cluster_id IS NULL
      AND s.clock_in_location_id IS NULL
      AND COALESCE(s.clock_in_accuracy, 20) <= 50
      AND ST_DWithin(
        ST_SetSRID(ST_MakePoint(
            (s.clock_in_location->>'longitude')::DOUBLE PRECISION,
            (s.clock_in_location->>'latitude')::DOUBLE PRECISION
        ), 4326)::geography,
        ST_SetSRID(ST_MakePoint(p_centroid_lng, p_centroid_lat), 4326)::geography,
        p_radius_meters
      )

    UNION ALL

    -- D. Clock-out locations near centroid (column-based filter)
    SELECT NULL::UUID AS trip_id, ep.full_name AS employee_name, 'clock_out'::TEXT AS endpoint_type,
           (s.clock_out_location->>'latitude')::DOUBLE PRECISION AS latitude,
           (s.clock_out_location->>'longitude')::DOUBLE PRECISION AS longitude,
           s.clocked_out_at AS seen_at,
           NULL::TEXT AS address,
           s.clock_out_accuracy::DOUBLE PRECISION AS gps_accuracy,
           NULL::DOUBLE PRECISION AS stop_duration_minutes
    FROM shifts s
    JOIN employee_profiles ep ON ep.id = s.employee_id
    WHERE s.clock_out_location IS NOT NULL
      AND s.clocked_out_at IS NOT NULL
      AND s.clocked_out_at >= NOW() - INTERVAL '90 days'
      AND s.clock_out_cluster_id IS NULL
      AND s.clock_out_location_id IS NULL
      AND COALESCE(s.clock_out_accuracy, 20) <= 50
      AND ST_DWithin(
        ST_SetSRID(ST_MakePoint(
            (s.clock_out_location->>'longitude')::DOUBLE PRECISION,
            (s.clock_out_location->>'latitude')::DOUBLE PRECISION
        ), 4326)::geography,
        ST_SetSRID(ST_MakePoint(p_centroid_lng, p_centroid_lat), 4326)::geography,
        p_radius_meters
      )
  ) sub
  ORDER BY sub.seen_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
