-- =============================================================================
-- Migration 026: Heartbeat, Realtime publication, zombie shift cleanup
-- =============================================================================
-- Adds:
--   1. last_heartbeat_at column on shifts (updated by GPS trigger)
--   2. Trigger on gps_points INSERT to update shift heartbeat
--   3. pg_cron extension + zombie shift cleanup job (every 15 min)
--   4. Realtime publication for active_device_sessions
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1A. Add heartbeat column to shifts
-- -----------------------------------------------------------------------------
ALTER TABLE shifts ADD COLUMN IF NOT EXISTS last_heartbeat_at TIMESTAMPTZ;

-- Backfill existing active shifts
UPDATE shifts SET last_heartbeat_at = updated_at WHERE status = 'active' AND last_heartbeat_at IS NULL;

-- Index for the cleanup job to find stale shifts efficiently
CREATE INDEX IF NOT EXISTS idx_shifts_active_heartbeat
  ON shifts (last_heartbeat_at)
  WHERE status = 'active';

-- -----------------------------------------------------------------------------
-- 1B. Trigger: update shift heartbeat on every GPS point insert
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_shift_heartbeat()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE shifts
  SET last_heartbeat_at = NOW()
  WHERE id = NEW.shift_id
    AND status = 'active';
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS gps_point_heartbeat ON gps_points;
CREATE TRIGGER gps_point_heartbeat
  AFTER INSERT ON gps_points
  FOR EACH ROW
  EXECUTE FUNCTION update_shift_heartbeat();

-- -----------------------------------------------------------------------------
-- 2A. Enable pg_cron
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- -----------------------------------------------------------------------------
-- 2B. Zombie shift cleanup function
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cleanup_zombie_shifts()
RETURNS TABLE(closed_count INT, closed_ids UUID[]) AS $$
DECLARE
  v_ids UUID[];
  v_count INT;
BEGIN
  -- Close active shifts that are clearly stale:
  --   a) Has heartbeat but none in 2 hours
  --   b) No heartbeat at all and clocked in 2+ hours ago
  --   c) Hard cap: any shift active for 16+ hours
  WITH closed AS (
    UPDATE shifts
    SET status = 'completed',
        clocked_out_at = NOW(),
        clock_out_reason = 'auto_zombie_cleanup'
    WHERE status = 'active'
      AND (
        (last_heartbeat_at IS NOT NULL AND last_heartbeat_at < NOW() - INTERVAL '15 minutes')
        OR (last_heartbeat_at IS NULL AND clocked_in_at < NOW() - INTERVAL '15 minutes')
        OR (clocked_in_at < NOW() - INTERVAL '16 hours')
      )
    RETURNING id
  )
  SELECT array_agg(id), count(*)::INT INTO v_ids, v_count FROM closed;

  RETURN QUERY SELECT COALESCE(v_count, 0), COALESCE(v_ids, ARRAY[]::UUID[]);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- -----------------------------------------------------------------------------
-- 2C. Schedule cleanup every 15 minutes
-- -----------------------------------------------------------------------------
SELECT cron.schedule(
  'cleanup-zombie-shifts',
  '*/5 * * * *',
  $$SELECT * FROM cleanup_zombie_shifts()$$
);

-- -----------------------------------------------------------------------------
-- 3. Realtime publication
-- -----------------------------------------------------------------------------
-- shifts is already in supabase_realtime; add active_device_sessions
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE active_device_sessions;
EXCEPTION WHEN duplicate_object THEN
  -- already added
END;
$$;

-- REPLICA IDENTITY FULL so Realtime sends old + new values on UPDATE
ALTER TABLE active_device_sessions REPLICA IDENTITY FULL;
ALTER TABLE shifts REPLICA IDENTITY FULL;

-- -----------------------------------------------------------------------------
-- 4. App-level heartbeat RPC (independent of GPS points)
-- -----------------------------------------------------------------------------
-- The app calls this every ~90s to prove it's still alive,
-- even if GPS stream has died. Prevents false zombie cleanup.
CREATE OR REPLACE FUNCTION ping_shift_heartbeat(p_shift_id UUID)
RETURNS VOID AS $$
BEGIN
  UPDATE shifts
  SET last_heartbeat_at = NOW()
  WHERE id = p_shift_id
    AND employee_id = auth.uid()
    AND status = 'active';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
