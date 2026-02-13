-- =============================================================================
-- Migration 016: Cleaning Session Tracking via QR Code
-- Feature: 016-cleaning-qr-tracking
-- =============================================================================

-- Part 1: Enums, Tables, Indexes, Triggers (T005)
-- =============================================================================

-- Enum: studio type
CREATE TYPE studio_type AS ENUM ('unit', 'common_area', 'conciergerie');

-- Enum: cleaning session status
CREATE TYPE cleaning_session_status AS ENUM ('in_progress', 'completed', 'auto_closed', 'manually_closed');

-- Table: buildings
CREATE TABLE buildings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Table: studios
CREATE TABLE studios (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  qr_code TEXT NOT NULL UNIQUE,
  studio_number TEXT NOT NULL,
  building_id UUID NOT NULL REFERENCES buildings(id) ON DELETE CASCADE,
  studio_type studio_type NOT NULL DEFAULT 'unit',
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (building_id, studio_number)
);

-- Table: cleaning_sessions
CREATE TABLE cleaning_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
  studio_id UUID NOT NULL REFERENCES studios(id) ON DELETE CASCADE,
  shift_id UUID NOT NULL REFERENCES shifts(id) ON DELETE CASCADE,
  status cleaning_session_status NOT NULL DEFAULT 'in_progress',
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  duration_minutes NUMERIC(10,2),
  is_flagged BOOLEAN NOT NULL DEFAULT false,
  flag_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_completed_after_started CHECK (completed_at IS NULL OR completed_at > started_at),
  CONSTRAINT chk_duration_positive CHECK (duration_minutes IS NULL OR duration_minutes >= 0)
);

-- Indexes
CREATE INDEX idx_cleaning_sessions_employee_status ON cleaning_sessions(employee_id, status);
CREATE INDEX idx_cleaning_sessions_studio_started ON cleaning_sessions(studio_id, started_at);
CREATE INDEX idx_cleaning_sessions_shift ON cleaning_sessions(shift_id);
CREATE INDEX idx_cleaning_sessions_active ON cleaning_sessions(status) WHERE status = 'in_progress';
CREATE INDEX idx_studios_building ON studios(building_id);
CREATE INDEX idx_studios_qr_code ON studios(qr_code);

-- Triggers: auto-update updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_buildings_updated_at') THEN
    CREATE TRIGGER trg_buildings_updated_at
      BEFORE UPDATE ON buildings
      FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
  END IF;
END$$;

CREATE TRIGGER trg_studios_updated_at
  BEFORE UPDATE ON studios
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER trg_cleaning_sessions_updated_at
  BEFORE UPDATE ON cleaning_sessions
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- =============================================================================
-- Part 2: RLS Policies (T006)
-- =============================================================================

ALTER TABLE buildings ENABLE ROW LEVEL SECURITY;
ALTER TABLE studios ENABLE ROW LEVEL SECURITY;
ALTER TABLE cleaning_sessions ENABLE ROW LEVEL SECURITY;

-- Buildings: all authenticated can read
CREATE POLICY buildings_select_authenticated ON buildings
  FOR SELECT TO authenticated
  USING (true);

-- Buildings: only admin/super_admin can modify
CREATE POLICY buildings_admin_insert ON buildings
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM employee_profiles
      WHERE id = auth.uid() AND role IN ('admin', 'super_admin')
    )
  );

CREATE POLICY buildings_admin_update ON buildings
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM employee_profiles
      WHERE id = auth.uid() AND role IN ('admin', 'super_admin')
    )
  );

CREATE POLICY buildings_admin_delete ON buildings
  FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM employee_profiles
      WHERE id = auth.uid() AND role IN ('admin', 'super_admin')
    )
  );

-- Studios: all authenticated can read
CREATE POLICY studios_select_authenticated ON studios
  FOR SELECT TO authenticated
  USING (true);

-- Studios: only admin/super_admin can modify
CREATE POLICY studios_admin_insert ON studios
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM employee_profiles
      WHERE id = auth.uid() AND role IN ('admin', 'super_admin')
    )
  );

CREATE POLICY studios_admin_update ON studios
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM employee_profiles
      WHERE id = auth.uid() AND role IN ('admin', 'super_admin')
    )
  );

CREATE POLICY studios_admin_delete ON studios
  FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM employee_profiles
      WHERE id = auth.uid() AND role IN ('admin', 'super_admin')
    )
  );

-- Cleaning sessions: employees can read own sessions
CREATE POLICY cleaning_sessions_select_own ON cleaning_sessions
  FOR SELECT TO authenticated
  USING (employee_id = auth.uid());

-- Cleaning sessions: supervisors can read supervised employee sessions
CREATE POLICY cleaning_sessions_select_supervised ON cleaning_sessions
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM employee_supervisors
      WHERE supervisor_id = auth.uid() AND employee_id = cleaning_sessions.employee_id
    )
  );

