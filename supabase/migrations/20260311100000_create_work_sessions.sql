-- ============================================================
-- Migration: Create work_sessions table (Phase 1 — non-breaking)
-- Unifies cleaning_sessions + maintenance_sessions
-- ============================================================

-- 1. Create work_sessions table
CREATE TABLE work_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
  shift_id UUID NOT NULL REFERENCES shifts(id) ON DELETE CASCADE,
  activity_type TEXT NOT NULL CHECK (activity_type IN ('cleaning', 'maintenance', 'admin')),
  location_type TEXT CHECK (location_type IN ('studio', 'apartment', 'building', 'office')),

  -- Cleaning-specific (studio)
  studio_id UUID REFERENCES studios(id) ON DELETE CASCADE,
  -- Maintenance-specific (building/apartment)
  building_id UUID REFERENCES property_buildings(id) ON DELETE CASCADE,
  apartment_id UUID REFERENCES apartments(id) ON DELETE SET NULL,

  status TEXT NOT NULL DEFAULT 'in_progress'
    CHECK (status IN ('in_progress', 'completed', 'auto_closed', 'manually_closed')),
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  duration_minutes NUMERIC(10,2),

  -- Cleaning-specific flags
  is_flagged BOOLEAN DEFAULT false,
  flag_reason TEXT,

  -- Maintenance-specific
  notes TEXT,

  -- GPS capture
  start_latitude DOUBLE PRECISION,
  start_longitude DOUBLE PRECISION,
  start_accuracy DOUBLE PRECISION,
  end_latitude DOUBLE PRECISION,
  end_longitude DOUBLE PRECISION,
  end_accuracy DOUBLE PRECISION,

  -- Sync
  sync_status TEXT DEFAULT 'synced',

  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Constraints
  CONSTRAINT chk_ws_completed_after_started
    CHECK (completed_at IS NULL OR completed_at > started_at),
  CONSTRAINT chk_ws_duration_positive
    CHECK (duration_minutes IS NULL OR duration_minutes >= 0),
  CONSTRAINT chk_ws_cleaning_has_studio
    CHECK (activity_type != 'cleaning' OR studio_id IS NOT NULL),
  CONSTRAINT chk_ws_maintenance_has_building
    CHECK (activity_type != 'maintenance' OR building_id IS NOT NULL),
  CONSTRAINT chk_ws_admin_no_location
    CHECK (activity_type != 'admin' OR (studio_id IS NULL AND building_id IS NULL AND apartment_id IS NULL))
);

-- 2. Indexes
CREATE INDEX idx_work_sessions_employee_status ON work_sessions(employee_id, status);
CREATE INDEX idx_work_sessions_shift ON work_sessions(shift_id);
CREATE INDEX idx_work_sessions_activity_type ON work_sessions(activity_type);
CREATE INDEX idx_work_sessions_studio ON work_sessions(studio_id) WHERE studio_id IS NOT NULL;
CREATE INDEX idx_work_sessions_building ON work_sessions(building_id) WHERE building_id IS NOT NULL;
CREATE INDEX idx_work_sessions_active ON work_sessions(status) WHERE status = 'in_progress';
CREATE INDEX idx_work_sessions_started_at ON work_sessions(started_at);

-- 3. Trigger: auto-update updated_at
CREATE TRIGGER trg_work_sessions_updated_at
  BEFORE UPDATE ON work_sessions
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- 4. RLS
ALTER TABLE work_sessions ENABLE ROW LEVEL SECURITY;

-- Employee: read/write own
CREATE POLICY work_sessions_select_own ON work_sessions
  FOR SELECT USING (employee_id = auth.uid());
CREATE POLICY work_sessions_insert_own ON work_sessions
  FOR INSERT WITH CHECK (employee_id = auth.uid());
CREATE POLICY work_sessions_update_own ON work_sessions
  FOR UPDATE USING (employee_id = auth.uid() AND status = 'in_progress');

-- Supervisor: read/update supervised
CREATE POLICY work_sessions_select_supervised ON work_sessions
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM employee_supervisors es
      WHERE es.employee_id = work_sessions.employee_id
        AND es.manager_id = auth.uid()
    )
  );
