-- Migration 093: Hours approval system
-- Two tables: day_approvals (day-level status) + activity_overrides (line-level admin decisions)

-- ============================================================
-- Table: day_approvals
-- ============================================================
CREATE TABLE day_approvals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
    date DATE NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved')),
    total_shift_minutes INTEGER,
    approved_minutes INTEGER,
    rejected_minutes INTEGER,
    approved_by UUID REFERENCES employee_profiles(id),
    approved_at TIMESTAMPTZ,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(employee_id, date)
);

-- Indexes
CREATE INDEX idx_day_approvals_employee_date ON day_approvals(employee_id, date);
CREATE INDEX idx_day_approvals_status ON day_approvals(status);
CREATE INDEX idx_day_approvals_date ON day_approvals(date);

-- Updated_at trigger
CREATE TRIGGER set_day_approvals_updated_at
    BEFORE UPDATE ON day_approvals
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- Table: activity_overrides
-- ============================================================
CREATE TABLE activity_overrides (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    day_approval_id UUID NOT NULL REFERENCES day_approvals(id) ON DELETE CASCADE,
    activity_type TEXT NOT NULL CHECK (activity_type IN ('trip', 'stop', 'clock_in', 'clock_out')),
    activity_id UUID NOT NULL,
    override_status TEXT NOT NULL CHECK (override_status IN ('approved', 'rejected')),
    reason TEXT,
    created_by UUID NOT NULL REFERENCES employee_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(day_approval_id, activity_type, activity_id)
);

CREATE INDEX idx_activity_overrides_day ON activity_overrides(day_approval_id);

-- ============================================================
-- RLS Policies
-- ============================================================

ALTER TABLE day_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE activity_overrides ENABLE ROW LEVEL SECURITY;

-- day_approvals: admin/super_admin full access
CREATE POLICY "admin_full_access_day_approvals"
    ON day_approvals
    FOR ALL
    USING (is_admin_or_super_admin(auth.uid()));

-- day_approvals: employees can view their own
CREATE POLICY "employee_view_own_day_approvals"
    ON day_approvals
    FOR SELECT
    USING (employee_id = auth.uid());

-- activity_overrides: admin/super_admin full access (via join check)
CREATE POLICY "admin_full_access_activity_overrides"
    ON activity_overrides
    FOR ALL
    USING (is_admin_or_super_admin(auth.uid()));
