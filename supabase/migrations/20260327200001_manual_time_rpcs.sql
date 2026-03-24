-- ============================================================
-- add_manual_time & delete_manual_time RPCs
-- Allows admins to add standalone manual quarts and delete
-- any manual time entry (including reverting clock extensions).
-- ============================================================

-- add_manual_time ------------------------------------------------
CREATE OR REPLACE FUNCTION add_manual_time(
    p_employee_id UUID,
    p_date DATE,
    p_starts_at TIMESTAMPTZ,
    p_ends_at TIMESTAMPTZ,
    p_reason TEXT,
    p_location_id UUID DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
    v_result JSONB;
BEGIN
    -- Auth
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can add manual time';
    END IF;

    -- Validate reason
    IF TRIM(COALESCE(p_reason, '')) = '' THEN
        RAISE EXCEPTION 'Reason is mandatory for manual time entries';
    END IF;

    -- Validate times
    IF p_ends_at <= p_starts_at THEN
        RAISE EXCEPTION 'End time must be after start time';
    END IF;

    -- Validate date
    IF to_business_date(p_starts_at) != p_date THEN
        RAISE EXCEPTION 'Start time does not match the specified date';
    END IF;

    -- Day not approved
    IF EXISTS (
        SELECT 1 FROM day_approvals
        WHERE employee_id = p_employee_id AND date = p_date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Day is approved. Reopen it before adding manual time.';
    END IF;

    -- Overlap with shifts
    IF EXISTS (
        SELECT 1
        FROM shifts s
        CROSS JOIN LATERAL effective_shift_times(s.id) est
        WHERE s.employee_id = p_employee_id
        AND s.clocked_in_at::DATE = p_date
        AND s.status = 'completed'
        AND NOT s.is_lunch
        AND est.effective_clocked_out_at IS NOT NULL
        AND tstzrange(est.effective_clocked_in_at, est.effective_clocked_out_at) &&
            tstzrange(p_starts_at, p_ends_at)
    ) THEN
        RAISE EXCEPTION 'Manual time overlaps with an existing shift';
    END IF;

    -- Overlap with other manual entries
    IF EXISTS (
        SELECT 1 FROM manual_time_entries
        WHERE employee_id = p_employee_id AND date = p_date
        AND tstzrange(starts_at, ends_at) && tstzrange(p_starts_at, p_ends_at)
    ) THEN
        RAISE EXCEPTION 'Manual time overlaps with another manual entry';
    END IF;

    -- Insert
    INSERT INTO manual_time_entries (employee_id, date, starts_at, ends_at, reason, location_id, created_by)
    VALUES (p_employee_id, p_date, p_starts_at, p_ends_at, p_reason, p_location_id, v_caller);

    -- Return updated detail
    SELECT get_day_approval_detail(p_employee_id, p_date) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- delete_manual_time ---------------------------------------------
CREATE OR REPLACE FUNCTION delete_manual_time(
    p_manual_time_id UUID
)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
    v_entry RECORD;
    v_edit RECORD;
    v_day_approval_id UUID;
    v_result JSONB;
BEGIN
    -- Auth
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can delete manual time';
    END IF;

    -- Get entry
    SELECT * INTO v_entry FROM manual_time_entries WHERE id = p_manual_time_id;
    IF v_entry IS NULL THEN
        RAISE EXCEPTION 'Manual time entry not found';
    END IF;

    -- Day not approved
    IF EXISTS (
        SELECT 1 FROM day_approvals
        WHERE employee_id = v_entry.employee_id AND date = v_entry.date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Day is approved. Reopen it before deleting manual time.';
    END IF;

    -- If clock extension: revert ALL clock edits for that (shift_id, field)
    IF v_entry.shift_time_edit_id IS NOT NULL THEN
        SELECT shift_id, field INTO v_edit
        FROM shift_time_edits WHERE id = v_entry.shift_time_edit_id;

        IF v_edit IS NOT NULL THEN
            DELETE FROM shift_time_edits
            WHERE shift_id = v_edit.shift_id AND field = v_edit.field;
        END IF;
    END IF;

    -- Delete any overrides for this manual_time activity
    SELECT id INTO v_day_approval_id
    FROM day_approvals
    WHERE employee_id = v_entry.employee_id AND date = v_entry.date;

    IF v_day_approval_id IS NOT NULL THEN
        DELETE FROM activity_overrides
        WHERE day_approval_id = v_day_approval_id
        AND activity_type = 'manual_time'
        AND activity_id = p_manual_time_id;
    END IF;

    -- Delete the entry (may already be cascade-deleted if shift_time_edit was deleted)
    DELETE FROM manual_time_entries WHERE id = p_manual_time_id;

    -- Return updated detail
    SELECT get_day_approval_detail(v_entry.employee_id, v_entry.date) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
