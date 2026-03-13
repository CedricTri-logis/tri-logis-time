-- Add power_save_mode column to device_status
-- Tracks whether the device's system-wide battery saver / power saving mode is ON
ALTER TABLE device_status
  ADD COLUMN IF NOT EXISTS power_save_mode boolean DEFAULT false;

COMMENT ON COLUMN device_status.power_save_mode IS 'True when the device power save / battery saver mode is ON at clock-in time. Detected via PowerManager.isPowerSaveMode() on Android.';

-- Recreate upsert_device_status to accept the new parameter
CREATE OR REPLACE FUNCTION upsert_device_status(
  p_notifications_enabled boolean,
  p_gps_permission text,
  p_precise_location_enabled boolean,
  p_battery_optimization_disabled boolean,
  p_app_version text,
  p_device_model text,
  p_os_version text,
  p_platform text,
  p_app_standby_bucket text DEFAULT NULL,
  p_power_save_mode boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
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
    app_standby_bucket,
    power_save_mode,
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
    p_app_standby_bucket,
    p_power_save_mode,
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
    app_standby_bucket = EXCLUDED.app_standby_bucket,
    power_save_mode = EXCLUDED.power_save_mode,
    updated_at = now();
END;
$$;
