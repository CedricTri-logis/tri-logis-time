# Lunch Break → Shift Split Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `lunch_breaks` table with a shift-split model where lunch physically creates a dedicated shift segment (`is_lunch=true`) linked by `work_body_id`, enabling proper cluster/trip detection during lunch periods.

**Architecture:** Each lunch break splits a shift into 3 segments (work → lunch → work) sharing a `work_body_id`. The `lunch_breaks` table is kept as an inbox during transition — a trigger converts inserts into shift splits. `detect_trips` runs independently on each segment. The dashboard renders lunch as an expandable row with child stops/trips.

**Tech Stack:** PostgreSQL (Supabase migrations), TypeScript/Next.js (dashboard), PL/pgSQL (RPCs/triggers)

**Spec:** `docs/superpowers/specs/2026-03-17-lunch-shift-split-design.md`

---

## File Map

### Database (Phase 1)

| Action | File | Purpose |
|--------|------|---------|
| Create | `supabase/migrations/20260317000001_lunch_shift_split_schema.sql` | Add `work_body_id`, `is_lunch` columns + indexes |
| Create | `supabase/migrations/20260317000002_lunch_inbox_trigger.sql` | Trigger on `lunch_breaks` INSERT/UPDATE to convert to shift split |
| Create | `supabase/migrations/20260317000003_lunch_trigger_updates.sql` | Update `auto_close_sessions`, `set_shift_type_on_insert`, `flag_gpsless_shifts` |
| Create | `supabase/migrations/20260317000004_lunch_retroactive_split.sql` | Split existing 57 lunch breaks into shift segments |
| Create | `supabase/migrations/20260317000005_lunch_rpc_rewrites.sql` | Rewrite `get_day_approval_detail`, `get_weekly_approval_summary`, `get_monitored_team`, `save_activity_override` |
| Delete | `supabase/migrations/20260316000001_add_work_body_id_to_shifts.sql` | Old draft (gap-derived model) |
| Delete | `supabase/migrations/20260316000002_retroactive_lunch_to_shift_split.sql` | Old draft |
| Delete | `supabase/migrations/20260316000003_update_triggers_for_lunch_shifts.sql` | Old draft |
| Delete | `supabase/migrations/20260316000004_rewrite_rpcs_shift_lunch.sql` | Old draft |
| Delete | `supabase/migrations/20260316000005_drop_lunch_breaks_table.sql` | Old draft |

### Dashboard (Phase 2)

| Action | File | Purpose |
|--------|------|---------|
| Modify | `dashboard/src/types/mileage.ts:230` | Add `'lunch'` to `activity_type` union, add `children` field, add `lunch_minutes` to summary |
| Modify | `dashboard/src/lib/utils/merge-clock-events.ts:9` | Add `'lunch'` to `MergeableActivity` union, exclude lunch from stop merging |
| Modify | `dashboard/src/components/approvals/day-approval-detail.tsx:868` | Add `isLunch` type guard, render lunch row, expandable children, summary card |
| Modify | `dashboard/src/components/approvals/approval-grid.tsx:155` | Show lunch minutes in tooltip |

---

## Phase 1: Database Migrations

### Task 1: Schema Changes — Add columns and indexes

**Files:**
- Create: `supabase/migrations/20260317000001_lunch_shift_split_schema.sql`

- [ ] **Step 1: Write the migration SQL**

```sql
-- Add shift-split columns
ALTER TABLE shifts ADD COLUMN work_body_id UUID;
ALTER TABLE shifts ADD COLUMN is_lunch BOOLEAN NOT NULL DEFAULT false;

-- Add clock_out_reason values (no constraint change needed — it's a text column)

-- Indexes for efficient querying
CREATE INDEX idx_shifts_work_body_id ON shifts (work_body_id, is_lunch) WHERE work_body_id IS NOT NULL;
CREATE INDEX idx_shifts_is_lunch ON shifts (employee_id, clocked_in_at) WHERE is_lunch = true;

-- Column comments
COMMENT ON COLUMN shifts.work_body_id IS 'Groups shift segments from the same work day. NULL = simple shift without breaks. Set when a lunch split occurs.';
COMMENT ON COLUMN shifts.is_lunch IS 'TRUE for lunch break segments. GPS continues during lunch but activities are auto-rejected in approvals.';
```

- [ ] **Step 2: Apply migration via MCP `apply_migration`**

- [ ] **Step 3: Verify columns exist**

```sql
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_name = 'shifts' AND column_name IN ('work_body_id', 'is_lunch')
ORDER BY column_name;
```

Expected: `is_lunch` boolean NOT NULL default false, `work_body_id` uuid nullable.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260317000001_lunch_shift_split_schema.sql
git commit -m "feat(db): add work_body_id and is_lunch columns to shifts"
```

---

### Task 2: Inbox Conversion Trigger

**Files:**
- Create: `supabase/migrations/20260317000002_lunch_inbox_trigger.sql`

**Dependencies:** Task 1

This trigger converts `lunch_breaks` INSERT/UPDATE into shift splits. It handles:
- INSERT with `ended_at NOT NULL` (lunch already ended) → 3-way split
- INSERT with `ended_at IS NULL` (lunch starting) → close work segment, create lunch segment
- UPDATE `ended_at` from NULL to value (lunch ending) → close lunch segment, create post-lunch segment

- [ ] **Step 1: Write the trigger function**

The trigger must be `SECURITY DEFINER` to bypass RLS when creating shift segments.

Key logic for INSERT with ended_at NOT NULL:
```sql
CREATE OR REPLACE FUNCTION convert_lunch_to_shift_split()
RETURNS TRIGGER AS $$
DECLARE
  v_shift RECORD;
  v_work_body_id UUID;
  v_lunch_segment_id UUID;
  v_post_lunch_id UUID;
  v_original_status TEXT;
