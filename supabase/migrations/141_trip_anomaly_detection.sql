-- Migration 141: Trip Anomaly Detection — Expected route columns
-- Stores OSRM-computed expected distance and duration for known-to-known trips.
-- Used by get_day_approval_detail to flag anomalous trips.

ALTER TABLE trips
    ADD COLUMN IF NOT EXISTS expected_distance_km DECIMAL(8, 3),
    ADD COLUMN IF NOT EXISTS expected_duration_seconds INTEGER;

COMMENT ON COLUMN trips.expected_distance_km IS 'OSRM optimal road distance between start and end locations (NULL if either endpoint unknown)';
COMMENT ON COLUMN trips.expected_duration_seconds IS 'OSRM estimated travel time in seconds between start and end locations (NULL if either endpoint unknown)';
