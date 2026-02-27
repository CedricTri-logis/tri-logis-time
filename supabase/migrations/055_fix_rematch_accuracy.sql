-- Fix rematch_trips_near_location to include GPS accuracy buffer
-- Bug: was using only location radius, ignoring GPS point accuracy
-- This caused trip endpoints whose center fell just outside a geofence
-- to be missed, even when their accuracy circle overlapped it.
-- All other matching functions (match_trip_to_location, detect_trips,
-- rematch_all_trip_locations) already correctly use radius + accuracy.

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

    -- Match unmatched trip starts within radius + GPS accuracy (skip manual overrides)
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

    -- Match unmatched trip ends within radius + GPS accuracy (skip manual overrides)
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

    RETURN QUERY SELECT v_start_count, v_end_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION rematch_trips_near_location IS 'Re-match unmatched trip endpoints near a location after creation. Uses location radius + GPS accuracy buffer. Skips manually overridden matches.';
