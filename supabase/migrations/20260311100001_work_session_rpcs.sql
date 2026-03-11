-- =============================================================================
-- Migration: 20260311100001_work_session_rpcs
-- Description: Unified work session RPCs replacing cleaning/maintenance-specific RPCs
-- Creates: start_work_session, complete_work_session, auto_close_work_sessions,
--          manually_close_work_session, get_active_work_session, get_work_sessions_dashboard
-- =============================================================================

-- =============================================================================
-- RPC 1: start_work_session
-- Replaces: scan_in (cleaning) and start_maintenance
-- =============================================================================
CREATE OR REPLACE FUNCTION start_work_session(
  p_employee_id UUID,
  p_shift_id UUID,
  p_activity_type TEXT,
  p_studio_id UUID DEFAULT NULL,
  p_qr_code TEXT DEFAULT NULL,
  p_building_id UUID DEFAULT NULL,
  p_apartment_id UUID DEFAULT NULL,
  p_latitude DOUBLE PRECISION DEFAULT NULL,
  p_longitude DOUBLE PRECISION DEFAULT NULL,
  p_accuracy DOUBLE PRECISION DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_shift RECORD;
  v_studio RECORD;
  v_building RECORD;
  v_apartment RECORD;
  v_existing RECORD;
  v_session_id UUID;
  v_location_type TEXT;
  v_resolved_studio_id UUID;
  v_now TIMESTAMPTZ := now();
BEGIN
  -- 1. Validate activity_type
  IF p_activity_type NOT IN ('cleaning', 'maintenance', 'admin') THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_ACTIVITY_TYPE');
  END IF;

  -- 2. Validate shift is active
  SELECT id, status INTO v_shift FROM shifts
  WHERE id = p_shift_id AND employee_id = p_employee_id;
  IF NOT FOUND OR v_shift.status != 'active' THEN
    RETURN jsonb_build_object('success', false, 'error', 'NO_ACTIVE_SHIFT');
  END IF;

  -- 3. Resolve studio (cleaning)
  IF p_activity_type = 'cleaning' THEN
    IF p_qr_code IS NOT NULL THEN
      SELECT id, studio_number, building_id, studio_type, is_active,
             b.name AS building_name
      INTO v_studio
      FROM studios s JOIN buildings b ON b.id = s.building_id
      WHERE s.qr_code = p_qr_code;
      IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_QR_CODE');
      END IF;
      IF NOT v_studio.is_active THEN
        RETURN jsonb_build_object('success', false, 'error', 'STUDIO_INACTIVE');
      END IF;
      v_resolved_studio_id := v_studio.id;
    ELSIF p_studio_id IS NOT NULL THEN
      v_resolved_studio_id := p_studio_id;
      SELECT id, studio_number, building_id, studio_type,
             b.name AS building_name
      INTO v_studio
      FROM studios s JOIN buildings b ON b.id = s.building_id
      WHERE s.id = p_studio_id;
    ELSE
      RETURN jsonb_build_object('success', false, 'error', 'STUDIO_REQUIRED');
    END IF;
    v_location_type := 'studio';
  END IF;

  -- 4. Resolve building/apartment (maintenance)
  IF p_activity_type = 'maintenance' THEN
    IF p_building_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'BUILDING_REQUIRED');
    END IF;
    SELECT id, name INTO v_building FROM property_buildings WHERE id = p_building_id;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'BUILDING_NOT_FOUND');
    END IF;
    IF p_apartment_id IS NOT NULL THEN
      SELECT id, unit_number INTO v_apartment FROM apartments
      WHERE id = p_apartment_id AND building_id = p_building_id;
      IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'APARTMENT_NOT_FOUND');
      END IF;
      v_location_type := 'apartment';
    ELSE
      v_location_type := 'building';
    END IF;
  END IF;

  -- 5. Admin: no location
  IF p_activity_type = 'admin' THEN
    v_location_type := 'office';
  END IF;

  -- 6. Double-tap protection (same location < 5 seconds)
  SELECT id, started_at INTO v_existing FROM work_sessions
  WHERE employee_id = p_employee_id
    AND status = 'in_progress'
    AND activity_type = p_activity_type
    AND (
      (p_activity_type = 'cleaning' AND studio_id = v_resolved_studio_id)
      OR (p_activity_type = 'maintenance' AND building_id = p_building_id
          AND apartment_id IS NOT DISTINCT FROM p_apartment_id)
      OR (p_activity_type = 'admin')
    )
    AND started_at > v_now - INTERVAL '5 seconds'
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', true,
      'session_id', v_existing.id,
      'started_at', v_existing.started_at,
      'deduplicated', true
    );
  END IF;

  -- 7. Auto-close any active sessions for this employee
  UPDATE work_sessions
  SET status = 'manually_closed',
      completed_at = v_now,
      duration_minutes = EXTRACT(EPOCH FROM (v_now - started_at)) / 60.0,
      updated_at = v_now
  WHERE employee_id = p_employee_id AND status = 'in_progress';

  -- Also close old-table sessions (Phase 1 compatibility)
  UPDATE cleaning_sessions
  SET status = 'manually_closed',
      completed_at = v_now,
      duration_minutes = EXTRACT(EPOCH FROM (v_now - started_at)) / 60.0,
      updated_at = v_now
  WHERE employee_id = p_employee_id AND status = 'in_progress';

  UPDATE maintenance_sessions
  SET status = 'manually_closed',
      completed_at = v_now,
      duration_minutes = EXTRACT(EPOCH FROM (v_now - started_at)) / 60.0,
      updated_at = v_now
  WHERE employee_id = p_employee_id AND status = 'in_progress';

  -- 8. Create new session
  INSERT INTO work_sessions (
    employee_id, shift_id, activity_type, location_type,
    studio_id, building_id, apartment_id,
    status, started_at,
    start_latitude, start_longitude, start_accuracy
  ) VALUES (
    p_employee_id, p_shift_id, p_activity_type, v_location_type,
    v_resolved_studio_id, p_building_id, p_apartment_id,
    'in_progress', v_now,
    p_latitude, p_longitude, p_accuracy
  ) RETURNING id INTO v_session_id;

  -- 9. Return result
  RETURN jsonb_build_object(
    'success', true,
    'session_id', v_session_id,
    'activity_type', p_activity_type,
    'location_type', v_location_type,
    'started_at', v_now,
    'building_name', COALESCE(v_building.name, v_studio.building_name),
    'studio_number', v_studio.studio_number,
    'unit_number', v_apartment.unit_number,
    'deduplicated', false
  );
