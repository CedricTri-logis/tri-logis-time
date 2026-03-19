-- Geocode cache: stores reverse-geocoded addresses to avoid duplicate Google API calls.
-- Points within ~55m share the same address (matches DBSCAN eps=0.0005 used in cluster grouping).

CREATE TABLE IF NOT EXISTS geocode_cache (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    location GEOGRAPHY(POINT, 4326) NOT NULL,
    formatted_address TEXT NOT NULL,
    place_name TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_geocode_cache_location
    ON geocode_cache USING GIST (location);

ALTER TABLE geocode_cache ENABLE ROW LEVEL SECURITY;

CREATE POLICY geocode_cache_read ON geocode_cache
    FOR SELECT TO authenticated USING (true);

COMMENT ON TABLE geocode_cache IS 'Cache of reverse-geocoded addresses. Used by approval views and suggested locations to display addresses for GPS points that don''t match any known location. Points within 55m share a single cached entry.';
COMMENT ON COLUMN geocode_cache.location IS 'PostGIS point (SRID 4326) — the geocoded GPS coordinate';
COMMENT ON COLUMN geocode_cache.formatted_address IS 'Full address from Google reverse geocoding (fr locale)';
COMMENT ON COLUMN geocode_cache.place_name IS 'Business/POI name from Google Places Nearby (null if none found)';

-- RPC for the API route to check cache by proximity
CREATE OR REPLACE FUNCTION find_geocode_cache(
    p_lat DOUBLE PRECISION,
    p_lng DOUBLE PRECISION,
    p_radius DOUBLE PRECISION DEFAULT 55
)
RETURNS TABLE (
    formatted_address TEXT,
    place_name TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT gc.formatted_address, gc.place_name
    FROM geocode_cache gc
    WHERE ST_DWithin(
        gc.location,
        ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography,
        p_radius
    )
    ORDER BY ST_Distance(
        gc.location,
        ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography
    )
    LIMIT 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path TO public, extensions;
