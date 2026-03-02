-- =============================================================================
-- 105: Extend rematch RPCs to handle clock-in/out location linking on shifts
-- =============================================================================
-- FIXES: When a location is updated or created, shifts.clock_in_location_id
-- and shifts.clock_out_location_id are now correctly updated. Previously, only
-- trips.start/end_location_id and stationary_clusters.matched_location_id were
-- updated, causing clock-in/out events to remain as "suggested locations" even
-- after a location was modified to cover them.
--
-- Two cases handled per clock event:
--   1. Direct match (clock_in_cluster_id IS NULL): the clock-in GPS coordinate
--      is matched directly to the updated/new location geofence.
--   2. Cluster propagation (clock_in_cluster_id IS NOT NULL): after a cluster
--      is matched/un-matched to a location, that change is propagated to the
--      shift's clock_in_location_id.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. rematch_trips_for_updated_location: called when editing a location
--    Now also handles clock-in/out location linking on shifts.
-- ─────────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS rematch_trips_for_updated_location(UUID);

CREATE OR REPLACE FUNCTION rematch_trips_for_updated_location(p_location_id UUID)
RETURNS TABLE (
    newly_matched_start INTEGER,
    newly_matched_end INTEGER,
    unmatched_start INTEGER,
    unmatched_end INTEGER,
    newly_matched_clusters INTEGER,
    unmatched_clusters INTEGER,
    newly_matched_shifts INTEGER,
    unmatched_shifts INTEGER
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
    v_newly_matched_shifts INTEGER := 0;
    v_unmatched_shifts INTEGER := 0;
BEGIN
    SELECT
        ST_Y(l.location::geometry),
        ST_X(l.location::geometry),
        l.radius_meters
    INTO v_lat, v_lng, v_radius
    FROM locations l
    WHERE l.id = p_location_id AND l.is_active = TRUE;

    IF v_lat IS NULL THEN
        RETURN QUERY SELECT 0, 0, 0, 0, 0, 0, 0, 0;
        RETURN;
    END IF;

    -- =========================================================================
    -- STEP 1: UN-MATCH trips/clusters/shifts outside the zone
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

    -- Un-match shifts: cluster-based clock-in/out whose cluster is no longer matched here
    -- (runs after cluster un-match above, so stationary_clusters reflects updated state)
    WITH cleared_clock_in AS (
        UPDATE shifts
        SET clock_in_location_id = NULL
        WHERE clock_in_location_id = p_location_id
          AND clock_in_cluster_id IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM stationary_clusters sc
              WHERE sc.id = shifts.clock_in_cluster_id
                AND sc.matched_location_id = p_location_id
          )
        RETURNING id
    ),
    cleared_clock_out AS (
        UPDATE shifts
        SET clock_out_location_id = NULL
        WHERE clock_out_location_id = p_location_id
          AND clock_out_cluster_id IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM stationary_clusters sc
              WHERE sc.id = shifts.clock_out_cluster_id
                AND sc.matched_location_id = p_location_id
          )
        RETURNING id
    )
    SELECT
        (SELECT COUNT(*)::INTEGER FROM cleared_clock_in) +
        (SELECT COUNT(*)::INTEGER FROM cleared_clock_out)
    INTO v_unmatched_shifts;

    -- Un-match shifts: direct clock-in/out (no cluster) whose coordinate is now outside zone
    WITH cleared_direct_in AS (
        UPDATE shifts
        SET clock_in_location_id = NULL
        WHERE clock_in_location_id = p_location_id
          AND clock_in_cluster_id IS NULL
          AND clock_in_location IS NOT NULL
          AND NOT ST_DWithin(
              ST_SetSRID(ST_MakePoint(
                  (clock_in_location->>'longitude')::DOUBLE PRECISION,
                  (clock_in_location->>'latitude')::DOUBLE PRECISION
              ), 4326)::geography,
              ST_SetSRID(ST_MakePoint(v_lng, v_lat), 4326)::geography,
              v_radius + COALESCE((clock_in_location->>'accuracy')::DOUBLE PRECISION, 20)
          )
        RETURNING id
    ),
    cleared_direct_out AS (
        UPDATE shifts
        SET clock_out_location_id = NULL
        WHERE clock_out_location_id = p_location_id
          AND clock_out_cluster_id IS NULL
          AND clock_out_location IS NOT NULL
          AND NOT ST_DWithin(
              ST_SetSRID(ST_MakePoint(
                  (clock_out_location->>'longitude')::DOUBLE PRECISION,
                  (clock_out_location->>'latitude')::DOUBLE PRECISION
              ), 4326)::geography,
              ST_SetSRID(ST_MakePoint(v_lng, v_lat), 4326)::geography,
              v_radius + COALESCE((clock_out_location->>'accuracy')::DOUBLE PRECISION, 20)
          )
        RETURNING id
    )
    SELECT v_unmatched_shifts +
        (SELECT COUNT(*)::INTEGER FROM cleared_direct_in) +
        (SELECT COUNT(*)::INTEGER FROM cleared_direct_out)
    INTO v_unmatched_shifts;

    -- =========================================================================
    -- STEP 2: MATCH unmatched trips/clusters/shifts now inside the zone
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

    -- Match unmatched clusters inside zone
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

    -- Match shifts: cluster-based clock-in/out whose cluster is now matched here
    -- (runs after cluster match above, so stationary_clusters reflects updated state)
    WITH new_clock_in AS (
        UPDATE shifts
        SET clock_in_location_id = p_location_id
        WHERE clock_in_location_id IS NULL
          AND clock_in_cluster_id IS NOT NULL
          AND EXISTS (
              SELECT 1 FROM stationary_clusters sc
              WHERE sc.id = shifts.clock_in_cluster_id
                AND sc.matched_location_id = p_location_id
          )
        RETURNING id
    ),
    new_clock_out AS (
        UPDATE shifts
        SET clock_out_location_id = p_location_id
        WHERE clock_out_location_id IS NULL
          AND clock_out_cluster_id IS NOT NULL
          AND EXISTS (
              SELECT 1 FROM stationary_clusters sc
              WHERE sc.id = shifts.clock_out_cluster_id
                AND sc.matched_location_id = p_location_id
          )
        RETURNING id
    )
    SELECT
        (SELECT COUNT(*)::INTEGER FROM new_clock_in) +
        (SELECT COUNT(*)::INTEGER FROM new_clock_out)
    INTO v_newly_matched_shifts;

    -- Match shifts: direct clock-in/out (no cluster) whose coordinate is now inside zone
    WITH new_direct_in AS (
        UPDATE shifts
        SET clock_in_location_id = p_location_id
        WHERE clock_in_location_id IS NULL
          AND clock_in_cluster_id IS NULL
          AND clock_in_location IS NOT NULL
          AND COALESCE((clock_in_location->>'accuracy')::DOUBLE PRECISION, 20) <= 50
          AND ST_DWithin(
              ST_SetSRID(ST_MakePoint(
                  (clock_in_location->>'longitude')::DOUBLE PRECISION,
                  (clock_in_location->>'latitude')::DOUBLE PRECISION
              ), 4326)::geography,
              ST_SetSRID(ST_MakePoint(v_lng, v_lat), 4326)::geography,
              v_radius + COALESCE((clock_in_location->>'accuracy')::DOUBLE PRECISION, 20)
          )
        RETURNING id
    ),
    new_direct_out AS (
        UPDATE shifts
        SET clock_out_location_id = p_location_id
        WHERE clock_out_location_id IS NULL
          AND clock_out_cluster_id IS NULL
          AND clock_out_location IS NOT NULL
          AND COALESCE((clock_out_location->>'accuracy')::DOUBLE PRECISION, 20) <= 50
          AND ST_DWithin(
              ST_SetSRID(ST_MakePoint(
                  (clock_out_location->>'longitude')::DOUBLE PRECISION,
                  (clock_out_location->>'latitude')::DOUBLE PRECISION
              ), 4326)::geography,
              ST_SetSRID(ST_MakePoint(v_lng, v_lat), 4326)::geography,
              v_radius + COALESCE((clock_out_location->>'accuracy')::DOUBLE PRECISION, 20)
          )
        RETURNING id
    )
    SELECT v_newly_matched_shifts +
        (SELECT COUNT(*)::INTEGER FROM new_direct_in) +
        (SELECT COUNT(*)::INTEGER FROM new_direct_out)
    INTO v_newly_matched_shifts;

    RETURN QUERY SELECT
        v_newly_matched_start, v_newly_matched_end,
        v_unmatched_start, v_unmatched_end,
        v_newly_matched_clusters, v_unmatched_clusters,
        v_newly_matched_shifts, v_unmatched_shifts;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. rematch_trips_near_location: called when creating a new location
