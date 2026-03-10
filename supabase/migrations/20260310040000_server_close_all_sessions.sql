-- Migration: Server-side session cleanup on device change or sign-out
--
-- Problem: Session closure depended on the OLD phone detecting device change
-- and executing clock-out locally. If old phone is dead/offline, sessions
-- stay open forever (Celine's 21h18 maintenance session).
--
-- Fix: server_close_all_sessions() atomically closes everything server-side.
-- Called from register_device_login() and sign_out_cleanup().
--
-- Note: Cleaning sessions closed by this function do NOT get is_flagged/flag_reason
-- computed (unlike the shift-complete trigger in 036 which calls _compute_cleaning_flags).
-- This is intentional — server_auto_close is an emergency/abnormal path and these sessions
-- should be reviewed by a supervisor anyway.
--
-- Note: server_close_all_sessions() is for INTERNAL use only (called by
-- register_device_login and sign_out_cleanup). Not intended as a public RPC.

-- ============ 1. Core function: close all sessions for an employee ============
CREATE OR REPLACE FUNCTION server_close_all_sessions(p_employee_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cleaning_closed INT;
  v_maintenance_closed INT;
  v_shifts_closed INT;
  v_lunch_closed INT;
BEGIN
  -- Step 1: Close active cleaning sessions
  UPDATE cleaning_sessions
  SET status = 'auto_closed',
      completed_at = now(),
      duration_minutes = ROUND(EXTRACT(EPOCH FROM (now() - started_at)) / 60.0, 2)
  WHERE employee_id = p_employee_id
    AND status = 'in_progress';
  GET DIAGNOSTICS v_cleaning_closed = ROW_COUNT;

  -- Step 2: Close active maintenance sessions
  UPDATE maintenance_sessions
  SET status = 'auto_closed',
      completed_at = now(),
      duration_minutes = ROUND(EXTRACT(EPOCH FROM (now() - started_at)) / 60.0, 2)
  WHERE employee_id = p_employee_id
    AND status = 'in_progress';
  GET DIAGNOSTICS v_maintenance_closed = ROW_COUNT;

  -- Step 3: Close active lunch breaks
  UPDATE lunch_breaks
  SET ended_at = now()
  WHERE employee_id = p_employee_id
    AND ended_at IS NULL;
  GET DIAGNOSTICS v_lunch_closed = ROW_COUNT;

  -- Step 4: Close active shifts (AFTER sessions so trigger finds nothing to double-process)
  UPDATE shifts
  SET status = 'completed',
      clocked_out_at = now(),
      clock_out_reason = 'server_auto_close'
  WHERE employee_id = p_employee_id
    AND status = 'active';
  GET DIAGNOSTICS v_shifts_closed = ROW_COUNT;

  RETURN jsonb_build_object(
    'success', true,
    'shifts_closed', v_shifts_closed,
    'cleaning_closed', v_cleaning_closed,
    'maintenance_closed', v_maintenance_closed,
    'lunch_closed', v_lunch_closed
  );
END;
$$;

-- ============ 2. Updated register_device_login: close sessions on device change ============
CREATE OR REPLACE FUNCTION register_device_login(
  p_device_id TEXT,
  p_device_platform TEXT DEFAULT NULL,
  p_device_os_version TEXT DEFAULT NULL,
  p_device_model TEXT DEFAULT NULL,
  p_app_version TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID;
  v_old_device_id TEXT;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('error', 'not_authenticated');
  END IF;

  -- Check if employee has a DIFFERENT active device -> close all sessions first
  SELECT device_id INTO v_old_device_id
  FROM active_device_sessions
  WHERE employee_id = v_user_id;

  IF v_old_device_id IS NOT NULL AND v_old_device_id != p_device_id THEN
    PERFORM server_close_all_sessions(v_user_id);
  END IF;

  -- Unmark any current device for this employee
  UPDATE employee_devices
    SET is_current = false
    WHERE employee_id = v_user_id AND is_current = true;

  -- Upsert the device record
  INSERT INTO employee_devices (employee_id, device_id, platform, os_version, model, app_version, is_current)
    VALUES (v_user_id, p_device_id, p_device_platform, p_device_os_version, p_device_model, p_app_version, true)
    ON CONFLICT (employee_id, device_id)
    DO UPDATE SET
      platform = COALESCE(EXCLUDED.platform, employee_devices.platform),
      os_version = COALESCE(EXCLUDED.os_version, employee_devices.os_version),
      model = COALESCE(EXCLUDED.model, employee_devices.model),
      app_version = COALESCE(EXCLUDED.app_version, employee_devices.app_version),
      last_seen_at = now(),
      is_current = true;

  -- Upsert active device session
  INSERT INTO active_device_sessions (employee_id, device_id, session_started_at)
    VALUES (v_user_id, p_device_id, now())
    ON CONFLICT (employee_id)
    DO UPDATE SET
      device_id = EXCLUDED.device_id,
      session_started_at = now();

  -- Update legacy employee_profiles columns
  UPDATE employee_profiles SET
    device_platform = p_device_platform,
    device_os_version = p_device_os_version,
    device_model = p_device_model,
    device_app_version = p_app_version,
    device_updated_at = now()
  WHERE id = v_user_id;

  RETURN jsonb_build_object('success', true, 'device_id', p_device_id);
END;
$$;

-- ============ 3. New RPC: sign_out_cleanup (called before supabase.auth.signOut) ============
CREATE OR REPLACE FUNCTION sign_out_cleanup()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id UUID;
  v_result JSONB;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('error', 'not_authenticated');
  END IF;

  -- Close all active sessions/shifts
  v_result := server_close_all_sessions(v_user_id);

  -- Remove active device session
  DELETE FROM active_device_sessions WHERE employee_id = v_user_id;

  RETURN v_result;
END;
$$;
