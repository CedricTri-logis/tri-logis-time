-- =============================================================================
-- Migration 081: Clock Event → Cluster / Location Linking
-- =============================================================================
-- Adds 4 nullable FK columns to shifts so that every clock-in and clock-out
-- can be associated with a stationary cluster and/or a known location.
--
-- 1. Schema: 4 new columns + 4 partial indexes
-- 2. Backfill clock-in  → nearest cluster on the same shift (within 50 m)
-- 3. Backfill clock-out → nearest cluster on the same shift (within 50 m)
-- 4. Backfill standalone clock-in  location match (no cluster found)
-- 5. Backfill standalone clock-out location match (no cluster found)
-- =============================================================================

-- =============================================================================
-- 1. Schema additions
-- =============================================================================
ALTER TABLE shifts ADD COLUMN IF NOT EXISTS clock_in_cluster_id UUID
    REFERENCES stationary_clusters(id) ON DELETE SET NULL;

ALTER TABLE shifts ADD COLUMN IF NOT EXISTS clock_out_cluster_id UUID
    REFERENCES stationary_clusters(id) ON DELETE SET NULL;

ALTER TABLE shifts ADD COLUMN IF NOT EXISTS clock_in_location_id UUID
    REFERENCES locations(id) ON DELETE SET NULL;

ALTER TABLE shifts ADD COLUMN IF NOT EXISTS clock_out_location_id UUID
    REFERENCES locations(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_shifts_clock_in_cluster
    ON shifts(clock_in_cluster_id) WHERE clock_in_cluster_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_shifts_clock_out_cluster
    ON shifts(clock_out_cluster_id) WHERE clock_out_cluster_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_shifts_clock_in_location
    ON shifts(clock_in_location_id) WHERE clock_in_location_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_shifts_clock_out_location
    ON shifts(clock_out_location_id) WHERE clock_out_location_id IS NOT NULL;

-- =============================================================================
-- 2. Backfill clock-in → nearest cluster on the same shift (within 50 m)
-- =============================================================================
UPDATE shifts s
SET
    clock_in_cluster_id  = sub.cluster_id,
    clock_in_location_id = sub.matched_location_id
FROM (
    SELECT DISTINCT ON (s2.id)
        s2.id AS shift_id,
        sc.id AS cluster_id,
        sc.matched_location_id
    FROM shifts s2
    JOIN stationary_clusters sc ON sc.shift_id = s2.id
    WHERE s2.clock_in_location IS NOT NULL
      AND ST_DWithin(
            ST_SetSRID(ST_MakePoint(
                (s2.clock_in_location->>'longitude')::DOUBLE PRECISION,
                (s2.clock_in_location->>'latitude')::DOUBLE PRECISION
            ), 4326)::geography,
            ST_SetSRID(ST_MakePoint(
                sc.centroid_longitude::DOUBLE PRECISION,
                sc.centroid_latitude::DOUBLE PRECISION
            ), 4326)::geography,
            50
          )
    ORDER BY s2.id,
             ST_Distance(
                ST_SetSRID(ST_MakePoint(
                    (s2.clock_in_location->>'longitude')::DOUBLE PRECISION,
                    (s2.clock_in_location->>'latitude')::DOUBLE PRECISION
                ), 4326)::geography,
                ST_SetSRID(ST_MakePoint(
                    sc.centroid_longitude::DOUBLE PRECISION,
                    sc.centroid_latitude::DOUBLE PRECISION
                ), 4326)::geography
             ) ASC
) sub
WHERE s.id = sub.shift_id;

-- =============================================================================
-- 3. Backfill clock-out → nearest cluster on the same shift (within 50 m)
-- =============================================================================
UPDATE shifts s
SET
    clock_out_cluster_id  = sub.cluster_id,
    clock_out_location_id = sub.matched_location_id
FROM (
    SELECT DISTINCT ON (s2.id)
        s2.id AS shift_id,
        sc.id AS cluster_id,
        sc.matched_location_id
    FROM shifts s2
    JOIN stationary_clusters sc ON sc.shift_id = s2.id
    WHERE s2.clock_out_location IS NOT NULL
      AND s2.clocked_out_at IS NOT NULL
      AND ST_DWithin(
            ST_SetSRID(ST_MakePoint(
                (s2.clock_out_location->>'longitude')::DOUBLE PRECISION,
                (s2.clock_out_location->>'latitude')::DOUBLE PRECISION
            ), 4326)::geography,
            ST_SetSRID(ST_MakePoint(
                sc.centroid_longitude::DOUBLE PRECISION,
                sc.centroid_latitude::DOUBLE PRECISION
            ), 4326)::geography,
            50
          )
    ORDER BY s2.id,
             ST_Distance(
                ST_SetSRID(ST_MakePoint(
                    (s2.clock_out_location->>'longitude')::DOUBLE PRECISION,
                    (s2.clock_out_location->>'latitude')::DOUBLE PRECISION
                ), 4326)::geography,
                ST_SetSRID(ST_MakePoint(
                    sc.centroid_longitude::DOUBLE PRECISION,
                    sc.centroid_latitude::DOUBLE PRECISION
                ), 4326)::geography
             ) ASC
) sub
WHERE s.id = sub.shift_id;

-- =============================================================================
-- 4. Backfill standalone clock-in location match (no cluster found)
-- =============================================================================
UPDATE shifts s
SET clock_in_location_id = match_trip_to_location(
        (s.clock_in_location->>'latitude')::DECIMAL,
        (s.clock_in_location->>'longitude')::DECIMAL,
        COALESCE(s.clock_in_accuracy, 20)
    )
WHERE s.clock_in_location IS NOT NULL
  AND s.clock_in_cluster_id IS NULL
  AND s.clock_in_location_id IS NULL;

-- =============================================================================
-- 5. Backfill standalone clock-out location match (no cluster found)
-- =============================================================================
UPDATE shifts s
SET clock_out_location_id = match_trip_to_location(
        (s.clock_out_location->>'latitude')::DECIMAL,
        (s.clock_out_location->>'longitude')::DECIMAL,
        COALESCE(s.clock_out_accuracy, 20)
    )
WHERE s.clock_out_location IS NOT NULL
  AND s.clocked_out_at IS NOT NULL
  AND s.clock_out_cluster_id IS NULL
  AND s.clock_out_location_id IS NULL;
