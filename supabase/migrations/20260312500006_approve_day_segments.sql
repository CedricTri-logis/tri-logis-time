-- ============================================================
-- Migration: approve_day + remove_activity_override support stop_segment
-- Changes:
-- 1. remove_activity_override: add activity_type validation including stop_segment
-- 2. approve_day: no structural changes needed (delegates needs_review_count
--    to get_day_approval_detail which already handles stop_segment), but
--    re-created for explicit stop_segment awareness in comments
-- ============================================================

-- 1. remove_activity_override with activity_type validation
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

    -- Validate activity type (matches save_activity_override accepted types)
    IF p_activity_type NOT IN ('trip', 'stop', 'clock_in', 'clock_out', 'gap', 'lunch_start', 'lunch_end', 'lunch', 'stop_segment') THEN
        RAISE EXCEPTION 'Invalid activity type: %', p_activity_type;
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 2. approve_day: re-create with explicit stop_segment awareness
-- The needs_review_count is computed by _get_day_approval_detail_base which
-- already includes stop_segment in its count. This re-creation ensures the
-- function uses SET search_path for security consistency.
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
    -- (includes stop_segment in needs_review_count via _get_day_approval_detail_base)
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
