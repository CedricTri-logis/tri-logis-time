-- Migration: lunch_shift_split_rpcs
-- Creates start_lunch and end_lunch RPCs that split shifts at lunch boundaries.
-- Both are idempotent and redistribute GPS points by timestamp for the offline case.

-- ============================================================================
-- start_lunch: closes the current work segment, opens a lunch segment
-- ============================================================================
CREATE OR REPLACE FUNCTION start_lunch(
    p_shift_id UUID,
    p_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID;
    v_shift shifts%ROWTYPE;
    v_work_body_id UUID;
    v_new_shift_id UUID;
    v_now TIMESTAMPTZ;
    v_existing_lunch shifts%ROWTYPE;
BEGIN
    v_user_id := auth.uid();
    v_now := COALESCE(p_at, NOW());

    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Not authenticated');
    END IF;

    -- Fetch and lock the shift
    SELECT * INTO v_shift
    FROM shifts
    WHERE id = p_shift_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Shift not found');
    END IF;

    -- Must be the shift owner
    IF v_shift.employee_id != v_user_id THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Not your shift');
    END IF;

    -- Idempotent: if already completed with clock_out_reason='lunch',
    -- find and return the lunch segment that was created
    IF v_shift.status = 'completed' AND v_shift.clock_out_reason = 'lunch' THEN
        SELECT * INTO v_existing_lunch
        FROM shifts
        WHERE work_body_id = v_shift.work_body_id
          AND is_lunch = true
          AND clocked_in_at >= v_shift.clocked_out_at - INTERVAL '1 second'
        ORDER BY clocked_in_at ASC
        LIMIT 1;

        IF FOUND THEN
            RETURN jsonb_build_object(
                'status', 'already_processed',
                'new_shift_id', v_existing_lunch.id,
                'work_body_id', v_existing_lunch.work_body_id,
                'started_at', v_existing_lunch.clocked_in_at
            );
        END IF;
    END IF;

    -- Validate: shift must be active
    IF v_shift.status != 'active' THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Shift is not active');
    END IF;

    -- Validate: must not already be a lunch segment
    IF v_shift.is_lunch = true THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Shift is already a lunch segment');
    END IF;

    -- Generate work_body_id if this is the first split
    v_work_body_id := COALESCE(v_shift.work_body_id, v_shift.id);

    -- Close the work segment
    UPDATE shifts SET
        status = 'completed',
        clocked_out_at = v_now,
        clock_out_reason = 'lunch',
        work_body_id = v_work_body_id,
        updated_at = NOW()
    WHERE id = p_shift_id;

    -- Create new lunch segment
    INSERT INTO shifts (
        employee_id,
        status,
        clocked_in_at,
        is_lunch,
        work_body_id,
        shift_type,
        clock_in_location_id,
        clock_in_cluster_id,
        app_version
    ) VALUES (
        v_user_id,
        'active',
        v_now,
        true,
        v_work_body_id,
        v_shift.shift_type,
        v_shift.clock_in_location_id,
        v_shift.clock_in_cluster_id,
        v_shift.app_version
    )
    RETURNING id INTO v_new_shift_id;

    -- Redistribute GPS points captured after p_at to the new lunch segment
    UPDATE gps_points SET
        shift_id = v_new_shift_id
    WHERE shift_id = p_shift_id
      AND captured_at >= v_now;

    RETURN jsonb_build_object(
        'status', 'success',
        'new_shift_id', v_new_shift_id,
        'work_body_id', v_work_body_id,
        'started_at', v_now
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public, extensions;

-- ============================================================================
-- end_lunch: closes the lunch segment, opens a new work segment
-- ============================================================================
CREATE OR REPLACE FUNCTION end_lunch(
    p_shift_id UUID,
    p_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID;
    v_shift shifts%ROWTYPE;
    v_new_shift_id UUID;
    v_now TIMESTAMPTZ;
    v_existing_work shifts%ROWTYPE;
BEGIN
    v_user_id := auth.uid();
    v_now := COALESCE(p_at, NOW());

    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Not authenticated');
    END IF;

    -- Fetch and lock the shift
    SELECT * INTO v_shift
    FROM shifts
    WHERE id = p_shift_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Shift not found');
    END IF;

    -- Must be the shift owner
    IF v_shift.employee_id != v_user_id THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Not your shift');
    END IF;

    -- Idempotent: if already completed with clock_out_reason='lunch_end',
    -- find and return the work segment that was created
    IF v_shift.status = 'completed' AND v_shift.clock_out_reason = 'lunch_end' THEN
        SELECT * INTO v_existing_work
        FROM shifts
        WHERE work_body_id = v_shift.work_body_id
          AND is_lunch = false
          AND clocked_in_at >= v_shift.clocked_out_at - INTERVAL '1 second'
        ORDER BY clocked_in_at ASC
        LIMIT 1;

        IF FOUND THEN
            RETURN jsonb_build_object(
                'status', 'already_processed',
                'new_shift_id', v_existing_work.id,
                'work_body_id', v_existing_work.work_body_id,
                'started_at', v_existing_work.clocked_in_at
            );
        END IF;
    END IF;

    -- Validate: shift must be active
    IF v_shift.status != 'active' THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Shift is not active');
    END IF;

    -- Validate: must be a lunch segment
    IF v_shift.is_lunch != true THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Shift is not a lunch segment');
    END IF;

    -- Close the lunch segment
    UPDATE shifts SET
        status = 'completed',
        clocked_out_at = v_now,
        clock_out_reason = 'lunch_end',
        updated_at = NOW()
    WHERE id = p_shift_id;

    -- Create new work segment
    INSERT INTO shifts (
        employee_id,
        status,
        clocked_in_at,
        is_lunch,
        work_body_id,
        shift_type,
        clock_in_location_id,
        clock_in_cluster_id,
        app_version
    ) VALUES (
        v_user_id,
        'active',
        v_now,
        false,
        v_shift.work_body_id,
        v_shift.shift_type,
        v_shift.clock_in_location_id,
        v_shift.clock_in_cluster_id,
        v_shift.app_version
    )
    RETURNING id INTO v_new_shift_id;

    -- Redistribute GPS points captured after p_at to the new work segment
    UPDATE gps_points SET
        shift_id = v_new_shift_id
    WHERE shift_id = p_shift_id
      AND captured_at >= v_now;

    RETURN jsonb_build_object(
        'status', 'success',
        'new_shift_id', v_new_shift_id,
        'work_body_id', v_shift.work_body_id,
        'started_at', v_now
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public, extensions;
