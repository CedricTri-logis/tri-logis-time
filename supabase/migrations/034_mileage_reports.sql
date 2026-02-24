-- =============================================================================
-- 034: Mileage Tracking - Mileage Reports
-- Feature: 017-mileage-tracking
-- =============================================================================

CREATE TABLE mileage_reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,

    -- Report period
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,

    -- Calculated totals (snapshot at generation time)
    total_distance_km DECIMAL(10, 3) NOT NULL,
    business_distance_km DECIMAL(10, 3) NOT NULL,
    personal_distance_km DECIMAL(10, 3) NOT NULL,
    trip_count INTEGER NOT NULL,
    business_trip_count INTEGER NOT NULL,
    total_reimbursement DECIMAL(10, 2) NOT NULL,

    -- Rate used (snapshot)
    rate_per_km_used DECIMAL(5, 4) NOT NULL,
    rate_source_used TEXT NOT NULL,

    -- File reference
    file_path TEXT,
    file_format TEXT NOT NULL DEFAULT 'pdf'
        CHECK (file_format IN ('pdf', 'csv')),

    -- Metadata
    generated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE mileage_reports IS 'Generated mileage reimbursement report references (017-mileage-tracking)';

CREATE INDEX idx_mileage_reports_employee ON mileage_reports(employee_id);
CREATE INDEX idx_mileage_reports_period ON mileage_reports(period_start, period_end);

-- =============================================================================
-- ROW LEVEL SECURITY
-- =============================================================================

ALTER TABLE mileage_reports ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Employees can view own reports"
ON mileage_reports FOR SELECT TO authenticated
USING ((SELECT auth.uid()) = employee_id);

CREATE POLICY "Employees can insert own reports"
ON mileage_reports FOR INSERT TO authenticated
WITH CHECK ((SELECT auth.uid()) = employee_id);

-- Managers can view supervised employee reports
CREATE POLICY "Managers can view supervised employee reports"
ON mileage_reports FOR SELECT TO authenticated
USING (
    employee_id IN (
        SELECT es.employee_id FROM employee_supervisors es
        WHERE es.manager_id = (SELECT auth.uid())
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
    )
);
