-- =============================================================================
-- 132: Add estimated_distance_km column to trips
-- =============================================================================
-- Tracks how much of road_distance_km is estimated via OSRM /route
-- (as opposed to GPS-matched via /match). Allows displaying
-- "18.3 km (dont 4.2 km estimes)" in the dashboard.
-- =============================================================================

ALTER TABLE trips ADD COLUMN IF NOT EXISTS estimated_distance_km DECIMAL(8,3) DEFAULT 0;
COMMENT ON COLUMN trips.estimated_distance_km IS 'Portion of road_distance_km estimated via OSRM /route (not GPS-matched)';
