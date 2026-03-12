-- ============================================================
-- Migration: Employee Hourly Rates & Pay Settings
-- Feature: Per-employee hourly rates with period history
--          + global weekend cleaning premium
-- ============================================================

-- ===================
-- 1. pay_settings
-- ===================
CREATE TABLE IF NOT EXISTS pay_settings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key TEXT UNIQUE NOT NULL,
  value JSONB NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now(),
  updated_by UUID REFERENCES employee_profiles(id)
);

-- Trigger: auto-update updated_at
CREATE TRIGGER update_pay_settings_updated_at
  BEFORE UPDATE ON pay_settings
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- RLS
ALTER TABLE pay_settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage pay_settings"
  ON pay_settings FOR ALL
  USING (is_admin_or_super_admin(auth.uid()))
  WITH CHECK (is_admin_or_super_admin(auth.uid()));

CREATE POLICY "Authenticated users can read pay_settings"
  ON pay_settings FOR SELECT
  USING (auth.role() = 'authenticated');

-- Seed default weekend cleaning premium
INSERT INTO pay_settings (key, value)
VALUES ('weekend_cleaning_premium', '{"amount": 0.00, "currency": "CAD"}');

-- Comments
COMMENT ON TABLE pay_settings IS
  'ROLE: Stores global pay configuration key-value pairs.
   STATUTS: N/A (config rows, not status-driven).
   REGLES: Only admins can modify. Authenticated users can read.
   RELATIONS: updated_by → employee_profiles.
   TRIGGERS: update_updated_at_column on UPDATE.';

COMMENT ON COLUMN pay_settings.key IS 'Unique config key, e.g. weekend_cleaning_premium';
COMMENT ON COLUMN pay_settings.value IS 'JSONB value — for weekend_cleaning_premium: {"amount": decimal, "currency": "CAD"}';

-- ===================
-- 2. employee_hourly_rates
-- ===================
CREATE TABLE IF NOT EXISTS employee_hourly_rates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
  rate DECIMAL(10,2) NOT NULL CHECK (rate > 0),
  effective_from DATE NOT NULL,
  effective_to DATE NULL,
  created_by UUID REFERENCES employee_profiles(id),
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT hourly_rate_dates_valid CHECK (effective_to IS NULL OR effective_to > effective_from),
  CONSTRAINT hourly_rate_unique_period UNIQUE (employee_id, effective_from)
);

-- Partial unique index: only one active (no end date) rate per employee
CREATE UNIQUE INDEX idx_employee_hourly_rates_active
  ON employee_hourly_rates(employee_id) WHERE effective_to IS NULL;

-- Performance index for per-day rate lookups
CREATE INDEX idx_employee_hourly_rates_lookup
  ON employee_hourly_rates(employee_id, effective_from DESC);

-- Trigger: auto-update updated_at
CREATE TRIGGER update_employee_hourly_rates_updated_at
  BEFORE UPDATE ON employee_hourly_rates
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- ===================
-- 3. Overlap prevention trigger
-- ===================
CREATE OR REPLACE FUNCTION check_hourly_rate_overlap()
RETURNS TRIGGER AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM employee_hourly_rates
    WHERE employee_id = NEW.employee_id
      AND id != COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid)
      AND effective_from < COALESCE(NEW.effective_to, '9999-12-31'::date)
      AND COALESCE(effective_to, '9999-12-31'::date) > NEW.effective_from
  ) THEN
    RAISE EXCEPTION 'Overlapping hourly rate period for employee %', NEW.employee_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_hourly_rate_overlap
  BEFORE INSERT OR UPDATE ON employee_hourly_rates
  FOR EACH ROW
  EXECUTE FUNCTION check_hourly_rate_overlap();

-- ===================
-- 4. RLS for employee_hourly_rates
-- ===================
ALTER TABLE employee_hourly_rates ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage hourly rates"
  ON employee_hourly_rates FOR ALL
  USING (is_admin_or_super_admin(auth.uid()))
  WITH CHECK (is_admin_or_super_admin(auth.uid()));

-- Comments
COMMENT ON TABLE employee_hourly_rates IS
  'ROLE: Stores per-employee hourly rates with period-based history.
   STATUTS: effective_to IS NULL means currently active rate.
   REGLES: No overlapping periods per employee (trigger). At most one active rate per employee (partial unique index). Rate must be > 0.
   RELATIONS: employee_id → employee_profiles (CASCADE), created_by → employee_profiles.
   TRIGGERS: check_hourly_rate_overlap (BEFORE INSERT/UPDATE), update_updated_at_column (BEFORE UPDATE).';

COMMENT ON COLUMN employee_hourly_rates.rate IS 'Hourly rate in CAD ($/h)';
COMMENT ON COLUMN employee_hourly_rates.effective_from IS 'Start date of this rate period (inclusive)';
COMMENT ON COLUMN employee_hourly_rates.effective_to IS 'End date of this rate period (inclusive). NULL = currently active.';
COMMENT ON COLUMN employee_hourly_rates.created_by IS 'Admin who created/modified this rate entry';

-- Grant
GRANT ALL ON employee_hourly_rates TO authenticated;
GRANT ALL ON pay_settings TO authenticated;
