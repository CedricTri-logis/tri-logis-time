-- =============================================================================
-- 073: Extend rematch RPCs to also rematch stationary_clusters
-- =============================================================================
-- When a location is created or edited, unmatched stationary_clusters that now
-- fall within the geofence should be matched. When a location is moved/resized,
-- clusters that no longer fall within the zone should be unmatched.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. rematch_trips_near_location: called when creating a new location
--    Now also matches unmatched clusters within the geofence.
-- ─────────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS rematch_trips_near_location(UUID);

CREATE OR REPLACE FUNCTION rematch_trips_near_location(p_location_id UUID)
RETURNS TABLE (matched_start INTEGER, matched_end INTEGER, matched_clusters INTEGER) AS $$
DECLARE
    v_lat DOUBLE PRECISION;
    v_lng DOUBLE PRECISION;
    v_radius DOUBLE PRECISION;
    v_start_count INTEGER := 0;
    v_end_count INTEGER := 0;
    v_cluster_count INTEGER := 0;
BEGIN
    SELECT
        ST_Y(l.location::geometry),
        ST_X(l.location::geometry),
        l.radius_meters
    INTO v_lat, v_lng, v_radius
    FROM locations l
    WHERE l.id = p_location_id AND l.is_active = TRUE;

    IF v_lat IS NULL THEN
        RETURN QUERY SELECT 0, 0, 0;
        RETURN;
    END IF;

    -- Match unmatched trip starts within radius + GPS accuracy
    WITH updated_starts AS (
        UPDATE trips
        SET start_location_id = p_location_id,
            start_location_match_method = 'auto'
        WHERE start_location_id IS NULL
          AND COALESCE(start_location_match_method, '') != 'manual'
          AND ST_DWithin(
              ST_SetSRID(ST_MakePoint(start_longitude, start_latitude), 4326)::geography,
              ST_SetSRID(ST_MakePoint(v_lng, v_lat), 4326)::geography,
              v_radius + COALESCE((
                  SELECT gp.accuracy FROM trip_gps_points tgp
                  JOIN gps_points gp ON gp.id = tgp.gps_point_id
                  WHERE tgp.trip_id = trips.id
                  ORDER BY tgp.sequence_order ASC LIMIT 1
              ), 0)
          )
        RETURNING id
    )
    SELECT COUNT(*)::INTEGER INTO v_start_count FROM updated_starts;

    -- Match unmatched trip ends within radius + GPS accuracy
    WITH updated_ends AS (
        UPDATE trips
        SET end_location_id = p_location_id,
            end_location_match_method = 'auto'
        WHERE end_location_id IS NULL
          AND COALESCE(end_location_match_method, '') != 'manual'
          AND ST_DWithin(
              ST_SetSRID(ST_MakePoint(end_longitude, end_latitude), 4326)::geography,
              ST_SetSRID(ST_MakePoint(v_lng, v_lat), 4326)::geography,
              v_radius + COALESCE((
                  SELECT gp.accuracy FROM trip_gps_points tgp
                  JOIN gps_points gp ON gp.id = tgp.gps_point_id
                  WHERE tgp.trip_id = trips.id
                  ORDER BY tgp.sequence_order DESC LIMIT 1
              ), 0)
          )
        RETURNING id
    )
    SELECT COUNT(*)::INTEGER INTO v_end_count FROM updated_ends;

    -- Match unmatched stationary clusters within radius + centroid accuracy
    WITH updated_clusters AS (
        UPDATE stationary_clusters
        SET matched_location_id = p_location_id
        WHERE matched_location_id IS NULL
          AND ST_DWithin(
              ST_SetSRID(ST_MakePoint(centroid_longitude, centroid_latitude), 4326)::geography,
              ST_SetSRID(ST_MakePoint(v_lng, v_lat), 4326)::geography,
              v_radius + COALESCE(centroid_accuracy, 0)
          )
        RETURNING id
    )
    SELECT COUNT(*)::INTEGER INTO v_cluster_count FROM updated_clusters;

    RETURN QUERY SELECT v_start_count, v_end_count, v_cluster_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. rematch_trips_for_updated_location: called when editing a location
--    Now also un-matches/re-matches stationary_clusters.
-- ─────────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS rematch_trips_for_updated_location(UUID);

CREATE OR REPLACE FUNCTION rematch_trips_for_updated_location(p_location_id UUID)
RETURNS TABLE (
    newly_matched_start INTEGER,
    newly_matched_end INTEGER,
    unmatched_start INTEGER,
    unmatched_end INTEGER,
    newly_matched_clusters INTEGER,
    unmatched_clusters INTEGER
) AS $$
DECLARE
    v_lat DOUBLE PRECISION;
    v_lng DOUBLE PRECISION;
    v_radius DOUBLE PRECISION;
    v_newly_matched_start INTEGER := 0;
    v_newly_matched_end INTEGER := 0;
    v_unmatched_start INTEGER := 0;
    v_unmatched_end INTEGER := 0;
    v_newly_matched_clusters INTEGER := 0;
    v_unmatched_clusters INTEGER := 0;