-- Cleaning sessions: admin/super_admin can read all
CREATE POLICY cleaning_sessions_select_admin ON cleaning_sessions
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM employee_profiles
      WHERE id = auth.uid() AND role IN ('admin', 'super_admin')
    )
  );

-- Cleaning sessions: employees can insert own sessions
CREATE POLICY cleaning_sessions_insert_own ON cleaning_sessions
  FOR INSERT TO authenticated
  WITH CHECK (employee_id = auth.uid());

-- Cleaning sessions: employees can update own in_progress sessions
CREATE POLICY cleaning_sessions_update_own ON cleaning_sessions
  FOR UPDATE TO authenticated
  USING (employee_id = auth.uid() AND status = 'in_progress');

-- Cleaning sessions: supervisors can update supervised employee sessions
CREATE POLICY cleaning_sessions_update_supervised ON cleaning_sessions
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM employee_supervisors
      WHERE supervisor_id = auth.uid() AND employee_id = cleaning_sessions.employee_id
    )
  );

-- Cleaning sessions: admin/super_admin can update all
CREATE POLICY cleaning_sessions_update_admin ON cleaning_sessions
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM employee_profiles
      WHERE id = auth.uid() AND role IN ('admin', 'super_admin')
    )
  );

-- =============================================================================
-- Part 3: Core RPC Functions (T007)
-- =============================================================================

-- Helper: compute duration and flag logic
CREATE OR REPLACE FUNCTION _compute_cleaning_flags(
  p_studio_type studio_type,
  p_duration_minutes NUMERIC
) RETURNS TABLE(is_flagged BOOLEAN, flag_reason TEXT) AS $$
BEGIN
  IF p_studio_type = 'unit' AND p_duration_minutes < 5 THEN
    RETURN QUERY SELECT true, 'Duration too short for unit (< 5 min)';
  ELSIF p_studio_type IN ('common_area', 'conciergerie') AND p_duration_minutes < 2 THEN
    RETURN QUERY SELECT true, 'Duration too short (< 2 min)';
  ELSIF p_duration_minutes > 240 THEN
    RETURN QUERY SELECT true, 'Duration too long (> 4 hours)';
  ELSE
    RETURN QUERY SELECT false, NULL::TEXT;
  END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- RPC: scan_in
