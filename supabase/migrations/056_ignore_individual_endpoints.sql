-- =============================================================================
-- Migration 056: Per-endpoint ignore (replaces cluster-level ignore)
-- =============================================================================
-- 1. ignored_trip_endpoints table
-- 2. ignore_trip_endpoint() RPC
-- 3. Updated get_unmatched_trip_clusters() — excludes ignored endpoints
-- 4. Updated get_cluster_occurrences() — excludes ignored endpoints
-- =============================================================================

-- =============================================================================
-- 1. ignored_trip_endpoints table
-- =============================================================================
CREATE TABLE ignored_trip_endpoints (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  endpoint_type TEXT NOT NULL CHECK (endpoint_type IN ('start', 'end')),
  ignored_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ignored_by UUID REFERENCES auth.users(id),
  UNIQUE(trip_id, endpoint_type)
);

ALTER TABLE ignored_trip_endpoints ENABLE ROW LEVEL SECURITY;

CREATE POLICY "admin_manage_ignored_endpoints" ON ignored_trip_endpoints
  FOR ALL USING (is_admin_or_super_admin(auth.uid()));

COMMENT ON TABLE ignored_trip_endpoints IS 'Individual trip endpoints dismissed by admins from the Suggested locations tab';

-- =============================================================================
-- 2. ignore_trip_endpoint() RPC
-- =============================================================================
CREATE OR REPLACE FUNCTION ignore_trip_endpoint(
  p_trip_id UUID,
  p_endpoint_type TEXT
) RETURNS UUID AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO ignored_trip_endpoints (trip_id, endpoint_type, ignored_by)
  VALUES (p_trip_id, p_endpoint_type, auth.uid())
  ON CONFLICT (trip_id, endpoint_type) DO NOTHING
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION ignore_trip_endpoint IS 'Dismiss a single trip endpoint from suggested locations.';

-- =============================================================================
-- 3. Updated get_unmatched_trip_clusters() — excludes ignored endpoints
-- =============================================================================
CREATE OR REPLACE FUNCTION get_unmatched_trip_clusters(
    p_min_occurrences INTEGER DEFAULT 1
)
RETURNS TABLE (
    cluster_id INTEGER,
    centroid_latitude DOUBLE PRECISION,
    centroid_longitude DOUBLE PRECISION,
    occurrence_count BIGINT,
    has_start_endpoints BOOLEAN,
    has_end_endpoints BOOLEAN,
    employee_names TEXT[],
    first_seen TIMESTAMPTZ,
    last_seen TIMESTAMPTZ,
    sample_addresses TEXT[]
) AS $$
BEGIN
    RETURN QUERY
    WITH unmatched_endpoints AS (
        SELECT
            t.start_latitude AS lat,
            t.start_longitude AS lng,
            'start'::TEXT AS endpoint_type,
            t.employee_id,
            t.started_at AS seen_at,
            t.start_address AS address
        FROM trips t
        WHERE t.start_location_id IS NULL
          AND NOT EXISTS (
              SELECT 1 FROM ignored_trip_endpoints ite
              WHERE ite.trip_id = t.id AND ite.endpoint_type = 'start'
          )

        UNION ALL

        SELECT
            t.end_latitude AS lat,
            t.end_longitude AS lng,
            'end'::TEXT AS endpoint_type,
            t.employee_id,
            t.ended_at AS seen_at,
            t.end_address AS address
        FROM trips t
        WHERE t.end_location_id IS NULL
          AND NOT EXISTS (
              SELECT 1 FROM ignored_trip_endpoints ite
              WHERE ite.trip_id = t.id AND ite.endpoint_type = 'end'
          )
    ),
    clustered AS (
        SELECT
            ue.*,
            ST_ClusterDBSCAN(
                ST_SetSRID(ST_MakePoint(ue.lng, ue.lat), 4326)::geometry,
                eps := 0.001,
                minpoints := 1
            ) OVER () AS cid
        FROM unmatched_endpoints ue
    ),
    aggregated AS (
        SELECT
            c.cid,
            AVG(c.lat)::DOUBLE PRECISION AS centroid_lat,
            AVG(c.lng)::DOUBLE PRECISION AS centroid_lng,
            COUNT(*) AS cnt,
            BOOL_OR(c.endpoint_type = 'start') AS has_starts,
            BOOL_OR(c.endpoint_type = 'end') AS has_ends,
            ARRAY_AGG(DISTINCT ep.full_name) FILTER (WHERE ep.full_name IS NOT NULL) AS emp_names,
            MIN(c.seen_at) AS first_at,
            MAX(c.seen_at) AS last_at,
            ARRAY_AGG(DISTINCT c.address) FILTER (WHERE c.address IS NOT NULL) AS addrs
        FROM clustered c
        LEFT JOIN employee_profiles ep ON ep.id = c.employee_id
        WHERE c.cid IS NOT NULL
        GROUP BY c.cid
        HAVING COUNT(*) >= p_min_occurrences
    )
    SELECT
        a.cid::INTEGER,
        a.centroid_lat,
        a.centroid_lng,
        a.cnt,
        a.has_starts,
        a.has_ends,
        a.emp_names,
        a.first_at,
        a.last_at,
        a.addrs
    FROM aggregated a
    -- Keep legacy cluster-level ignore filter for previously ignored clusters
    WHERE NOT EXISTS (
        SELECT 1
        FROM ignored_location_clusters ic
        WHERE ST_DWithin(
            ST_SetSRID(ST_MakePoint(a.centroid_lng, a.centroid_lat), 4326)::geography,
            ST_SetSRID(ST_MakePoint(ic.centroid_longitude, ic.centroid_latitude), 4326)::geography,
            150
        )
        AND a.cnt <= ic.occurrence_count_at_ignore
    )
    ORDER BY a.cnt DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

-- =============================================================================
-- 4. Updated get_cluster_occurrences() — excludes ignored endpoints
-- =============================================================================
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
      AND NOT EXISTS (
          SELECT 1 FROM ignored_trip_endpoints ite
          WHERE ite.trip_id = tw.id AND ite.endpoint_type = 'end'
      )
      AND ST_DWithin(
        ST_SetSRID(ST_MakePoint(tw.end_longitude, tw.end_latitude), 4326)::geography,
        ST_SetSRID(ST_MakePoint(p_centroid_lng, p_centroid_lat), 4326)::geography,
        p_radius_meters
      )
  ) sub
  ORDER BY sub.seen_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