BEGIN
  -- === INSERT TRIGGER ===
  IF TG_OP = 'INSERT' THEN
    -- 1. Find the shift covering this lunch
    -- First try the exact shift_id from the lunch_break row.
    -- If that shift was already split (completed with clock_out_reason='lunch'),
    -- find the latest active work segment in the same work_body_id instead.
    -- This handles the multiple-lunches-per-day case where the Flutter app
    -- still references the original shift_id.
    SELECT * INTO v_shift FROM shifts
    WHERE employee_id = NEW.employee_id
      AND id = NEW.shift_id
      AND clocked_in_at <= NEW.started_at
      AND (clocked_out_at IS NULL OR clocked_out_at >= NEW.started_at);

    -- If parent shift was already split, find the latest active/covering work segment
    IF NOT FOUND OR (v_shift.status = 'completed' AND v_shift.clock_out_reason = 'lunch') THEN
      SELECT * INTO v_shift FROM shifts
      WHERE employee_id = NEW.employee_id
        AND work_body_id = (SELECT work_body_id FROM shifts WHERE id = NEW.shift_id)
        AND is_lunch = false
        AND clocked_in_at <= NEW.started_at
        AND (clocked_out_at IS NULL OR clocked_out_at >= NEW.started_at)
      ORDER BY clocked_in_at DESC
      LIMIT 1;
    END IF;

    IF NOT FOUND THEN
      RETURN NEW; -- No matching shift, skip
    END IF;

    v_original_status := v_shift.status;

    -- 2. Generate work_body_id if not set
    v_work_body_id := COALESCE(v_shift.work_body_id, gen_random_uuid());
    IF v_shift.work_body_id IS NULL THEN
      UPDATE shifts SET work_body_id = v_work_body_id WHERE id = v_shift.id;
    END IF;

    -- 3. Close current segment at lunch start
    UPDATE shifts SET
      clocked_out_at = NEW.started_at,
      clock_out_reason = 'lunch',
      status = 'completed',
      updated_at = NOW()
    WHERE id = v_shift.id;

    -- 4. Create lunch segment
    v_lunch_segment_id := gen_random_uuid();
    INSERT INTO shifts (id, employee_id, work_body_id, is_lunch,
      clocked_in_at, clocked_out_at, clock_out_reason, status,
      shift_type, shift_type_source)
    VALUES (
      v_lunch_segment_id, NEW.employee_id, v_work_body_id, true,
      NEW.started_at,
      CASE WHEN NEW.ended_at IS NOT NULL THEN NEW.ended_at ELSE NULL END,
      CASE WHEN NEW.ended_at IS NOT NULL THEN 'lunch_end' ELSE NULL END,
      CASE WHEN NEW.ended_at IS NOT NULL THEN 'completed' ELSE 'active' END,
      v_shift.shift_type, v_shift.shift_type_source
    );

    -- 5. Create post-lunch work segment (only if lunch has ended)
    IF NEW.ended_at IS NOT NULL THEN
      v_post_lunch_id := gen_random_uuid();
      INSERT INTO shifts (id, employee_id, work_body_id, is_lunch,
        clocked_in_at, clocked_out_at, clock_out_reason, status,
        shift_type, shift_type_source)
      VALUES (
        v_post_lunch_id, NEW.employee_id, v_work_body_id, false,
        NEW.ended_at,
        CASE WHEN v_original_status = 'completed' THEN v_shift.clocked_out_at ELSE NULL END,
        CASE WHEN v_original_status = 'completed' THEN v_shift.clock_out_reason ELSE NULL END,
        v_original_status,
        v_shift.shift_type, v_shift.shift_type_source
      );

      -- 6. Redistribute GPS points to lunch and post-lunch segments
      UPDATE gps_points SET shift_id = v_lunch_segment_id
      WHERE shift_id = v_shift.id
        AND captured_at >= NEW.started_at AND captured_at < NEW.ended_at;

      UPDATE gps_points SET shift_id = v_post_lunch_id
      WHERE shift_id = v_shift.id
        AND captured_at >= NEW.ended_at;

      -- 7. Redistribute work_sessions
      UPDATE work_sessions SET shift_id = v_lunch_segment_id
      WHERE shift_id = v_shift.id
        AND started_at >= NEW.started_at AND started_at < NEW.ended_at;

      UPDATE work_sessions SET shift_id = v_post_lunch_id
      WHERE shift_id = v_shift.id
        AND started_at >= NEW.ended_at;

      -- 8. Delete existing clusters/trips (will be re-detected async)
      DELETE FROM trip_gps_points WHERE trip_id IN (
        SELECT id FROM trips WHERE shift_id = v_shift.id
      );
      DELETE FROM trips WHERE shift_id = v_shift.id;
      DELETE FROM stationary_clusters WHERE shift_id = v_shift.id;
    ELSE
      -- Lunch starting (ended_at NULL): redistribute GPS after lunch start to lunch segment
      UPDATE gps_points SET shift_id = v_lunch_segment_id
      WHERE shift_id = v_shift.id
        AND captured_at >= NEW.started_at;
    END IF;

  -- === UPDATE TRIGGER (lunch ending) ===
  ELSIF TG_OP = 'UPDATE' AND OLD.ended_at IS NULL AND NEW.ended_at IS NOT NULL THEN
    -- Find the active lunch segment
    SELECT * INTO v_shift FROM shifts
    WHERE employee_id = NEW.employee_id
      AND is_lunch = true
      AND work_body_id IS NOT NULL
      AND status = 'active'
      AND clocked_in_at = OLD.started_at
    ORDER BY clocked_in_at DESC LIMIT 1;

    IF NOT FOUND THEN
      RETURN NEW;
    END IF;

    -- Close the lunch segment
    UPDATE shifts SET
      clocked_out_at = NEW.ended_at,
      clock_out_reason = 'lunch_end',
      status = 'completed',
      updated_at = NOW()
    WHERE id = v_shift.id;

    -- Create post-lunch work segment
    v_post_lunch_id := gen_random_uuid();
    INSERT INTO shifts (id, employee_id, work_body_id, is_lunch,
      clocked_in_at, status, shift_type, shift_type_source)
    VALUES (
      v_post_lunch_id, NEW.employee_id, v_shift.work_body_id, false,
      NEW.ended_at, 'active',
      v_shift.shift_type, v_shift.shift_type_source
    );

    -- Redistribute GPS points after lunch end to post-lunch segment
    UPDATE gps_points SET shift_id = v_post_lunch_id
    WHERE shift_id = v_shift.id
      AND captured_at >= NEW.ended_at;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

