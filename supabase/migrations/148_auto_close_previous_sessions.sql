-- Migration 148: Auto-close previous sessions when starting a new one
--
-- Problem: scan_in only checks for active sessions on the SAME studio.
-- Scanning a new studio creates a new session without closing the old one.
-- start_maintenance blocks instead of auto-closing.
--
-- Fix: When starting any new session (cleaning or maintenance),
-- auto-close all active sessions for this employee first.
-- Also adds double-tap protection (< 5 seconds = return existing session).

-- ============ UPDATED scan_in ============
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
  v_studio RECORD;
  v_existing_session RECORD;
  v_session_id UUID;
BEGIN
  -- Validate QR code
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

  -- Double-tap protection: if same employee+studio session started < 5 seconds ago, return it
  SELECT id, started_at INTO v_existing_session
  FROM cleaning_sessions
  WHERE employee_id = p_employee_id
    AND studio_id = v_studio.id
    AND status = 'in_progress'
    AND started_at > now() - INTERVAL '5 seconds';
  IF FOUND THEN
    RETURN jsonb_build_object('success', true, 'session_id', v_existing_session.id,
      'studio', jsonb_build_object('id', v_studio.id, 'studio_number', v_studio.studio_number,
        'building_name', v_studio.building_name, 'studio_type', v_studio.studio_type),
      'started_at', v_existing_session.started_at,
      'deduplicated', true);
  END IF;

  -- Auto-close any active cleaning sessions for this employee
  UPDATE cleaning_sessions
  SET status = 'manually_closed',
      completed_at = now(),
      duration_minutes = ROUND(EXTRACT(EPOCH FROM (now() - started_at)) / 60.0, 2)
  WHERE employee_id = p_employee_id
    AND status = 'in_progress';

  -- Auto-close any active maintenance sessions for this employee
  UPDATE maintenance_sessions
  SET status = 'manually_closed',
      completed_at = now(),
      duration_minutes = ROUND(EXTRACT(EPOCH FROM (now() - started_at)) / 60.0, 2)
  WHERE employee_id = p_employee_id
    AND status = 'in_progress';

  -- Create new cleaning session
  INSERT INTO cleaning_sessions (employee_id, studio_id, shift_id, status, started_at,
    start_latitude, start_longitude, start_accuracy)
  VALUES (p_employee_id, v_studio.id, p_shift_id, 'in_progress', now(),
    p_latitude, p_longitude, p_accuracy)
  RETURNING id INTO v_session_id;

  RETURN jsonb_build_object('success', true, 'session_id', v_session_id,
    'studio', jsonb_build_object('id', v_studio.id, 'studio_number', v_studio.studio_number,
      'building_name', v_studio.building_name, 'studio_type', v_studio.studio_type),
    'started_at', now());
END;
$$;

-- ============ UPDATED start_maintenance ============
CREATE OR REPLACE FUNCTION start_maintenance(
  p_employee_id UUID,
  p_shift_id UUID,
  p_building_id UUID,
  p_apartment_id UUID DEFAULT NULL,
  p_latitude DOUBLE PRECISION DEFAULT NULL,
  p_longitude DOUBLE PRECISION DEFAULT NULL,
  p_accuracy DOUBLE PRECISION DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_building RECORD;
  v_apartment RECORD;
  v_session_id UUID;
  v_existing_session RECORD;
BEGIN
  -- Validate shift
  IF NOT EXISTS (SELECT 1 FROM shifts WHERE id = p_shift_id AND status = 'active') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NO_ACTIVE_SHIFT', 'message', 'No active shift found');
  END IF;

  -- Validate building
  SELECT id, name INTO v_building FROM property_buildings WHERE id = p_building_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'BUILDING_NOT_FOUND', 'message', 'Building not found');
  END IF;

  -- Validate apartment if provided
  IF p_apartment_id IS NOT NULL THEN
    SELECT id, unit_number INTO v_apartment FROM apartments WHERE id = p_apartment_id AND building_id = p_building_id;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'APARTMENT_NOT_FOUND', 'message', 'Apartment not found in this building');
    END IF;
  END IF;

  -- Double-tap protection: same employee+building+apartment started < 5 seconds ago
  SELECT id, started_at INTO v_existing_session
  FROM maintenance_sessions
  WHERE employee_id = p_employee_id
    AND building_id = p_building_id
    AND (apartment_id = p_apartment_id OR (apartment_id IS NULL AND p_apartment_id IS NULL))
    AND status = 'in_progress'
    AND started_at > now() - INTERVAL '5 seconds';
  IF FOUND THEN
    RETURN jsonb_build_object('success', true, 'session_id', v_existing_session.id,
      'building_name', v_building.name,
      'unit_number', CASE WHEN v_apartment IS NOT NULL THEN v_apartment.unit_number ELSE NULL END,
      'started_at', v_existing_session.started_at,
      'deduplicated', true);
  END IF;

  -- Auto-close any active cleaning sessions for this employee
  UPDATE cleaning_sessions
  SET status = 'manually_closed',
      completed_at = now(),
      duration_minutes = ROUND(EXTRACT(EPOCH FROM (now() - started_at)) / 60.0, 2)
  WHERE employee_id = p_employee_id
    AND status = 'in_progress';

  -- Auto-close any active maintenance sessions for this employee
  UPDATE maintenance_sessions
  SET status = 'manually_closed',
      completed_at = now(),
      duration_minutes = ROUND(EXTRACT(EPOCH FROM (now() - started_at)) / 60.0, 2)
  WHERE employee_id = p_employee_id
    AND status = 'in_progress';

  -- Create new maintenance session
  INSERT INTO maintenance_sessions (employee_id, shift_id, building_id, apartment_id, status, started_at,
    start_latitude, start_longitude, start_accuracy)
  VALUES (p_employee_id, p_shift_id, p_building_id, p_apartment_id, 'in_progress', now(),
    p_latitude, p_longitude, p_accuracy)
  RETURNING id INTO v_session_id;

  RETURN jsonb_build_object(
    'success', true,
    'session_id', v_session_id,
    'building_name', v_building.name,
    'unit_number', CASE WHEN v_apartment IS NOT NULL THEN v_apartment.unit_number ELSE NULL END,
    'started_at', now()
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
