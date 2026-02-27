-- Migration 065: Employee vehicle periods
-- Tracks when employees have access to personal or company vehicles (period-based)

CREATE TABLE employee_vehicle_periods (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
    vehicle_type TEXT NOT NULL CHECK (vehicle_type IN ('personal', 'company')),
    started_at DATE NOT NULL,
    ended_at DATE,  -- NULL = ongoing period
    notes TEXT,
    created_by UUID REFERENCES employee_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_vehicle_periods_employee ON employee_vehicle_periods(employee_id);
CREATE INDEX idx_vehicle_periods_type ON employee_vehicle_periods(vehicle_type);
CREATE INDEX idx_vehicle_periods_dates ON employee_vehicle_periods(started_at, ended_at);

-- Prevent overlapping periods for the same employee + vehicle_type
CREATE OR REPLACE FUNCTION check_vehicle_period_overlap()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM employee_vehicle_periods
        WHERE employee_id = NEW.employee_id
          AND vehicle_type = NEW.vehicle_type
          AND id != COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::UUID)
          AND started_at <= COALESCE(NEW.ended_at, '9999-12-31'::DATE)
          AND COALESCE(ended_at, '9999-12-31'::DATE) >= NEW.started_at
    ) THEN
        RAISE EXCEPTION 'Overlapping vehicle period exists for this employee and vehicle type';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_vehicle_period_overlap
    BEFORE INSERT OR UPDATE ON employee_vehicle_periods
    FOR EACH ROW EXECUTE FUNCTION check_vehicle_period_overlap();

-- Updated_at trigger
CREATE TRIGGER trg_vehicle_periods_updated_at
    BEFORE UPDATE ON employee_vehicle_periods
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- RLS
ALTER TABLE employee_vehicle_periods ENABLE ROW LEVEL SECURITY;

-- Admin/super_admin can do everything
CREATE POLICY "Admins manage vehicle periods"
    ON employee_vehicle_periods FOR ALL
    USING (is_admin_or_super_admin(auth.uid()));

-- Employees can view their own periods
CREATE POLICY "Employees view own vehicle periods"
    ON employee_vehicle_periods FOR SELECT
    USING (employee_id = auth.uid());

-- Helper function: check if employee has active vehicle period of a given type on a date
CREATE OR REPLACE FUNCTION has_active_vehicle_period(
    p_employee_id UUID,
    p_vehicle_type TEXT,
    p_date DATE
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
    SELECT EXISTS (
        SELECT 1 FROM employee_vehicle_periods
        WHERE employee_id = p_employee_id
          AND vehicle_type = p_vehicle_type
          AND started_at <= p_date
          AND (ended_at IS NULL OR ended_at >= p_date)
    );
$$;

COMMENT ON TABLE employee_vehicle_periods IS 'Tracks periods when employees have access to personal or company vehicles';
COMMENT ON FUNCTION has_active_vehicle_period IS 'Check if employee has active vehicle period of given type on date';