Then create the triggers:
```sql
CREATE TRIGGER trg_lunch_to_shift_split
  AFTER INSERT ON lunch_breaks
  FOR EACH ROW
  EXECUTE FUNCTION convert_lunch_to_shift_split();

CREATE TRIGGER trg_lunch_end_to_shift_split
  AFTER UPDATE OF ended_at ON lunch_breaks
  FOR EACH ROW
  WHEN (OLD.ended_at IS NULL AND NEW.ended_at IS NOT NULL)
  EXECUTE FUNCTION convert_lunch_to_shift_split();
```

- [ ] **Step 2: Apply migration via MCP `apply_migration`**

- [ ] **Step 3: Test with a manual insert**

```sql
-- Dry-run test: insert a lunch break for a known completed shift
-- First find a test shift
SELECT id, employee_id, clocked_in_at, clocked_out_at, status
FROM shifts WHERE status = 'completed'
ORDER BY clocked_in_at DESC LIMIT 1;
```

Verify the trigger fires and creates 3 segments. Then rollback if needed.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260317000002_lunch_inbox_trigger.sql
git commit -m "feat(db): add lunch_breaks inbox conversion trigger"
```

---

### Task 3: Update Existing Triggers and Crons

**Files:**
- Create: `supabase/migrations/20260317000003_lunch_trigger_updates.sql`

**Dependencies:** Task 1

- [ ] **Step 1: Write the migration**

Three updates in one migration:

**A) `auto_close_sessions_on_shift_complete` — skip lunch clock-outs:**

The current trigger (migration 036) auto-closes cleaning/maintenance/work sessions when a shift completes. We must skip this when `clock_out_reason = 'lunch'` because the employee is returning.

```sql
CREATE OR REPLACE FUNCTION auto_close_sessions_on_shift_complete()
RETURNS TRIGGER AS $$
BEGIN
  -- Skip auto-close for lunch clock-outs (employee is returning)
  IF NEW.clock_out_reason = 'lunch' OR NEW.clock_out_reason = 'lunch_end' THEN
    RETURN NEW;
  END IF;

  -- [... rest of existing function unchanged ...]
END;
$$ LANGUAGE plpgsql;
```

Read the full current function from migration 036 before writing. Add the lunch guard at the top.

**B) `set_shift_type_on_insert` — inherit from work_body_id:**

New trigger. When inserting a post-lunch segment, inherit `shift_type` from the first segment in the same `work_body_id`.

```sql
CREATE OR REPLACE FUNCTION set_shift_type_on_insert()
RETURNS TRIGGER AS $$
DECLARE
  v_existing RECORD;
BEGIN
  -- If this shift has a work_body_id, check for existing segments
  IF NEW.work_body_id IS NOT NULL THEN
    SELECT shift_type, shift_type_source INTO v_existing
    FROM shifts
    WHERE work_body_id = NEW.work_body_id
      AND id != NEW.id
    ORDER BY clocked_in_at ASC
    LIMIT 1;

    IF FOUND AND v_existing.shift_type IS NOT NULL THEN
      NEW.shift_type := v_existing.shift_type;
      NEW.shift_type_source := v_existing.shift_type_source;
      RETURN NEW;
    END IF;
  END IF;

  -- Auto-classify by Montreal hour (existing logic)
  IF EXTRACT(HOUR FROM NEW.clocked_in_at AT TIME ZONE 'America/Montreal') >= 17
     OR EXTRACT(HOUR FROM NEW.clocked_in_at AT TIME ZONE 'America/Montreal') < 5 THEN
    NEW.shift_type := 'call';
    NEW.shift_type_source := 'auto';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Drop the old trigger (may exist as trg_set_shift_type from callback_shifts migration)
-- then create with the new name to avoid duplicate triggers
DROP TRIGGER IF EXISTS trg_set_shift_type ON shifts;
DROP TRIGGER IF EXISTS trg_set_shift_type_on_insert ON shifts;

CREATE TRIGGER trg_set_shift_type_on_insert
  BEFORE INSERT ON shifts
  FOR EACH ROW
  EXECUTE FUNCTION set_shift_type_on_insert();
