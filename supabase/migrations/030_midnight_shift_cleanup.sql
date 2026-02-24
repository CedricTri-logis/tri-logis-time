-- =============================================================================
-- Migration 030: Replace zombie cleanup with midnight-only auto clock-out
-- =============================================================================
-- Changes:
--   1. Removes 15-minute heartbeat staleness check (was causing false clock-outs)
--   2. Removes 16-hour hard cap
--   3. All active shifts auto-close at midnight (America/Montreal timezone)
--   4. Clock-in/clock-out should ONLY happen from the app, except midnight reset
--
-- The cron job still runs every 5 minutes to catch the midnight window.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Replace the zombie cleanup function with midnight-only cleanup
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cleanup_zombie_shifts()
RETURNS TABLE(closed_count INT, closed_ids UUID[]) AS $$
DECLARE
  v_ids UUID[];
  v_count INT;
  v_local_time TIME;
  v_midnight TIMESTAMPTZ;
BEGIN
  -- Current local time in Eastern timezone
  v_local_time := (NOW() AT TIME ZONE 'America/Montreal')::TIME;

  -- Only act during the midnight window (00:00 – 00:04:59)
  -- The cron runs every 5 minutes, so this guarantees we catch it exactly once.
  IF v_local_time >= '00:00:00' AND v_local_time < '00:05:00' THEN
    -- Midnight instant in UTC (start of today in Montreal, converted back to UTC)
    v_midnight := DATE_TRUNC('day', NOW() AT TIME ZONE 'America/Montreal')
                  AT TIME ZONE 'America/Montreal';

    WITH closed AS (
      UPDATE shifts
      SET status   = 'completed',
          clocked_out_at   = v_midnight,  -- exactly midnight, not cron exec time
          clock_out_reason = 'midnight_auto_cleanup'
      WHERE status = 'active'
        -- Only close shifts that started BEFORE midnight
        -- (don't touch shifts clocked in after midnight)
        AND clocked_in_at < v_midnight
      RETURNING id
    )
    SELECT array_agg(id), count(*)::INT INTO v_ids, v_count FROM closed;
  ELSE
    v_count := 0;
    v_ids   := ARRAY[]::UUID[];
  END IF;

  RETURN QUERY SELECT COALESCE(v_count, 0), COALESCE(v_ids, ARRAY[]::UUID[]);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- The cron schedule ('*/5 * * * *') from migration 026 stays unchanged —
-- the function itself now decides whether to act based on local time.
