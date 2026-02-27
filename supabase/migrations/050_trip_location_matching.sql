-- =============================================================================
-- 050: Trip Location Matching — Match Method Columns + Helper Function
-- Feature: Trip-to-location geofence matching
-- =============================================================================
-- Adds match method tracking columns to trips, updates FK constraints to
-- ON DELETE SET NULL (so deleting a location doesn't cascade-delete trips),
-- adds indexes for location lookups, and creates a PostGIS helper function
-- to find the nearest active location geofence for a given GPS coordinate.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Add match method columns to trips
-- -----------------------------------------------------------------------------
ALTER TABLE trips
    ADD COLUMN IF NOT EXISTS start_location_match_method TEXT DEFAULT 'auto'
        CHECK (start_location_match_method IN ('auto', 'manual')),
    ADD COLUMN IF NOT EXISTS end_location_match_method TEXT DEFAULT 'auto'
        CHECK (end_location_match_method IN ('auto', 'manual'));

COMMENT ON COLUMN trips.start_location_match_method IS 'How start_location_id was assigned: auto (geofence match) or manual (admin override)';
COMMENT ON COLUMN trips.end_location_match_method IS 'How end_location_id was assigned: auto (geofence match) or manual (admin override)';

-- -----------------------------------------------------------------------------
-- 2. Update FK constraints to ON DELETE SET NULL
-- -----------------------------------------------------------------------------
-- Original FKs from migration 032 lack ON DELETE SET NULL, so deleting a
-- location would fail with a FK violation. We want soft-unlinking instead.
ALTER TABLE trips DROP CONSTRAINT IF EXISTS trips_start_location_id_fkey;
ALTER TABLE trips DROP CONSTRAINT IF EXISTS trips_end_location_id_fkey;

ALTER TABLE trips
    ADD CONSTRAINT trips_start_location_id_fkey
        FOREIGN KEY (start_location_id) REFERENCES locations(id) ON DELETE SET NULL,
    ADD CONSTRAINT trips_end_location_id_fkey
        FOREIGN KEY (end_location_id) REFERENCES locations(id) ON DELETE SET NULL;

-- -----------------------------------------------------------------------------
-- 3. Indexes for location FK lookups
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_trips_start_location_id ON trips(start_location_id);
CREATE INDEX IF NOT EXISTS idx_trips_end_location_id ON trips(end_location_id);

-- -----------------------------------------------------------------------------
-- 4. match_trip_to_location() — find nearest active geofence for a GPS point
-- -----------------------------------------------------------------------------
-- Returns the UUID of the closest active location whose geofence circle
-- (radius_meters + GPS accuracy buffer) contains the given coordinate,
-- or NULL if no location matches.
CREATE OR REPLACE FUNCTION match_trip_to_location(
    p_latitude DECIMAL,
    p_longitude DECIMAL,
    p_accuracy_meters DECIMAL DEFAULT 0
)
RETURNS UUID AS $$
DECLARE
    v_location_id UUID;
BEGIN
    SELECT l.id INTO v_location_id
    FROM locations l
    WHERE l.is_active = TRUE
      AND ST_DWithin(
          l.location,
          ST_SetSRID(ST_MakePoint(p_longitude, p_latitude), 4326)::geography,
          l.radius_meters + COALESCE(p_accuracy_meters, 0)
      )
    ORDER BY ST_Distance(
        l.location,
        ST_SetSRID(ST_MakePoint(p_longitude, p_latitude), 4326)::geography
    ) ASC
    LIMIT 1;

    RETURN v_location_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

COMMENT ON FUNCTION match_trip_to_location IS 'Find the nearest active location geofence containing the given GPS coordinate (with optional accuracy buffer)';
