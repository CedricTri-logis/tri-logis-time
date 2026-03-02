-- Migration 097: Server-side version enforcement in clock_in RPC
--
-- Problem: The minimum app version check is client-side only. Old builds
-- (pre-+87) don't have the check code and bypass it entirely, allowing
-- clock-in without critical safety features like the GPS verification gate.
-- This caused Maeva's 1-hour shift with 0 GPS points on build +83.
--
-- Fix: Add p_app_version parameter to clock_in RPC and reject builds below
-- the minimum_app_version configured in app_config. Old builds that don't
-- pass this parameter are also rejected (NULL → build 0 → below minimum).

-- Helper: extract build number from version string "1.0.0+88" → 88
CREATE OR REPLACE FUNCTION extract_build_number(version_string TEXT)
RETURNS INTEGER AS $$
BEGIN
  RETURN COALESCE(
    NULLIF(split_part(version_string, '+', 2), '')::INTEGER,
    0
  );
EXCEPTION WHEN OTHERS THEN
  RETURN 0;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Updated clock_in with server-side version enforcement
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
    v_recent_shift shifts%ROWTYPE;
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