END;
$$;

-- =============================================================================
-- RPC 2: complete_work_session
-- Replaces: scan_out (cleaning) and complete_maintenance
-- =============================================================================
CREATE OR REPLACE FUNCTION complete_work_session(
  p_employee_id UUID,
  p_session_id UUID DEFAULT NULL,
  p_qr_code TEXT DEFAULT NULL,
  p_latitude DOUBLE PRECISION DEFAULT NULL,
  p_longitude DOUBLE PRECISION DEFAULT NULL,
  p_accuracy DOUBLE PRECISION DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_session RECORD;
  v_duration NUMERIC;
  v_is_flagged BOOLEAN := false;
  v_flag_reason TEXT;
  v_studio_type TEXT;
  v_now TIMESTAMPTZ := now();
BEGIN
  -- Find session: by ID, by QR code, or just the active one
  IF p_session_id IS NOT NULL THEN
    SELECT ws.*, s.studio_type
    INTO v_session
    FROM work_sessions ws
    LEFT JOIN studios s ON s.id = ws.studio_id
    WHERE ws.id = p_session_id AND ws.employee_id = p_employee_id;
  ELSIF p_qr_code IS NOT NULL THEN
    SELECT ws.*, s.studio_type
    INTO v_session
    FROM work_sessions ws
    JOIN studios s ON s.id = ws.studio_id
    WHERE ws.employee_id = p_employee_id
      AND ws.status = 'in_progress'
      AND s.qr_code = p_qr_code;
  ELSE
    SELECT ws.*, s.studio_type
    INTO v_session
    FROM work_sessions ws
    LEFT JOIN studios s ON s.id = ws.studio_id
    WHERE ws.employee_id = p_employee_id
      AND ws.status = 'in_progress'
    ORDER BY ws.started_at DESC LIMIT 1;
  END IF;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'NO_ACTIVE_SESSION');
  END IF;

  -- Compute duration
  v_duration := EXTRACT(EPOCH FROM (v_now - v_session.started_at)) / 60.0;

  -- Compute flags (cleaning only)
  IF v_session.activity_type = 'cleaning' AND v_session.studio_type IS NOT NULL THEN
    SELECT cf.is_flagged, cf.flag_reason
    INTO v_is_flagged, v_flag_reason
    FROM _compute_cleaning_flags(v_session.studio_type::studio_type, v_duration) cf;
  END IF;

  -- Update session
  UPDATE work_sessions SET
    status = 'completed',
    completed_at = v_now,
    duration_minutes = v_duration,
    is_flagged = v_is_flagged,
    flag_reason = v_flag_reason,
    end_latitude = p_latitude,
    end_longitude = p_longitude,
    end_accuracy = p_accuracy,
    updated_at = v_now
  WHERE id = v_session.id;

  RETURN jsonb_build_object(
    'success', true,
    'session_id', v_session.id,
    'activity_type', v_session.activity_type,
    'duration_minutes', round(v_duration, 2),
    'completed_at', v_now,
    'is_flagged', v_is_flagged,
    'flag_reason', v_flag_reason
  );