CREATE OR REPLACE FUNCTION scan_in(
  p_employee_id UUID,
  p_qr_code TEXT,
  p_shift_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_studio RECORD;
  v_existing_session RECORD;
  v_session_id UUID;
BEGIN
  -- Look up studio by QR code
  SELECT s.id, s.studio_number, s.studio_type, s.is_active, b.name AS building_name
  INTO v_studio
  FROM studios s JOIN buildings b ON s.building_id = b.id
  WHERE s.qr_code = p_qr_code;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_QR_CODE', 'message', 'QR code not found');
  END IF;

  IF NOT v_studio.is_active THEN
    RETURN jsonb_build_object('success', false, 'error', 'STUDIO_INACTIVE', 'message', 'Studio is no longer active');
  END IF;

  -- Validate shift exists and is active
  IF NOT EXISTS (SELECT 1 FROM shifts WHERE id = p_shift_id AND status = 'active') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NO_ACTIVE_SHIFT', 'message', 'No active shift found');
  END IF;

  -- Check for existing active session for this employee + studio
  SELECT id INTO v_existing_session
  FROM cleaning_sessions
  WHERE employee_id = p_employee_id AND studio_id = v_studio.id AND status = 'in_progress';

  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'SESSION_EXISTS',
      'message', 'Active session already exists for this studio',
      'existing_session_id', v_existing_session.id
    );
  END IF;

  -- Create new cleaning session
  INSERT INTO cleaning_sessions (employee_id, studio_id, shift_id, status, started_at)
  VALUES (p_employee_id, v_studio.id, p_shift_id, 'in_progress', now())
  RETURNING id INTO v_session_id;

  RETURN jsonb_build_object(
    'success', true,
    'session_id', v_session_id,
    'studio', jsonb_build_object(
      'id', v_studio.id,
      'studio_number', v_studio.studio_number,
      'building_name', v_studio.building_name,
      'studio_type', v_studio.studio_type
    ),
    'started_at', now()
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- RPC: scan_out
CREATE OR REPLACE FUNCTION scan_out(
  p_employee_id UUID,
  p_qr_code TEXT
) RETURNS JSONB AS $$
DECLARE
  v_studio RECORD;
  v_session RECORD;
  v_duration NUMERIC;
  v_flags RECORD;
BEGIN
  -- Look up studio
  SELECT s.id, s.studio_number, s.studio_type, b.name AS building_name
  INTO v_studio
  FROM studios s JOIN buildings b ON s.building_id = b.id
  WHERE s.qr_code = p_qr_code;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_QR_CODE', 'message', 'QR code not found');
  END IF;

  -- Find active session
  SELECT id, started_at INTO v_session
  FROM cleaning_sessions
  WHERE employee_id = p_employee_id AND studio_id = v_studio.id AND status = 'in_progress';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'NO_ACTIVE_SESSION', 'message', 'No active cleaning session for this studio');
  END IF;

  -- Compute duration
  v_duration := EXTRACT(EPOCH FROM (now() - v_session.started_at)) / 60.0;

  -- Apply flagging logic
  SELECT * INTO v_flags FROM _compute_cleaning_flags(v_studio.studio_type, v_duration);

  -- Update session
  UPDATE cleaning_sessions
  SET status = 'completed',
      completed_at = now(),
      duration_minutes = ROUND(v_duration, 2),
      is_flagged = v_flags.is_flagged,
      flag_reason = v_flags.flag_reason
  WHERE id = v_session.id;

  RETURN jsonb_build_object(
    'success', true,
    'session_id', v_session.id,
    'studio', jsonb_build_object(
      'id', v_studio.id,
      'studio_number', v_studio.studio_number,
      'building_name', v_studio.building_name,
      'studio_type', v_studio.studio_type
    ),
    'started_at', v_session.started_at,
    'completed_at', now(),
    'duration_minutes', ROUND(v_duration, 2),
    'is_flagged', v_flags.is_flagged
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- RPC: auto_close_shift_sessions
CREATE OR REPLACE FUNCTION auto_close_shift_sessions(
  p_shift_id UUID,
  p_employee_id UUID,
  p_closed_at TIMESTAMPTZ
) RETURNS JSONB AS $$
DECLARE
  v_session RECORD;
  v_duration NUMERIC;
  v_flags RECORD;
  v_closed_sessions JSONB := '[]'::JSONB;
  v_closed_count INT := 0;
BEGIN
  FOR v_session IN
    SELECT cs.id, cs.started_at, s.studio_number, s.studio_type
    FROM cleaning_sessions cs
    JOIN studios s ON cs.studio_id = s.id
    WHERE cs.shift_id = p_shift_id
      AND cs.employee_id = p_employee_id
      AND cs.status = 'in_progress'
  LOOP
    v_duration := EXTRACT(EPOCH FROM (p_closed_at - v_session.started_at)) / 60.0;
    SELECT * INTO v_flags FROM _compute_cleaning_flags(v_session.studio_type, v_duration);

    UPDATE cleaning_sessions
    SET status = 'auto_closed',
        completed_at = p_closed_at,
        duration_minutes = ROUND(v_duration, 2),
        is_flagged = v_flags.is_flagged,
        flag_reason = v_flags.flag_reason
    WHERE id = v_session.id;

    v_closed_sessions := v_closed_sessions || jsonb_build_object(
      'session_id', v_session.id,
      'studio_number', v_session.studio_number,
      'duration_minutes', ROUND(v_duration, 2)
    );
    v_closed_count := v_closed_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'closed_count', v_closed_count,
    'sessions', v_closed_sessions
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- RPC: get_active_session
CREATE OR REPLACE FUNCTION get_active_session(
  p_employee_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_result RECORD;
BEGIN
  SELECT cs.id AS session_id, cs.started_at, s.id AS studio_id, s.studio_number, s.studio_type, b.name AS building_name
  INTO v_result
  FROM cleaning_sessions cs
  JOIN studios s ON cs.studio_id = s.id
  JOIN buildings b ON s.building_id = b.id
  WHERE cs.employee_id = p_employee_id AND cs.status = 'in_progress'
  ORDER BY cs.started_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'session_id', v_result.session_id,
    'studio', jsonb_build_object(
      'id', v_result.studio_id,
      'studio_number', v_result.studio_number,
      'building_name', v_result.building_name,
      'studio_type', v_result.studio_type
    ),
    'started_at', v_result.started_at
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================================================================
-- Part 4: Dashboard RPC Functions (T008)
-- =============================================================================

-- RPC: get_cleaning_dashboard
CREATE OR REPLACE FUNCTION get_cleaning_dashboard(
  p_building_id UUID DEFAULT NULL,
  p_employee_id UUID DEFAULT NULL,
  p_date_from DATE DEFAULT CURRENT_DATE,
  p_date_to DATE DEFAULT CURRENT_DATE,
  p_limit INT DEFAULT 50,
  p_offset INT DEFAULT 0
) RETURNS JSONB AS $$
DECLARE
  v_summary JSONB;
  v_sessions JSONB;
  v_total_count INT;
BEGIN
  -- Summary aggregation
  SELECT jsonb_build_object(
    'total_sessions', COUNT(*),
    'completed', COUNT(*) FILTER (WHERE cs.status = 'completed'),
    'in_progress', COUNT(*) FILTER (WHERE cs.status = 'in_progress'),
    'auto_closed', COUNT(*) FILTER (WHERE cs.status = 'auto_closed'),
    'avg_duration_minutes', ROUND(COALESCE(AVG(cs.duration_minutes) FILTER (WHERE cs.status IN ('completed', 'auto_closed', 'manually_closed')), 0), 1),
    'flagged_count', COUNT(*) FILTER (WHERE cs.is_flagged = true)
  )
  INTO v_summary
  FROM cleaning_sessions cs
  JOIN studios s ON cs.studio_id = s.id
  WHERE cs.started_at::DATE BETWEEN p_date_from AND p_date_to
    AND (p_building_id IS NULL OR s.building_id = p_building_id)
    AND (p_employee_id IS NULL OR cs.employee_id = p_employee_id);

  -- Total count for pagination
  SELECT COUNT(*)
  INTO v_total_count
  FROM cleaning_sessions cs
  JOIN studios s ON cs.studio_id = s.id
  WHERE cs.started_at::DATE BETWEEN p_date_from AND p_date_to
    AND (p_building_id IS NULL OR s.building_id = p_building_id)
    AND (p_employee_id IS NULL OR cs.employee_id = p_employee_id);

  -- Paginated sessions
  SELECT COALESCE(jsonb_agg(row_data), '[]'::JSONB)
  INTO v_sessions
  FROM (
    SELECT jsonb_build_object(
      'id', cs.id,
      'employee_id', cs.employee_id,
      'employee_name', COALESCE(ep.full_name, ep.email),
      'studio_id', cs.studio_id,
      'studio_number', s.studio_number,
      'building_name', b.name,
      'studio_type', s.studio_type,
      'shift_id', cs.shift_id,
      'status', cs.status,
      'started_at', cs.started_at,
      'completed_at', cs.completed_at,
      'duration_minutes', cs.duration_minutes,
      'is_flagged', cs.is_flagged,
      'flag_reason', cs.flag_reason
    ) AS row_data
    FROM cleaning_sessions cs
    JOIN studios s ON cs.studio_id = s.id
    JOIN buildings b ON s.building_id = b.id
    JOIN employee_profiles ep ON cs.employee_id = ep.id
    WHERE cs.started_at::DATE BETWEEN p_date_from AND p_date_to
      AND (p_building_id IS NULL OR s.building_id = p_building_id)
      AND (p_employee_id IS NULL OR cs.employee_id = p_employee_id)
    ORDER BY cs.started_at DESC
    LIMIT p_limit OFFSET p_offset
  ) sub;

  RETURN jsonb_build_object(
    'summary', v_summary,
    'sessions', v_sessions,
    'total_count', v_total_count
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- RPC: get_cleaning_stats_by_building
CREATE OR REPLACE FUNCTION get_cleaning_stats_by_building(
  p_date_from DATE DEFAULT CURRENT_DATE,
  p_date_to DATE DEFAULT CURRENT_DATE
) RETURNS JSONB AS $$
BEGIN
  RETURN (
    SELECT COALESCE(jsonb_agg(row_data), '[]'::JSONB)
    FROM (
      SELECT jsonb_build_object(
        'building_id', b.id,
        'building_name', b.name,
        'total_studios', (SELECT COUNT(*) FROM studios WHERE building_id = b.id AND is_active = true),
        'cleaned_today', COUNT(DISTINCT cs.studio_id) FILTER (WHERE cs.status IN ('completed', 'auto_closed', 'manually_closed')),
        'in_progress', COUNT(*) FILTER (WHERE cs.status = 'in_progress'),
        'not_started', (SELECT COUNT(*) FROM studios WHERE building_id = b.id AND is_active = true) - COUNT(DISTINCT cs.studio_id),
        'avg_duration_minutes', ROUND(COALESCE(AVG(cs.duration_minutes) FILTER (WHERE cs.status IN ('completed', 'auto_closed', 'manually_closed')), 0), 1)
      ) AS row_data
      FROM buildings b
      LEFT JOIN studios s ON s.building_id = b.id AND s.is_active = true
      LEFT JOIN cleaning_sessions cs ON cs.studio_id = s.id
        AND cs.started_at::DATE BETWEEN p_date_from AND p_date_to
      GROUP BY b.id, b.name
      ORDER BY b.name
    ) sub
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- RPC: get_employee_cleaning_stats
CREATE OR REPLACE FUNCTION get_employee_cleaning_stats(
  p_employee_id UUID DEFAULT NULL,
  p_date_from DATE DEFAULT CURRENT_DATE,
  p_date_to DATE DEFAULT CURRENT_DATE
) RETURNS JSONB AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'employee_name', COALESCE(ep.full_name, ep.email),
    'total_sessions', COUNT(cs.id),
    'avg_duration_minutes', ROUND(COALESCE(AVG(cs.duration_minutes) FILTER (WHERE cs.status IN ('completed', 'auto_closed', 'manually_closed')), 0), 1),
    'sessions_by_building', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'building_name', b2.name,
        'count', sub.cnt,
        'avg_duration', sub.avg_dur
      )), '[]'::JSONB)
      FROM (
        SELECT s2.building_id, COUNT(*) AS cnt, ROUND(COALESCE(AVG(cs2.duration_minutes), 0), 1) AS avg_dur
        FROM cleaning_sessions cs2
        JOIN studios s2 ON cs2.studio_id = s2.id
        WHERE cs2.employee_id = ep.id
          AND cs2.started_at::DATE BETWEEN p_date_from AND p_date_to
        GROUP BY s2.building_id
      ) sub
      JOIN buildings b2 ON sub.building_id = b2.id
    ),
    'flagged_sessions', COUNT(cs.id) FILTER (WHERE cs.is_flagged = true)
  )
  INTO v_result
  FROM employee_profiles ep
  LEFT JOIN cleaning_sessions cs ON cs.employee_id = ep.id
    AND cs.started_at::DATE BETWEEN p_date_from AND p_date_to
  WHERE (p_employee_id IS NULL OR ep.id = p_employee_id)
  GROUP BY ep.id, ep.full_name, ep.email;

  RETURN COALESCE(v_result, '{}'::JSONB);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- RPC: manually_close_session
