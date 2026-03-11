# Unified Work Sessions Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge `cleaning_sessions` + `maintenance_sessions` into a unified `work_sessions` table with mandatory activity type selection at clock-in, simplifying 19 RPCs to ~10 and removing duplicate code across Flutter and dashboard.

**Architecture:** Three-phase rollout. Phase 1 creates `work_sessions` alongside existing tables with bidirectional sync triggers (no breaking changes). Phase 2 deploys Flutter app using new unified service. Phase 3 cleans up old tables/RPCs after all phones updated. The Flutter app replaces separate cleaning/maintenance features with a single `work_sessions` feature module. Dashboard replaces `/cleaning` page with `/work-sessions`.

**Tech Stack:** PostgreSQL (Supabase), Dart/Flutter (mobile), TypeScript/Next.js (dashboard), Riverpod (state), SQLCipher (local storage)

**Spec:** `docs/superpowers/specs/2026-03-11-unified-work-sessions-design.md`

---

## File Structure

### New Files — Supabase
- `supabase/migrations/20260311100000_create_work_sessions.sql` — Table, indexes, RLS, trigger, data migration
- `supabase/migrations/20260311100001_work_session_rpcs.sql` — Unified RPCs
- `supabase/migrations/20260311100002_work_sessions_sync_triggers.sql` — Forward sync (old tables → work_sessions)
- `supabase/migrations/20260311100003_update_dependent_functions.sql` — Update approval detail, team monitoring, cluster types, server close

### New Files — Flutter
- `lib/features/work_sessions/models/activity_type.dart` — ActivityType enum
- `lib/features/work_sessions/models/work_session.dart` — WorkSession model + WorkSessionStatus enum + WorkSessionResult class
- `lib/features/work_sessions/services/work_session_local_db.dart` — SQLCipher tables
- `lib/features/work_sessions/services/work_session_service.dart` — Business logic
- `lib/features/work_sessions/services/studio_cache_service.dart` — Moved from cleaning/ (unchanged)
- `lib/features/work_sessions/services/property_cache_service.dart` — Moved from maintenance/ (unchanged)
- `lib/features/work_sessions/providers/work_session_provider.dart` — Riverpod state
- `lib/features/work_sessions/widgets/activity_type_picker.dart` — Full-screen type picker
- `lib/features/work_sessions/widgets/active_work_session_card.dart` — Active session card
- `lib/features/work_sessions/widgets/work_session_history_list.dart` — Session history
- `lib/features/work_sessions/widgets/scan_result_dialog.dart` — Moved from cleaning/widgets/ (unchanged)
- `lib/features/work_sessions/widgets/manual_entry_dialog.dart` — Moved from cleaning/widgets/ (unchanged)
- `lib/features/work_sessions/screens/qr_scanner_screen.dart` — Moved from cleaning/

### New Files — Dashboard
- `dashboard/src/app/dashboard/work-sessions/page.tsx` — Work sessions page
- `dashboard/src/components/work-sessions/work-sessions-table.tsx` — Sessions table
- `dashboard/src/components/work-sessions/work-session-filters.tsx` — Filters
- `dashboard/src/components/work-sessions/close-session-dialog.tsx` — Manual close
- `dashboard/src/lib/hooks/use-work-sessions.ts` — RPC hooks
- `dashboard/src/types/work-session.ts` — TypeScript types

### Modified Files — Flutter
- `lib/features/shifts/screens/shift_dashboard_screen.dart` — Remove tabs, unified view, activity type at clock-in
- `lib/features/shifts/services/shift_service.dart` — Pass activity_type to clock_in RPC, use work session auto-close

### Modified Files — Dashboard
- `dashboard/src/components/layout/sidebar.tsx` — "Ménage" → "Sessions de travail"
- `dashboard/src/components/monitoring/team-list.tsx` — Read from work_sessions

### Files Removed (Phase 3 only — NOT during initial implementation)
- `lib/features/cleaning/` — entire directory (after all phones updated)
- `lib/features/maintenance/` — entire directory (after all phones updated)
- `dashboard/src/app/dashboard/cleaning/` — entire directory
- `dashboard/src/components/cleaning/` — entire directory

---

## Chunk 1: Database — Table, Data Migration, RPCs

### Task 1: Create work_sessions table

**Files:**
- Create: `supabase/migrations/20260311100000_create_work_sessions.sql`

- [ ] **Step 1: Write the migration SQL**

```sql
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
```

- [ ] **Step 2: Apply migration via MCP**

Run: `mcp__supabase__apply_migration` with file name `20260311100000_create_work_sessions` and the SQL above.
Expected: Migration succeeds, table created, data migrated.

- [ ] **Step 3: Verify data migration**

Run via `mcp__supabase__execute_sql`:
```sql
SELECT activity_type, count(*) FROM work_sessions GROUP BY activity_type;
SELECT count(*) FROM cleaning_sessions;
SELECT count(*) FROM maintenance_sessions;
```
Expected: work_sessions cleaning count = cleaning_sessions count, maintenance count = maintenance_sessions count.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260311100000_create_work_sessions.sql
git commit -m "feat: create work_sessions table with data migration from cleaning/maintenance"
```

---

### Task 2: Create unified RPCs

**Files:**
- Create: `supabase/migrations/20260311100001_work_session_rpcs.sql`

- [ ] **Step 1: Write start_work_session RPC**

This RPC replaces `scan_in` (cleaning) and `start_maintenance`. Logic:
1. Validate shift is active
2. Double-tap protection (same employee+location < 5s → return existing)
3. Auto-close any active work_sessions for this employee
4. Create new work_session
5. Return session details

```sql
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
```

- [ ] **Step 2: Write complete_work_session RPC**

Replaces `scan_out` (cleaning) and `complete_maintenance`.

```sql
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
```

- [ ] **Step 3: Write auto_close_work_sessions RPC**

Replaces `auto_close_shift_sessions` + `auto_close_maintenance_sessions`.

```sql
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

    -- Compute flags for cleaning sessions
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
```

- [ ] **Step 4: Write manually_close_work_session RPC**

```sql
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
```

- [ ] **Step 5: Write get_active_work_session RPC**

```sql
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
```

- [ ] **Step 6: Write get_work_sessions_dashboard RPC**

Replaces `get_cleaning_dashboard` — now supports all activity types.

```sql
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
```

- [ ] **Step 7: Apply migration and verify**

Run: `mcp__supabase__apply_migration` with name `20260311100001_work_session_rpcs`.
Verify RPCs exist by calling `get_work_sessions_dashboard()` with no args.

- [ ] **Step 8: Commit**

```bash
git add supabase/migrations/20260311100001_work_session_rpcs.sql
git commit -m "feat: unified work session RPCs (start, complete, close, dashboard)"
```

---

### Task 3: Forward sync triggers (old tables → work_sessions)

**Files:**
- Create: `supabase/migrations/20260311100002_work_sessions_sync_triggers.sql`

Purpose: During Phase 1, old phones still write to `cleaning_sessions`/`maintenance_sessions`. These triggers forward-sync changes INTO `work_sessions`. The reverse direction is NOT needed — new RPCs write directly to `work_sessions` AND close old-table sessions explicitly.

- [ ] **Step 1: Write sync triggers**

```sql
-- ============================================================
-- Forward sync: old tables -> work_sessions (one-directional)
-- Active during Phase 1 only. Removed in Phase 3.
-- ============================================================