END;
$$;

-- =============================================================================
-- RPC 3: auto_close_work_sessions
-- Auto-closes all in-progress sessions when a shift ends
-- =============================================================================
CREATE OR REPLACE FUNCTION auto_close_work_sessions(
  p_shift_id UUID,
  p_employee_id UUID,
  p_closed_at TIMESTAMPTZ DEFAULT now()
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_closed_count INT := 0;
  v_rec RECORD;
  v_is_flagged BOOLEAN;
  v_flag_reason TEXT;
  v_duration NUMERIC;
BEGIN
  FOR v_rec IN
    SELECT ws.id, ws.started_at, ws.activity_type, ws.studio_id, s.studio_type
    FROM work_sessions ws
    LEFT JOIN studios s ON s.id = ws.studio_id
    WHERE ws.shift_id = p_shift_id
      AND ws.employee_id = p_employee_id
      AND ws.status = 'in_progress'
  LOOP
    v_duration := EXTRACT(EPOCH FROM (p_closed_at - v_rec.started_at)) / 60.0;
    v_is_flagged := false;
    v_flag_reason := NULL;

    IF v_rec.activity_type = 'cleaning' AND v_rec.studio_type IS NOT NULL THEN
      SELECT cf.is_flagged, cf.flag_reason
      INTO v_is_flagged, v_flag_reason
      FROM _compute_cleaning_flags(v_rec.studio_type::studio_type, v_duration) cf;
    END IF;

    UPDATE work_sessions SET
      status = 'auto_closed',
      completed_at = p_closed_at,
      duration_minutes = v_duration,
      is_flagged = v_is_flagged,
      flag_reason = v_flag_reason,
      updated_at = now()
    WHERE id = v_rec.id;

    v_closed_count := v_closed_count + 1;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'closed_count', v_closed_count);
END;
$$;

-- =============================================================================
-- RPC 4: manually_close_work_session
-- Allows employee or supervisor to manually close a session
-- =============================================================================
CREATE OR REPLACE FUNCTION manually_close_work_session(
  p_employee_id UUID,
  p_session_id UUID,
  p_closed_at TIMESTAMPTZ DEFAULT now()
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_session RECORD;
  v_duration NUMERIC;
  v_is_flagged BOOLEAN := false;
  v_flag_reason TEXT;
BEGIN
  SELECT ws.*, s.studio_type INTO v_session
  FROM work_sessions ws
  LEFT JOIN studios s ON s.id = ws.studio_id
  WHERE ws.id = p_session_id AND ws.employee_id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'SESSION_NOT_FOUND');
  END IF;
  IF v_session.status != 'in_progress' THEN
    RETURN jsonb_build_object('success', false, 'error', 'SESSION_NOT_ACTIVE');
  END IF;

  v_duration := EXTRACT(EPOCH FROM (p_closed_at - v_session.started_at)) / 60.0;

  IF v_session.activity_type = 'cleaning' AND v_session.studio_type IS NOT NULL THEN
    SELECT cf.is_flagged, cf.flag_reason
    INTO v_is_flagged, v_flag_reason
    FROM _compute_cleaning_flags(v_session.studio_type::studio_type, v_duration) cf;
  END IF;

  UPDATE work_sessions SET
    status = 'manually_closed',
    completed_at = p_closed_at,
    duration_minutes = v_duration,
    is_flagged = v_is_flagged,
    flag_reason = v_flag_reason,
    updated_at = now()
  WHERE id = p_session_id;

  RETURN jsonb_build_object(
    'success', true,
    'session_id', p_session_id,
    'status', 'manually_closed',
    'duration_minutes', round(v_duration, 2)
  );
END;
$$;

-- =============================================================================
-- RPC 5: get_active_work_session
-- Returns the current in-progress session for an employee (or NULL)
-- =============================================================================
CREATE OR REPLACE FUNCTION get_active_work_session(
  p_employee_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER STABLE
AS $$
DECLARE
  v_session RECORD;
BEGIN
  SELECT ws.*,
    s.studio_number, s.studio_type, b_clean.name AS studio_building_name,
    pb.name AS building_name, a.unit_number
  INTO v_session
  FROM work_sessions ws
  LEFT JOIN studios s ON s.id = ws.studio_id
  LEFT JOIN buildings b_clean ON b_clean.id = s.building_id
  LEFT JOIN property_buildings pb ON pb.id = ws.building_id
  LEFT JOIN apartments a ON a.id = ws.apartment_id
  WHERE ws.employee_id = p_employee_id AND ws.status = 'in_progress'
  ORDER BY ws.started_at DESC LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'session_id', v_session.id,
    'activity_type', v_session.activity_type,
    'location_type', v_session.location_type,
    'studio_number', v_session.studio_number,
    'studio_type', v_session.studio_type,
    'building_name', COALESCE(v_session.building_name, v_session.studio_building_name),
    'unit_number', v_session.unit_number,
    'started_at', v_session.started_at
  );