CREATE OR REPLACE FUNCTION manually_close_session(
  p_session_id UUID,
  p_closed_by UUID
) RETURNS JSONB AS $$
DECLARE
  v_session RECORD;
  v_duration NUMERIC;
  v_flags RECORD;
BEGIN
  -- Get session with studio info
  SELECT cs.id, cs.started_at, cs.status, s.studio_type
  INTO v_session
  FROM cleaning_sessions cs
  JOIN studios s ON cs.studio_id = s.id
  WHERE cs.id = p_session_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'SESSION_NOT_FOUND', 'message', 'Session not found');
  END IF;

  IF v_session.status != 'in_progress' THEN
    RETURN jsonb_build_object('success', false, 'error', 'SESSION_NOT_ACTIVE', 'message', 'Session is not in progress');
  END IF;

  -- Compute duration and flags
  v_duration := EXTRACT(EPOCH FROM (now() - v_session.started_at)) / 60.0;
  SELECT * INTO v_flags FROM _compute_cleaning_flags(v_session.studio_type, v_duration);

  -- Update session
  UPDATE cleaning_sessions
  SET status = 'manually_closed',
      completed_at = now(),
      duration_minutes = ROUND(v_duration, 2),
      is_flagged = v_flags.is_flagged,
      flag_reason = v_flags.flag_reason
  WHERE id = p_session_id;

  RETURN jsonb_build_object(
    'success', true,
    'session_id', p_session_id,
    'status', 'manually_closed',
    'duration_minutes', ROUND(v_duration, 2)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================================================================
-- Part 5: Seed Data (T009)
-- =============================================================================

-- Insert buildings
INSERT INTO buildings (name) VALUES
  ('Le Citadin'),
  ('Le Cardinal'),
  ('Le Chic-urbain'),
  ('Le Contemporain'),
  ('Le Cinq Étoiles'),
  ('Le Central'),
  ('Le Court-toit'),
  ('Le Centre-Ville'),
  ('Le Convivial'),
  ('Le Chambreur');

-- Insert studios: Le Citadin
INSERT INTO studios (qr_code, studio_number, building_id, studio_type) VALUES
  ('8FJ3K2L9H4', '201', (SELECT id FROM buildings WHERE name = 'Le Citadin'), 'unit'),
  ('B7Z2Q1M8N5', '202', (SELECT id FROM buildings WHERE name = 'Le Citadin'), 'unit'),
  ('R3X8J7T6P2', '203', (SELECT id FROM buildings WHERE name = 'Le Citadin'), 'unit'),
  ('S9A4N5W7F8', '204', (SELECT id FROM buildings WHERE name = 'Le Citadin'), 'unit'),
  ('L1D4M7P9J0', '205', (SELECT id FROM buildings WHERE name = 'Le Citadin'), 'unit'),
  ('P8K2W3H1R6', '206', (SELECT id FROM buildings WHERE name = 'Le Citadin'), 'unit'),
  ('G5B8Q1D2Z9', '207', (SELECT id FROM buildings WHERE name = 'Le Citadin'), 'unit'),
  ('Q2F7L4S8V1', '208', (SELECT id FROM buildings WHERE name = 'Le Citadin'), 'unit'),
  ('D6X3R8J1T5', '209', (SELECT id FROM buildings WHERE name = 'Le Citadin'), 'unit'),
  ('N7W9P3K4B2', '210', (SELECT id FROM buildings WHERE name = 'Le Citadin'), 'unit'),
  ('M1J8P2K4L6', '211', (SELECT id FROM buildings WHERE name = 'Le Citadin'), 'unit'),
  ('10SAJKFAS423', 'Aires communes', (SELECT id FROM buildings WHERE name = 'Le Citadin'), 'common_area'),
  ('FSAKLJ412LK3J1JKL', 'Conciergerie', (SELECT id FROM buildings WHERE name = 'Le Citadin'), 'conciergerie');

-- Insert studios: Le Cardinal
INSERT INTO studios (qr_code, studio_number, building_id, studio_type) VALUES
  ('H4Q3N5D8X7', '254', (SELECT id FROM buildings WHERE name = 'Le Cardinal'), 'unit'),
  ('T9B2W7L1Z3', '254-A', (SELECT id FROM buildings WHERE name = 'Le Cardinal'), 'unit'),
  ('C8R2F1V5P9', '254-B', (SELECT id FROM buildings WHERE name = 'Le Cardinal'), 'unit'),
  ('K7S2X4D9M0', '256', (SELECT id FROM buildings WHERE name = 'Le Cardinal'), 'unit'),
  ('P8L4S2D9R3', '256-A', (SELECT id FROM buildings WHERE name = 'Le Cardinal'), 'unit'),
  ('Q7J3H8L2V5', '258', (SELECT id FROM buildings WHERE name = 'Le Cardinal'), 'unit'),
  ('W1R9T3U5I7', '258-A', (SELECT id FROM buildings WHERE name = 'Le Cardinal'), 'unit'),
  ('FKJL312123', 'Aires communes', (SELECT id FROM buildings WHERE name = 'Le Cardinal'), 'common_area'),
  ('H312HL3JLJFKF', 'Conciergerie', (SELECT id FROM buildings WHERE name = 'Le Cardinal'), 'conciergerie');

-- Insert studios: Le Chic-urbain
INSERT INTO studios (qr_code, studio_number, building_id, studio_type) VALUES
  ('E2Y7U5R3O8', '311', (SELECT id FROM buildings WHERE name = 'Le Chic-urbain'), 'unit'),
  ('A1S2D3F4G5', '312', (SELECT id FROM buildings WHERE name = 'Le Chic-urbain'), 'unit'),
  ('N4B6V8C0X2', '313', (SELECT id FROM buildings WHERE name = 'Le Chic-urbain'), 'unit'),
  ('Z9X8C7V6B5', '314', (SELECT id FROM buildings WHERE name = 'Le Chic-urbain'), 'unit'),
  ('O9P8Q7L6K5', '315', (SELECT id FROM buildings WHERE name = 'Le Chic-urbain'), 'unit'),
  ('I6T4R9Y3U2', '316', (SELECT id FROM buildings WHERE name = 'Le Chic-urbain'), 'unit'),
  ('Q1W2E3R4T5', '317', (SELECT id FROM buildings WHERE name = 'Le Chic-urbain'), 'unit'),
  ('A7S8D2F3G4', '321', (SELECT id FROM buildings WHERE name = 'Le Chic-urbain'), 'unit'),
  ('H6J7K8L9Z0', '322', (SELECT id FROM buildings WHERE name = 'Le Chic-urbain'), 'unit'),
  ('X1C2V3B4N5', '323', (SELECT id FROM buildings WHERE name = 'Le Chic-urbain'), 'unit'),
  ('Q9W8E7R6T5', '324', (SELECT id FROM buildings WHERE name = 'Le Chic-urbain'), 'unit'),
  ('L8K7J6H5G4', '325', (SELECT id FROM buildings WHERE name = 'Le Chic-urbain'), 'unit'),
  ('M3N5B7V9C1', '326', (SELECT id FROM buildings WHERE name = 'Le Chic-urbain'), 'unit'),
  ('Y6U7I8O9P0', '327', (SELECT id FROM buildings WHERE name = 'Le Chic-urbain'), 'unit'),
  ('JLJ43J2LK4J', 'Aires communes', (SELECT id FROM buildings WHERE name = 'Le Chic-urbain'), 'common_area'),
  ('L32J4L1HHL1H4', 'Conciergerie', (SELECT id FROM buildings WHERE name = 'Le Chic-urbain'), 'conciergerie');

-- Insert studios: Le Contemporain
INSERT INTO studios (qr_code, studio_number, building_id, studio_type) VALUES
  ('P0O9I8U7Y6', '401', (SELECT id FROM buildings WHERE name = 'Le Contemporain'), 'unit'),
  ('M1N2B3V4C5', '411', (SELECT id FROM buildings WHERE name = 'Le Contemporain'), 'unit'),
  ('L6K5J4H3G2', '421', (SELECT id FROM buildings WHERE name = 'Le Contemporain'), 'unit'),
  ('F3G4H5J6K7', '431', (SELECT id FROM buildings WHERE name = 'Le Contemporain'), 'unit'),
  ('HGHSKJH32421', 'Aires communes', (SELECT id FROM buildings WHERE name = 'Le Contemporain'), 'common_area'),
  ('K32H4J24HK', 'Conciergerie', (SELECT id FROM buildings WHERE name = 'Le Contemporain'), 'conciergerie');

-- Insert studios: Le Cinq Étoiles
INSERT INTO studios (qr_code, studio_number, building_id, studio_type) VALUES
  ('D4S3A2Q1W0', '500-6', (SELECT id FROM buildings WHERE name = 'Le Cinq Étoiles'), 'unit'),
  ('JHK23214HK', 'Aires communes', (SELECT id FROM buildings WHERE name = 'Le Cinq Étoiles'), 'common_area'),
  ('K34H42KJ4H1', 'Conciergerie', (SELECT id FROM buildings WHERE name = 'Le Cinq Étoiles'), 'conciergerie');

-- Insert studios: Le Central
INSERT INTO studios (qr_code, studio_number, building_id, studio_type) VALUES
  ('R2T3Y4U5I6', '511', (SELECT id FROM buildings WHERE name = 'Le Central'), 'unit'),
  ('V1C2X3Z4A5', '512', (SELECT id FROM buildings WHERE name = 'Le Central'), 'unit'),
  ('B4N3M2V1C0', '513', (SELECT id FROM buildings WHERE name = 'Le Central'), 'unit'),
  ('S6D7F8G9H0', '514', (SELECT id FROM buildings WHERE name = 'Le Central'), 'unit'),
  ('T8R7E6W5Q4', '515', (SELECT id FROM buildings WHERE name = 'Le Central'), 'unit'),
  ('O7P6I5U4Y3', '521', (SELECT id FROM buildings WHERE name = 'Le Central'), 'unit'),
  ('L9K8J7H6G5', '522', (SELECT id FROM buildings WHERE name = 'Le Central'), 'unit'),
  ('J1K2L3M4N5', '523', (SELECT id FROM buildings WHERE name = 'Le Central'), 'unit'),
  ('Q2W3E4R5T6', '524', (SELECT id FROM buildings WHERE name = 'Le Central'), 'unit'),
  ('Y7U8I9O0P1', '525', (SELECT id FROM buildings WHERE name = 'Le Central'), 'unit'),
  ('A9B8C7D6E5', '526', (SELECT id FROM buildings WHERE name = 'Le Central'), 'unit'),
  ('KHJDSHAF423', 'Aires communes', (SELECT id FROM buildings WHERE name = 'Le Central'), 'common_area'),
  ('THTKJH25', 'Conciergerie', (SELECT id FROM buildings WHERE name = 'Le Central'), 'conciergerie');

-- Insert studios: Le Court-toit
INSERT INTO studios (qr_code, studio_number, building_id, studio_type) VALUES
  ('X5Z4C3V2B1', '601', (SELECT id FROM buildings WHERE name = 'Le Court-toit'), 'unit'),
  ('U9Y8T7R6E5', '602', (SELECT id FROM buildings WHERE name = 'Le Court-toit'), 'unit'),
  ('P3O2I1U0Y9', '603', (SELECT id FROM buildings WHERE name = 'Le Court-toit'), 'unit'),
  ('Q1A2Z3S4D5', '604', (SELECT id FROM buildings WHERE name = 'Le Court-toit'), 'unit'),
  ('I4O3P2L1K0', '611', (SELECT id FROM buildings WHERE name = 'Le Court-toit'), 'unit'),
  ('Z2X3C4V5B6', '612', (SELECT id FROM buildings WHERE name = 'Le Court-toit'), 'unit'),
  ('N7M8B9V0C1', '613', (SELECT id FROM buildings WHERE name = 'Le Court-toit'), 'unit'),
  ('F4G3H2J1K0', '614', (SELECT id FROM buildings WHERE name = 'Le Court-toit'), 'unit'),
  ('KHFAJKSHJ32432', 'Aires communes', (SELECT id FROM buildings WHERE name = 'Le Court-toit'), 'common_area'),
  ('H3425KH35JH2341', 'Conciergerie', (SELECT id FROM buildings WHERE name = 'Le Court-toit'), 'conciergerie');

-- Insert studios: Le Centre-Ville
INSERT INTO studios (qr_code, studio_number, building_id, studio_type) VALUES
  ('B7V8C9X0Z1', '701', (SELECT id FROM buildings WHERE name = 'Le Centre-Ville'), 'unit'),
  ('L1K2J3H4G5', '702', (SELECT id FROM buildings WHERE name = 'Le Centre-Ville'), 'unit'),
  ('M6N7B8V9C0', '703', (SELECT id FROM buildings WHERE name = 'Le Centre-Ville'), 'unit'),
  ('Q4W5E6R7T8', '704', (SELECT id FROM buildings WHERE name = 'Le Centre-Ville'), 'unit'),
  ('Y9U8I7O6P5', '705', (SELECT id FROM buildings WHERE name = 'Le Centre-Ville'), 'unit'),
  ('J2K3L4M5N6', '706', (SELECT id FROM buildings WHERE name = 'Le Centre-Ville'), 'unit'),
  ('H1J2K3L4Z5', '707', (SELECT id FROM buildings WHERE name = 'Le Centre-Ville'), 'unit'),
  ('U1I2O3P4A5', '708', (SELECT id FROM buildings WHERE name = 'Le Centre-Ville'), 'unit'),
  ('W6E7R8T9Y0', '709', (SELECT id FROM buildings WHERE name = 'Le Centre-Ville'), 'unit'),
  ('X9C8V7B6N5', '710', (SELECT id FROM buildings WHERE name = 'Le Centre-Ville'), 'unit'),
  ('ASDFJLKK4J23', 'Aires communes', (SELECT id FROM buildings WHERE name = 'Le Centre-Ville'), 'common_area'),
  ('J2H5K2JH342J3H4', 'Conciergerie', (SELECT id FROM buildings WHERE name = 'Le Centre-Ville'), 'conciergerie');

-- Insert studios: Le Convivial
INSERT INTO studios (qr_code, studio_number, building_id, studio_type) VALUES
  ('Q5W6E7R8T9', '803', (SELECT id FROM buildings WHERE name = 'Le Convivial'), 'unit'),
  ('T3R4E5W6Q7', '804', (SELECT id FROM buildings WHERE name = 'Le Convivial'), 'unit'),
  ('H7J8K9L0Z1', '808', (SELECT id FROM buildings WHERE name = 'Le Convivial'), 'unit'),
  ('I8O9P0L1K2', '809', (SELECT id FROM buildings WHERE name = 'Le Convivial'), 'unit'),
  ('P4O5I6U7Y8', '810', (SELECT id FROM buildings WHERE name = 'Le Convivial'), 'unit'),
  ('Y0U1I2O3P4', '812', (SELECT id FROM buildings WHERE name = 'Le Convivial'), 'unit'),
  ('A2S3D4F5G6', '813', (SELECT id FROM buildings WHERE name = 'Le Convivial'), 'unit'),
  ('Z6X5C4V3B2', '820', (SELECT id FROM buildings WHERE name = 'Le Convivial'), 'unit'),
  ('X2C3V4B5N6', '823', (SELECT id FROM buildings WHERE name = 'Le Convivial'), 'unit'),
  ('M4N5B6V7C8', '825', (SELECT id FROM buildings WHERE name = 'Le Convivial'), 'unit'),
  ('FALJSDJ3244LJ', 'Aires communes', (SELECT id FROM buildings WHERE name = 'Le Convivial'), 'common_area'),
  ('24H1K23JH41K2', 'Conciergerie', (SELECT id FROM buildings WHERE name = 'Le Convivial'), 'conciergerie');

-- Insert studios: Le Chambreur
INSERT INTO studios (qr_code, studio_number, building_id, studio_type) VALUES
  ('N3M4B5V6C7', '901', (SELECT id FROM buildings WHERE name = 'Le Chambreur'), 'unit'),
  ('F5G6H7J8K9', '902', (SELECT id FROM buildings WHERE name = 'Le Chambreur'), 'unit'),
  ('D1S2A3Q4W5', '903', (SELECT id FROM buildings WHERE name = 'Le Chambreur'), 'unit'),
  ('E6R7T8Y9U0', '904', (SELECT id FROM buildings WHERE name = 'Le Chambreur'), 'unit'),
  ('I7O8P9L0K1', '905', (SELECT id FROM buildings WHERE name = 'Le Chambreur'), 'unit'),
  ('J3K4L5M6N7', '906', (SELECT id FROM buildings WHERE name = 'Le Chambreur'), 'unit'),
  ('B8N9M0V1C2', '911', (SELECT id FROM buildings WHERE name = 'Le Chambreur'), 'unit'),
  ('X3Z4C5V6B7', '912', (SELECT id FROM buildings WHERE name = 'Le Chambreur'), 'unit'),
  ('Q7W8E9R0T1', '913', (SELECT id FROM buildings WHERE name = 'Le Chambreur'), 'unit'),
  ('Y2U3I4O5P6', '914', (SELECT id FROM buildings WHERE name = 'Le Chambreur'), 'unit'),
  ('A3S4D5F6G7', '915', (SELECT id FROM buildings WHERE name = 'Le Chambreur'), 'unit'),
  ('H8J9K0L1Z2', '916', (SELECT id FROM buildings WHERE name = 'Le Chambreur'), 'unit'),
  ('X4C5V6B7N8', '921', (SELECT id FROM buildings WHERE name = 'Le Chambreur'), 'unit'),
  ('M9N8B7V6C5', '922', (SELECT id FROM buildings WHERE name = 'Le Chambreur'), 'unit'),
  ('U3I4O5P6A7', '923', (SELECT id FROM buildings WHERE name = 'Le Chambreur'), 'unit'),
  ('S4D5F6G7H8', '924', (SELECT id FROM buildings WHERE name = 'Le Chambreur'), 'unit'),
  ('J9K8L7M6N5', '925', (SELECT id FROM buildings WHERE name = 'Le Chambreur'), 'unit'),
  ('Z3F1K9N7T2', '926', (SELECT id FROM buildings WHERE name = 'Le Chambreur'), 'unit'),
  ('JFASLKDFJH4241', 'Aires communes', (SELECT id FROM buildings WHERE name = 'Le Chambreur'), 'common_area'),
  ('4K12H341K2J3H41K32FAS', 'Conciergerie', (SELECT id FROM buildings WHERE name = 'Le Chambreur'), 'conciergerie');