-- A) cleaning_sessions -> work_sessions
CREATE OR REPLACE FUNCTION sync_cleaning_to_work_sessions()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO work_sessions (
      id, employee_id, shift_id, activity_type, location_type,
      studio_id, status, started_at, completed_at, duration_minutes,
      is_flagged, flag_reason,
      start_latitude, start_longitude, start_accuracy,
      end_latitude, end_longitude, end_accuracy,
      sync_status, created_at, updated_at
    ) VALUES (
      NEW.id, NEW.employee_id, NEW.shift_id, 'cleaning', 'studio',
      NEW.studio_id, NEW.status::text, NEW.started_at, NEW.completed_at, NEW.duration_minutes,
      NEW.is_flagged, NEW.flag_reason,
      NEW.start_latitude, NEW.start_longitude, NEW.start_accuracy,
      NEW.end_latitude, NEW.end_longitude, NEW.end_accuracy,
      'synced', NEW.created_at, NEW.updated_at
    ) ON CONFLICT (id) DO UPDATE SET
      status = EXCLUDED.status,
      completed_at = EXCLUDED.completed_at,
      duration_minutes = EXCLUDED.duration_minutes,
      is_flagged = EXCLUDED.is_flagged,
      flag_reason = EXCLUDED.flag_reason,
      end_latitude = EXCLUDED.end_latitude,
      end_longitude = EXCLUDED.end_longitude,
      end_accuracy = EXCLUDED.end_accuracy,
      updated_at = EXCLUDED.updated_at;
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    UPDATE work_sessions SET
      status = NEW.status::text,
      completed_at = NEW.completed_at,
      duration_minutes = NEW.duration_minutes,
      is_flagged = NEW.is_flagged,
      flag_reason = NEW.flag_reason,
      end_latitude = NEW.end_latitude,
      end_longitude = NEW.end_longitude,
      end_accuracy = NEW.end_accuracy,
      updated_at = NEW.updated_at
    WHERE id = NEW.id;
    RETURN NEW;
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_sync_cleaning_to_work
  AFTER INSERT OR UPDATE ON cleaning_sessions
  FOR EACH ROW EXECUTE FUNCTION sync_cleaning_to_work_sessions();

-- B) maintenance_sessions -> work_sessions
CREATE OR REPLACE FUNCTION sync_maintenance_to_work_sessions()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO work_sessions (
      id, employee_id, shift_id, activity_type, location_type,
      building_id, apartment_id,
      status, started_at, completed_at, duration_minutes,
      notes,
      start_latitude, start_longitude, start_accuracy,
      end_latitude, end_longitude, end_accuracy,
      sync_status, created_at, updated_at
    ) VALUES (
      NEW.id, NEW.employee_id, NEW.shift_id, 'maintenance',
      CASE WHEN NEW.apartment_id IS NOT NULL THEN 'apartment' ELSE 'building' END,
      NEW.building_id, NEW.apartment_id,
      NEW.status::text, NEW.started_at, NEW.completed_at, NEW.duration_minutes,
      NEW.notes,
      NEW.start_latitude, NEW.start_longitude, NEW.start_accuracy,
      NEW.end_latitude, NEW.end_longitude, NEW.end_accuracy,
      COALESCE(NEW.sync_status, 'synced'), NEW.created_at, NEW.updated_at
    ) ON CONFLICT (id) DO UPDATE SET
      status = EXCLUDED.status,
      completed_at = EXCLUDED.completed_at,
      duration_minutes = EXCLUDED.duration_minutes,
      notes = EXCLUDED.notes,
      end_latitude = EXCLUDED.end_latitude,
      end_longitude = EXCLUDED.end_longitude,
      end_accuracy = EXCLUDED.end_accuracy,
      updated_at = EXCLUDED.updated_at;
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    UPDATE work_sessions SET
      status = NEW.status::text,
      completed_at = NEW.completed_at,
      duration_minutes = NEW.duration_minutes,
      notes = NEW.notes,
      end_latitude = NEW.end_latitude,
      end_longitude = NEW.end_longitude,
      end_accuracy = NEW.end_accuracy,
      updated_at = NEW.updated_at
    WHERE id = NEW.id;
    RETURN NEW;
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_sync_maintenance_to_work
  AFTER INSERT OR UPDATE ON maintenance_sessions
  FOR EACH ROW EXECUTE FUNCTION sync_maintenance_to_work_sessions();
```

- [ ] **Step 2: Apply migration and verify**

Apply migration. Then test: insert a cleaning_session via old `scan_in` RPC and verify it appears in `work_sessions`.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260311100002_work_sessions_sync_triggers.sql
git commit -m "feat: forward sync triggers from old tables to work_sessions"
```

---

### Task 4: Update dependent database functions

**Files:**
- Create: `supabase/migrations/20260311100003_update_dependent_functions.sql`

Updates: `auto_close_sessions_on_shift_complete` trigger, `server_close_all_sessions`, `_get_day_approval_detail_base` project sessions CTE, team monitoring queries, `compute_cluster_effective_types`.

- [ ] **Step 1: Update auto_close_sessions_on_shift_complete trigger**

Add work_sessions closure alongside existing cleaning/maintenance closures. **IMPORTANT:** The implementer MUST first read the full current function from migration `036_auto_close_sessions_on_shift_complete.sql` and copy the existing cleaning_sessions and maintenance_sessions closure loops verbatim (they include flag computation via `_compute_cleaning_flags`). Then add the work_sessions loop before them:

```sql
-- Update the trigger function to also close work_sessions
CREATE OR REPLACE FUNCTION auto_close_sessions_on_shift_complete()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_rec RECORD;
  v_duration NUMERIC;
  v_is_flagged BOOLEAN;
  v_flag_reason TEXT;
BEGIN
  IF NEW.status = 'completed' AND OLD.status = 'active' THEN
    -- ===== NEW: Close work_sessions (unified table) =====
    FOR v_rec IN
      SELECT ws.id, ws.started_at, ws.activity_type, ws.studio_id, s.studio_type
      FROM work_sessions ws
      LEFT JOIN studios s ON s.id = ws.studio_id
      WHERE ws.shift_id = NEW.id AND ws.status = 'in_progress'
    LOOP
      v_duration := EXTRACT(EPOCH FROM (NEW.clocked_out_at - v_rec.started_at)) / 60.0;
      v_is_flagged := false;
      v_flag_reason := NULL;
      IF v_rec.activity_type = 'cleaning' AND v_rec.studio_type IS NOT NULL THEN
        SELECT cf.is_flagged, cf.flag_reason
        INTO v_is_flagged, v_flag_reason
        FROM _compute_cleaning_flags(v_rec.studio_type::studio_type, v_duration) cf;
      END IF;
      UPDATE work_sessions SET
        status = 'auto_closed', completed_at = NEW.clocked_out_at,
        duration_minutes = v_duration, is_flagged = v_is_flagged,
        flag_reason = v_flag_reason, updated_at = now()
      WHERE id = v_rec.id;
    END LOOP;

    -- ===== EXISTING: Keep cleaning_sessions closure (Phase 1 compatibility) =====
    -- Copy the FOR v_rec IN ... cleaning_sessions ... LOOP from migration 036 verbatim here.
    -- It includes: SELECT from cleaning_sessions WHERE shift_id = NEW.id AND status = 'in_progress',
    -- flag computation via _compute_cleaning_flags, UPDATE to auto_closed.

    -- ===== EXISTING: Keep maintenance_sessions closure (Phase 1 compatibility) =====
    -- Copy the maintenance_sessions closure from migration 036 verbatim here.
    -- It includes: UPDATE maintenance_sessions SET status = 'auto_closed' WHERE shift_id = NEW.id.
  END IF;
  RETURN NEW;
END;
$$;
```

