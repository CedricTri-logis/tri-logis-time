-- Migration 092: Reopen recent shift on quick re-clock-in (< 30s)
--
-- Problem: When an employee accidentally clocks out and immediately clocks
-- back in (within 30 seconds), a new shift is created and their timer resets
-- to zero. This is confusing and loses the continuity of the original shift.
--
-- Fix: If clock_in detects a recently-completed shift (< 30s ago), reopen it
-- instead of creating a new one. The timer continues from the original time.

CREATE OR REPLACE FUNCTION clock_in(
    p_request_id UUID,
    p_location JSONB DEFAULT NULL,
    p_accuracy DECIMAL DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID;
    v_existing_shift shifts%ROWTYPE;
    v_recent_shift shifts%ROWTYPE;
    v_new_shift shifts%ROWTYPE;
    v_has_consent BOOLEAN;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Not authenticated');
    END IF;

    -- Check for privacy consent (Constitution III)
    SELECT privacy_consent_at IS NOT NULL INTO v_has_consent
    FROM employee_profiles WHERE id = v_user_id;

    IF NOT v_has_consent THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'message', 'Privacy consent required before clock in'
        );
    END IF;

    -- Check for duplicate request (idempotency)
    SELECT * INTO v_existing_shift FROM shifts
    WHERE request_id = p_request_id;

    IF FOUND THEN
        RETURN jsonb_build_object(
            'status', 'already_processed',
            'shift_id', v_existing_shift.id,
            'clocked_in_at', v_existing_shift.clocked_in_at
        );
    END IF;

    -- Check for active shift — auto-close if stale, reject if fresh
    SELECT * INTO v_existing_shift FROM shifts
    WHERE employee_id = v_user_id AND status = 'active';

    IF FOUND THEN
        IF v_existing_shift.last_heartbeat_at IS NULL
           OR v_existing_shift.last_heartbeat_at < NOW() - INTERVAL '15 minutes' THEN
            -- Stale shift: auto-close with last known heartbeat as clock-out time
            UPDATE shifts SET
                status = 'completed',
                clocked_out_at = COALESCE(v_existing_shift.last_heartbeat_at, v_existing_shift.clocked_in_at),
                clock_out_reason = 'auto_clock_in_cleanup'
            WHERE id = v_existing_shift.id;
            -- Fall through to create new shift
        ELSE
            -- Fresh shift with recent heartbeat — genuinely still working
            RETURN jsonb_build_object(
                'status', 'error',
                'message', 'Already clocked in',
                'active_shift_id', v_existing_shift.id
            );
        END IF;
    END IF;

    -- Check for recently-closed shift (< 30s ago) — reopen instead of creating new
    SELECT * INTO v_recent_shift FROM shifts
    WHERE employee_id = v_user_id
      AND status = 'completed'
      AND clocked_out_at > NOW() - INTERVAL '30 seconds'
    ORDER BY clocked_out_at DESC
    LIMIT 1;

    IF FOUND THEN
        -- Reopen the shift: clear clock-out data, set back to active
        UPDATE shifts SET
            status = 'active',
            clocked_out_at = NULL,
            clock_out_location = NULL,
            clock_out_accuracy = NULL,
            clock_out_reason = NULL
        WHERE id = v_recent_shift.id;

        RETURN jsonb_build_object(
            'status', 'reopened',
            'shift_id', v_recent_shift.id,
            'clocked_in_at', v_recent_shift.clocked_in_at
        );
    END IF;

    -- Create new shift
    INSERT INTO shifts (
        employee_id, request_id, clocked_in_at,
        clock_in_location, clock_in_accuracy
    )
    VALUES (v_user_id, p_request_id, NOW(), p_location, p_accuracy)
    RETURNING * INTO v_new_shift;

    RETURN jsonb_build_object(
        'status', 'success',
        'shift_id', v_new_shift.id,
        'clocked_in_at', v_new_shift.clocked_in_at
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
