-- Migration 037: Add GPS capture to cleaning & maintenance sessions
--
-- Captures GPS position at start and end of every cleaning/maintenance session,
-- providing location proof for each scan-in and scan-out event.

-- ============ CLEANING SESSIONS ============
ALTER TABLE cleaning_sessions ADD COLUMN start_latitude DOUBLE PRECISION;
ALTER TABLE cleaning_sessions ADD COLUMN start_longitude DOUBLE PRECISION;
ALTER TABLE cleaning_sessions ADD COLUMN start_accuracy DOUBLE PRECISION;
ALTER TABLE cleaning_sessions ADD COLUMN end_latitude DOUBLE PRECISION;
ALTER TABLE cleaning_sessions ADD COLUMN end_longitude DOUBLE PRECISION;
ALTER TABLE cleaning_sessions ADD COLUMN end_accuracy DOUBLE PRECISION;

-- ============ MAINTENANCE SESSIONS ============
ALTER TABLE maintenance_sessions ADD COLUMN start_latitude DOUBLE PRECISION;
ALTER TABLE maintenance_sessions ADD COLUMN start_longitude DOUBLE PRECISION;
ALTER TABLE maintenance_sessions ADD COLUMN start_accuracy DOUBLE PRECISION;
ALTER TABLE maintenance_sessions ADD COLUMN end_latitude DOUBLE PRECISION;
ALTER TABLE maintenance_sessions ADD COLUMN end_longitude DOUBLE PRECISION;
ALTER TABLE maintenance_sessions ADD COLUMN end_accuracy DOUBLE PRECISION;

-- ============ UPDATE scan_in RPC ============
CREATE OR REPLACE FUNCTION scan_in(
  p_employee_id UUID,
  p_qr_code TEXT,
  p_shift_id UUID,
  p_latitude DOUBLE PRECISION DEFAULT NULL,
  p_longitude DOUBLE PRECISION DEFAULT NULL,
  p_accuracy DOUBLE PRECISION DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_studio RECORD; v_existing_session RECORD; v_session_id UUID;
BEGIN
  SELECT s.id, s.studio_number, s.studio_type, s.is_active, b.name AS building_name
  INTO v_studio FROM studios s JOIN buildings b ON s.building_id = b.id WHERE s.qr_code = p_qr_code;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_QR_CODE', 'message', 'QR code not found');
  END IF;
  IF NOT v_studio.is_active THEN
    RETURN jsonb_build_object('success', false, 'error', 'STUDIO_INACTIVE', 'message', 'Studio is no longer active');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM shifts WHERE id = p_shift_id AND status = 'active') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NO_ACTIVE_SHIFT', 'message', 'No active shift found');
  END IF;
  SELECT id INTO v_existing_session FROM cleaning_sessions
  WHERE employee_id = p_employee_id AND studio_id = v_studio.id AND status = 'in_progress';
  IF FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'SESSION_EXISTS', 'message', 'Active session already exists for this studio', 'existing_session_id', v_existing_session.id);
  END IF;
  INSERT INTO cleaning_sessions (employee_id, studio_id, shift_id, status, started_at, start_latitude, start_longitude, start_accuracy)
  VALUES (p_employee_id, v_studio.id, p_shift_id, 'in_progress', now(), p_latitude, p_longitude, p_accuracy) RETURNING id INTO v_session_id;
  RETURN jsonb_build_object('success', true, 'session_id', v_session_id,
    'studio', jsonb_build_object('id', v_studio.id, 'studio_number', v_studio.studio_number, 'building_name', v_studio.building_name, 'studio_type', v_studio.studio_type),
    'started_at', now());
END;
$$;

-- ============ UPDATE scan_out RPC ============
CREATE OR REPLACE FUNCTION scan_out(
  p_employee_id UUID,
  p_qr_code TEXT,
  p_latitude DOUBLE PRECISION DEFAULT NULL,
  p_longitude DOUBLE PRECISION DEFAULT NULL,
  p_accuracy DOUBLE PRECISION DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_studio RECORD; v_session RECORD; v_duration NUMERIC; v_flags RECORD;
BEGIN
  SELECT s.id, s.studio_number, s.studio_type, b.name AS building_name
  INTO v_studio FROM studios s JOIN buildings b ON s.building_id = b.id WHERE s.qr_code = p_qr_code;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_QR_CODE', 'message', 'QR code not found');
  END IF;
  SELECT id, started_at INTO v_session FROM cleaning_sessions
  WHERE employee_id = p_employee_id AND studio_id = v_studio.id AND status = 'in_progress';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'NO_ACTIVE_SESSION', 'message', 'No active cleaning session for this studio');
  END IF;
  v_duration := EXTRACT(EPOCH FROM (now() - v_session.started_at)) / 60.0;
  SELECT * INTO v_flags FROM _compute_cleaning_flags(v_studio.studio_type, v_duration);
  UPDATE cleaning_sessions SET status = 'completed', completed_at = now(), duration_minutes = ROUND(v_duration, 2),
    is_flagged = v_flags.is_flagged, flag_reason = v_flags.flag_reason,
    end_latitude = p_latitude, end_longitude = p_longitude, end_accuracy = p_accuracy
  WHERE id = v_session.id;
  RETURN jsonb_build_object('success', true, 'session_id', v_session.id,
    'studio', jsonb_build_object('id', v_studio.id, 'studio_number', v_studio.studio_number, 'building_name', v_studio.building_name, 'studio_type', v_studio.studio_type),
    'started_at', v_session.started_at, 'completed_at', now(), 'duration_minutes', ROUND(v_duration, 2), 'is_flagged', v_flags.is_flagged);
END;
$$;