- [ ] **Step 2: Update server_close_all_sessions**

Add work_sessions closure:

```sql
CREATE OR REPLACE FUNCTION server_close_all_sessions(p_employee_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cleaning_count INT;
  v_maintenance_count INT;
  v_work_count INT;
  v_lunch_count INT;
  v_shift_count INT;
  v_now TIMESTAMPTZ := now();
BEGIN
  -- Close work_sessions
  UPDATE work_sessions SET
    status = 'auto_closed', completed_at = v_now,
    duration_minutes = EXTRACT(EPOCH FROM (v_now - started_at)) / 60.0,
    updated_at = v_now
  WHERE employee_id = p_employee_id AND status = 'in_progress';
  GET DIAGNOSTICS v_work_count = ROW_COUNT;

  -- Keep existing old-table closures for Phase 1 compatibility
  UPDATE cleaning_sessions SET status = 'auto_closed', completed_at = v_now,
    duration_minutes = EXTRACT(EPOCH FROM (v_now - started_at)) / 60.0, updated_at = v_now
  WHERE employee_id = p_employee_id AND status = 'in_progress';
  GET DIAGNOSTICS v_cleaning_count = ROW_COUNT;

  UPDATE maintenance_sessions SET status = 'auto_closed', completed_at = v_now,
    duration_minutes = EXTRACT(EPOCH FROM (v_now - started_at)) / 60.0, updated_at = v_now
  WHERE employee_id = p_employee_id AND status = 'in_progress';
  GET DIAGNOSTICS v_maintenance_count = ROW_COUNT;

  UPDATE lunch_breaks SET ended_at = v_now WHERE employee_id = p_employee_id AND ended_at IS NULL;
  GET DIAGNOSTICS v_lunch_count = ROW_COUNT;

  UPDATE shifts SET status = 'completed', clocked_out_at = v_now,
    clock_out_reason = 'server_auto_close', updated_at = v_now
  WHERE employee_id = p_employee_id AND status = 'active';
  GET DIAGNOSTICS v_shift_count = ROW_COUNT;

  RETURN jsonb_build_object('success', true,
    'work_sessions_closed', v_work_count,
    'cleaning_closed', v_cleaning_count,
    'maintenance_closed', v_maintenance_count,
    'lunch_closed', v_lunch_count,
    'shifts_closed', v_shift_count);
END;
$$;
```

- [ ] **Step 3: Update project sessions query in approval detail**

**IMPORTANT:** The project_sessions query is NOT in `_get_day_approval_detail_base`. It is in a separate function. The implementer MUST:
1. Query `pg_proc` to find which function contains the UNION ALL of `cleaning_sessions` + `maintenance_sessions`:
   ```sql
   SELECT proname, prosrc FROM pg_proc
   WHERE prosrc LIKE '%cleaning_sessions%' AND prosrc LIKE '%maintenance_sessions%'
   AND prosrc LIKE '%session_type%';
   ```
2. It is likely in `get_day_approval_detail` (migration 147) or `_get_project_sessions` (migration 20260310010000).
3. Replace the UNION ALL with a single SELECT from `work_sessions`:

```sql
-- REPLACE the existing cleaning_sessions UNION ALL maintenance_sessions with:
SELECT
  ws.id AS session_id,
  ws.activity_type AS session_type,
  ws.started_at,
  COALESCE(ws.completed_at, ws.started_at) AS ended_at,
  COALESCE(ws.duration_minutes, 0) AS duration_minutes,
  COALESCE(pb.name, b.name) AS building_name,
  COALESCE(a.unit_number, s.studio_number) AS unit_label,
  COALESCE(s.studio_type::text, a.apartment_category) AS unit_type,
  ws.status AS session_status,
  COALESCE(pb.location_id, b.location_id) AS location_id
FROM work_sessions ws
LEFT JOIN studios s ON s.id = ws.studio_id
LEFT JOIN buildings b ON b.id = s.building_id
LEFT JOIN property_buildings pb ON pb.id = ws.building_id
LEFT JOIN apartments a ON a.id = ws.apartment_id
WHERE ws.employee_id = p_employee_id
  AND ws.started_at::date = p_date
ORDER BY ws.started_at ASC
```

4. Preserve ALL other parts of the function unchanged (activities array, summary, gaps, etc.).

- [ ] **Step 4: Update team monitoring queries**

In `get_team_active_status` and `get_monitored_team`, replace the two LATERAL subqueries (cleaning + maintenance) with a single LATERAL on work_sessions:

```sql
-- Replace the two LATERAL joins with:
LEFT JOIN LATERAL (
  SELECT
    ws.activity_type AS active_session_type,
    CASE
      WHEN ws.activity_type = 'cleaning' THEN
        s.studio_number || ' — ' || b.name
      WHEN ws.activity_type = 'maintenance' THEN
        CASE WHEN a.unit_number IS NOT NULL
          THEN pb.name || ' — ' || a.unit_number
          ELSE pb.name
        END
      WHEN ws.activity_type = 'admin' THEN 'Administration'
    END AS active_session_location,
    ws.started_at AS active_session_started_at
  FROM work_sessions ws
  LEFT JOIN studios s ON s.id = ws.studio_id
  LEFT JOIN buildings b ON b.id = s.building_id
  LEFT JOIN property_buildings pb ON pb.id = ws.building_id
  LEFT JOIN apartments a ON a.id = ws.apartment_id
  WHERE ws.employee_id = ep.id AND ws.status = 'in_progress'
  ORDER BY ws.started_at DESC LIMIT 1
) ws_active ON true
```

**IMPORTANT notes for implementer:**
- Read the FULL current `get_team_active_status` and `get_monitored_team` functions. They may have been updated in later migrations (check migration 140+ for lunch columns).
- `get_team_active_status` has TWO branches (admin vs supervisor) — BOTH must have their session LATERAL joins replaced.
- `get_monitored_team` includes `is_on_lunch` and `lunch_started_at` columns — these MUST be preserved. Only replace the `ac` (active cleaning) and `am` (active maintenance) LATERAL subqueries with the single `ws_active` LATERAL above.
- Replace references to `ac.active_session_type` / `am.active_session_type` with `ws_active.active_session_type` in the SELECT list and COALESCE expressions.

- [ ] **Step 5: Update compute_cluster_effective_types**

In `compute_cluster_effective_types` (migration 101), the existing code uses `WHEN EXISTS (...)` subqueries in a CASE expression (NOT LATERAL joins). Replace the two separate EXISTS subqueries on `cleaning_sessions` + `maintenance_sessions` with a single EXISTS on `work_sessions`:

```sql
-- Replace the two EXISTS checks (one for cleaning_sessions, one for maintenance_sessions) with:
WHEN EXISTS (
  SELECT 1 FROM work_sessions ws
  LEFT JOIN studios s ON s.id = ws.studio_id
  LEFT JOIN buildings b ON b.id = s.building_id
  LEFT JOIN property_buildings pb ON pb.id = ws.building_id
  WHERE COALESCE(pb.location_id, b.location_id) = sc.matched_location_id
    AND ws.employee_id = p_employee_id
    AND ws.shift_id = p_shift_id
    AND ws.started_at < sc.ended_at
    AND (ws.completed_at > sc.started_at OR ws.completed_at IS NULL)
) THEN 'building'
```

