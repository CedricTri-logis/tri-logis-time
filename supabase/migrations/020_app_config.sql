-- App configuration table for dynamic settings (e.g., minimum app version)
CREATE TABLE IF NOT EXISTS app_config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  description TEXT,
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Enable RLS
ALTER TABLE app_config ENABLE ROW LEVEL SECURITY;

-- All authenticated users can read config
CREATE POLICY "Authenticated users can read app_config"
  ON app_config FOR SELECT
  TO authenticated
  USING (true);

-- Only admins can modify config
CREATE POLICY "Admins can manage app_config"
  ON app_config FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM employee_profiles
      WHERE id = auth.uid()
      AND role IN ('admin', 'super_admin')
    )
  );

-- Insert initial minimum version
INSERT INTO app_config (key, value, description)
VALUES (
  'minimum_app_version',
  '1.0.0+9',
  'Minimum app version required to clock in. Format: major.minor.patch+build'
);
