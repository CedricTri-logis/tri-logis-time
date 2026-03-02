-- =============================================================================
-- 117: Auto-backfill location matches for completed shifts
-- =============================================================================
-- ROOT CAUSE: detect_trips is called by the Flutter app during active shifts
-- (v_create_clusters=FALSE), skipping all location-matching steps (step 7,
-- step 6.5). When the employee clocks out and closes the app, the final
-- detect_trips call with v_create_clusters=TRUE often never runs (or runs
-- too late after a timeout). This leaves clock_in/out_location_id and
-- trip start/end_location_id NULL for otherwise matchable events.
--
-- FIX:
--   1. backfill_location_matches() — fast targeted UPDATEs for all 4 event
--      types on recently completed shifts. Runs in seconds (no GPS loop).
--   2. pg_cron job every 5 minutes — catches new shifts as they complete.
--   3. One-time full backfill on migration apply.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Function: backfill_location_matches
--    Matches clock-in/out and trip endpoints for recently completed shifts
--    that still have NULL location IDs.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION backfill_location_matches(
    p_lookback_interval INTERVAL DEFAULT '90 days'
)
RETURNS TABLE (
    clock_in_matched  INTEGER,
    clock_out_matched INTEGER,
    trip_end_matched  INTEGER,
    trip_start_matched INTEGER
) AS $$
DECLARE
    v_clock_in  INTEGER := 0;
    v_clock_out INTEGER := 0;
    v_trip_end  INTEGER := 0;
    v_trip_start INTEGER := 0;
BEGIN
    -- Clock-in location matching
    WITH updated AS (
        UPDATE shifts s SET
            clock_in_location_id = match_trip_to_location(
                (s.clock_in_location->>'latitude')::DECIMAL,
                (s.clock_in_location->>'longitude')::DECIMAL,
                COALESCE(s.clock_in_accuracy, 20)
            )
        WHERE s.clocked_out_at IS NOT NULL
          AND s.clock_in_location IS NOT NULL
          AND s.clock_in_location_id IS NULL
          AND COALESCE(s.clock_in_accuracy, 20) <= 50
          AND s.clocked_in_at >= NOW() - p_lookback_interval
          AND match_trip_to_location(
              (s.clock_in_location->>'latitude')::DECIMAL,
              (s.clock_in_location->>'longitude')::DECIMAL,
              COALESCE(s.clock_in_accuracy, 20)
          ) IS NOT NULL
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_clock_in FROM updated;

    -- Clock-out location matching
    WITH updated AS (
        UPDATE shifts s SET
            clock_out_location_id = match_trip_to_location(
                (s.clock_out_location->>'latitude')::DECIMAL,
                (s.clock_out_location->>'longitude')::DECIMAL,
                COALESCE(s.clock_out_accuracy, 20)
            )
        WHERE s.clocked_out_at IS NOT NULL
          AND s.clock_out_location IS NOT NULL
          AND s.clock_out_location_id IS NULL
          AND COALESCE(s.clock_out_accuracy, 20) <= 50
          AND s.clocked_out_at >= NOW() - p_lookback_interval
          AND match_trip_to_location(
              (s.clock_out_location->>'latitude')::DECIMAL,
              (s.clock_out_location->>'longitude')::DECIMAL,
              COALESCE(s.clock_out_accuracy, 20)
          ) IS NOT NULL
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_clock_out FROM updated;

    -- Trip end location matching (using last GPS point accuracy)
    WITH updated AS (
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
          AND s.clocked_in_at >= NOW() - p_lookback_interval
          AND t.end_latitude IS NOT NULL
          AND match_trip_to_location(
              t.end_latitude::DECIMAL,
              t.end_longitude::DECIMAL,
              COALESCE(
                  (SELECT gp2.accuracy FROM trip_gps_points tgp2
                   JOIN gps_points gp2 ON gp2.id = tgp2.gps_point_id
                   WHERE tgp2.trip_id = t.id
                   ORDER BY tgp2.sequence_order DESC LIMIT 1),
                  20
              )
          ) IS NOT NULL
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_trip_end FROM updated;

    -- Trip start location matching (using first GPS point accuracy)
    WITH updated AS (
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
          AND s.clocked_in_at >= NOW() - p_lookback_interval
          AND t.start_latitude IS NOT NULL
          AND match_trip_to_location(
              t.start_latitude::DECIMAL,
              t.start_longitude::DECIMAL,
              COALESCE(
                  (SELECT gp2.accuracy FROM trip_gps_points tgp2
                   JOIN gps_points gp2 ON gp2.id = tgp2.gps_point_id
                   WHERE tgp2.trip_id = t.id
                   ORDER BY tgp2.sequence_order ASC LIMIT 1),
                  20
              )
          ) IS NOT NULL
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_trip_start FROM updated;

    RETURN QUERY SELECT v_clock_in, v_clock_out, v_trip_end, v_trip_start;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. pg_cron: run every 5 minutes on recent shifts (last 24h window)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT cron.schedule(
    'backfill-location-matches',
    '*/5 * * * *',
    $$SELECT backfill_location_matches('24 hours')$$
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. One-time full backfill (90 days)
-- ─────────────────────────────────────────────────────────────────────────────
SET search_path TO extensions, public, pg_catalog;
SELECT * FROM backfill_location_matches('90 days');