**IMPORTANT:** The implementer MUST read the full function from migration 101. The overall CASE structure (priority: building > home > office > default) stays the same — only replace the source tables in the EXISTS subqueries. The column names `sc.matched_location_id`, `sc.ended_at`, `sc.started_at` may differ — match the existing code's aliases.

- [ ] **Step 6: Apply migration and verify**

Apply migration. Run verification queries:
```sql
-- Verify approval detail still works
SELECT get_day_approval_detail(
  (SELECT id FROM employee_profiles LIMIT 1),
  CURRENT_DATE
);
-- Verify team monitoring still works
SELECT get_monitored_team(NULL, 'all', NULL, NULL, 50, 0);
```

- [ ] **Step 7: Commit**

```bash
git add supabase/migrations/20260311100003_update_dependent_functions.sql
git commit -m "feat: update dependent functions to read from work_sessions"
```

---

## Chunk 2: Flutter — Models, Local DB, Service

### Task 5: Create ActivityType enum

**Files:**
- Create: `gps_tracker/lib/features/work_sessions/models/activity_type.dart`

- [ ] **Step 1: Write the enum**

```dart
import 'package:flutter/material.dart';

enum ActivityType {
  cleaning,
  maintenance,
  admin;

  String toJson() {
    switch (this) {
      case ActivityType.cleaning:
        return 'cleaning';
      case ActivityType.maintenance:
        return 'maintenance';
      case ActivityType.admin:
        return 'admin';
    }
  }

  static ActivityType fromJson(String json) {
    switch (json) {
      case 'cleaning':
        return ActivityType.cleaning;
      case 'maintenance':
        return ActivityType.maintenance;
      case 'admin':
        return ActivityType.admin;
      default:
        return ActivityType.cleaning;
    }
  }

  String get displayName {
    switch (this) {
      case ActivityType.cleaning:
        return 'Ménage';
      case ActivityType.maintenance:
        return 'Entretien';
      case ActivityType.admin:
        return 'Administration';
    }
  }

  String get description {
    switch (this) {
      case ActivityType.cleaning:
        return 'Nettoyage — studios, aires communes, appartements';
      case ActivityType.maintenance:
        return 'Maintenance, réparations, rénovations';
      case ActivityType.admin:
        return 'Bureau, gestion, planification';
    }
  }

  Color get color {
    switch (this) {
      case ActivityType.cleaning:
        return const Color(0xFF4CAF50); // Green
      case ActivityType.maintenance:
        return const Color(0xFFFF9800); // Orange
      case ActivityType.admin:
        return const Color(0xFF2196F3); // Blue
    }
  }

  IconData get icon {
    switch (this) {
      case ActivityType.cleaning:
        return Icons.cleaning_services;
      case ActivityType.maintenance:
        return Icons.handyman;
      case ActivityType.admin:
        return Icons.business_center;
    }
  }

  /// Whether this activity type requires location selection
  bool get requiresLocation => this != ActivityType.admin;

  /// Whether this activity type supports QR scanning
  bool get supportsQrScan => this == ActivityType.cleaning;
}
```

- [ ] **Step 2: Verify**

Run: `cd gps_tracker && flutter analyze lib/features/work_sessions/models/activity_type.dart`
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/work_sessions/models/activity_type.dart
git commit -m "feat: add ActivityType enum for unified work sessions"
```

---

### Task 6: Create WorkSession model

**Files:**
- Create: `gps_tracker/lib/features/work_sessions/models/work_session.dart`

- [ ] **Step 1: Write the model**

This file contains THREE classes: `WorkSessionStatus` enum, `WorkSession` model, and `WorkSessionResult`.

**WorkSessionStatus enum** (follows `CleaningSessionStatus` pattern):
```dart
enum WorkSessionStatus {
  inProgress, completed, autoClosed, manuallyClosed;
  String toJson() => switch (this) { inProgress => 'in_progress', completed => 'completed', autoClosed => 'auto_closed', manuallyClosed => 'manually_closed' };
  static WorkSessionStatus fromJson(String s) => switch (s) { 'in_progress' => inProgress, 'completed' => completed, 'auto_closed' => autoClosed, 'manually_closed' => manuallyClosed, _ => inProgress };
  bool get isActive => this == inProgress;
}
```

**WorkSession model fields:**
- `id` (String), `employeeId` (String), `shiftId` (String)
- `activityType` (ActivityType)
- `locationType` (String?)
- `status` (WorkSessionStatus)
- `studioId`, `buildingId`, `apartmentId` (all String?, nullable)
- `buildingName`, `studioNumber`, `unitNumber`, `studioType` (String?, denormalized display)
- `startedAt` (DateTime), `completedAt` (DateTime?), `durationMinutes` (double?)
- `isFlagged` (bool), `flagReason` (String?)
- `notes` (String?)
- GPS: `startLatitude`, `startLongitude`, `startAccuracy`, `endLatitude`, `endLongitude`, `endAccuracy` (double?)
- `syncStatus` (SyncStatus — reuse existing enum from `shift_enums.dart`)
- `serverId` (String?)

Key methods: `fromLocalDb()`, `toLocalDb()`, `copyWith()`, `duration` getter, `computedDurationMinutes` getter, `locationLabel` getter (returns "studioNumber — buildingName" for cleaning, "unitNumber — buildingName" for maintenance, "Administration" for admin).

**WorkSessionResult class** (replaces both `ScanResult` and `MaintenanceSessionResult`):
```dart
class WorkSessionResult {
  final bool success;
  final WorkSession? session;
  final String? errorType;   // 'INVALID_QR_CODE', 'NO_ACTIVE_SESSION', etc.
  final String? errorMessage;
  final String? warning;

  WorkSessionResult.success(this.session, {this.warning}) : success = true, errorType = null, errorMessage = null;
  WorkSessionResult.error(this.errorType, {this.errorMessage}) : success = false, session = null, warning = null;
}
```

The model file should be ~300 lines following existing patterns in `cleaning_session.dart` and `maintenance_session.dart`.

- [ ] **Step 2: Verify**

Run: `cd gps_tracker && flutter analyze lib/features/work_sessions/models/work_session.dart`

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/work_sessions/models/work_session.dart
git commit -m "feat: add WorkSession model"
```

---

### Task 7: Create WorkSessionLocalDb

**Files:**
- Create: `gps_tracker/lib/features/work_sessions/services/work_session_local_db.dart`

- [ ] **Step 1: Write the local DB service**

Follow the pattern from `cleaning_local_db.dart`. Table schema:

```sql
CREATE TABLE IF NOT EXISTS local_work_sessions (
  id TEXT PRIMARY KEY,
  employee_id TEXT NOT NULL,
  shift_id TEXT NOT NULL,
  activity_type TEXT NOT NULL,
  location_type TEXT,
  studio_id TEXT,
  studio_number TEXT,
  studio_type TEXT,
  building_id TEXT,
  building_name TEXT,
  apartment_id TEXT,
  unit_number TEXT,
  status TEXT NOT NULL DEFAULT 'in_progress',
  started_at TEXT NOT NULL,
  completed_at TEXT,
  duration_minutes REAL,
  is_flagged INTEGER NOT NULL DEFAULT 0,
  flag_reason TEXT,
  notes TEXT,
  sync_status TEXT NOT NULL DEFAULT 'pending',
  server_id TEXT,
  start_latitude REAL,
  start_longitude REAL,
  start_accuracy REAL,
  end_latitude REAL,
  end_longitude REAL,
  end_accuracy REAL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
)
```

