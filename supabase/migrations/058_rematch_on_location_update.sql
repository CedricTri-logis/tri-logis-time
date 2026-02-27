-- =============================================================================
-- 058: Rematch trips when a location's position or radius is updated
-- =============================================================================
-- When an admin edits a location's coordinates or geofence radius, trips that
-- were auto-matched to this location may no longer fall within the new zone,
-- and new unmatched trips may now fall within it.
--
-- This function:
-- 1. UN-matches auto-matched trips whose endpoints are now outside the zone
-- 2. Matches unmatched trips whose endpoints are now inside the zone
-- 3. Skips manual overrides in both directions
-- =============================================================================

CREATE OR REPLACE FUNCTION rematch_trips_for_updated_location(p_location_id UUID)
RETURNS TABLE (
    newly_matched_start INTEGER,
    newly_matched_end INTEGER,
    unmatched_start INTEGER,
    unmatched_end INTEGER
) AS $$
DECLARE
    v_lat DOUBLE PRECISION;
    v_lng DOUBLE PRECISION;
    v_radius DOUBLE PRECISION;
    v_newly_matched_start INTEGER := 0;
    v_newly_matched_end INTEGER := 0;
    v_unmatched_start INTEGER := 0;
    v_unmatched_end INTEGER := 0;
BEGIN
    -- Fetch updated location coordinates and radius
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

    -- =========================================================================
    -- STEP 1: UN-MATCH auto-matched trips that no longer fall within the zone
    -- =========================================================================

    -- Un-match starts that are now outside radius + accuracy
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

    -- Un-match ends that are now outside radius + accuracy
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

    -- =========================================================================
    -- STEP 2: MATCH unmatched trips that now fall within the zone
    -- =========================================================================

    -- Match unmatched starts within radius + accuracy
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

    -- Match unmatched ends within radius + accuracy
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

    RETURN QUERY SELECT v_newly_matched_start, v_newly_matched_end, v_unmatched_start, v_unmatched_end;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION rematch_trips_for_updated_location IS
    'After editing a location position/radius: un-matches auto trips now outside the zone, matches unmatched trips now inside. Skips manual overrides.';
