-- =============================================================================
-- Migration 025: GPS gaps tracking + clock_out_reason
-- =============================================================================
-- Adds:
--   1. clock_out_reason column on shifts table
--   2. gps_gaps table for tracking GPS signal loss periods
--   3. sync_gps_gaps RPC for batch inserting GPS gaps
--   4. Updated clock_out RPC with p_reason parameter
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Add clock_out_reason to shifts
-- -----------------------------------------------------------------------------
ALTER TABLE shifts ADD COLUMN IF NOT EXISTS clock_out_reason TEXT DEFAULT 'manual';

-- -----------------------------------------------------------------------------
-- 2. Create gps_gaps table
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS gps_gaps (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id UUID NOT NULL UNIQUE,
    shift_id UUID NOT NULL REFERENCES shifts(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES employee_profiles(id),
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ,
    reason TEXT NOT NULL DEFAULT 'signal_loss',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_gps_gaps_shift ON gps_gaps(shift_id);
CREATE INDEX IF NOT EXISTS idx_gps_gaps_employee ON gps_gaps(employee_id);
CREATE INDEX IF NOT EXISTS idx_gps_gaps_started ON gps_gaps(started_at);

-- RLS
ALTER TABLE gps_gaps ENABLE ROW LEVEL SECURITY;

-- Employees can insert/read their own gaps
CREATE POLICY "Employees can insert own GPS gaps"
    ON gps_gaps FOR INSERT
    WITH CHECK (employee_id = auth.uid());

CREATE POLICY "Employees can read own GPS gaps"
    ON gps_gaps FOR SELECT
    USING (employee_id = auth.uid());

-- Supervisors can read gaps for their employees
CREATE POLICY "Supervisors can read employee GPS gaps"
    ON gps_gaps FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM employee_supervisors es
            WHERE es.manager_id = auth.uid()
              AND es.employee_id = gps_gaps.employee_id
        )
    );

-- Admins can read all gaps
CREATE POLICY "Admins can read all GPS gaps"
    ON gps_gaps FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM employee_profiles
            WHERE id = auth.uid()
              AND role IN ('admin', 'super_admin')
        )
    );

-- -----------------------------------------------------------------------------
-- 3. sync_gps_gaps RPC
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_gps_gaps(p_gaps JSONB)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID;
    v_gap JSONB;
    v_inserted INTEGER := 0;
    v_duplicates INTEGER := 0;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Not authenticated');
    END IF;

    FOR v_gap IN SELECT * FROM jsonb_array_elements(p_gaps)
    LOOP
        BEGIN
            INSERT INTO gps_gaps (
                client_id, shift_id, employee_id,
                started_at, ended_at, reason
            )
            VALUES (
                (v_gap->>'client_id')::UUID,
                (v_gap->>'shift_id')::UUID,
                v_user_id,
                (v_gap->>'started_at')::TIMESTAMPTZ,
                CASE WHEN v_gap->>'ended_at' IS NOT NULL
                     THEN (v_gap->>'ended_at')::TIMESTAMPTZ
                     ELSE NULL
                END,
                COALESCE(v_gap->>'reason', 'signal_loss')
            );
            v_inserted := v_inserted + 1;
        EXCEPTION WHEN unique_violation THEN
            v_duplicates := v_duplicates + 1;
        END;
    END LOOP;

    RETURN jsonb_build_object(
        'status', 'success',
        'inserted', v_inserted,
        'duplicates', v_duplicates
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- -----------------------------------------------------------------------------
-- 4. Update clock_out RPC to accept p_reason
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clock_out(
    p_shift_id UUID,
    p_request_id UUID,
    p_location JSONB DEFAULT NULL,
    p_accuracy DECIMAL DEFAULT NULL,
    p_reason TEXT DEFAULT 'manual'
)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID;
    v_shift shifts%ROWTYPE;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Not authenticated');
    END IF;

    -- Get shift and verify ownership
    SELECT * INTO v_shift FROM shifts
    WHERE id = p_shift_id AND employee_id = v_user_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Shift not found');
    END IF;

    -- Check if already clocked out (idempotency via status check)
    IF v_shift.status = 'completed' THEN
        RETURN jsonb_build_object(
            'status', 'already_processed',
            'shift_id', v_shift.id,
            'clocked_out_at', v_shift.clocked_out_at
        );
    END IF;

    -- Update shift with reason
    UPDATE shifts SET
        status = 'completed',
        clocked_out_at = NOW(),
        clock_out_location = p_location,
        clock_out_accuracy = p_accuracy,
        clock_out_reason = p_reason
    WHERE id = p_shift_id
    RETURNING * INTO v_shift;

    RETURN jsonb_build_object(
        'status', 'success',
        'shift_id', v_shift.id,
        'clocked_out_at', v_shift.clocked_out_at
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