Indexes:
- `idx_local_ws_employee_status` ON (employee_id, status)
- `idx_local_ws_shift` ON (shift_id)
- `idx_local_ws_sync` ON (sync_status)
- `idx_local_ws_activity_type` ON (activity_type)

Methods (same pattern as cleaning_local_db.dart):
- `ensureTables()` — create table + indexes + migrate from old tables
- `resolveServerShiftId()` — lookup from local_shifts
- `insertWorkSession()` — REPLACE insert
- `updateWorkSession()` — update by id
- `getActiveSessionForEmployee()` — LEFT JOIN with studios, property_buildings, apartments for denorm fields
- `getSessionsForShift()` — all sessions for shift, ordered DESC
- `getPendingWorkSessions()` — sync_status = 'pending'
- `markWorkSessionSynced()` — set synced + server_id
- `markWorkSessionSyncError()` — set error
- `getInProgressSessionsForShift()` — for auto-close

**Migration from old tables in `ensureTables()`:**

**CRITICAL:** Must check table existence BEFORE migrating — new installs won't have old tables.

```dart
// After creating local_work_sessions, migrate existing data:

// 1. Check if local_cleaning_sessions exists, then migrate
final cleaningTables = await db.rawQuery(
  "SELECT name FROM sqlite_master WHERE type='table' AND name='local_cleaning_sessions'"
);
if (cleaningTables.isNotEmpty) {
  await db.execute('''
    INSERT OR IGNORE INTO local_work_sessions (
      id, employee_id, shift_id, activity_type, location_type,
      studio_id, status, started_at, completed_at, duration_minutes,
      is_flagged, flag_reason, sync_status, server_id,
      start_latitude, start_longitude, start_accuracy,
      end_latitude, end_longitude, end_accuracy,
      created_at, updated_at
    )
    SELECT
      id, employee_id, shift_id, 'cleaning', 'studio',
      studio_id, status, started_at, completed_at, duration_minutes,
      is_flagged, flag_reason, sync_status, server_id,
      start_latitude, start_longitude, start_accuracy,
      end_latitude, end_longitude, end_accuracy,
      created_at, updated_at
    FROM local_cleaning_sessions
  ''');
  // Drop old table after successful migration
  await db.execute('DROP TABLE IF EXISTS local_cleaning_sessions');
}

// 2. Check if local_maintenance_sessions exists, then migrate
final maintenanceTables = await db.rawQuery(
  "SELECT name FROM sqlite_master WHERE type='table' AND name='local_maintenance_sessions'"
);
if (maintenanceTables.isNotEmpty) {
  await db.execute('''
    INSERT OR IGNORE INTO local_work_sessions (
      id, employee_id, shift_id, activity_type, location_type,
      building_id, building_name, apartment_id, unit_number,
      status, started_at, completed_at, duration_minutes,
      is_flagged, flag_reason, notes, sync_status, server_id,
      start_latitude, start_longitude, start_accuracy,
      end_latitude, end_longitude, end_accuracy,
      created_at, updated_at
    )
    SELECT
      id, employee_id, shift_id, 'maintenance',
      CASE WHEN apartment_id IS NOT NULL THEN 'apartment' ELSE 'building' END,
      building_id, building_name, apartment_id, unit_number,
      status, started_at, completed_at, duration_minutes,
      0, NULL, notes, sync_status, server_id,
      start_latitude, start_longitude, start_accuracy,
      end_latitude, end_longitude, end_accuracy,
      created_at, updated_at
    FROM local_maintenance_sessions
  ''');
  // Drop old table after successful migration
  await db.execute('DROP TABLE IF EXISTS local_maintenance_sessions');
}
```

- [ ] **Step 2: Verify**

Run: `cd gps_tracker && flutter analyze lib/features/work_sessions/services/work_session_local_db.dart`

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/work_sessions/services/work_session_local_db.dart
git commit -m "feat: add WorkSessionLocalDb with migration from old tables"
```

---

### Task 8: Create WorkSessionService

**Files:**
- Create: `gps_tracker/lib/features/work_sessions/services/work_session_service.dart`

- [ ] **Step 1: Write the service**

Follow the pattern from `cleaning_session_service.dart` but unified. Constructor:

```dart
WorkSessionService(
  this._supabase,
  this._localDb,          // WorkSessionLocalDb
  this._studioCache,      // StudioCacheService
  this._propertyCache,    // PropertyCacheService (for maintenance)
)
```

**Key methods:**

**`startSession()`** — unified replacement for `scanIn()` + `startMaintenanceSession()`:
```dart
Future<WorkSessionResult> startSession({
  required String employeeId,
  required String shiftId,
  required ActivityType activityType,
  // Cleaning params
  String? qrCode,
  String? studioId,
  // Maintenance params
  String? buildingId,
  String? buildingName,
  String? apartmentId,
  String? unitNumber,
  // Server shift
  String? serverShiftId,
  // GPS
  double? latitude,
  double? longitude,
  double? accuracy,
})
```

Logic:
1. If cleaning + qrCode → look up studio in cache (same as existing scanIn)
2. Auto-close any active work session (local)
3. Create local work_session with UUID
4. Resolve server shift ID (retry loop)
5. Call RPC `start_work_session` with all params
6. On success: mark synced; on error: leave as pending

**`completeSession()`** — replaces `scanOut()` + `completeMaintenanceSession()`:
```dart
Future<WorkSessionResult> completeSession({
  required String employeeId,
  String? qrCode,     // For cleaning scan-out
  double? latitude,
  double? longitude,
  double? accuracy,
})
```

Logic:
1. Find active local session
2. If cleaning + qrCode → validate QR matches current studio
3. Compute duration + flags (cleaning only, same logic as existing)
4. Update local session to completed
5. Call RPC `complete_work_session`
6. Return result

**`manualClose()`**, **`autoCloseSessions()`**, **`getActiveSession()`**, **`getShiftSessions()`**, **`syncPendingSessions()`** — follow existing patterns, calling new RPCs.

The service should be ~500 lines, consolidating logic from both `cleaning_session_service.dart` (~510 lines) and `maintenance_session_service.dart` (~400 lines).

- [ ] **Step 2: Verify**

Run: `cd gps_tracker && flutter analyze lib/features/work_sessions/services/work_session_service.dart`

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/work_sessions/services/work_session_service.dart
git commit -m "feat: add WorkSessionService (unified cleaning + maintenance)"
```

---

## Chunk 3: Flutter — Provider, Widgets, UI Changes

### Task 9: Create WorkSessionProvider

**Files:**
- Create: `gps_tracker/lib/features/work_sessions/providers/work_session_provider.dart`

- [ ] **Step 1: Write the provider**

Follow the pattern from `cleaning_session_provider.dart`. Key elements:

```dart
// Cache services — import from their new locations in work_sessions/services/
final studioCacheServiceProvider = Provider<StudioCacheService>((ref) {
  return StudioCacheService(ref.watch(supabaseProvider), ref.watch(workSessionLocalDbProvider));
});
final propertyCacheServiceProvider = Provider<PropertyCacheService>((ref) {
  return PropertyCacheService(ref.watch(supabaseProvider), ref.watch(workSessionLocalDbProvider));
});

// Core providers
final workSessionLocalDbProvider = Provider<WorkSessionLocalDb>((ref) { ... });
final workSessionServiceProvider = Provider<WorkSessionService>((ref) {
  return WorkSessionService(
    ref.watch(supabaseProvider),
    ref.watch(workSessionLocalDbProvider),
    ref.watch(studioCacheServiceProvider),
    ref.watch(propertyCacheServiceProvider),
  );
});
final workSessionProvider = StateNotifierProvider<WorkSessionNotifier, WorkSessionState>((ref) { ... });

// Derived
final hasActiveWorkSessionProvider = Provider<bool>((ref) => ...);
final activeWorkSessionProvider = Provider<WorkSession?>((ref) => ...);
final shiftWorkSessionsProvider = FutureProvider.family<List<WorkSession>, String>((ref, shiftId) => ...);
```

