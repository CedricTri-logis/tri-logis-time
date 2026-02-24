-- =============================================================================
-- Migration 018: Maintenance Session Tracking
-- Feature: 017-maintenance-sessions (renumbered after property data)
-- References property_buildings/apartments instead of cleaning buildings/studios
-- =============================================================================

-- Enum: maintenance session status
CREATE TYPE maintenance_session_status AS ENUM ('in_progress', 'completed', 'auto_closed', 'manually_closed');

-- Table: maintenance_sessions
CREATE TABLE maintenance_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
  shift_id UUID NOT NULL REFERENCES shifts(id) ON DELETE CASCADE,
  building_id UUID NOT NULL REFERENCES property_buildings(id) ON DELETE CASCADE,
  apartment_id UUID REFERENCES apartments(id) ON DELETE SET NULL,
  status maintenance_session_status NOT NULL DEFAULT 'in_progress',
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  duration_minutes NUMERIC(10,2),
  notes TEXT,
  sync_status TEXT DEFAULT 'synced',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_maintenance_completed_after_started CHECK (completed_at IS NULL OR completed_at > started_at),
  CONSTRAINT chk_maintenance_duration_positive CHECK (duration_minutes IS NULL OR duration_minutes >= 0)
);

-- Indexes
CREATE INDEX idx_maintenance_sessions_employee_status ON maintenance_sessions(employee_id, status);
CREATE INDEX idx_maintenance_sessions_shift ON maintenance_sessions(shift_id);
CREATE INDEX idx_maintenance_sessions_building ON maintenance_sessions(building_id);
CREATE INDEX idx_maintenance_sessions_active ON maintenance_sessions(status) WHERE status = 'in_progress';

-- Trigger: auto-update updated_at
CREATE TRIGGER trg_maintenance_sessions_updated_at
  BEFORE UPDATE ON maintenance_sessions
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- =============================================================================
-- RLS Policies
-- =============================================================================

ALTER TABLE maintenance_sessions ENABLE ROW LEVEL SECURITY;

-- Employees can read own sessions
CREATE POLICY maintenance_sessions_select_own ON maintenance_sessions
  FOR SELECT TO authenticated
  USING (employee_id = auth.uid());

-- Supervisors can read supervised employee sessions
CREATE POLICY maintenance_sessions_select_supervised ON maintenance_sessions
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM employee_supervisors
      WHERE manager_id = auth.uid() AND employee_id = maintenance_sessions.employee_id
    )
  );

-- Admin/super_admin can read all
CREATE POLICY maintenance_sessions_select_admin ON maintenance_sessions
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM employee_profiles
      WHERE id = auth.uid() AND role IN ('admin', 'super_admin')
    )
  );

-- Employees can insert own sessions
CREATE POLICY maintenance_sessions_insert_own ON maintenance_sessions
  FOR INSERT TO authenticated
  WITH CHECK (employee_id = auth.uid());

-- Employees can update own in_progress sessions
CREATE POLICY maintenance_sessions_update_own ON maintenance_sessions
  FOR UPDATE TO authenticated
  USING (employee_id = auth.uid() AND status = 'in_progress');

-- Supervisors can update supervised employee sessions
CREATE POLICY maintenance_sessions_update_supervised ON maintenance_sessions
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM employee_supervisors
      WHERE manager_id = auth.uid() AND employee_id = maintenance_sessions.employee_id
    )
  );

-- Admin/super_admin can update all
CREATE POLICY maintenance_sessions_update_admin ON maintenance_sessions
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM employee_profiles
      WHERE id = auth.uid() AND role IN ('admin', 'super_admin')
    )
  );

-- =============================================================================
-- RPC Functions (reference property_buildings/apartments)
-- =============================================================================

