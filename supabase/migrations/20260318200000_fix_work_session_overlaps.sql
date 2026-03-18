-- =============================================================================
-- Migration: 20260318200000_fix_work_session_overlaps
-- Description:
--   1. Cleanup: truncate overlapping work sessions so s1.completed_at = s2.started_at
--   2. Prevention: add advisory lock in start_work_session to serialize concurrent calls
-- =============================================================================

-- =============================================================================
-- Part 1: Cleanup existing overlaps
-- For each pair where s1 ends after s2 starts (within same shift/employee),
-- truncate s1.completed_at to s2.started_at and recompute duration.
-- =============================================================================
WITH next_session AS (
  -- For each session, find the next session's start time in the same shift
  SELECT ws.id,
    LEAD(ws.started_at) OVER (
      PARTITION BY ws.shift_id, ws.employee_id
      ORDER BY ws.started_at
    ) AS next_start
  FROM work_sessions ws
  WHERE ws.status IN ('completed', 'auto_closed', 'manually_closed')
    AND ws.completed_at IS NOT NULL
),
to_fix AS (
  SELECT ns.id, ns.next_start
  FROM next_session ns
  JOIN work_sessions ws ON ws.id = ns.id
  WHERE ns.next_start IS NOT NULL
    AND ws.completed_at > ns.next_start  -- overlap exists
)
UPDATE work_sessions ws
SET completed_at = tf.next_start,
    duration_minutes = GREATEST(EXTRACT(EPOCH FROM (tf.next_start - ws.started_at)) / 60.0, 0),
    updated_at = now()
FROM to_fix tf
WHERE ws.id = tf.id;

-- =============================================================================
-- Part 2: Prevention — add advisory lock to start_work_session
-- Serialize concurrent calls per employee to prevent race condition
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
  -- *** NEW: Advisory lock per employee to prevent concurrent session creation ***
  PERFORM pg_advisory_xact_lock('work_sessions'::regclass::int, hashtext(p_employee_id::text));

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
      -- Cleaning without studio: check if building_id provided (long-term cleaning)
      IF p_building_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'STUDIO_REQUIRED');
      END IF;
    END IF;
    IF v_resolved_studio_id IS NOT NULL THEN
      v_location_type := 'studio';
    ELSE
      v_location_type := 'apartment';
    END IF;
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
      (p_activity_type = 'cleaning' AND studio_id IS NOT DISTINCT FROM v_resolved_studio_id)
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