--    Now also handles clock-in/out location linking on shifts.
-- ─────────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS rematch_trips_near_location(UUID);

CREATE OR REPLACE FUNCTION rematch_trips_near_location(p_location_id UUID)
RETURNS TABLE (matched_start INTEGER, matched_end INTEGER, matched_clusters INTEGER, matched_shifts INTEGER) AS $$
DECLARE
    v_lat DOUBLE PRECISION;
    v_lng DOUBLE PRECISION;
    v_radius DOUBLE PRECISION;
    v_start_count INTEGER := 0;
    v_end_count INTEGER := 0;
    v_cluster_count INTEGER := 0;
    v_shift_count INTEGER := 0;
BEGIN
    SELECT
        ST_Y(l.location::geometry),
        ST_X(l.location::geometry),
        l.radius_meters
    INTO v_lat, v_lng, v_radius
    FROM locations l
    WHERE l.id = p_location_id AND l.is_active = TRUE;

    IF v_lat IS NULL THEN
        RETURN QUERY SELECT 0, 0, 0, 0;
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

    -- Match shifts: cluster-based clock-in/out whose cluster is now matched here
    -- (runs after cluster match above)
    WITH new_clock_in AS (
        UPDATE shifts
        SET clock_in_location_id = p_location_id
        WHERE clock_in_location_id IS NULL
          AND clock_in_cluster_id IS NOT NULL
          AND EXISTS (
              SELECT 1 FROM stationary_clusters sc
              WHERE sc.id = shifts.clock_in_cluster_id
                AND sc.matched_location_id = p_location_id
          )
        RETURNING id
    ),
    new_clock_out AS (
        UPDATE shifts
        SET clock_out_location_id = p_location_id
        WHERE clock_out_location_id IS NULL
          AND clock_out_cluster_id IS NOT NULL
          AND EXISTS (
              SELECT 1 FROM stationary_clusters sc
              WHERE sc.id = shifts.clock_out_cluster_id
                AND sc.matched_location_id = p_location_id
          )
        RETURNING id
    )
    SELECT
        (SELECT COUNT(*)::INTEGER FROM new_clock_in) +
        (SELECT COUNT(*)::INTEGER FROM new_clock_out)
    INTO v_shift_count;

    -- Match shifts: direct clock-in/out (no cluster) inside zone
    WITH new_direct_in AS (
        UPDATE shifts
        SET clock_in_location_id = p_location_id
        WHERE clock_in_location_id IS NULL
          AND clock_in_cluster_id IS NULL
          AND clock_in_location IS NOT NULL
          AND COALESCE((clock_in_location->>'accuracy')::DOUBLE PRECISION, 20) <= 50
          AND ST_DWithin(
              ST_SetSRID(ST_MakePoint(
                  (clock_in_location->>'longitude')::DOUBLE PRECISION,
                  (clock_in_location->>'latitude')::DOUBLE PRECISION
              ), 4326)::geography,
              ST_SetSRID(ST_MakePoint(v_lng, v_lat), 4326)::geography,
              v_radius + COALESCE((clock_in_location->>'accuracy')::DOUBLE PRECISION, 20)
          )
        RETURNING id
    ),
    new_direct_out AS (
        UPDATE shifts
        SET clock_out_location_id = p_location_id
        WHERE clock_out_location_id IS NULL
          AND clock_out_cluster_id IS NULL
          AND clock_out_location IS NOT NULL
          AND COALESCE((clock_out_location->>'accuracy')::DOUBLE PRECISION, 20) <= 50
          AND ST_DWithin(
              ST_SetSRID(ST_MakePoint(
                  (clock_out_location->>'longitude')::DOUBLE PRECISION,
                  (clock_out_location->>'latitude')::DOUBLE PRECISION
              ), 4326)::geography,
              ST_SetSRID(ST_MakePoint(v_lng, v_lat), 4326)::geography,
              v_radius + COALESCE((clock_out_location->>'accuracy')::DOUBLE PRECISION, 20)
          )
        RETURNING id
    )
    SELECT v_shift_count +
        (SELECT COUNT(*)::INTEGER FROM new_direct_in) +
        (SELECT COUNT(*)::INTEGER FROM new_direct_out)
    INTO v_shift_count;

    RETURN QUERY SELECT v_start_count, v_end_count, v_cluster_count, v_shift_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION rematch_trips_for_updated_location IS
    'After editing a location position/radius: un-matches auto trips/clusters/shifts now outside the zone, matches unmatched trips/clusters/shifts now inside. Skips manual overrides.';

COMMENT ON FUNCTION rematch_trips_near_location IS
    'After creating a new location: matches unmatched trips, clusters, and clock-in/out events within the geofence.';
