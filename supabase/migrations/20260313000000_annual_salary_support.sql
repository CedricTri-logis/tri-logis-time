-- ============================================================
-- Migration: Annual Salary Support
-- Feature: Add pay_type to employee_profiles + employee_annual_salaries table
-- ============================================================

-- ===================
-- 1. Add pay_type to employee_profiles
-- ===================
ALTER TABLE employee_profiles
  ADD COLUMN pay_type TEXT NOT NULL DEFAULT 'hourly'
  CHECK (pay_type IN ('hourly', 'annual'));

COMMENT ON COLUMN employee_profiles.pay_type IS 'Pay type: hourly (default) or annual (fixed salary contract). Determines how compensation is calculated in get_timesheet_with_pay.';

-- ===================
-- 2. employee_annual_salaries table
-- ===================
CREATE TABLE IF NOT EXISTS employee_annual_salaries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
  salary DECIMAL(12,2) NOT NULL CHECK (salary > 0),
  effective_from DATE NOT NULL,
  effective_to DATE NULL,
  created_by UUID REFERENCES employee_profiles(id),
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT annual_salary_dates_valid CHECK (effective_to IS NULL OR effective_to > effective_from),
  CONSTRAINT annual_salary_unique_period UNIQUE (employee_id, effective_from)
);

-- Partial unique index: only one active (no end date) salary per employee
CREATE UNIQUE INDEX idx_employee_annual_salaries_active
  ON employee_annual_salaries(employee_id) WHERE effective_to IS NULL;

-- Performance index for per-day salary lookups
CREATE INDEX idx_employee_annual_salaries_lookup
  ON employee_annual_salaries(employee_id, effective_from DESC);

-- Trigger: auto-update updated_at
CREATE TRIGGER update_employee_annual_salaries_updated_at
  BEFORE UPDATE ON employee_annual_salaries
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- ===================
-- 3. Overlap prevention trigger
-- ===================
CREATE OR REPLACE FUNCTION check_annual_salary_overlap()
RETURNS TRIGGER AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM employee_annual_salaries
    WHERE employee_id = NEW.employee_id
      AND id != COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid)
      AND effective_from < COALESCE(NEW.effective_to, '9999-12-31'::date)
      AND COALESCE(effective_to, '9999-12-31'::date) > NEW.effective_from
  ) THEN
    RAISE EXCEPTION 'Overlapping annual salary period for employee %', NEW.employee_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_annual_salary_overlap
  BEFORE INSERT OR UPDATE ON employee_annual_salaries
  FOR EACH ROW
  EXECUTE FUNCTION check_annual_salary_overlap();

-- ===================
-- 4. RLS
-- ===================
ALTER TABLE employee_annual_salaries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage annual salaries"
  ON employee_annual_salaries FOR ALL
  USING (is_admin_or_super_admin(auth.uid()))
  WITH CHECK (is_admin_or_super_admin(auth.uid()));

-- Grant
GRANT ALL ON employee_annual_salaries TO authenticated;

-- ===================
-- 5. Comments
-- ===================
COMMENT ON TABLE employee_annual_salaries IS
  'ROLE: Stores per-employee annual salary amounts with period-based history.
   STATUTS: effective_to IS NULL means currently active salary.
   REGLES: No overlapping periods per employee (trigger). At most one active salary per employee (partial unique index). Salary must be > 0.
   RELATIONS: employee_id → employee_profiles (CASCADE), created_by → employee_profiles.
   TRIGGERS: check_annual_salary_overlap (BEFORE INSERT/UPDATE), update_updated_at_column (BEFORE UPDATE).';

COMMENT ON COLUMN employee_annual_salaries.salary IS 'Annual salary in CAD ($/year). Biweekly amount = salary / 26.';
COMMENT ON COLUMN employee_annual_salaries.effective_from IS 'Start date of this salary period (inclusive)';
COMMENT ON COLUMN employee_annual_salaries.effective_to IS 'End date of this salary period (inclusive). NULL = currently active.';
COMMENT ON COLUMN employee_annual_salaries.created_by IS 'Admin who created/modified this salary entry';

-- ===================
-- 6. RPC: update_employee_pay_type (with validation)
-- ===================
CREATE OR REPLACE FUNCTION update_employee_pay_type(
  p_employee_id UUID,
  p_pay_type TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_has_compensation BOOLEAN;
BEGIN
  -- Validate pay_type value
  IF p_pay_type NOT IN ('hourly', 'annual') THEN
    RAISE EXCEPTION 'Invalid pay_type: %. Must be hourly or annual.', p_pay_type;
  END IF;

  -- Check that the target compensation type has an active record
  IF p_pay_type = 'hourly' THEN
    SELECT EXISTS(
      SELECT 1 FROM employee_hourly_rates
      WHERE employee_id = p_employee_id AND effective_to IS NULL
    ) INTO v_has_compensation;
  ELSE
    SELECT EXISTS(
      SELECT 1 FROM employee_annual_salaries
      WHERE employee_id = p_employee_id AND effective_to IS NULL
    ) INTO v_has_compensation;
  END IF;

  IF NOT v_has_compensation THEN
    RAISE EXCEPTION 'Cannot switch to %: no active % found for employee %. Set the % first.',
      p_pay_type,
      CASE WHEN p_pay_type = 'hourly' THEN 'hourly rate' ELSE 'annual salary' END,
      p_employee_id,
      CASE WHEN p_pay_type = 'hourly' THEN 'rate' ELSE 'salary' END;
  END IF;

  -- Update pay_type
  UPDATE employee_profiles SET pay_type = p_pay_type WHERE id = p_employee_id;
END;
$$;

GRANT EXECUTE ON FUNCTION update_employee_pay_type TO authenticated;