END;
$$;

-- =============================================================================
-- RPC 6: get_work_sessions_dashboard
-- Dashboard view with summary stats and paginated session list
-- =============================================================================
CREATE OR REPLACE FUNCTION get_work_sessions_dashboard(
  p_activity_type TEXT DEFAULT NULL,
  p_building_id UUID DEFAULT NULL,
  p_employee_id UUID DEFAULT NULL,
  p_date_from DATE DEFAULT CURRENT_DATE,
  p_date_to DATE DEFAULT CURRENT_DATE,
  p_status TEXT DEFAULT NULL,
  p_limit INT DEFAULT 50,
  p_offset INT DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER STABLE
AS $$
DECLARE
  v_summary JSONB;
  v_sessions JSONB;
  v_total INT;
BEGIN
  -- Summary
  SELECT jsonb_build_object(
    'total_sessions', count(*),
    'completed', count(*) FILTER (WHERE ws.status = 'completed'),
    'in_progress', count(*) FILTER (WHERE ws.status = 'in_progress'),
    'auto_closed', count(*) FILTER (WHERE ws.status = 'auto_closed'),
    'manually_closed', count(*) FILTER (WHERE ws.status = 'manually_closed'),
    'avg_duration_minutes', round(avg(ws.duration_minutes) FILTER (WHERE ws.status IN ('completed','auto_closed','manually_closed')), 1),
    'flagged_count', count(*) FILTER (WHERE ws.is_flagged = true),
    'by_type', jsonb_build_object(
      'cleaning', count(*) FILTER (WHERE ws.activity_type = 'cleaning'),
      'maintenance', count(*) FILTER (WHERE ws.activity_type = 'maintenance'),
      'admin', count(*) FILTER (WHERE ws.activity_type = 'admin')
    )
  ) INTO v_summary
  FROM work_sessions ws
  WHERE ws.started_at::date BETWEEN p_date_from AND p_date_to
    AND (p_activity_type IS NULL OR ws.activity_type = p_activity_type)
    AND (p_employee_id IS NULL OR ws.employee_id = p_employee_id)
    AND (p_building_id IS NULL OR ws.building_id = p_building_id
         OR ws.studio_id IN (SELECT id FROM studios WHERE building_id IN (
           SELECT id FROM buildings WHERE id::text = p_building_id::text
         )))
    AND (p_status IS NULL OR ws.status = p_status);

  -- Count for pagination
  SELECT count(*) INTO v_total
  FROM work_sessions ws
  WHERE ws.started_at::date BETWEEN p_date_from AND p_date_to
    AND (p_activity_type IS NULL OR ws.activity_type = p_activity_type)
    AND (p_employee_id IS NULL OR ws.employee_id = p_employee_id)
    AND (p_building_id IS NULL OR ws.building_id = p_building_id)
    AND (p_status IS NULL OR ws.status = p_status);

  -- Paginated sessions
  SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::jsonb) INTO v_sessions
  FROM (
    SELECT
      ws.id, ws.employee_id, ws.activity_type, ws.location_type,
      ws.status, ws.started_at, ws.completed_at,
      round(ws.duration_minutes, 2) AS duration_minutes,
      ws.is_flagged, ws.flag_reason, ws.notes,
      ep.full_name AS employee_name,
      s.studio_number, s.studio_type::text,
      COALESCE(pb.name, b.name) AS building_name,
      a.unit_number
    FROM work_sessions ws
    JOIN employee_profiles ep ON ep.id = ws.employee_id
    LEFT JOIN studios s ON s.id = ws.studio_id
    LEFT JOIN buildings b ON b.id = s.building_id
    LEFT JOIN property_buildings pb ON pb.id = ws.building_id
    LEFT JOIN apartments a ON a.id = ws.apartment_id
    WHERE ws.started_at::date BETWEEN p_date_from AND p_date_to
      AND (p_activity_type IS NULL OR ws.activity_type = p_activity_type)
      AND (p_employee_id IS NULL OR ws.employee_id = p_employee_id)
      AND (p_building_id IS NULL OR ws.building_id = p_building_id)
      AND (p_status IS NULL OR ws.status = p_status)
    ORDER BY ws.started_at DESC
    LIMIT p_limit OFFSET p_offset
  ) t;

  RETURN jsonb_build_object(
    'summary', v_summary,
    'sessions', v_sessions,
    'total_count', v_total
  );
END;
$$;
