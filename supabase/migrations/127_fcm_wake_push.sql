-- =============================================================================
-- 127: FCM token storage and wake push throttling
-- =============================================================================
-- Adds fcm_token and last_wake_push_at to employee_profiles.
-- get_stale_active_devices() finds active shifts with stale heartbeats
-- (>5 min) and valid FCM tokens. Throttled to max 1 push per 5 min.
-- =============================================================================

-- 1. Add columns to employee_profiles
ALTER TABLE employee_profiles
  ADD COLUMN IF NOT EXISTS fcm_token TEXT,
  ADD COLUMN IF NOT EXISTS last_wake_push_at TIMESTAMPTZ;

-- 2. Create function to find stale devices
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
    s.id as shift_id,
    EXTRACT(EPOCH FROM (now() - s.last_heartbeat_at))::int / 60 as minutes_since_heartbeat
  FROM shifts s
  JOIN employee_profiles ep ON ep.id = s.employee_id
  WHERE s.status = 'active'
    AND s.last_heartbeat_at < now() - interval '5 minutes'
    AND ep.fcm_token IS NOT NULL
    AND (ep.last_wake_push_at IS NULL
         OR ep.last_wake_push_at < now() - interval '5 minutes');
$$;

-- 3. Create function to record wake push sent
CREATE OR REPLACE FUNCTION record_wake_push(p_employee_id UUID)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $$
  UPDATE employee_profiles
  SET last_wake_push_at = now()
  WHERE id = p_employee_id;
$$;
