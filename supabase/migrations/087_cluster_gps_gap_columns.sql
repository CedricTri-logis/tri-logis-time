-- Migration 087: Add GPS gap tracking columns
-- stationary_clusters: track total missing GPS time and gap count
-- trips: flag trips created across GPS gaps (no GPS trace)

ALTER TABLE stationary_clusters
  ADD COLUMN gps_gap_seconds INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN gps_gap_count INTEGER NOT NULL DEFAULT 0;

ALTER TABLE trips
  ADD COLUMN has_gps_gap BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN stationary_clusters.gps_gap_seconds IS 'Total seconds of GPS gaps > 5 min within this cluster (excess over 5-min grace period)';
COMMENT ON COLUMN stationary_clusters.gps_gap_count IS 'Number of individual GPS gaps > 5 min within this cluster';
COMMENT ON COLUMN trips.has_gps_gap IS 'TRUE when trip was created across a GPS gap with no/minimal GPS trace';