```

**C) `flag_gpsless_shifts` — skip post-lunch segments:**

Add exclusion for segments that share a `work_body_id` with a recently-completed lunch segment.

```sql
CREATE OR REPLACE FUNCTION flag_gpsless_shifts()
RETURNS void AS $$
BEGIN
  -- [read current function from migration 110, then add WHERE clause:]
  -- AND NOT (
  --   s.work_body_id IS NOT NULL
  --   AND EXISTS (
  --     SELECT 1 FROM shifts s2
  --     WHERE s2.work_body_id = s.work_body_id
  --       AND s2.clock_out_reason = 'lunch'
  --       AND s2.clocked_out_at > NOW() - INTERVAL '30 minutes'
  --   )
  -- )
END;
$$ LANGUAGE plpgsql;
```

- [ ] **Step 2: Read current functions from migrations 036 and 110 to get exact SQL**

Read `supabase/migrations/036_auto_close_sessions_on_shift_complete.sql` and `supabase/migrations/110_match_clock_events_on_gpsless_close.sql` to copy the full function bodies and add the lunch guards.

- [ ] **Step 3: Apply migration via MCP `apply_migration`**

- [ ] **Step 4: Verify triggers exist**

```sql
SELECT tgname, tgtype FROM pg_trigger
WHERE tgrelid = 'shifts'::regclass
  AND tgname IN ('trg_set_shift_type_on_insert', 'auto_close_sessions_trigger');
```

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260317000003_lunch_trigger_updates.sql
git commit -m "feat(db): update triggers for lunch shift-split support"
```

---

### Task 4: Retroactive Migration

**Files:**
- Create: `supabase/migrations/20260317000004_lunch_retroactive_split.sql`

**Dependencies:** Tasks 1, 2, 3

This migration splits the existing 57 lunch breaks into shift segments. Structure:
- All 57 splits in a single transaction (57 is small enough — no batching needed)
- `detect_trips` re-runs in a separate `DO $$` block after the structural split commits
- If a `detect_trips` call fails, it logs a warning and continues (the split is already done)

- [ ] **Step 1: Write the retroactive migration**

```sql
-- Retroactive lunch-to-shift-split migration
-- Processes existing lunch_breaks and splits their parent shifts into segments

DO $$
DECLARE
  v_lb RECORD;
  v_shift RECORD;
  v_work_body_id UUID;
  v_lunch_segment_id UUID;
  v_post_lunch_id UUID;
  v_count INTEGER := 0;
  v_gps_moved INTEGER := 0;
BEGIN
  RAISE NOTICE 'Starting retroactive lunch split...';

  FOR v_lb IN
    SELECT lb.*, s.status AS shift_status, s.clocked_out_at AS shift_clock_out,
           s.clock_out_reason AS shift_clock_out_reason,
           s.shift_type, s.shift_type_source, s.work_body_id AS existing_wbi
    FROM lunch_breaks lb
    JOIN shifts s ON s.id = lb.shift_id
    WHERE lb.ended_at IS NOT NULL  -- Only process completed lunches
      AND s.work_body_id IS NULL   -- Skip already-split shifts
    ORDER BY lb.shift_id, lb.started_at
  LOOP
    -- Generate work_body_id
    v_work_body_id := COALESCE(v_lb.existing_wbi, gen_random_uuid());

    -- Set work_body_id on parent shift
    UPDATE shifts SET work_body_id = v_work_body_id WHERE id = v_lb.shift_id;

    -- Close parent shift at lunch start
    UPDATE shifts SET
      clocked_out_at = v_lb.started_at,
      clock_out_reason = 'lunch',
      status = 'completed',
      updated_at = NOW()
    WHERE id = v_lb.shift_id;

    -- Create lunch segment
    v_lunch_segment_id := gen_random_uuid();
    INSERT INTO shifts (id, employee_id, work_body_id, is_lunch,
      clocked_in_at, clocked_out_at, clock_out_reason, status,
      shift_type, shift_type_source)
    VALUES (
      v_lunch_segment_id, v_lb.employee_id, v_work_body_id, true,
      v_lb.started_at, v_lb.ended_at, 'lunch_end', 'completed',
      v_lb.shift_type, v_lb.shift_type_source
    );

    -- Create post-lunch work segment
    v_post_lunch_id := gen_random_uuid();
    INSERT INTO shifts (id, employee_id, work_body_id, is_lunch,
      clocked_in_at, clocked_out_at, clock_out_reason, status,
      shift_type, shift_type_source)
    VALUES (
      v_post_lunch_id, v_lb.employee_id, v_work_body_id, false,
      v_lb.ended_at, v_lb.shift_clock_out, v_lb.shift_clock_out_reason,
      v_lb.shift_status, v_lb.shift_type, v_lb.shift_type_source
    );

    -- Redistribute GPS points
    UPDATE gps_points SET shift_id = v_lunch_segment_id
    WHERE shift_id = v_lb.shift_id
      AND captured_at >= v_lb.started_at AND captured_at < v_lb.ended_at;
    GET DIAGNOSTICS v_gps_moved = ROW_COUNT;

    UPDATE gps_points SET shift_id = v_post_lunch_id
    WHERE shift_id = v_lb.shift_id
      AND captured_at >= v_lb.ended_at;

    -- Redistribute work_sessions
    UPDATE work_sessions SET shift_id = v_lunch_segment_id
    WHERE shift_id = v_lb.shift_id
      AND started_at >= v_lb.started_at AND started_at < v_lb.ended_at;

    UPDATE work_sessions SET shift_id = v_post_lunch_id
    WHERE shift_id = v_lb.shift_id
      AND started_at >= v_lb.ended_at;

    -- Redistribute gps_gaps
    UPDATE gps_gaps SET shift_id = v_lunch_segment_id
    WHERE shift_id = v_lb.shift_id
      AND started_at >= v_lb.started_at AND started_at < v_lb.ended_at;

    UPDATE gps_gaps SET shift_id = v_post_lunch_id
    WHERE shift_id = v_lb.shift_id
      AND started_at >= v_lb.ended_at;

    -- Delete existing clusters/trips (will be re-detected)
    DELETE FROM cluster_segments WHERE stationary_cluster_id IN (
      SELECT id FROM stationary_clusters WHERE shift_id = v_lb.shift_id
    );
    DELETE FROM trip_gps_points WHERE trip_id IN (
      SELECT id FROM trips WHERE shift_id = v_lb.shift_id
    );
    DELETE FROM trips WHERE shift_id = v_lb.shift_id;
    UPDATE gps_points SET stationary_cluster_id = NULL
    WHERE shift_id IN (v_lb.shift_id, v_lunch_segment_id, v_post_lunch_id);
    DELETE FROM stationary_clusters WHERE shift_id = v_lb.shift_id;

    v_count := v_count + 1;
    RAISE NOTICE 'Split shift % (lunch #%), GPS moved: %', v_lb.shift_id, v_count, v_gps_moved;
  END LOOP;

  -- Delete day_approvals and activity_overrides for affected shifts
  -- (supervisors will need to re-approve)
  DELETE FROM activity_overrides WHERE day_approval_id IN (
    SELECT da.id FROM day_approvals da
    JOIN shifts s ON s.employee_id = da.employee_id
    WHERE s.work_body_id IS NOT NULL
      AND da.date = (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date
  );

  DELETE FROM day_approvals WHERE id IN (
    SELECT da.id FROM day_approvals da
    JOIN shifts s ON s.employee_id = da.employee_id
    WHERE s.work_body_id IS NOT NULL
      AND da.date = (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date
  );

  RAISE NOTICE 'Retroactive split complete: % lunch breaks processed', v_count;
END $$;

-- Re-run detect_trips on all split segments
DO $$
DECLARE
  v_seg RECORD;
  v_count INTEGER := 0;
BEGIN
  RAISE NOTICE 'Re-running detect_trips on split segments...';

  FOR v_seg IN
    SELECT id FROM shifts
    WHERE work_body_id IS NOT NULL
      AND status = 'completed'
    ORDER BY clocked_in_at
  LOOP
    BEGIN
      PERFORM detect_trips(v_seg.id);
      v_count := v_count + 1;
      IF v_count % 10 = 0 THEN
        RAISE NOTICE 'detect_trips progress: %/total', v_count;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'detect_trips failed for shift %: %', v_seg.id, SQLERRM;
    END;
  END LOOP;

  RAISE NOTICE 'detect_trips re-run complete: % segments processed', v_count;
END $$;
```

