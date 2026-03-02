-- Migration 111: Remove "reopen recent shift" logic from clock_in
--
-- Reverts the reopen logic added in migration 092 (carried forward in 097).
-- Clock-out is now always final — reopening a shift causes inconsistencies
-- with trip detection, cleaning sessions, GPS tracking, and Live Activities
-- that were already triggered/stopped on clock-out.
-- The dashboard still hides rapid clock-out→clock-in transitions cosmetically.

CREATE OR REPLACE FUNCTION clock_in(
    p_request_id UUID,
    p_location JSONB DEFAULT NULL,
    p_accuracy DECIMAL DEFAULT NULL,
    p_app_version TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID;
    v_existing_shift shifts%ROWTYPE;
    v_new_shift shifts%ROWTYPE;
    v_has_consent BOOLEAN;
    v_min_version TEXT;
    v_min_build INTEGER;
    v_app_build INTEGER;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Not authenticated');
    END IF;

    -- Version enforcement (server-side, cannot be bypassed by old builds)
    SELECT value INTO v_min_version FROM app_config WHERE key = 'minimum_app_version';
    IF v_min_version IS NOT NULL THEN
        v_min_build := extract_build_number(v_min_version);
        v_app_build := extract_build_number(COALESCE(p_app_version, '0'));
        IF v_app_build < v_min_build THEN
            RETURN jsonb_build_object(
                'status', 'error',
                'code', 'version_too_old',
                'message', 'App update required. Minimum version: ' || v_min_version
            );
        END IF;
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

    -- Create new shift (clock-out is always final, no reopen logic)
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
