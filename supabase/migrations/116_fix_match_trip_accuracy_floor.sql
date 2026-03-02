-- =============================================================================
-- 116: Apply 10m accuracy floor in match_trip_to_location
-- =============================================================================
-- BUG: detect_trips passes the cluster centroid_accuracy to match_trip_to_location
-- for trip endpoint matching. Centroid accuracy is computed as:
--     1.0 / SQRT(SUM(1.0 / GREATEST(acc * acc, 1)))
-- This formula measures the statistical precision of the centroid MEAN, not
-- the typical GPS scatter. With many GPS points at 5m accuracy, this value
-- collapses to <2m:
--     N=10 points @ 5m → centroid_acc ≈ 1.6m
--     N=20 points @ 5m → centroid_acc ≈ 1.1m
--
-- Result: match threshold = radius + centroid_acc ≈ 10 + 1.5 = 11.5m
--         which misses trip endpoints at 12m from a 10m geofence even though
--         the raw GPS accuracy is 5.4m (threshold should be 15.4m).
--
-- FIX: Apply a minimum of 10m to p_accuracy_meters inside match_trip_to_location.
--      10m represents a reasonable GPS error floor for typical outdoor conditions.
--      This does not affect clock-event matching (which already uses raw GPS
--      accuracy from the phone, typically 5-20m) — it only tightens centroid-
--      based calls that were previously over-precise.
--
-- BACKFILL: rematch all unmatched trip endpoints using the fixed function.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Update match_trip_to_location with 10m accuracy floor
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION match_trip_to_location(
    p_latitude  DECIMAL,
    p_longitude DECIMAL,
    p_accuracy_meters DECIMAL DEFAULT 0
)
RETURNS UUID AS $$
DECLARE
    v_location_id UUID;
    -- Floor at 10m: centroid_accuracy can collapse to <2m with many GPS points,
    -- causing misses on tight geofences. 10m reflects realistic GPS scatter.
    v_effective_accuracy DECIMAL := GREATEST(COALESCE(p_accuracy_meters, 0), 10.0);
BEGIN
    SELECT l.id INTO v_location_id
    FROM locations l
    WHERE l.is_active = TRUE
      AND ST_DWithin(
          l.location,
          ST_SetSRID(ST_MakePoint(p_longitude, p_latitude), 4326)::geography,
          l.radius_meters + v_effective_accuracy
      )
    ORDER BY ST_Distance(
        l.location,
        ST_SetSRID(ST_MakePoint(p_longitude, p_latitude), 4326)::geography
    ) ASC
    LIMIT 1;

    RETURN v_location_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Backfill: rematch all unmatched trip endpoints
--    (trips from completed shifts in last 90 days)
-- ─────────────────────────────────────────────────────────────────────────────
SET search_path TO extensions, public, pg_catalog;

-- Trip ends
UPDATE trips t SET
    end_location_id = match_trip_to_location(
        t.end_latitude::DECIMAL,
        t.end_longitude::DECIMAL,
        COALESCE(
            (SELECT gp.accuracy FROM trip_gps_points tgp
             JOIN gps_points gp ON gp.id = tgp.gps_point_id
             WHERE tgp.trip_id = t.id
             ORDER BY tgp.sequence_order DESC LIMIT 1),
            20
        )
    )
FROM shifts s
WHERE t.shift_id = s.id
  AND t.end_location_id IS NULL
  AND s.clocked_out_at IS NOT NULL
  AND s.clocked_in_at >= NOW() - INTERVAL '90 days'
  AND t.end_latitude IS NOT NULL;

-- Trip starts
UPDATE trips t SET
    start_location_id = match_trip_to_location(
        t.start_latitude::DECIMAL,
        t.start_longitude::DECIMAL,
        COALESCE(
            (SELECT gp.accuracy FROM trip_gps_points tgp
             JOIN gps_points gp ON gp.id = tgp.gps_point_id
             WHERE tgp.trip_id = t.id
             ORDER BY tgp.sequence_order ASC LIMIT 1),
            20
        )
    )
FROM shifts s
WHERE t.shift_id = s.id
  AND t.start_location_id IS NULL
  AND s.clocked_out_at IS NOT NULL
  AND s.clocked_in_at >= NOW() - INTERVAL '90 days'
  AND t.start_latitude IS NOT NULL;
