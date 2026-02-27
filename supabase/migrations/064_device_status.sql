-- Device status tracking: permissions, device info, reported at clock-in
CREATE TABLE IF NOT EXISTS device_status (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL UNIQUE REFERENCES employee_profiles(id) ON DELETE CASCADE,
  notifications_enabled BOOLEAN NOT NULL DEFAULT false,
  gps_permission TEXT NOT NULL DEFAULT 'denied',
  precise_location_enabled BOOLEAN NOT NULL DEFAULT true,
  battery_optimization_disabled BOOLEAN NOT NULL DEFAULT true,
  app_version TEXT,
  device_model TEXT,
  os_version TEXT,
  platform TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index for admin lookups
CREATE INDEX idx_device_status_employee_id ON device_status(employee_id);

-- RLS
ALTER TABLE device_status ENABLE ROW LEVEL SECURITY;

-- Employee can upsert their own row
CREATE POLICY "employee_own_device_status"
  ON device_status
  FOR ALL
  USING (auth.uid() = employee_id)
  WITH CHECK (auth.uid() = employee_id);

-- Admin/super_admin can read all
CREATE POLICY "admin_read_device_status"
  ON device_status
  FOR SELECT
  USING (is_admin_or_super_admin(auth.uid()));

-- RPC: upsert device status (called at clock-in)
CREATE OR REPLACE FUNCTION upsert_device_status(
  p_notifications_enabled BOOLEAN,
  p_gps_permission TEXT,
  p_precise_location_enabled BOOLEAN,
  p_battery_optimization_disabled BOOLEAN,
  p_app_version TEXT,
  p_device_model TEXT,
  p_os_version TEXT,
  p_platform TEXT
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO device_status (
    employee_id,
    notifications_enabled,
    gps_permission,
    precise_location_enabled,
    battery_optimization_disabled,
    app_version,
    device_model,
    os_version,
    platform,
    updated_at
  ) VALUES (
    auth.uid(),
    p_notifications_enabled,
    p_gps_permission,
    p_precise_location_enabled,
    p_battery_optimization_disabled,
    p_app_version,
    p_device_model,
    p_os_version,
    p_platform,
    now()
  )
  ON CONFLICT (employee_id) DO UPDATE SET
    notifications_enabled = EXCLUDED.notifications_enabled,
    gps_permission = EXCLUDED.gps_permission,
    precise_location_enabled = EXCLUDED.precise_location_enabled,
    battery_optimization_disabled = EXCLUDED.battery_optimization_disabled,
    app_version = EXCLUDED.app_version,
    device_model = EXCLUDED.device_model,
    os_version = EXCLUDED.os_version,
    platform = EXCLUDED.platform,
    updated_at = now();
END;
$$;
