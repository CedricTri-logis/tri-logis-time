-- Create lunch_breaks table
CREATE TABLE lunch_breaks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    shift_id UUID NOT NULL REFERENCES shifts(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES employee_profiles(id),
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_lunch_breaks_shift_id ON lunch_breaks(shift_id);
CREATE INDEX idx_lunch_breaks_employee_date ON lunch_breaks(employee_id, started_at DESC);

-- RLS
ALTER TABLE lunch_breaks ENABLE ROW LEVEL SECURITY;

-- Employees can view their own lunch breaks
CREATE POLICY "Employees can view own lunch breaks"
    ON lunch_breaks FOR SELECT
    USING (employee_id = auth.uid());

-- Employees can insert their own lunch breaks
CREATE POLICY "Employees can insert own lunch breaks"
    ON lunch_breaks FOR INSERT
    WITH CHECK (employee_id = auth.uid());

-- Employees can update their own lunch breaks (to set ended_at)
CREATE POLICY "Employees can update own lunch breaks"
    ON lunch_breaks FOR UPDATE
    USING (employee_id = auth.uid());

-- Supervisors can view their employees' lunch breaks
CREATE POLICY "Supervisors can view employee lunch breaks"
    ON lunch_breaks FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM employee_supervisors
            WHERE manager_id = auth.uid()
            AND employee_id = lunch_breaks.employee_id
        )
    );

-- Admins can do everything
CREATE POLICY "Admins have full access to lunch breaks"
    ON lunch_breaks FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM employee_profiles
            WHERE id = auth.uid() AND role = 'admin'
        )
    );
