CREATE OR REPLACE FUNCTION edit_shift_time(
    p_shift_id UUID,
    p_field TEXT,
    p_new_value TIMESTAMPTZ,
    p_reason TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
    v_employee_id UUID;
    v_shift_record RECORD;
    v_effective RECORD;
    v_current_date DATE;
    v_new_date DATE;
    v_effective_in TIMESTAMPTZ;
    v_effective_out TIMESTAMPTZ;
    v_result JSONB;
BEGIN
    -- Auth
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can edit shift times';
    END IF;

    -- Validate field
    IF p_field NOT IN ('clocked_in_at', 'clocked_out_at') THEN
        RAISE EXCEPTION 'Field must be clocked_in_at or clocked_out_at';
    END IF;

    -- Get shift
    SELECT id, employee_id, clocked_in_at, clocked_out_at, status
    INTO v_shift_record
    FROM shifts
    WHERE id = p_shift_id;

    IF v_shift_record IS NULL THEN
        RAISE EXCEPTION 'Shift not found';
    END IF;

    v_employee_id := v_shift_record.employee_id;

    -- Cannot edit clock_out on active shift
    IF p_field = 'clocked_out_at' AND v_shift_record.status = 'active' THEN
        RAISE EXCEPTION 'Cannot edit clock-out on an active shift';
    END IF;

    -- Get current effective times
    SELECT * INTO v_effective FROM effective_shift_times(p_shift_id);
    v_current_date := to_business_date(v_effective.effective_clocked_in_at);

    -- Check day not approved
    IF EXISTS (
        SELECT 1 FROM day_approvals
        WHERE employee_id = v_employee_id
        AND date = v_current_date
        AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Day is approved. Reopen it before editing shift times.';
    END IF;

    -- Date change guard (clocked_in_at only)
    IF p_field = 'clocked_in_at' THEN
        v_new_date := to_business_date(p_new_value);
        IF v_new_date != v_current_date THEN
            RAISE EXCEPTION 'Edit would move shift to a different day (% → %). Adjust to stay within the same calendar date.', v_current_date, v_new_date;
        END IF;
    END IF;

    -- Temporal consistency: clock_in < clock_out
    IF p_field = 'clocked_in_at' THEN
        v_effective_in := p_new_value;
        v_effective_out := v_effective.effective_clocked_out_at;
    ELSE
        v_effective_in := v_effective.effective_clocked_in_at;
        v_effective_out := p_new_value;
    END IF;

    IF v_effective_out IS NOT NULL AND v_effective_in >= v_effective_out THEN
        RAISE EXCEPTION 'Clock-in must be before clock-out';
    END IF;

    -- Overlap check with other shifts of same employee
    IF EXISTS (
        SELECT 1
        FROM shifts s
        CROSS JOIN LATERAL effective_shift_times(s.id) est
        WHERE s.employee_id = v_employee_id
        AND s.id != p_shift_id
        AND s.status = 'completed'
        AND est.effective_clocked_out_at IS NOT NULL
        AND tstzrange(est.effective_clocked_in_at, est.effective_clocked_out_at) &&
            tstzrange(v_effective_in, v_effective_out)
    ) THEN
        RAISE EXCEPTION 'Edited time would overlap with another shift';
    END IF;

    -- Get old value (effective, not necessarily original)
    DECLARE
        v_old_value TIMESTAMPTZ;
    BEGIN
        IF p_field = 'clocked_in_at' THEN
            v_old_value := v_effective.effective_clocked_in_at;
        ELSE
            v_old_value := v_effective.effective_clocked_out_at;
        END IF;

        -- Insert audit row
        INSERT INTO shift_time_edits (shift_id, field, old_value, new_value, reason, changed_by)
        VALUES (p_shift_id, p_field, v_old_value, p_new_value, p_reason, v_caller);
    END;

    -- Return updated day detail
    SELECT get_day_approval_detail(v_employee_id, v_current_date) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