- [ ] **Step 2: Verify current lunch break count before applying**

```sql
SELECT count(*) FROM lunch_breaks WHERE ended_at IS NOT NULL;
```

Expected: ~57

- [ ] **Step 3: Apply migration via MCP `apply_migration`**

Monitor the NOTICE output for progress and any warnings.

- [ ] **Step 4: Verify results**

```sql
-- Count split shifts
SELECT count(*) FROM shifts WHERE work_body_id IS NOT NULL;

-- Verify 3 segments per lunch (approx)
SELECT work_body_id, count(*),
       count(*) FILTER (WHERE is_lunch) AS lunch_segments,
       count(*) FILTER (WHERE NOT is_lunch) AS work_segments
FROM shifts WHERE work_body_id IS NOT NULL
GROUP BY work_body_id
ORDER BY count(*) DESC
LIMIT 10;

-- Verify Fatima's shift is now split
SELECT id, is_lunch,
       clocked_in_at AT TIME ZONE 'America/Montreal' AS clock_in,
       clocked_out_at AT TIME ZONE 'America/Montreal' AS clock_out,
       clock_out_reason, status
FROM shifts
WHERE employee_id = 'df60ac38-8f23-484f-8d9b-25c8bd1d8287'
  AND clocked_in_at >= '2026-03-16'::date AT TIME ZONE 'America/Montreal'
  AND clocked_in_at < '2026-03-17'::date AT TIME ZONE 'America/Montreal'
ORDER BY clocked_in_at;
```

Expected for Fatima: 3 rows — work (08:18→12:55), lunch (12:55→14:31), work (14:31→19:07).

- [ ] **Step 5: Verify detect_trips created proper clusters**

```sql
-- Fatima should now have separate clusters per segment
SELECT sc.shift_id, s.is_lunch,
       sc.started_at AT TIME ZONE 'America/Montreal' AS started,
       sc.ended_at AT TIME ZONE 'America/Montreal' AS ended,
       sc.duration_seconds
FROM stationary_clusters sc
JOIN shifts s ON s.id = sc.shift_id
WHERE s.employee_id = 'df60ac38-8f23-484f-8d9b-25c8bd1d8287'
  AND s.clocked_in_at >= '2026-03-16'::date AT TIME ZONE 'America/Montreal'
ORDER BY sc.started_at;
```

