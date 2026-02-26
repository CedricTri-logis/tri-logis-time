-- =============================================================================
-- 043: Route Map Matching - Add route geometry and matching status to trips
-- Feature: 018-route-map-matching
-- =============================================================================

-- Route geometry: encoded polyline (polyline6 format) from OSRM
ALTER TABLE trips ADD COLUMN route_geometry TEXT;

-- Road-based distance from OSRM (replaces Haversine estimate when available)
ALTER TABLE trips ADD COLUMN road_distance_km DECIMAL(8, 3);

-- Matching status lifecycle
ALTER TABLE trips ADD COLUMN match_status TEXT NOT NULL DEFAULT 'pending'
    CHECK (match_status IN ('pending', 'processing', 'matched', 'failed', 'anomalous'));

-- OSRM matching confidence (0.00 to 1.00)
ALTER TABLE trips ADD COLUMN match_confidence DECIMAL(3, 2)
    CHECK (match_confidence IS NULL OR (match_confidence >= 0 AND match_confidence <= 1));

-- Error details for failed/anomalous matches
ALTER TABLE trips ADD COLUMN match_error TEXT;

-- Timestamp when matching completed
ALTER TABLE trips ADD COLUMN matched_at TIMESTAMPTZ;

-- Retry counter (max 3 attempts)
ALTER TABLE trips ADD COLUMN match_attempts INTEGER NOT NULL DEFAULT 0;

-- Index for querying unmatched trips (batch processing, monitoring)
CREATE INDEX idx_trips_match_status ON trips(match_status);

COMMENT ON COLUMN trips.route_geometry IS 'Encoded polyline6 of road-matched route from OSRM';
COMMENT ON COLUMN trips.road_distance_km IS 'Road-based distance in km from OSRM (replaces Haversine when matched)';
COMMENT ON COLUMN trips.match_status IS 'Map matching lifecycle: pending→processing→matched/failed/anomalous';

-- =============================================================================
-- update_trip_match: Called by Edge Function to store matching results
-- SECURITY DEFINER to bypass RLS (Edge Function uses service role key)
-- =============================================================================
CREATE OR REPLACE FUNCTION update_trip_match(
    p_trip_id UUID,
    p_match_status TEXT,
    p_route_geometry TEXT DEFAULT NULL,
    p_road_distance_km DECIMAL DEFAULT NULL,
    p_match_confidence DECIMAL DEFAULT NULL,
    p_match_error TEXT DEFAULT NULL
) RETURNS VOID AS $$
BEGIN
    UPDATE trips SET
        match_status = p_match_status,
        route_geometry = COALESCE(p_route_geometry, route_geometry),
        road_distance_km = COALESCE(p_road_distance_km, road_distance_km),
        match_confidence = COALESCE(p_match_confidence, match_confidence),
        match_error = p_match_error,
        matched_at = NOW(),
        match_attempts = match_attempts + 1,
        -- Update distance_km with road distance when matched
        distance_km = CASE
            WHEN p_match_status = 'matched' AND p_road_distance_km IS NOT NULL
            THEN p_road_distance_km
            ELSE distance_km
        END
    WHERE id = p_trip_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