**NOTE:** The `StudioCacheService` currently uses `CleaningLocalDb` for local studio storage. Since we're moving it to `work_sessions/services/`, adapt it to use `WorkSessionLocalDb` instead — the `local_studios` table stays the same, just accessed via the new DB class. Alternatively, keep importing the `CleaningLocalDb` provider during Phase 2 and refactor in Phase 3.

**WorkSessionState:**
```dart
class WorkSessionState {
  final WorkSession? activeSession;
  final bool isScanning;   // During RPC call
  final bool isLoading;
  final String? error;
  final bool isInitialized;
}
```

**WorkSessionNotifier methods:**
- `_initialize()` — sync studio/property cache, load active session, listen to connectivity
- `startSession()` — GPS health gate → capture location → service.startSession() → update Live Activity
- `completeSession()` — GPS health gate → capture location → service.completeSession() → clear Live Activity
- `manualClose()` — service.manualClose()
- `scanIn()` — convenience wrapper calling startSession with activityType=cleaning
- `scanOut()` — convenience wrapper calling completeSession with qrCode
- `changeActivityType()` — complete current session → return (caller opens type picker)
- `syncPending()` — service.syncPendingSessions()

- [ ] **Step 2: Verify**

Run: `cd gps_tracker && flutter analyze lib/features/work_sessions/providers/work_session_provider.dart`

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/work_sessions/providers/work_session_provider.dart
git commit -m "feat: add WorkSessionProvider (Riverpod state management)"
```

---

### Task 10: Create ActivityTypePicker widget

**Files:**
- Create: `gps_tracker/lib/features/work_sessions/widgets/activity_type_picker.dart`

- [ ] **Step 1: Write the widget**

Full-screen modal picker shown at clock-in. Returns selected `ActivityType`.

```dart
class ActivityTypePicker extends StatelessWidget {
  /// Shows the picker and returns selected activity type, or null if dismissed.
  static Future<ActivityType?> show(BuildContext context) {
    return showModalBottomSheet<ActivityType>(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      builder: (_) => const ActivityTypePicker(),
    );
  }
  // ... build method renders 3 large tappable cards:
  // - Ménage (green, cleaning_services icon)
  // - Entretien (orange, handyman icon)
  // - Administration (blue, business_center icon)
  // Each card shows: icon, title (displayName), description
  // Tap returns the ActivityType via Navigator.pop
}
```

UI layout: 3 vertical cards filling the bottom sheet, each ~120px tall with icon left, text right. Colored left border matching activity color.

- [ ] **Step 2: Verify**

Run: `cd gps_tracker && flutter analyze lib/features/work_sessions/widgets/activity_type_picker.dart`

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/work_sessions/widgets/activity_type_picker.dart
git commit -m "feat: add ActivityTypePicker widget"
```

---

### Task 11: Create ActiveWorkSessionCard widget

**Files:**
- Create: `gps_tracker/lib/features/work_sessions/widgets/active_work_session_card.dart`

- [ ] **Step 1: Write the widget**

Unified card replacing `ActiveSessionCard` + `ActiveMaintenanceCard`. ConsumerStatefulWidget with 1-second timer.

Key differences from existing:
- Card border color matches `activeSession.activityType.color`
- Activity type badge in header (icon + label, colored)
- Location display adapts: studio info (cleaning) vs building/apartment (maintenance) vs "Bureau" (admin)
- Buttons: "Scanner pour terminer" (cleaning only), "Terminer" (all types), "Terminer sans scanner" (cleaning fallback)
- Empty state: shows prompt to start work (opens ActivityTypePicker or QR scanner depending on context)

Follow the layout pattern from `active_session_card.dart` (lines 146-327) but with activity-type-aware rendering.

- [ ] **Step 2: Verify**

Run: `cd gps_tracker && flutter analyze`

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/work_sessions/widgets/active_work_session_card.dart
git commit -m "feat: add ActiveWorkSessionCard (unified session display)"
```

---

### Task 12: Create WorkSessionHistoryList widget

**Files:**
- Create: `gps_tracker/lib/features/work_sessions/widgets/work_session_history_list.dart`

- [ ] **Step 1: Write the widget**

Replaces both `CleaningHistoryList` and `MaintenanceHistoryList`. Single list of all session types.

Uses `shiftWorkSessionsProvider(activeShift.id)` to get all sessions.

Each tile shows:
- Activity type icon + color indicator (left)
- Location label (studio number for cleaning, building/apartment for maintenance, "Administration" for admin)
- Status badge (colored by status)
- Duration (right-aligned)
- Sync indicator

Header: "Historique des sessions" with badge count.

Follow `cleaning_history_list.dart` pattern but with activity_type-aware rendering per tile.

- [ ] **Step 2: Verify and commit**

```bash
git add gps_tracker/lib/features/work_sessions/widgets/work_session_history_list.dart
git commit -m "feat: add WorkSessionHistoryList (unified session history)"
```

---

### Task 13: Move QR scanner screen

**Files:**
- Create: `gps_tracker/lib/features/work_sessions/screens/qr_scanner_screen.dart`

- [ ] **Step 1: Copy and adapt the QR scanner**

Copy `lib/features/cleaning/screens/qr_scanner_screen.dart` to `lib/features/work_sessions/screens/qr_scanner_screen.dart`.

Changes:
- Import `WorkSessionProvider` instead of `CleaningSessionProvider`
- In `_processQrCode()`: use `workSessionProvider.notifier.scanIn()` and `workSessionProvider.notifier.scanOut()`
- Keep all existing QR logic (same/different studio handling, manual entry dialog, etc.)

- [ ] **Step 2: Verify**

Run: `cd gps_tracker && flutter analyze lib/features/work_sessions/screens/qr_scanner_screen.dart`

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/work_sessions/screens/qr_scanner_screen.dart
git commit -m "feat: move QR scanner to work_sessions feature"
```

---

### Task 14: Modify ShiftDashboardScreen

**Files:**
- Modify: `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`

This is the most complex UI change. The screen currently has a `SegmentedButton` with Ménager/Entretien tabs. The new design removes tabs entirely.

- [ ] **Step 1: Remove tab state and imports**

Remove:
- `_DashboardTab` enum
- `_selectedTab` state variable
- Imports from `cleaning/` and `maintenance/`
- All references to `cleaningSessionProvider`, `maintenanceSessionProvider`

Add imports from `work_sessions/`.

- [ ] **Step 2: Replace tab section with unified view**

Replace the SegmentedButton + tab-conditional rendering (lines ~1333-1371) with:

```dart
// Activity type badge (shows current session type)
if (activeWorkSession != null)
  _ActivityTypeBadge(activityType: activeWorkSession.activityType),

const SizedBox(height: 16),

// Active session card (unified)
const ActiveWorkSessionCard(),

const SizedBox(height: 16),

// Session history (all types)
const WorkSessionHistoryList(),
```

- [ ] **Step 3: Update FAB**

Replace tab-aware FAB logic with:

```dart
floatingActionButton: hasActiveShift && !hasActiveWorkSession
    ? FloatingActionButton.extended(
        onPressed: _startNewSession,
        icon: const Icon(Icons.add),
        label: const Text('Nouvelle session'),
      )
    : null,
```

`_startNewSession()` opens `ActivityTypePicker`, then:
- If cleaning → open QR scanner or building picker
- If maintenance → open BuildingPickerSheet
- If admin → directly call `workSessionProvider.notifier.startSession(activityType: admin)`

- [ ] **Step 4: Add "Changer d'activité" button**

Add a small/discrete button near the bottom alongside "Pause dîner":

```dart
if (hasActiveWorkSession)
  TextButton.icon(
    onPressed: _changeActivityType,
    icon: const Icon(Icons.swap_horiz, size: 18),
    label: const Text("Changer d'activité"),
    style: TextButton.styleFrom(foregroundColor: Colors.grey),
  ),
```

`_changeActivityType()`:
1. Complete current session via `workSessionProvider.notifier.completeSession()`
2. Open `ActivityTypePicker`
3. Start new session with selected type

- [ ] **Step 5: Update clock-in flow**

In `_handleClockIn()`, after GPS validation and permission checks, BEFORE calling `shiftProvider.notifier.clockIn()`:

**NOTE:** The spec says "Shift does NOT start until activity type + location are selected." So the picker must appear BEFORE clockIn(). If the user cancels the picker, the entire clock-in is aborted (shift is NOT created).

```dart
// Show activity type picker BEFORE clock-in
final activityType = await ActivityTypePicker.show(context);
if (activityType == null) return; // User cancelled — do NOT create shift

// For cleaning: get location BEFORE clock-in
String? qrCode;
if (activityType == ActivityType.cleaning) {
  // Note: QR scanner can be opened after shift creation instead — see below
}

// For maintenance: get building BEFORE clock-in
BuildingPickerResult? buildingResult;
if (activityType == ActivityType.maintenance) {
  buildingResult = await BuildingPickerSheet.show(context);
  if (buildingResult == null) return; // User cancelled
}

// NOW create the shift (activity type is confirmed)
await shiftProvider.notifier.clockIn(...);

// After shift created, start first work session
if (activityType == ActivityType.cleaning) {
  // Open QR scanner
  _openQrScanner();
} else if (activityType == ActivityType.maintenance) {
  final result = await BuildingPickerSheet.show(context);
  if (result != null) {
    await workSessionNotifier.startSession(
      activityType: ActivityType.maintenance,
      shiftId: activeShift.id,
      buildingId: result.buildingId,
      buildingName: result.buildingName,
      apartmentId: result.apartmentId,
      unitNumber: result.unitNumber,
    );
  }
} else {
  // Admin — start session immediately
  await workSessionNotifier.startSession(
    activityType: ActivityType.admin,
    shiftId: activeShift.id,
  );
}
```

- [ ] **Step 6: Verify**

Run: `cd gps_tracker && flutter analyze`
Expected: No issues.

- [ ] **Step 7: Commit**

```bash
git add gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart
git commit -m "feat: unified shift dashboard — remove tabs, add activity type picker at clock-in"
```

---

### Task 15: Update auto-close and sync integration

**Files:**
- Modify: `gps_tracker/lib/features/shifts/services/shift_service.dart`
- Modify: Various sync-related files

- [ ] **Step 1: Update shift service clock-out to use work session auto-close**

In `ShiftService.clockOut()`, replace calls to:
- `cleaningSessionService.autoCloseSessions()`
- `maintenanceSessionService.autoCloseSessions()`

With:
- `workSessionService.autoCloseSessions(shiftId, employeeId, closedAt)`

- [ ] **Step 2: Update sync provider**

In the sync provider/service that triggers pending session sync, add `workSessionService.syncPendingSessions()` alongside (or replacing) the existing cleaning/maintenance sync calls.

- [ ] **Step 3: Update Live Activity integration**

Ensure `ShiftActivityService.updateSessionInfo()` is called with the correct session type from `WorkSession.activityType` instead of hardcoded 'cleaning'/'maintenance'.

- [ ] **Step 4: Verify and commit**

```bash
flutter analyze
git add -A
git commit -m "feat: integrate work sessions with shift lifecycle and sync"
```

---

## Chunk 4: Dashboard — Work Sessions Page & Updates

### Task 16: Create dashboard types and hooks

**Files:**
- Create: `dashboard/src/types/work-session.ts`
- Create: `dashboard/src/lib/hooks/use-work-sessions.ts`

- [ ] **Step 1: Write TypeScript types**

**NOTE:** The Supabase RPC returns snake_case JSON keys (`employee_id`, `activity_type`, etc.). The hook must map these to camelCase when parsing. Follow the same approach used in `use-cleaning-sessions.ts` — check how it handles the response transformation. If it uses raw snake_case, match that pattern.

```typescript
// dashboard/src/types/work-session.ts
export type ActivityType = 'cleaning' | 'maintenance' | 'admin';
export type WorkSessionStatus = 'in_progress' | 'completed' | 'auto_closed' | 'manually_closed';

// Field names match the RPC response (snake_case from Supabase)
export interface WorkSession {
  id: string;
  employee_id: string;
  employee_name: string;
  activity_type: ActivityType;
  location_type: string | null;
  studio_number: string | null;
  studio_type: string | null;
  building_name: string | null;
  unit_number: string | null;
  status: WorkSessionStatus;
  started_at: string;
  completed_at: string | null;
  duration_minutes: number | null;
  is_flagged: boolean;
  flag_reason: string | null;
  notes: string | null;
}

export interface WorkSessionSummary {
  totalSessions: number;
  completed: number;
  inProgress: number;
  autoClosed: number;
  manuallyClosed: number;
  avgDurationMinutes: number | null;
  flaggedCount: number;
  byType: {
    cleaning: number;
    maintenance: number;
    admin: number;
  };
}

export const ACTIVITY_TYPE_CONFIG: Record<ActivityType, {
  label: string;
  color: string;
  bgColor: string;
  icon: string; // lucide-react icon name
}> = {
  cleaning: { label: 'Ménage', color: '#4CAF50', bgColor: '#E8F5E9', icon: 'SprayCan' },
  maintenance: { label: 'Entretien', color: '#FF9800', bgColor: '#FFF3E0', icon: 'Wrench' },
  admin: { label: 'Administration', color: '#2196F3', bgColor: '#E3F2FD', icon: 'Briefcase' },
};
```

- [ ] **Step 2: Write hooks**

```typescript
// dashboard/src/lib/hooks/use-work-sessions.ts
// Follow pattern from use-cleaning-sessions.ts
// Main hook: useWorkSessions() — calls get_work_sessions_dashboard RPC
// Params: activityType, buildingId, employeeId, dateFrom, dateTo, status, limit, offset
// Returns: { summary, sessions, totalCount, isLoading, error }
```

- [ ] **Step 3: Commit**

```bash
git add dashboard/src/types/work-session.ts dashboard/src/lib/hooks/use-work-sessions.ts
git commit -m "feat: add work session types and hooks for dashboard"
```

---

### Task 17: Create work-sessions dashboard page

**Files:**
- Create: `dashboard/src/app/dashboard/work-sessions/page.tsx`
- Create: `dashboard/src/components/work-sessions/work-sessions-table.tsx`
- Create: `dashboard/src/components/work-sessions/work-session-filters.tsx`
- Create: `dashboard/src/components/work-sessions/close-session-dialog.tsx`

- [ ] **Step 1: Write the page**