BEGIN
    SELECT
        ST_Y(l.location::geometry),
        ST_X(l.location::geometry),
        l.radius_meters
    INTO v_lat, v_lng, v_radius
    FROM locations l
    WHERE l.id = p_location_id AND l.is_active = TRUE;

    IF v_lat IS NULL THEN
        RETURN QUERY SELECT 0, 0, 0, 0, 0, 0;
        RETURN;
    END IF;

    -- =========================================================================
    -- STEP 1: UN-MATCH trips/clusters that no longer fall within the zone
    -- =========================================================================

    -- Un-match trip starts outside radius + accuracy
    WITH cleared_starts AS (
        UPDATE trips
        SET start_location_id = NULL,
            start_location_match_method = NULL
        WHERE start_location_id = p_location_id
          AND start_location_match_method = 'auto'
          AND NOT ST_DWithin(
              ST_SetSRID(ST_MakePoint(start_longitude, start_latitude), 4326)::geography,
              ST_SetSRID(ST_MakePoint(v_lng, v_lat), 4326)::geography,
              v_radius + COALESCE((
                  SELECT gp.accuracy FROM trip_gps_points tgp
                  JOIN gps_points gp ON gp.id = tgp.gps_point_id
                  WHERE tgp.trip_id = trips.id
                  ORDER BY tgp.sequence_order ASC LIMIT 1
              ), 0)
          )
        RETURNING id
    )
    SELECT COUNT(*)::INTEGER INTO v_unmatched_start FROM cleared_starts;

    -- Un-match trip ends outside radius + accuracy
    WITH cleared_ends AS (
        UPDATE trips
        SET end_location_id = NULL,
            end_location_match_method = NULL
        WHERE end_location_id = p_location_id
          AND end_location_match_method = 'auto'
          AND NOT ST_DWithin(
              ST_SetSRID(ST_MakePoint(end_longitude, end_latitude), 4326)::geography,
              ST_SetSRID(ST_MakePoint(v_lng, v_lat), 4326)::geography,
              v_radius + COALESCE((
                  SELECT gp.accuracy FROM trip_gps_points tgp
                  JOIN gps_points gp ON gp.id = tgp.gps_point_id
                  WHERE tgp.trip_id = trips.id
                  ORDER BY tgp.sequence_order DESC LIMIT 1
              ), 0)
          )
        RETURNING id
    )
    SELECT COUNT(*)::INTEGER INTO v_unmatched_end FROM cleared_ends;

    -- Un-match clusters outside radius + centroid accuracy
    WITH cleared_clusters AS (
        UPDATE stationary_clusters
        SET matched_location_id = NULL
        WHERE matched_location_id = p_location_id
          AND NOT ST_DWithin(
              ST_SetSRID(ST_MakePoint(centroid_longitude, centroid_latitude), 4326)::geography,
              ST_SetSRID(ST_MakePoint(v_lng, v_lat), 4326)::geography,
              v_radius + COALESCE(centroid_accuracy, 0)
          )
        RETURNING id
    )
    SELECT COUNT(*)::INTEGER INTO v_unmatched_clusters FROM cleared_clusters;

    -- =========================================================================
    -- STEP 2: MATCH unmatched trips/clusters that now fall within the zone
    -- =========================================================================

    -- Match unmatched trip starts
    WITH new_starts AS (
        UPDATE trips
        SET start_location_id = p_location_id,
            start_location_match_method = 'auto'
        WHERE start_location_id IS NULL
          AND COALESCE(start_location_match_method, '') != 'manual'
          AND ST_DWithin(
              ST_SetSRID(ST_MakePoint(start_longitude, start_latitude), 4326)::geography,
              ST_SetSRID(ST_MakePoint(v_lng, v_lat), 4326)::geography,
              v_radius + COALESCE((
                  SELECT gp.accuracy FROM trip_gps_points tgp
                  JOIN gps_points gp ON gp.id = tgp.gps_point_id
                  WHERE tgp.trip_id = trips.id
                  ORDER BY tgp.sequence_order ASC LIMIT 1
              ), 0)
          )
        RETURNING id
    )
    SELECT COUNT(*)::INTEGER INTO v_newly_matched_start FROM new_starts;

    -- Match unmatched trip ends
    WITH new_ends AS (
        UPDATE trips
        SET end_location_id = p_location_id,
            end_location_match_method = 'auto'
        WHERE end_location_id IS NULL
          AND COALESCE(end_location_match_method, '') != 'manual'
          AND ST_DWithin(
              ST_SetSRID(ST_MakePoint(end_longitude, end_latitude), 4326)::geography,
              ST_SetSRID(ST_MakePoint(v_lng, v_lat), 4326)::geography,
              v_radius + COALESCE((
                  SELECT gp.accuracy FROM trip_gps_points tgp
                  JOIN gps_points gp ON gp.id = tgp.gps_point_id
                  WHERE tgp.trip_id = trips.id
                  ORDER BY tgp.sequence_order DESC LIMIT 1
              ), 0)
          )
        RETURNING id
    )
    SELECT COUNT(*)::INTEGER INTO v_newly_matched_end FROM new_ends;

    -- Match unmatched clusters
    WITH new_clusters AS (
        UPDATE stationary_clusters
        SET matched_location_id = p_location_id
        WHERE matched_location_id IS NULL
          AND ST_DWithin(
              ST_SetSRID(ST_MakePoint(centroid_longitude, centroid_latitude), 4326)::geography,
              ST_SetSRID(ST_MakePoint(v_lng, v_lat), 4326)::geography,
              v_radius + COALESCE(centroid_accuracy, 0)
          )
        RETURNING id
    )
    SELECT COUNT(*)::INTEGER INTO v_newly_matched_clusters FROM new_clusters;

    RETURN QUERY SELECT v_newly_matched_start, v_newly_matched_end,
                        v_unmatched_start, v_unmatched_end,
                        v_newly_matched_clusters, v_unmatched_clusters;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
