-- =============================================================================
-- 063: Rewrite suggested locations RPCs to source from stationary_clusters
-- =============================================================================
-- Replaces get_unmatched_trip_clusters() and get_cluster_occurrences() to use
-- stationary_clusters table instead of raw trip endpoints. Centroids are now
-- accuracy-weighted means of already-weighted cluster centroids.
-- =============================================================================

-- 1. Replace get_unmatched_trip_clusters
-- Must DROP first: return type changed (removed has_start/end_endpoints, sample_addresses; added total_duration_seconds, avg_accuracy)
DROP FUNCTION IF EXISTS get_unmatched_trip_clusters(INTEGER);
CREATE OR REPLACE FUNCTION get_unmatched_trip_clusters(
    p_min_occurrences INTEGER DEFAULT 1
)
RETURNS TABLE (
    cluster_id INTEGER,
    centroid_latitude DOUBLE PRECISION,
    centroid_longitude DOUBLE PRECISION,
    occurrence_count BIGINT,
    employee_names TEXT[],
    first_seen TIMESTAMPTZ,
    last_seen TIMESTAMPTZ,
    total_duration_seconds BIGINT,
    avg_accuracy DOUBLE PRECISION
) AS $$
BEGIN
    RETURN QUERY
    WITH unmatched AS (
        SELECT
            sc.id,
            sc.centroid_latitude AS lat,
            sc.centroid_longitude AS lng,
            sc.centroid_accuracy AS acc,
            sc.employee_id,
            sc.started_at,
            sc.duration_seconds
        FROM stationary_clusters sc
        WHERE sc.matched_location_id IS NULL
    ),
    clustered AS (
        SELECT
            u.*,
            ST_ClusterDBSCAN(
                ST_SetSRID(ST_MakePoint(u.lng, u.lat), 4326)::geometry,
                eps := 0.0005,
                minpoints := 1
            ) OVER () AS cid
        FROM unmatched u
    ),
    aggregated AS (
        SELECT
            c.cid,
            -- Accuracy-weighted centroid of centroids
            (SUM(c.lat::DOUBLE PRECISION / GREATEST(c.acc::DOUBLE PRECISION, 0.1))
             / SUM(1.0 / GREATEST(c.acc::DOUBLE PRECISION, 0.1))) AS centroid_lat,
            (SUM(c.lng::DOUBLE PRECISION / GREATEST(c.acc::DOUBLE PRECISION, 0.1))
             / SUM(1.0 / GREATEST(c.acc::DOUBLE PRECISION, 0.1))) AS centroid_lng,
            COUNT(*) AS cnt,
            ARRAY_AGG(DISTINCT ep.full_name) FILTER (WHERE ep.full_name IS NOT NULL) AS emp_names,
            MIN(c.started_at) AS first_at,
            MAX(c.started_at) AS last_at,
            SUM(c.duration_seconds)::BIGINT AS total_dur,
            AVG(c.acc::DOUBLE PRECISION) AS avg_acc
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
        a.emp_names,
        a.first_at,
        a.last_at,
        a.total_dur,
        a.avg_acc
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. Replace get_cluster_occurrences
-- Replays the same DBSCAN as get_unmatched_trip_clusters, then returns only
-- the members of the group whose centroid is closest to the requested point.
-- This guarantees perfect consistency with the cluster listing.
DROP FUNCTION IF EXISTS get_cluster_occurrences(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION);
CREATE OR REPLACE FUNCTION get_cluster_occurrences(
    p_centroid_lat DOUBLE PRECISION,
    p_centroid_lng DOUBLE PRECISION,
    p_radius_meters DOUBLE PRECISION DEFAULT 60
)
RETURNS TABLE (
    cluster_id UUID,
    employee_name TEXT,
    centroid_latitude DOUBLE PRECISION,
    centroid_longitude DOUBLE PRECISION,
    centroid_accuracy DOUBLE PRECISION,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    duration_seconds INTEGER,
    gps_point_count INTEGER,
    shift_id UUID
) AS $$
BEGIN
    RETURN QUERY
    WITH unmatched AS (
        SELECT
            sc.id,
            sc.centroid_latitude AS lat,
            sc.centroid_longitude AS lng,
            sc.centroid_accuracy AS acc,
            sc.employee_id,
            sc.started_at AS s_at,
            sc.ended_at AS e_at,
            sc.duration_seconds AS dur,
            sc.gps_point_count AS pts,
            sc.shift_id AS sid
        FROM stationary_clusters sc
        WHERE sc.matched_location_id IS NULL
    ),
    clustered AS (
        SELECT
            u.*,
            ST_ClusterDBSCAN(
                ST_SetSRID(ST_MakePoint(u.lng, u.lat), 4326)::geometry,
                eps := 0.0005,
                minpoints := 1
            ) OVER () AS cid
        FROM unmatched u
    ),
    group_centroids AS (
        SELECT
            c.cid,
            (SUM(c.lat::DOUBLE PRECISION / GREATEST(c.acc::DOUBLE PRECISION, 0.1))
             / SUM(1.0 / GREATEST(c.acc::DOUBLE PRECISION, 0.1))) AS g_lat,
            (SUM(c.lng::DOUBLE PRECISION / GREATEST(c.acc::DOUBLE PRECISION, 0.1))
             / SUM(1.0 / GREATEST(c.acc::DOUBLE PRECISION, 0.1))) AS g_lng
        FROM clustered c
        WHERE c.cid IS NOT NULL
        GROUP BY c.cid
    ),
    target_group AS (
        SELECT gc.cid
        FROM group_centroids gc
        WHERE ST_DWithin(
            ST_SetSRID(ST_MakePoint(gc.g_lng, gc.g_lat), 4326)::geography,
            ST_SetSRID(ST_MakePoint(p_centroid_lng, p_centroid_lat), 4326)::geography,
            p_radius_meters
        )
        ORDER BY ST_Distance(
            ST_SetSRID(ST_MakePoint(gc.g_lng, gc.g_lat), 4326)::geography,
            ST_SetSRID(ST_MakePoint(p_centroid_lng, p_centroid_lat), 4326)::geography
        )
        LIMIT 1
    )
    SELECT
        c.id AS cluster_id,
        ep.full_name::TEXT AS employee_name,
        c.lat::DOUBLE PRECISION,
        c.lng::DOUBLE PRECISION,
        c.acc::DOUBLE PRECISION,
        c.s_at,
        c.e_at,
        c.dur,
        c.pts,
        c.sid
    FROM clustered c
    JOIN employee_profiles ep ON ep.id = c.employee_id
    JOIN target_group tg ON c.cid = tg.cid
    ORDER BY c.s_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
