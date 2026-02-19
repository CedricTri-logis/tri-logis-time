-- Add device info columns to employee_profiles
ALTER TABLE employee_profiles
  ADD COLUMN IF NOT EXISTS device_platform TEXT,       -- 'android' or 'ios'
  ADD COLUMN IF NOT EXISTS device_os_version TEXT,     -- e.g. '14.2', '34'
  ADD COLUMN IF NOT EXISTS device_model TEXT,          -- e.g. 'iPhone 15', 'Pixel 8'
  ADD COLUMN IF NOT EXISTS device_app_version TEXT,    -- e.g. '1.0.0+9'
  ADD COLUMN IF NOT EXISTS device_updated_at TIMESTAMPTZ;  -- last time device info was updated
