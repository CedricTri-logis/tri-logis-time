-- =============================================================================
-- 110: Match clock-in/out locations when GPS-less shifts are auto-closed
-- =============================================================================
-- Ensure PostGIS types (geography) are visible to the backfill UPDATEs
SET search_path TO extensions, public, pg_catalog;
-- BUG: flag_gpsless_shifts() closes shifts with 0 GPS points but never calls
-- detect_trips(), so clock_in_location_id / clock_out_location_id are never
-- set. The shift then shows up as an unmatched clock-in suggestion forever.
--
-- FIX 1: Update flag_gpsless_shifts() to call detect_trips() after closing
--        each GPS-less shift. For 0-GPS shifts, detect_trips() is fast (no
--        loop) and just runs step 7: direct match via match_trip_to_location().
--
-- FIX 2: Backfill all existing completed shifts where:
--        - clock_in/out_location_id IS NULL
--        - clock_in/out_cluster_id IS NULL (no cluster → direct match only)
--        - clock_in accuracy <= 50m (reasonable GPS fix)
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Update flag_gpsless_shifts to call detect_trips after closing
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION flag_gpsless_shifts()
RETURNS void AS $$
DECLARE
    v_shift RECORD;
BEGIN
    FOR v_shift IN
        SELECT s.id, s.employee_id, s.clocked_in_at, s.last_heartbeat_at
        FROM shifts s
        WHERE s.status = 'active'
          AND s.clocked_in_at < NOW() - INTERVAL '10 minutes'
          AND NOT EXISTS (
              SELECT 1 FROM gps_points gp WHERE gp.shift_id = s.id
          )
    LOOP
        UPDATE shifts SET
            status = 'completed',
            clocked_out_at = COALESCE(v_shift.last_heartbeat_at, NOW()),
            clock_out_reason = 'no_gps_auto_close'
        WHERE id = v_shift.id;

        -- Run trip/cluster detection so clock_in/out_location_id gets set.
        -- For 0-GPS shifts this is fast: no GPS loop, just the direct
        -- match_trip_to_location() fallback at step 7.
        PERFORM detect_trips(v_shift.id);

        RAISE NOTICE 'Auto-closed GPS-less shift % for employee %',
            v_shift.id, v_shift.employee_id;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Backfill: match clock-in/out for all existing unmatched completed shifts
--    (no cluster = only direct match_trip_to_location() applies)
-- ─────────────────────────────────────────────────────────────────────────────
UPDATE shifts SET
    clock_in_location_id = match_trip_to_location(
        (clock_in_location->>'latitude')::DECIMAL,
        (clock_in_location->>'longitude')::DECIMAL,
        COALESCE(clock_in_accuracy, 20)
    )
WHERE clocked_out_at IS NOT NULL
  AND clock_in_location IS NOT NULL
  AND clock_in_location_id IS NULL
  AND clock_in_cluster_id IS NULL
  AND COALESCE(clock_in_accuracy, 20) <= 50
  AND clocked_in_at >= NOW() - INTERVAL '90 days';

UPDATE shifts SET
    clock_out_location_id = match_trip_to_location(
        (clock_out_location->>'latitude')::DECIMAL,
        (clock_out_location->>'longitude')::DECIMAL,
        COALESCE(clock_out_accuracy, 20)
    )
WHERE clocked_out_at IS NOT NULL
  AND clock_out_location IS NOT NULL
  AND clock_out_location_id IS NULL
  AND clock_out_cluster_id IS NULL
  AND COALESCE(clock_out_accuracy, 20) <= 50
  AND clocked_out_at >= NOW() - INTERVAL '90 days';
