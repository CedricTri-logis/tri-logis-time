-- =============================================================================
-- Migration 053: Ignore clusters + rematch trips near location
-- =============================================================================
-- 1. ignored_location_clusters table (admin-only)
-- 2. ignore_location_cluster() RPC
-- 3. Updated get_unmatched_trip_clusters() — filters out ignored clusters
-- 4. rematch_trips_near_location() RPC
-- =============================================================================

-- =============================================================================
-- 1. ignored_location_clusters table
-- =============================================================================
CREATE TABLE ignored_location_clusters (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  centroid_latitude DOUBLE PRECISION NOT NULL,
  centroid_longitude DOUBLE PRECISION NOT NULL,
  occurrence_count_at_ignore INTEGER NOT NULL,
  ignored_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ignored_by UUID REFERENCES auth.users(id)
);

ALTER TABLE ignored_location_clusters ENABLE ROW LEVEL SECURITY;

CREATE POLICY "admin_manage_ignored_clusters" ON ignored_location_clusters
  FOR ALL USING (is_admin_or_super_admin(auth.uid()));

COMMENT ON TABLE ignored_location_clusters IS 'Stores clusters dismissed by admins from the Suggested locations tab';

-- =============================================================================
-- 2. ignore_location_cluster() RPC
-- =============================================================================
CREATE OR REPLACE FUNCTION ignore_location_cluster(
  p_latitude DOUBLE PRECISION,
  p_longitude DOUBLE PRECISION,
  p_occurrence_count INTEGER
) RETURNS UUID AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO ignored_location_clusters (centroid_latitude, centroid_longitude, occurrence_count_at_ignore, ignored_by)
  VALUES (p_latitude, p_longitude, p_occurrence_count, auth.uid())
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION ignore_location_cluster IS 'Dismiss a suggested location cluster. Re-surfaces if occurrence count grows beyond ignored count.';

-- =============================================================================
-- 3. Updated get_unmatched_trip_clusters() — filters out ignored clusters
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
    -- Filter out ignored clusters (unless new occurrences surpass the count at ignore time)
    WHERE NOT EXISTS (
        SELECT 1
        FROM ignored_location_clusters ic
        WHERE ST_DWithin(
            ST_SetSRID(ST_MakePoint(a.centroid_lng, a.centroid_lat), 4326)::geography,
            ST_SetSRID(ST_MakePoint(ic.centroid_longitude, ic.centroid_latitude), 4326)::geography,
            150  -- 150m tolerance
        )
        AND a.cnt <= ic.occurrence_count_at_ignore
    )
    ORDER BY a.cnt DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

-- =============================================================================
-- 4. rematch_trips_near_location() RPC
-- =============================================================================
CREATE OR REPLACE FUNCTION rematch_trips_near_location(p_location_id UUID)
RETURNS TABLE (matched_start INTEGER, matched_end INTEGER) AS $$
DECLARE
    v_lat DOUBLE PRECISION;
    v_lng DOUBLE PRECISION;
    v_radius DOUBLE PRECISION;
    v_start_count INTEGER := 0;
    v_end_count INTEGER := 0;
BEGIN
    -- Fetch location coordinates and radius
    SELECT
        ST_Y(l.location::geometry),
        ST_X(l.location::geometry),
        l.radius_meters
    INTO v_lat, v_lng, v_radius
    FROM locations l
    WHERE l.id = p_location_id AND l.is_active = TRUE;

    IF v_lat IS NULL THEN
        RETURN QUERY SELECT 0, 0;
        RETURN;
    END IF;

    -- Match unmatched trip starts within radius (skip manual overrides)
    WITH updated_starts AS (
        UPDATE trips
        SET start_location_id = p_location_id,
            start_location_match_method = 'auto'
        WHERE start_location_id IS NULL
          AND COALESCE(start_location_match_method, '') != 'manual'
          AND ST_DWithin(
              ST_SetSRID(ST_MakePoint(start_longitude, start_latitude), 4326)::geography,
              ST_SetSRID(ST_MakePoint(v_lng, v_lat), 4326)::geography,
              v_radius
          )
        RETURNING id
    )
    SELECT COUNT(*)::INTEGER INTO v_start_count FROM updated_starts;

    -- Match unmatched trip ends within radius (skip manual overrides)
    WITH updated_ends AS (
        UPDATE trips
        SET end_location_id = p_location_id,
            end_location_match_method = 'auto'
        WHERE end_location_id IS NULL
          AND COALESCE(end_location_match_method, '') != 'manual'
          AND ST_DWithin(
              ST_SetSRID(ST_MakePoint(end_longitude, end_latitude), 4326)::geography,
              ST_SetSRID(ST_MakePoint(v_lng, v_lat), 4326)::geography,
              v_radius
          )
        RETURNING id
    )
    SELECT COUNT(*)::INTEGER INTO v_end_count FROM updated_ends;

    RETURN QUERY SELECT v_start_count, v_end_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION rematch_trips_near_location IS 'Re-match unmatched trip endpoints near a location after creation. Skips manually overridden matches.';