Follow the pattern from `dashboard/src/app/dashboard/cleaning/page.tsx` but with:

- **Filter tabs** at top: All / Ménage / Entretien / Admin (with live counts from summary.byType)
- **Stats cards**: Sessions today, Total hours, Utilization rate, Flagged sessions
- **Table** with columns: Employee, Type (color-coded badge), Location, Status, Started, Duration, Flagged
- Activity type badge: colored chip with icon matching `ACTIVITY_TYPE_CONFIG`
- Manual close dialog for in_progress sessions (same pattern as `close-session-dialog.tsx`)

- [ ] **Step 2: Write the filters component**

Date range picker, employee selector, building selector, status filter.
Follow existing `cleaning-filters.tsx` pattern, add activity type filter.

- [ ] **Step 3: Write the table component**

Follow `cleaning-sessions-table.tsx` pattern. Add activity_type column with colored badge.

- [ ] **Step 4: Write close-session-dialog**

Copy from `dashboard/src/components/cleaning/close-session-dialog.tsx`, change RPC call to `manually_close_work_session`.

- [ ] **Step 5: Verify**

Run: `cd dashboard && npm run build`
Expected: Build succeeds.

- [ ] **Step 6: Commit**

```bash
git add dashboard/src/app/dashboard/work-sessions/ dashboard/src/components/work-sessions/
git commit -m "feat: add work-sessions dashboard page"
```

---

### Task 18: Update sidebar navigation

**Files:**
- Modify: `dashboard/src/components/layout/sidebar.tsx`

- [ ] **Step 1: Change navigation link**

**NOTE:** First read the sidebar.tsx to check the actual field names (it may use `name` instead of `label`). Also verify the icon import — `ClipboardList` must be imported from `lucide-react`.

Replace the Ménage navigation item with:
```tsx
{ name: 'Sessions de travail', href: '/dashboard/work-sessions', icon: ClipboardList }
```

Add `ClipboardList` to the lucide-react imports at the top of the file.

- [ ] **Step 2: Add redirect from old URL**

Create `dashboard/src/app/dashboard/cleaning/page.tsx` as a redirect (or keep existing and add redirect):
```tsx
import { redirect } from 'next/navigation';
export default function CleaningRedirect() {
  redirect('/dashboard/work-sessions');
}
```

This prevents 404s for anyone with bookmarked URLs.

- [ ] **Step 3: Verify and commit**

```bash
cd dashboard && npm run build
git add dashboard/src/components/layout/sidebar.tsx dashboard/src/app/dashboard/cleaning/page.tsx
git commit -m "feat: update sidebar — Ménage → Sessions de travail, add redirect"
```

---

### Task 19: Update team monitoring

**Files:**
- Modify: `dashboard/src/components/monitoring/team-list.tsx`

- [ ] **Step 1: Update SessionBadge**

The `SessionBadge` component currently shows either a PaintBucket (cleaning) or Wrench (maintenance) icon. Update to support 'admin' type and use the `ACTIVITY_TYPE_CONFIG` for consistent styling:

```tsx
// Handle null sessionType (no active session) with early return
if (!sessionType) return null;
const config = ACTIVITY_TYPE_CONFIG[sessionType as ActivityType];
if (!config) return null; // Unknown type fallback
// Use config.color, config.icon, config.label
```

This is a small change — the underlying data already comes from the `get_monitored_team` RPC which was updated in Task 4 to read from `work_sessions`.

- [ ] **Step 2: Verify and commit**

```bash
cd dashboard && npm run build
git add dashboard/src/components/monitoring/team-list.tsx
git commit -m "feat: update monitoring badges for work session activity types"
```

---

### Task 20: Final verification

- [ ] **Step 1: Run Flutter analysis**

```bash
cd gps_tracker && flutter analyze
```
Expected: No issues.

- [ ] **Step 2: Run dashboard build**

```bash
cd dashboard && npm run build
```
Expected: Build succeeds.

- [ ] **Step 3: Verify database**

```sql
-- Check work_sessions table has data
SELECT activity_type, count(*), count(*) FILTER (WHERE status = 'in_progress') AS active
FROM work_sessions GROUP BY activity_type;

-- Check new RPCs exist
SELECT proname FROM pg_proc WHERE proname LIKE '%work_session%';

-- Check sync triggers exist
SELECT tgname FROM pg_trigger WHERE tgname LIKE '%sync%work%';
```

- [ ] **Step 4: Commit all remaining changes**

```bash
git add -A
git commit -m "feat: unified work sessions — Phase 1 complete (database + Flutter + dashboard)"
```

---

## Phase 3 Tasks (NOT included in initial implementation)

These tasks should be executed AFTER all phones are confirmed updated to the new app version.

### Future Task A: Remove bidirectional sync triggers
```sql
DROP TRIGGER trg_sync_cleaning_to_work ON cleaning_sessions;
DROP TRIGGER trg_sync_maintenance_to_work ON maintenance_sessions;
DROP FUNCTION sync_cleaning_to_work_sessions();
DROP FUNCTION sync_maintenance_to_work_sessions();
```

### Future Task B: Drop old tables
```sql
-- Verify no phones use old RPCs (check Supabase logs)
-- Then:
DROP TABLE cleaning_sessions CASCADE;
DROP TABLE maintenance_sessions CASCADE;
-- Drop old enums
DROP TYPE cleaning_session_status;
DROP TYPE maintenance_session_status;
```

### Future Task C: Remove old RPCs
```sql
DROP FUNCTION scan_in;
DROP FUNCTION scan_out;
DROP FUNCTION start_maintenance;
DROP FUNCTION complete_maintenance;
DROP FUNCTION auto_close_shift_sessions;
DROP FUNCTION auto_close_maintenance_sessions;
DROP FUNCTION manually_close_session;
DROP FUNCTION manual_close_cleaning_session;
DROP FUNCTION manually_close_maintenance_session;
DROP FUNCTION get_active_session;
DROP FUNCTION get_cleaning_dashboard;
DROP FUNCTION get_cleaning_stats_by_building;
DROP FUNCTION get_employee_cleaning_stats;
```

### Future Task D: Remove old Flutter code
Delete `lib/features/cleaning/` and `lib/features/maintenance/` directories.

### Future Task E: Remove old dashboard code
Delete `dashboard/src/app/dashboard/cleaning/` and `dashboard/src/components/cleaning/` directories.

---

## Design Notes

### Conflict: shift_type field
The spec says "Store the activity type chosen at clock-in in `shift_type`." However, `shift_type` already stores `regular`/`call` (callback shift detection per Article 58 LNT). These are orthogonal concerns. **Solution:** Do NOT overwrite shift_type. Instead, the activity type is tracked per work_session, not per shift. An employee can change activity type mid-shift (via "Changer d'activité"), creating a new work_session. The shift itself remains `regular` or `call`.

### Admin sessions
Admin sessions have no location and last the entire shift. When an employee selects "Administration" at clock-in, a single work_session is created with `activity_type='admin'` and `location_type='office'`. This session auto-closes when the shift ends. The employee can switch to cleaning/maintenance mid-shift.

### Backward compatibility
During Phase 1-2, both old and new systems coexist:
- Old phones write to `cleaning_sessions`/`maintenance_sessions` → sync triggers copy to `work_sessions`
- New phones write to `work_sessions` → new RPCs also close old-table sessions
- Dashboard reads from `work_sessions` (always has complete data via sync triggers)
- Old RPCs (`scan_in`, `start_maintenance`, etc.) remain functional