Expected: Multiple clusters, with lunch segment having its own cluster(s).

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/20260317000004_lunch_retroactive_split.sql
git commit -m "feat(db): retroactive lunch-to-shift-split migration"
```

---

### Task 5: Rewrite RPCs

**Files:**
- Create: `supabase/migrations/20260317000005_lunch_rpc_rewrites.sql`

**Dependencies:** Tasks 1, 4

This task rewrites 4 RPCs to handle the shift-split model. The implementer MUST read the current function definitions first.

- [ ] **Step 1: Read current RPC definitions**

Read these migration files to get the full current SQL:
- `supabase/migrations/147_project_sessions_location_id.sql` — `get_day_approval_detail` (lines 6-529)
- `supabase/migrations/144_restore_lunch_in_approvals.sql` — `get_weekly_approval_summary` (lines 607-823)
- `supabase/migrations/20260313163151_add_device_os_version_to_monitored_team.sql` — `get_monitored_team` (latest version, overwrites migration 140)
- `supabase/migrations/096_approval_actions.sql` — `save_activity_override` (lines 9-70)

- [ ] **Step 2: Rewrite `_get_day_approval_detail_base`**

Key changes to the existing function:

**A) Replace lunch_breaks CTE with lunch-from-shifts derivation:**

Remove any CTE that queries `lunch_breaks`. Instead, derive lunch activities from shifts with `is_lunch = true`:

```sql
-- LUNCH: derive from is_lunch segments
lunch_activities AS (
  SELECT
    s.id AS activity_id,
    'lunch'::TEXT AS activity_type,
    s.clocked_in_at AS started_at,
    s.clocked_out_at AS ended_at,
    EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at))::INTEGER / 60 AS duration_minutes,
    'rejected'::TEXT AS auto_status,
    'Pause dîner (non payée)'::TEXT AS auto_reason,
    s.id AS shift_id
  FROM shifts s
  WHERE s.employee_id = p_employee_id
    AND s.is_lunch = true
    AND s.work_body_id IS NOT NULL
    AND (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date = p_date
)
```

**B) Add children to lunch activities:**

For each lunch activity, nest the stops/trips from that lunch segment:

```sql
-- In the final SELECT, for lunch activities:
CASE WHEN a.activity_type = 'lunch' THEN (
  SELECT jsonb_agg(child ORDER BY child->>'started_at')
  FROM (
    -- stops from lunch segment's clusters
    SELECT jsonb_build_object(
      'activity_id', sc.id,
      'activity_type', 'stop',
      'started_at', sc.started_at,
      'ended_at', sc.ended_at,
      'duration_minutes', sc.duration_seconds / 60,
      'auto_status', 'rejected',
      'auto_reason', 'Pendant la pause dîner',
      'location_name', l.name,
      'location_type', l.location_type::TEXT
      -- ... other fields
    ) AS child
    FROM stationary_clusters sc
    LEFT JOIN locations l ON l.id = sc.matched_location_id
    WHERE sc.shift_id = a.shift_id

    UNION ALL

    -- trips from lunch segment
    SELECT jsonb_build_object(
      'activity_id', t.id,
      'activity_type', 'trip',
      'started_at', t.started_at,
      'ended_at', t.ended_at,
      'duration_minutes', t.duration_minutes,
      'distance_km', COALESCE(t.road_distance_km, t.distance_km),
      'auto_status', 'rejected',
      'auto_reason', 'Pendant la pause dîner',
      'transport_mode', t.transport_mode
      -- ... other fields
    ) AS child
    FROM trips t
    WHERE t.shift_id = a.shift_id
  ) children
) ELSE NULL END AS children
```

**C) Update shift-level queries to use work_body_id:**

When querying shifts for a day, group by `work_body_id` to treat segments as one continuous work period:

```sql
-- Get all shifts for the day (both standalone and segments)
day_shifts AS (
  SELECT s.*
  FROM shifts s
  WHERE s.employee_id = p_employee_id
    AND NOT s.is_lunch  -- Exclude lunch segments from main activity query
    AND (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date = p_date
)
```

**D) Update summary calculation:**

```sql
-- lunch_minutes = sum of is_lunch segment durations
v_lunch_minutes := COALESCE((
  SELECT SUM(EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at))::INTEGER / 60)
  FROM shifts s
  WHERE s.employee_id = p_employee_id
    AND s.is_lunch = true
    AND (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date = p_date
    AND s.clocked_out_at IS NOT NULL
), 0);

