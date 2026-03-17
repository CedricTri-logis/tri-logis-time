-- =============================================================================
-- 133: Fix GPS staleness detection in get_stale_active_devices()
-- =============================================================================
-- PROBLEM: The function only checked last_heartbeat_at to detect stale devices.
-- The heartbeat RPC (ping_shift_heartbeat) runs in the Dart main isolate,
-- independently of GPS collection. When iOS kills the background GPS service
-- but the main isolate survives, heartbeats keep flowing every ~90s while GPS
-- is dead. This caused 35+ min GPS gaps without triggering a wake push.
--
-- FIX: Add a second staleness condition: if a shift has been active for >5 min
-- AND the latest GPS point is older than 5 min, flag the device as stale even
-- if heartbeats are fresh. Uses the (shift_id, captured_at DESC) index from
-- migration 125 for efficient lookup.
-- =============================================================================

CREATE OR REPLACE FUNCTION get_stale_active_devices()
RETURNS TABLE(
  employee_id UUID,
  fcm_token TEXT,
  shift_id UUID,
  minutes_since_heartbeat INT
)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT
    s.employee_id,
    ep.fcm_token,
    s.id AS shift_id,
    EXTRACT(EPOCH FROM (now() - s.last_heartbeat_at))::int / 60 AS minutes_since_heartbeat
  FROM shifts s
  JOIN employee_profiles ep ON ep.id = s.employee_id
  WHERE s.status = 'active'
    AND ep.fcm_token IS NOT NULL
    -- Throttle: max 1 wake push per 5 minutes per employee
    AND (ep.last_wake_push_at IS NULL
         OR ep.last_wake_push_at < now() - interval '5 minutes')
    -- Flag as stale if EITHER condition is true:
    AND (
      -- Condition 1 (original): heartbeat fully dead (device/app killed)
      s.last_heartbeat_at < now() - interval '5 minutes'
      OR
      -- Condition 2 (new): GPS service dead but app alive
      -- Shift must be old enough (>5 min) to avoid flagging brand-new shifts
      -- that haven't accumulated GPS points yet
      (
        s.clocked_in_at < now() - interval '5 minutes'
        AND NOT EXISTS (
          SELECT 1
          FROM gps_points gp
          WHERE gp.shift_id = s.id
            AND gp.captured_at > now() - interval '5 minutes'
        )
      )
    );
$$;

COMMENT ON FUNCTION get_stale_active_devices() IS
  'Finds active shifts with stale devices needing a FCM wake push. '
  'Two staleness conditions (OR): '
  '(1) last_heartbeat_at > 5 min ago (device fully dead), '
  '(2) shift active > 5 min AND no GPS points in last 5 min (GPS service dead but app alive — '
  'e.g. iOS killed background GPS while main isolate kept heartbeating). '
  'Throttled to max 1 push per 5 min per employee via last_wake_push_at. '
  'Uses index gps_points(shift_id, captured_at DESC) for efficient GPS freshness check.';
