-- Migration 054: get_cluster_occurrences RPC
-- Returns individual trip endpoints near a cluster centroid for drill-down

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
  address TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT sub.trip_id, sub.employee_name, sub.endpoint_type,
         sub.latitude, sub.longitude, sub.seen_at, sub.address
  FROM (
    -- Unmatched starts near centroid
    SELECT t.id AS trip_id, ep.full_name AS employee_name, 'start'::TEXT AS endpoint_type,
           t.start_latitude::DOUBLE PRECISION AS latitude, t.start_longitude::DOUBLE PRECISION AS longitude,
           t.started_at AS seen_at, t.start_address AS address
    FROM trips t
    JOIN employee_profiles ep ON ep.id = t.employee_id
    WHERE t.start_location_id IS NULL
      AND ST_DWithin(
        ST_SetSRID(ST_MakePoint(t.start_longitude, t.start_latitude), 4326)::geography,
        ST_SetSRID(ST_MakePoint(p_centroid_lng, p_centroid_lat), 4326)::geography,
        p_radius_meters
      )
    UNION ALL
    -- Unmatched ends near centroid
    SELECT t.id, ep.full_name, 'end'::TEXT,
           t.end_latitude::DOUBLE PRECISION, t.end_longitude::DOUBLE PRECISION,
           t.ended_at, t.end_address
    FROM trips t
    JOIN employee_profiles ep ON ep.id = t.employee_id
    WHERE t.end_location_id IS NULL
      AND ST_DWithin(
        ST_SetSRID(ST_MakePoint(t.end_longitude, t.end_latitude), 4326)::geography,
        ST_SetSRID(ST_MakePoint(p_centroid_lng, p_centroid_lat), 4326)::geography,
        p_radius_meters
      )
  ) sub
  ORDER BY sub.seen_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
