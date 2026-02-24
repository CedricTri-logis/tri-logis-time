-- =============================================================================
-- 033: Mileage Tracking - Reimbursement Rates
-- Feature: 017-mileage-tracking
-- =============================================================================

CREATE TABLE reimbursement_rates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Rate tiers (CRA model: different rate after threshold)
    rate_per_km DECIMAL(5, 4) NOT NULL,
    threshold_km INTEGER,
    rate_after_threshold DECIMAL(5, 4),

    -- Validity
    effective_from DATE NOT NULL,
    effective_to DATE,

    -- Metadata
    rate_source TEXT NOT NULL DEFAULT 'cra'
        CHECK (rate_source IN ('cra', 'custom')),
    notes TEXT,
    created_by UUID REFERENCES employee_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT rate_positive CHECK (rate_per_km > 0)
);

COMMENT ON TABLE reimbursement_rates IS 'Per-km reimbursement rate configuration (017-mileage-tracking)';

CREATE INDEX idx_reimbursement_rates_effective ON reimbursement_rates(effective_from DESC);

-- =============================================================================
-- ROW LEVEL SECURITY
-- =============================================================================

ALTER TABLE reimbursement_rates ENABLE ROW LEVEL SECURITY;

-- All authenticated users can read rates
CREATE POLICY "All authenticated can view rates"
ON reimbursement_rates FOR SELECT TO authenticated
USING (true);

-- Admin insert/update handled via RPC with SECURITY DEFINER

-- =============================================================================
-- SEED: CRA 2026 default rate
-- =============================================================================

INSERT INTO reimbursement_rates (
    rate_per_km, threshold_km, rate_after_threshold,
    effective_from, rate_source, notes
) VALUES (
    0.7200, 5000, 0.6600,
    '2026-01-01', 'cra',
    'CRA/ARC 2026 automobile allowance rate: $0.72/km first 5,000 km, $0.66/km thereafter'
);