-- total_shift_minutes excludes lunch (only work segments)
```

Add `lunch_minutes` to the returned summary JSONB.

- [ ] **Step 3: Rewrite `get_weekly_approval_summary`**

Key change: Replace the `day_lunch` CTE (which queries `lunch_breaks`) with a query on `shifts WHERE is_lunch = true`.

```sql
-- Replace:
-- day_lunch AS (
--   SELECT ... FROM lunch_breaks lb ...
-- )
-- With:
day_lunch AS (
  SELECT
    s.employee_id,
    (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date AS work_date,
    SUM(EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at))::INTEGER / 60) AS lunch_minutes
  FROM shifts s
  WHERE s.is_lunch = true
    AND s.clocked_out_at IS NOT NULL
    AND s.employee_id = ANY(/* employee list */)
    AND (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date BETWEEN p_start_date AND p_end_date
  GROUP BY s.employee_id, (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date
)
```

- [ ] **Step 4: Rewrite `get_monitored_team`**

Replace the LATERAL join on `lunch_breaks` with a check on active `is_lunch` segments:

```sql
-- Replace:
-- LEFT JOIN LATERAL (
--   SELECT ... FROM lunch_breaks lb WHERE lb.shift_id = s.id AND lb.ended_at IS NULL
-- ) lunch ON true
-- With:
LEFT JOIN LATERAL (
  SELECT true AS is_on_lunch, s_lunch.clocked_in_at AS lunch_started_at
  FROM shifts s_lunch
  WHERE s_lunch.work_body_id = s.work_body_id
    AND s_lunch.is_lunch = true
    AND s_lunch.status = 'active'
  LIMIT 1
) lunch ON s.work_body_id IS NOT NULL
```

Also: when an employee has an active lunch segment, the monitoring should show "en pause" (display label in UI, not DB).

- [ ] **Step 5: Update `save_activity_override`**

Add lunch rejection to the activity_type validation (line 33 of migration 096):

```sql
-- Add explicit lunch rejection BEFORE the existing validation:
IF p_activity_type = 'lunch' THEN
  RAISE EXCEPTION 'Lunch activities cannot be overridden';
END IF;

-- Existing validation remains unchanged:
-- IF p_activity_type NOT IN ('trip', 'stop', 'clock_in', 'clock_out') THEN
--   RAISE EXCEPTION 'Invalid activity type';
-- END IF;
```

- [ ] **Step 6: Apply migration via MCP `apply_migration`**

- [ ] **Step 7: Test get_day_approval_detail for Fatima**

```sql
SELECT * FROM get_day_approval_detail(
  'df60ac38-8f23-484f-8d9b-25c8bd1d8287'::uuid,
  '2026-03-16'::date
);
```

Expected: Activities include a `lunch` activity with `children` array containing stops/trips during lunch.

- [ ] **Step 8: Commit**

```bash
git add supabase/migrations/20260317000005_lunch_rpc_rewrites.sql
git commit -m "feat(db): rewrite RPCs for lunch shift-split model"
```

---

### Task 6: Delete Old Draft Migrations

**Files:**
- Delete: `supabase/migrations/20260316000001_add_work_body_id_to_shifts.sql`
- Delete: `supabase/migrations/20260316000002_retroactive_lunch_to_shift_split.sql`
- Delete: `supabase/migrations/20260316000003_update_triggers_for_lunch_shifts.sql`
- Delete: `supabase/migrations/20260316000004_rewrite_rpcs_shift_lunch.sql`
- Delete: `supabase/migrations/20260316000005_drop_lunch_breaks_table.sql`

**Dependencies:** None (can be done anytime)

- [ ] **Step 1: Delete the 5 draft files**

```bash
rm supabase/migrations/20260316000001_add_work_body_id_to_shifts.sql
rm supabase/migrations/20260316000002_retroactive_lunch_to_shift_split.sql
rm supabase/migrations/20260316000003_update_triggers_for_lunch_shifts.sql
rm supabase/migrations/20260316000004_rewrite_rpcs_shift_lunch.sql
rm supabase/migrations/20260316000005_drop_lunch_breaks_table.sql
```

- [ ] **Step 2: Commit**

```bash
git add -A supabase/migrations/20260316*.sql
git commit -m "chore: remove old draft lunch-split migrations (gap-derived model)"
```

---

## Phase 2: Dashboard

### Task 7: Update TypeScript Types

**Files:**
- Modify: `dashboard/src/types/mileage.ts:230`

**Dependencies:** Task 5 (RPCs must return `lunch` activities)

- [ ] **Step 1: Read the current types file**

Read `dashboard/src/types/mileage.ts` to find exact line numbers for:
- `ApprovalActivity` interface and `activity_type` union
- Summary type with `total_shift_minutes`, etc.

- [ ] **Step 2: Add `'lunch'` to activity_type union**

```typescript
// Change:
activity_type: 'trip' | 'stop' | 'clock_in' | 'clock_out' | 'gap'
// To:
activity_type: 'trip' | 'stop' | 'clock_in' | 'clock_out' | 'gap' | 'lunch'
```

- [ ] **Step 3: Add `children` field to ApprovalActivity**

```typescript
// Add to ApprovalActivity interface:
children?: ApprovalActivity[]
```

- [ ] **Step 4: Add `lunch_minutes` to summary type and WeeklyDayEntry**

Find the summary type and add:
```typescript
lunch_minutes: number
```

Also find `WeeklyDayEntry` (around line 277) and add `lunch_minutes: number` — this is needed for the approval grid tooltip (Task 10).

- [ ] **Step 5: Verify build passes**

```bash
cd dashboard && npm run build
```

- [ ] **Step 6: Commit**

```bash
git add dashboard/src/types/mileage.ts
git commit -m "feat(dashboard): add lunch type to ApprovalActivity"
```

---

### Task 8: Update merge-clock-events.ts

**Files:**
- Modify: `dashboard/src/lib/utils/merge-clock-events.ts:9`

**Dependencies:** Task 7

- [ ] **Step 1: Read the current file**

Read `dashboard/src/lib/utils/merge-clock-events.ts` fully.

- [ ] **Step 2: Add `'lunch'` to MergeableActivity union**

```typescript
// Line 9, change:
activity_type: 'trip' | 'stop' | 'clock_in' | 'clock_out' | 'gap'
// To:
activity_type: 'trip' | 'stop' | 'clock_in' | 'clock_out' | 'gap' | 'lunch'
```

- [ ] **Step 3: Exclude lunch from stop merging**

In the merge logic where clock events are merged into stops (around line 90), add a guard to skip lunch activities:

```typescript
// When checking if a clock event should merge into a stop:
// Add: && filtered[j].activity_type !== 'lunch'
```

Lunch must remain as a standalone row, never merged into adjacent stops.

- [ ] **Step 4: Verify build passes**

```bash
cd dashboard && npm run build
```

- [ ] **Step 5: Commit**

```bash
git add dashboard/src/lib/utils/merge-clock-events.ts
git commit -m "feat(dashboard): add lunch support to merge-clock-events"
```

---

### Task 9: Implement Lunch Row Rendering

**Files:**
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx`

**Dependencies:** Tasks 7, 8

This is the main UI task. The implementer MUST read the full component first.

- [ ] **Step 1: Read the full component**

Read `dashboard/src/components/approvals/day-approval-detail.tsx` fully (1125 lines). Understand:
- How `ActivityRow` renders each activity type (lines 868+)
- How type guards work (`isTrip`, `isStop`, `isClock`, `isGap`)
- How expand/collapse works
- How summary cards are rendered (lines 600+)
- How approve/reject buttons work

- [ ] **Step 2: Add `isLunch` type guard**

Around line 868-873, add:

```typescript
const isLunch = activity.activity_type === 'lunch';
// Update canExpand:
const canExpand = isLunch || (!isClock && !isGap);
```

- [ ] **Step 3: Add lunch row styling**

In the row background logic, add lunch case:

```typescript
// Lunch: neutral slate background, no status-based coloring
if (isLunch) {
  return 'bg-slate-50 border-l-4 border-slate-400';
}
```

- [ ] **Step 4: Add lunch icon**

Import `UtensilsCrossed` from lucide-react. In the type icon column:

```typescript
if (isLunch) {
  return <UtensilsCrossed className="h-4 w-4 text-slate-500" />;
}
```

- [ ] **Step 5: Remove approve/reject buttons for lunch**

In the action column, skip buttons for lunch:

```typescript
if (isLunch) {
  return <span className="text-xs text-slate-400">Non payé</span>;
}
```

- [ ] **Step 6: Add lunch expand detail with children**

When `isLunch && isExpanded`, render child activities:

```tsx
{isLunch && isExpanded && activity.children && (
  <tr>
    <td colSpan={8} className="p-0">
      <div className="bg-slate-50 border-t border-slate-200 px-4 py-2">
        <p className="text-xs text-slate-500 mb-2 font-medium">
          Activités pendant la pause
        </p>
        <table className="w-full text-sm">
          <tbody>
            {activity.children.map((child) => (
              <tr key={`${child.activity_type}-${child.activity_id}`}
                  className="border-b border-slate-100 last:border-0">
                {/* Render child stop/trip rows — simplified version */}
                <td className="py-1.5 px-2">
                  {child.activity_type === 'trip' ? '🚗' : '📍'}
                </td>
                <td className="py-1.5">{child.location_name || 'Inconnu'}</td>
                <td className="py-1.5 text-right text-slate-400">
                  {child.duration_minutes} min
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </td>
  </tr>
)}
```

Use proper lucide-react icons instead of emoji in actual implementation.

- [ ] **Step 7: Add lunch summary card**

In the summary cards grid (around line 600), add a 6th card:

```tsx
{/* Lunch card */}
{detail.summary.lunch_minutes > 0 && (
  <div className="rounded-lg border bg-slate-50 p-3">
    <div className="flex items-center gap-2 text-sm text-slate-600">
      <UtensilsCrossed className="h-4 w-4" />
      <span>Dîner</span>
    </div>
    <p className="text-lg font-semibold text-slate-700 mt-1">
      {formatDuration(detail.summary.lunch_minutes)}
    </p>
  </div>
)}
```

Update the grid class to accommodate the new card (e.g., `sm:grid-cols-6` or keep responsive).

- [ ] **Step 8: Verify build passes**

```bash
cd dashboard && npm run build
```

- [ ] **Step 9: Test visually in browser**

Navigate to Fatima's approval detail for 2026-03-16. Verify:
- Lunch row appears with utensils icon and slate background
- Lunch is expandable with child stops/trips
- No approve/reject buttons on lunch
- Summary card shows "Dîner: 1h35"
- Pre-lunch and post-lunch stops are separate rows

- [ ] **Step 10: Commit**

```bash
git add dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "feat(dashboard): render lunch activities in approval timeline"
```

---

### Task 10: Update Approval Grid Tooltip

**Files:**
- Modify: `dashboard/src/components/approvals/approval-grid.tsx`

**Dependencies:** Task 5 (weekly summary RPC returns `lunch_minutes`)

- [ ] **Step 1: Read the component**

Read `dashboard/src/components/approvals/approval-grid.tsx` to find where day cells are rendered and if tooltips exist.

- [ ] **Step 2: Add lunch minutes to day cell display**

If tooltips exist, add lunch info. If not, add a title attribute:

```typescript
// In renderCell or equivalent:
const tooltip = `${formatDuration(day.shift_minutes)} travaillé` +
  (day.lunch_minutes > 0 ? ` · ${formatDuration(day.lunch_minutes)} dîner` : '');
```

- [ ] **Step 3: Verify build passes**

```bash
cd dashboard && npm run build
```

- [ ] **Step 4: Commit**

```bash
git add dashboard/src/components/approvals/approval-grid.tsx
git commit -m "feat(dashboard): show lunch duration in approval grid"
```

---

## Phase 3: Flutter App Update (Future — not in this plan)

Documented for reference. Will be a separate plan when ready:
- Remove `lunch_breaks` table writes from sync_provider
- Modify lunch_break_provider to use clock-out/clock-in with reason='lunch'
- Or keep current behavior (writes to lunch_breaks, trigger handles conversion)
- Deploy and bump `minimum_app_version`

## Phase 4: Cleanup (Future — not in this plan)

- Drop `lunch_breaks` table
- Remove conversion trigger
- Remove inbox compatibility code
