-- =============================================================================
-- Migration 083: Update suggestion RPCs with column-based clock filters
-- =============================================================================
-- Changes:
--   get_unmatched_trip_clusters:
--     - Blocks A & B (trip endpoints): add spatial safety net excluding points
--       within radius + GPS accuracy of any active location (catches centroid-drift
--       matching bugs where detect_trips missed the match)
--     - Blocks C & D (clock-in/out): replace expensive ST_DWithin location scan
--       with column-based filter on clock_in/out_cluster_id and clock_in/out_location_id
--       (leverages linking columns from migration 082)
--
--   get_cluster_occurrences:
--     - Blocks C & D: same column-based filter replacement
-- =============================================================================

DROP FUNCTION IF EXISTS get_unmatched_trip_clusters(INTEGER);
DROP FUNCTION IF EXISTS get_cluster_occurrences(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION);

-- =============================================================================
-- 1. get_unmatched_trip_clusters
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
        -- A. Trip start endpoints
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
          -- Spatial safety net: exclude if within radius + GPS accuracy of any active location
          -- (catches centroid-drift matching bug where detect_trips missed the match)
          AND NOT EXISTS (
              SELECT 1 FROM locations l
              WHERE l.is_active = TRUE
                AND ST_DWithin(
                    ST_SetSRID(ST_MakePoint(t.start_longitude::DOUBLE PRECISION, t.start_latitude::DOUBLE PRECISION), 4326)::geography,
                    l.location,
                    l.radius_meters + COALESCE(
                        (SELECT gp.accuracy FROM trip_gps_points tgp
                         JOIN gps_points gp ON gp.id = tgp.gps_point_id
                         WHERE tgp.trip_id = t.id
                         ORDER BY tgp.sequence_order ASC LIMIT 1),
                        0
                    )
                )
          )

        UNION ALL

        -- B. Trip end endpoints
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
          -- Spatial safety net: exclude if within radius + GPS accuracy of any active location
          AND NOT EXISTS (
              SELECT 1 FROM locations l
              WHERE l.is_active = TRUE
                AND ST_DWithin(
                    ST_SetSRID(ST_MakePoint(t.end_longitude::DOUBLE PRECISION, t.end_latitude::DOUBLE PRECISION), 4326)::geography,
                    l.location,
                    l.radius_meters + COALESCE(
                        (SELECT gp.accuracy FROM trip_gps_points tgp
                         JOIN gps_points gp ON gp.id = tgp.gps_point_id
                         WHERE tgp.trip_id = t.id
                         ORDER BY tgp.sequence_order DESC LIMIT 1),
                        0
                    )
                )
          )

        UNION ALL

        -- C. Clock-in locations (column-based filter via migration 082 linking)
        SELECT
            (s.clock_in_location->>'latitude')::DOUBLE PRECISION AS lat,
            (s.clock_in_location->>'longitude')::DOUBLE PRECISION AS lng,
            'clock_in'::TEXT AS endpoint_type,
            s.employee_id,
            s.clocked_in_at AS seen_at,
            NULL::TEXT AS address
        FROM shifts s
        WHERE s.clock_in_location IS NOT NULL
          AND s.clocked_in_at >= NOW() - INTERVAL '90 days'
          AND s.clock_in_cluster_id IS NULL      -- not linked to a cluster
          AND s.clock_in_location_id IS NULL     -- not matched to a location
          AND COALESCE(s.clock_in_accuracy, 20) <= 50  -- accuracy filter

        UNION ALL

        -- D. Clock-out locations (column-based filter via migration 082 linking)
        SELECT
            (s.clock_out_location->>'latitude')::DOUBLE PRECISION AS lat,
            (s.clock_out_location->>'longitude')::DOUBLE PRECISION AS lng,
            'clock_out'::TEXT AS endpoint_type,
            s.employee_id,
            s.clocked_out_at AS seen_at,
            NULL::TEXT AS address
        FROM shifts s
        WHERE s.clock_out_location IS NOT NULL
          AND s.clocked_out_at IS NOT NULL
          AND s.clocked_out_at >= NOW() - INTERVAL '90 days'
          AND s.clock_out_cluster_id IS NULL     -- not linked to a cluster
          AND s.clock_out_location_id IS NULL    -- not matched to a location
          AND COALESCE(s.clock_out_accuracy, 20) <= 50  -- accuracy filter
    ),
    clustered AS (
        SELECT
            ue.*,
            ST_ClusterDBSCAN(
                ST_SetSRID(ST_MakePoint(ue.lng, ue.lat), 4326)::geometry,
                eps := 0.0003,    -- ~30m
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
            BOOL_OR(c.endpoint_type IN ('start', 'clock_in')) AS has_starts,
            BOOL_OR(c.endpoint_type IN ('end', 'clock_out')) AS has_ends,
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
-- 2. get_cluster_occurrences — column-based clock filter + tighter default radius
-- =============================================================================
CREATE OR REPLACE FUNCTION get_cluster_occurrences(
  p_centroid_lat DOUBLE PRECISION,
  p_centroid_lng DOUBLE PRECISION,
  p_radius_meters DOUBLE PRECISION DEFAULT 100
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
      AND s.clock_in_cluster_id IS NULL      -- not linked to a cluster
      AND s.clock_in_location_id IS NULL     -- not matched to a location
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
      AND s.clock_out_cluster_id IS NULL     -- not linked to a cluster
      AND s.clock_out_location_id IS NULL    -- not matched to a location
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