CREATE POLICY work_sessions_update_supervised ON work_sessions
  FOR UPDATE USING (
    EXISTS (
      SELECT 1 FROM employee_supervisors es
      WHERE es.employee_id = work_sessions.employee_id
        AND es.manager_id = auth.uid()
    )
  );

-- Admin: read/update all
CREATE POLICY work_sessions_select_admin ON work_sessions
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM employee_profiles
      WHERE id = auth.uid() AND role IN ('admin', 'super_admin')
    )
  );
CREATE POLICY work_sessions_update_admin ON work_sessions
  FOR UPDATE USING (
    EXISTS (
      SELECT 1 FROM employee_profiles
      WHERE id = auth.uid() AND role IN ('admin', 'super_admin')
    )
  );

-- 5. Comments
COMMENT ON TABLE work_sessions IS 'ROLE: Unified work session tracking (cleaning, maintenance, admin). Replaces cleaning_sessions + maintenance_sessions.
STATUTS: in_progress → completed | auto_closed | manually_closed
REGLES: activity_type determines required location fields. cleaning→studio_id required. maintenance→building_id required. admin→no location.
RELATIONS: employee_profiles(employee_id), shifts(shift_id), studios(studio_id), property_buildings(building_id), apartments(apartment_id)
TRIGGERS: updated_at auto-set on update';

COMMENT ON COLUMN work_sessions.activity_type IS 'What employee is doing: cleaning (ménage), maintenance (entretien), admin (bureau/gestion)';
COMMENT ON COLUMN work_sessions.location_type IS 'Where: studio (QR-scanned), apartment, building (whole building), office (admin — no physical location)';
COMMENT ON COLUMN work_sessions.is_flagged IS 'Cleaning-only: duration too short/long per studio_type rules';

-- 6. Migrate historical data from cleaning_sessions
INSERT INTO work_sessions (
  id, employee_id, shift_id, activity_type, location_type,
  studio_id, building_id, apartment_id,
  status, started_at, completed_at, duration_minutes,
  is_flagged, flag_reason, notes,
  start_latitude, start_longitude, start_accuracy,
  end_latitude, end_longitude, end_accuracy,
  sync_status, created_at, updated_at
)
SELECT
  cs.id, cs.employee_id, cs.shift_id,
  'cleaning',  -- activity_type
  'studio',    -- location_type
  cs.studio_id, NULL, NULL,  -- studio, no building/apartment
  cs.status::text, cs.started_at, cs.completed_at, cs.duration_minutes,
  cs.is_flagged, cs.flag_reason, NULL,  -- no notes on cleaning
  cs.start_latitude, cs.start_longitude, cs.start_accuracy,
  cs.end_latitude, cs.end_longitude, cs.end_accuracy,
  'synced', cs.created_at, cs.updated_at
FROM cleaning_sessions cs;

-- 7. Migrate historical data from maintenance_sessions
INSERT INTO work_sessions (
  id, employee_id, shift_id, activity_type, location_type,
  studio_id, building_id, apartment_id,
  status, started_at, completed_at, duration_minutes,
  is_flagged, flag_reason, notes,
  start_latitude, start_longitude, start_accuracy,
  end_latitude, end_longitude, end_accuracy,
  sync_status, created_at, updated_at
)
SELECT
  ms.id, ms.employee_id, ms.shift_id,
  'maintenance',  -- activity_type
  CASE WHEN ms.apartment_id IS NOT NULL THEN 'apartment' ELSE 'building' END,
  NULL, ms.building_id, ms.apartment_id,
  ms.status::text, ms.started_at, ms.completed_at, ms.duration_minutes,
  false, NULL, ms.notes,
  ms.start_latitude, ms.start_longitude, ms.start_accuracy,
  ms.end_latitude, ms.end_longitude, ms.end_accuracy,
  COALESCE(ms.sync_status, 'synced'), ms.created_at, ms.updated_at
FROM maintenance_sessions ms;
