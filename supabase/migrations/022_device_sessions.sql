-- 021: Device identity tracking & single-device enforcement
-- Tracks all devices per employee and enforces one active device at a time.

-- Table: history of all devices that have logged in per employee
CREATE TABLE IF NOT EXISTS employee_devices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,
  platform TEXT,
  os_version TEXT,
  model TEXT,
  app_version TEXT,
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  is_current BOOLEAN NOT NULL DEFAULT false,
  UNIQUE (employee_id, device_id)
);

-- Table: one active device session per employee (for fast lookups)
CREATE TABLE IF NOT EXISTS active_device_sessions (
  employee_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,
  session_started_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index for quick device lookups
CREATE INDEX IF NOT EXISTS idx_employee_devices_employee
  ON employee_devices (employee_id);

CREATE INDEX IF NOT EXISTS idx_employee_devices_current
  ON employee_devices (employee_id) WHERE is_current = true;

-- RPC: Register a device login (called on sign-in)
-- Atomically: unmark old current device, upsert device record, upsert active session,
-- update legacy employee_profiles columns.
CREATE OR REPLACE FUNCTION register_device_login(
  p_device_id TEXT,
  p_device_platform TEXT DEFAULT NULL,
  p_device_os_version TEXT DEFAULT NULL,
  p_device_model TEXT DEFAULT NULL,
  p_app_version TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('error', 'not_authenticated');
  END IF;

  -- Unmark any current device for this employee
  UPDATE employee_devices
    SET is_current = false
    WHERE employee_id = v_user_id AND is_current = true;

  -- Upsert the device record
  INSERT INTO employee_devices (employee_id, device_id, platform, os_version, model, app_version, is_current)
    VALUES (v_user_id, p_device_id, p_device_platform, p_device_os_version, p_device_model, p_app_version, true)
    ON CONFLICT (employee_id, device_id)
    DO UPDATE SET
      platform = COALESCE(EXCLUDED.platform, employee_devices.platform),
      os_version = COALESCE(EXCLUDED.os_version, employee_devices.os_version),
      model = COALESCE(EXCLUDED.model, employee_devices.model),
      app_version = COALESCE(EXCLUDED.app_version, employee_devices.app_version),
      last_seen_at = now(),
      is_current = true;

  -- Upsert active device session
  INSERT INTO active_device_sessions (employee_id, device_id, session_started_at)
    VALUES (v_user_id, p_device_id, now())
    ON CONFLICT (employee_id)
    DO UPDATE SET
      device_id = EXCLUDED.device_id,
      session_started_at = now();

  -- Update legacy employee_profiles columns
  UPDATE employee_profiles SET
    device_platform = p_device_platform,
    device_os_version = p_device_os_version,
    device_model = p_device_model,
    device_app_version = p_app_version,
    device_updated_at = now()
  WHERE id = v_user_id;

  RETURN jsonb_build_object('success', true, 'device_id', p_device_id);
END;
$$;

-- RPC: Check if this device is still the active session
-- Lightweight read for periodic polling.
CREATE OR REPLACE FUNCTION check_device_session(
  p_device_id TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID;
  v_active_device TEXT;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('is_active', false, 'reason', 'not_authenticated');
  END IF;

  SELECT device_id INTO v_active_device
    FROM active_device_sessions
    WHERE employee_id = v_user_id;

  IF v_active_device IS NULL THEN
    -- No active session recorded yet — treat as active (first login)
    RETURN jsonb_build_object('is_active', true);
  END IF;

  RETURN jsonb_build_object('is_active', v_active_device = p_device_id);
END;
$$;

-- RLS policies for employee_devices
ALTER TABLE employee_devices ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own devices"
  ON employee_devices FOR SELECT
  USING (auth.uid() = employee_id);

CREATE POLICY "Admins can view all devices"
  ON employee_devices FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM employee_profiles
      WHERE id = auth.uid() AND role = 'admin'
    )
  );

-- RLS policies for active_device_sessions
ALTER TABLE active_device_sessions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own session"
  ON active_device_sessions FOR SELECT
  USING (auth.uid() = employee_id);

CREATE POLICY "Admins can view all sessions"
  ON active_device_sessions FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM employee_profiles
      WHERE id = auth.uid() AND role = 'admin'
    )
  );
