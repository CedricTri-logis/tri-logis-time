-- Migration 028: Auto-close stale shifts on clock-in + cleanup duplicates on clock-out
--
-- Problem: If a clock-out fails to sync to the server (network blip, app killed
-- for update), the shift stays "active" on the server indefinitely. The employee
-- sees they're clocked out locally, but the server never learns.
--
-- Fix:
-- 1. clock_in: Auto-close any stale active shift (no heartbeat for 15+ min)
--    instead of rejecting the clock-in. Only reject if the shift is genuinely
--    fresh (heartbeat < 15 min ago).
-- 2. clock_out: Also close any OTHER active shifts for the same employee
--    as a duplicate cleanup safety net.

-- -----------------------------------------------------------------------------
-- 1. Update clock_in to auto-close stale active shifts
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clock_in(
    p_request_id UUID,
    p_location JSONB DEFAULT NULL,
    p_accuracy DECIMAL DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID;
    v_existing_shift shifts%ROWTYPE;
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

-- -----------------------------------------------------------------------------
-- 2. Update clock_out to also close any duplicate active shifts
-- -----------------------------------------------------------------------------
-- Drop the old 4-param version first (no p_reason parameter).
-- Without this, CREATE OR REPLACE creates a second overloaded function
-- instead of replacing the existing one, causing PostgREST HTTP 300 errors.
DROP FUNCTION IF EXISTS clock_out(UUID, UUID, JSONB, NUMERIC);

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

    -- Close the requested shift
    UPDATE shifts SET
        status = 'completed',
        clocked_out_at = NOW(),
        clock_out_location = p_location,
        clock_out_accuracy = p_accuracy,
        clock_out_reason = p_reason
    WHERE id = p_shift_id
    RETURNING * INTO v_shift;

    -- Also close any OTHER active shifts for this employee (cleanup duplicates)
    UPDATE shifts SET
        status = 'completed',
        clocked_out_at = NOW(),
        clock_out_reason = 'auto_duplicate_cleanup'
    WHERE employee_id = v_user_id
      AND status = 'active'
      AND id != p_shift_id;

    RETURN jsonb_build_object(
        'status', 'success',
        'shift_id', v_shift.id,
        'clocked_out_at', v_shift.clocked_out_at
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
