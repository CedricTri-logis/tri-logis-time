-- Add app_standby_bucket column to device_status
ALTER TABLE device_status
ADD COLUMN app_standby_bucket TEXT;

-- Update upsert_device_status RPC to accept the new column
CREATE OR REPLACE FUNCTION upsert_device_status(
  p_notifications_enabled BOOLEAN,
  p_gps_permission TEXT,
  p_precise_location_enabled BOOLEAN,
  p_battery_optimization_disabled BOOLEAN,
  p_app_version TEXT,
  p_device_model TEXT,
  p_os_version TEXT,
  p_platform TEXT,
  p_app_standby_bucket TEXT DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
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
    updated_at = now();
END;
$$;