-- RPC: start_maintenance
CREATE OR REPLACE FUNCTION start_maintenance(
  p_employee_id UUID,
  p_shift_id UUID,
  p_building_id UUID,
  p_apartment_id UUID DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_building RECORD;
  v_apartment RECORD;
  v_session_id UUID;
BEGIN
  -- Validate shift exists and is active
  IF NOT EXISTS (SELECT 1 FROM shifts WHERE id = p_shift_id AND status = 'active') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NO_ACTIVE_SHIFT', 'message', 'No active shift found');
  END IF;

  -- Check for existing active cleaning session (cross-feature)
  IF EXISTS (SELECT 1 FROM cleaning_sessions WHERE employee_id = p_employee_id AND status = 'in_progress') THEN
    RETURN jsonb_build_object('success', false, 'error', 'CLEANING_SESSION_ACTIVE', 'message', 'Terminez votre session de ménage avant de commencer un entretien');
  END IF;

  -- Check for existing active maintenance session (one at a time)
  IF EXISTS (SELECT 1 FROM maintenance_sessions WHERE employee_id = p_employee_id AND status = 'in_progress') THEN
    RETURN jsonb_build_object('success', false, 'error', 'MAINTENANCE_SESSION_ACTIVE', 'message', 'Une session d''entretien est déjà en cours');
  END IF;

  -- Validate building exists in property_buildings
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

  -- Create new maintenance session
  INSERT INTO maintenance_sessions (employee_id, shift_id, building_id, apartment_id, status, started_at)
  VALUES (p_employee_id, p_shift_id, p_building_id, p_apartment_id, 'in_progress', now())
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

-- RPC: complete_maintenance
CREATE OR REPLACE FUNCTION complete_maintenance(
  p_employee_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_session RECORD;
  v_duration NUMERIC;
BEGIN
  -- Find active maintenance session
  SELECT ms.id, ms.started_at, b.name AS building_name, a.unit_number
  INTO v_session
  FROM maintenance_sessions ms
  JOIN property_buildings b ON ms.building_id = b.id
  LEFT JOIN apartments a ON ms.apartment_id = a.id
  WHERE ms.employee_id = p_employee_id AND ms.status = 'in_progress'
  ORDER BY ms.started_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'NO_ACTIVE_SESSION', 'message', 'No active maintenance session');
  END IF;

  -- Compute duration
  v_duration := EXTRACT(EPOCH FROM (now() - v_session.started_at)) / 60.0;

  -- Update session
  UPDATE maintenance_sessions
  SET status = 'completed',
      completed_at = now(),
      duration_minutes = ROUND(v_duration, 2)
  WHERE id = v_session.id;

  RETURN jsonb_build_object(
    'success', true,
    'session_id', v_session.id,
    'building_name', v_session.building_name,
    'unit_number', v_session.unit_number,
    'duration_minutes', ROUND(v_duration, 2),
    'completed_at', now()
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- RPC: auto_close_maintenance_sessions
CREATE OR REPLACE FUNCTION auto_close_maintenance_sessions(
  p_shift_id UUID,
  p_employee_id UUID,
  p_closed_at TIMESTAMPTZ
) RETURNS JSONB AS $$
DECLARE
  v_session RECORD;
  v_duration NUMERIC;
  v_closed_count INT := 0;
BEGIN
  FOR v_session IN
    SELECT ms.id, ms.started_at, b.name AS building_name
    FROM maintenance_sessions ms
    JOIN property_buildings b ON ms.building_id = b.id
    WHERE ms.shift_id = p_shift_id
      AND ms.employee_id = p_employee_id
      AND ms.status = 'in_progress'
  LOOP
    v_duration := EXTRACT(EPOCH FROM (p_closed_at - v_session.started_at)) / 60.0;

    UPDATE maintenance_sessions
    SET status = 'auto_closed',
        completed_at = p_closed_at,
        duration_minutes = ROUND(v_duration, 2)
    WHERE id = v_session.id;

    v_closed_count := v_closed_count + 1;
  END LOOP;

  RETURN jsonb_build_object('closed_count', v_closed_count);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- RPC: manually_close_maintenance_session
CREATE OR REPLACE FUNCTION manually_close_maintenance_session(
  p_employee_id UUID,
  p_session_id UUID,
  p_closed_at TIMESTAMPTZ
) RETURNS JSONB AS $$
DECLARE
  v_session RECORD;
  v_duration NUMERIC;
BEGIN
  SELECT id, started_at, status
  INTO v_session
  FROM maintenance_sessions
  WHERE id = p_session_id AND employee_id = p_employee_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'SESSION_NOT_FOUND', 'message', 'Session not found');
  END IF;

  IF v_session.status != 'in_progress' THEN
    RETURN jsonb_build_object('success', false, 'error', 'SESSION_NOT_ACTIVE', 'message', 'Session is not in progress');
  END IF;

  v_duration := EXTRACT(EPOCH FROM (p_closed_at - v_session.started_at)) / 60.0;

  UPDATE maintenance_sessions
  SET status = 'manually_closed',
      completed_at = p_closed_at,
      duration_minutes = ROUND(v_duration, 2)
  WHERE id = p_session_id;

  RETURN jsonb_build_object(
    'success', true,
    'session_id', p_session_id,
    'status', 'manually_closed',
    'duration_minutes', ROUND(v_duration, 2)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
