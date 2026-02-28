-- Migration 096: Approval action RPCs
-- save_activity_override: admin overrides a single activity line
-- remove_activity_override: admin removes an override
-- approve_day: freezes a day's approval

-- ============================================================
-- save_activity_override
-- ============================================================
CREATE OR REPLACE FUNCTION save_activity_override(
    p_employee_id UUID,
    p_date DATE,
    p_activity_type TEXT,
    p_activity_id UUID,
    p_status TEXT,
    p_reason TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_day_approval_id UUID;
    v_caller UUID := auth.uid();
BEGIN
    -- Verify caller is admin
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can save overrides';
    END IF;

    -- Verify valid status
    IF p_status NOT IN ('approved', 'rejected') THEN
        RAISE EXCEPTION 'Invalid override status: %. Must be approved or rejected', p_status;
    END IF;

    -- Verify valid activity type
    IF p_activity_type NOT IN ('trip', 'stop', 'clock_in', 'clock_out') THEN
        RAISE EXCEPTION 'Invalid activity type: %', p_activity_type;
    END IF;

    -- Check day is not already approved
    IF EXISTS(
        SELECT 1 FROM day_approvals
        WHERE employee_id = p_employee_id AND date = p_date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Cannot override activities on an already approved day';
    END IF;

    -- Find or create day_approval row
    INSERT INTO day_approvals (employee_id, date, status)
    VALUES (p_employee_id, p_date, 'pending')
    ON CONFLICT (employee_id, date) DO NOTHING
    RETURNING id INTO v_day_approval_id;

    IF v_day_approval_id IS NULL THEN
        SELECT id INTO v_day_approval_id
        FROM day_approvals
        WHERE employee_id = p_employee_id AND date = p_date;
    END IF;

    -- Upsert override
    INSERT INTO activity_overrides (day_approval_id, activity_type, activity_id, override_status, reason, created_by)
    VALUES (v_day_approval_id, p_activity_type, p_activity_id, p_status, p_reason, v_caller)
    ON CONFLICT (day_approval_id, activity_type, activity_id)
    DO UPDATE SET
        override_status = EXCLUDED.override_status,
        reason = EXCLUDED.reason,
        created_by = EXCLUDED.created_by,
        created_at = now();

    -- Return updated detail
    RETURN get_day_approval_detail(p_employee_id, p_date);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- remove_activity_override
-- ============================================================
CREATE OR REPLACE FUNCTION remove_activity_override(
    p_employee_id UUID,
    p_date DATE,
    p_activity_type TEXT,
    p_activity_id UUID
)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
BEGIN
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can remove overrides';
    END IF;

    -- Check day is not already approved
    IF EXISTS(
        SELECT 1 FROM day_approvals
        WHERE employee_id = p_employee_id AND date = p_date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Cannot modify overrides on an already approved day';
    END IF;

    DELETE FROM activity_overrides ao
    USING day_approvals da
    WHERE ao.day_approval_id = da.id
      AND da.employee_id = p_employee_id
      AND da.date = p_date
      AND ao.activity_type = p_activity_type
      AND ao.activity_id = p_activity_id;

    RETURN get_day_approval_detail(p_employee_id, p_date);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- approve_day
-- ============================================================
CREATE OR REPLACE FUNCTION approve_day(
    p_employee_id UUID,
    p_date DATE,
    p_notes TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
    v_detail JSONB;
    v_needs_review INTEGER;
    v_approved_minutes INTEGER;
    v_rejected_minutes INTEGER;
    v_total_shift_minutes INTEGER;
BEGIN
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can approve days';
    END IF;

    -- Get current detail to check needs_review
    v_detail := get_day_approval_detail(p_employee_id, p_date);
    v_needs_review := (v_detail->'summary'->>'needs_review_count')::INTEGER;

    IF v_needs_review > 0 THEN
        RAISE EXCEPTION 'Cannot approve day: % activities still need review', v_needs_review;
    END IF;

    v_approved_minutes := (v_detail->'summary'->>'approved_minutes')::INTEGER;
    v_rejected_minutes := (v_detail->'summary'->>'rejected_minutes')::INTEGER;
    v_total_shift_minutes := (v_detail->'summary'->>'total_shift_minutes')::INTEGER;

    -- Upsert day_approvals with frozen values
    INSERT INTO day_approvals (
        employee_id, date, status,
        total_shift_minutes, approved_minutes, rejected_minutes,
        approved_by, approved_at, notes
    )
    VALUES (
        p_employee_id, p_date, 'approved',
        v_total_shift_minutes, v_approved_minutes, v_rejected_minutes,
        v_caller, now(), p_notes
    )
    ON CONFLICT (employee_id, date)
    DO UPDATE SET
        status = 'approved',
        total_shift_minutes = EXCLUDED.total_shift_minutes,
        approved_minutes = EXCLUDED.approved_minutes,
        rejected_minutes = EXCLUDED.rejected_minutes,
        approved_by = EXCLUDED.approved_by,
        approved_at = EXCLUDED.approved_at,
        notes = EXCLUDED.notes;

    RETURN get_day_approval_detail(p_employee_id, p_date);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- reopen_day: revert an approved day back to pending
-- ============================================================
CREATE OR REPLACE FUNCTION reopen_day(
    p_employee_id UUID,
    p_date DATE
)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
BEGIN
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can reopen days';
    END IF;

    UPDATE day_approvals
    SET status = 'pending',
        approved_by = NULL,
        approved_at = NULL,
        total_shift_minutes = NULL,
        approved_minutes = NULL,
        rejected_minutes = NULL
    WHERE employee_id = p_employee_id AND date = p_date;

    RETURN get_day_approval_detail(p_employee_id, p_date);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
