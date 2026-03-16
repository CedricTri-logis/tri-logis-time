# Lunch Break → Shift Split Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the `lunch_breaks` table by treating lunch breaks as shift boundaries — closing the current shift with `clock_out_reason = 'lunch'` and opening a new shift with the same `work_body_id`. Lunch duration becomes the implicit gap between two shift segments.

**Architecture:** Add `work_body_id` UUID column to `shifts` to group segments of a continuous work body. Retroactively migrate 56 existing lunch breaks into shift splits. Rewrite 5 RPCs that query `lunch_breaks` to derive lunch data from shift gaps. Clean up `activity_overrides` CHECK constraint (remove obsolete `lunch_start`/`lunch_end` types). Update Flutter app to close/open shifts instead of creating lunch records. Update dashboard to display work body segments with lunch gaps.

**Tech Stack:** PostgreSQL (Supabase), Dart/Flutter, TypeScript/Next.js (dashboard)

**Spec:** `docs/superpowers/specs/2026-03-16-lunch-break-shift-split-design.md`

---

## File Structure

### Database migrations (create)
- `supabase/migrations/20260316000001_add_work_body_id_to_shifts.sql` — Add column + index
- `supabase/migrations/20260316000002_retroactive_lunch_to_shift_split.sql` — Convert 56 lunch breaks to shift splits
- `supabase/migrations/20260316000003_update_triggers_for_lunch_shifts.sql` — Adapt 2 triggers
- `supabase/migrations/20260316000004_rewrite_rpcs_shift_lunch.sql` — Rewrite 5 RPCs + clean up activity_overrides CHECK
- `supabase/migrations/20260316000005_drop_lunch_breaks_table.sql` — Final cleanup (deploy AFTER Flutter update)

### Flutter (modify)
- `gps_tracker/lib/features/shifts/providers/lunch_break_provider.dart` — Rewrite to close/open shifts
- `gps_tracker/lib/features/shifts/providers/shift_provider.dart` — Add work_body_id awareness
- `gps_tracker/lib/shared/services/local_database.dart` — Add work_body_id to local_shifts, drop local_lunch_breaks
- `gps_tracker/lib/features/shifts/services/sync_service.dart` — Remove _syncLunchBreaks
- `gps_tracker/lib/features/shifts/widgets/lunch_break_button.dart` — Keep, simplify (calls new provider methods)
- `gps_tracker/lib/features/shifts/widgets/shift_status_card.dart` — Detect lunch from shift state
- `gps_tracker/lib/features/shifts/widgets/shift_timer.dart` — Derive lunch from shift gaps
- `gps_tracker/lib/features/shifts/widgets/shift_summary_card.dart` — Work body duration
- `gps_tracker/lib/features/shifts/widgets/shift_card.dart` — Use lunchDurationForWorkBodyProvider
- `gps_tracker/lib/features/shifts/screens/shift_detail_screen.dart` — Remove lunch_break imports, use work body duration
- `gps_tracker/lib/features/shifts/models/day_approval.dart` — Keep 'lunch' activity type (still from RPC)
- `gps_tracker/lib/features/work_sessions/widgets/work_session_history_list.dart` — Remove lunch break tiles
- `gps_tracker/lib/features/work_sessions/widgets/active_work_session_card.dart` — Remove lunch card

### Flutter (no change needed)
- `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart` — Imports lunch_break_button (still used)
- `gps_tracker/lib/features/tracking/providers/tracking_provider.dart` — pauseForLunch() unchanged
- `gps_tracker/lib/features/shifts/widgets/activity_timeline.dart` — No current lunch references

### Flutter (delete)
- `gps_tracker/lib/features/shifts/models/lunch_break.dart` — No longer needed

### Dashboard (modify)
- `dashboard/src/types/mileage.ts` — Add work_body_id to shift types, keep lunch_minutes derived
- `dashboard/src/types/monitoring.ts` — Keep isOnLunch (now derived from shifts)
- `dashboard/src/components/approvals/approval-utils.ts` — Replace `nestLunchActivities` with shift-gap lunch detection
- `dashboard/src/components/approvals/day-approval-detail.tsx` — Update lunch summary, shift grouping
- `dashboard/src/components/approvals/approval-rows.tsx` — Update LunchGroupRow for shift-gap model
- `dashboard/src/components/approvals/approval-grid.tsx` — lunch_minutes now from RPC (no change needed)
- `dashboard/src/lib/utils/merge-clock-events.ts` — Remove 'lunch' from MergeableActivity
- `dashboard/src/lib/hooks/use-monitoring-badges.ts` — Change realtime subscription from lunch_breaks to shifts
- `dashboard/src/components/monitoring/team-list.tsx` — No code change (data comes from RPC)

---

## Chunk 1: Database Schema & Retroactive Migration

### Task 1: Add work_body_id column to shifts

**Files:**
- Create: `supabase/migrations/20260316000001_add_work_body_id_to_shifts.sql`

- [ ] **Step 1: Write migration SQL**

```sql
-- =============================================================================
-- Add work_body_id to shifts for grouping shift segments in a work body.
-- Each shift gets a work_body_id. Shifts sharing a work_body_id are segments
-- of the same continuous work period (split by lunch breaks).
-- =============================================================================

-- Add column with default so existing rows get unique UUIDs
ALTER TABLE shifts ADD COLUMN work_body_id UUID DEFAULT gen_random_uuid();

-- Backfill: ensure all existing rows have a value (DEFAULT handles this on ADD)
-- Make NOT NULL after backfill
ALTER TABLE shifts ALTER COLUMN work_body_id SET NOT NULL;

-- Index for grouping queries
CREATE INDEX idx_shifts_work_body_id ON shifts (work_body_id);

-- Composite index for the common query: "all segments for this employee's work body"
CREATE INDEX idx_shifts_employee_work_body ON shifts (employee_id, work_body_id, clocked_in_at);

-- Update table comment
COMMENT ON TABLE shifts IS '
ROLE: Tracks employee clock-in/clock-out periods. A "work body" groups shift segments split by lunch breaks.
STATUTS: status = active (clocked in) | completed (clocked out)
REGLES: work_body_id groups segments of the same continuous work day. clock_out_reason = lunch means employee went on lunch break. Lunch duration = gap between consecutive segments sharing a work_body_id.
RELATIONS: -> employee_profiles (N:1) | <- gps_points (1:N) | <- stationary_clusters (1:N) | <- trips (1:N) | <- gps_gaps (1:N) | <- work_sessions (1:N) | <- cleaning_sessions (1:N) | <- maintenance_sessions (1:N) | <- shift_time_edits (1:N)
TRIGGERS: trg_set_shift_type (BEFORE INSERT auto-classifies regular/call by Montreal hour). trg_auto_close_sessions_on_shift_complete (AFTER UPDATE closes cleaning/maintenance on shift complete, skipped for lunch).
';

COMMENT ON COLUMN shifts.work_body_id IS 'Groups shift segments in the same continuous work body. First segment generates the UUID; post-lunch segments inherit it. Separate callbacks/rappels get different work_body_ids.';
COMMENT ON COLUMN shifts.clock_out_reason IS 'Why shift was closed. Values: manual | lunch | auto_zombie_cleanup | midnight_auto_cleanup | admin_cleanup | no_gps_auto_close | midnight_auto_close | server_reconciliation | auto_clock_in_cleanup | manual_admin_cleanup | admin_manual_close. lunch = employee started a lunch break (shift resumes with same work_body_id).';
```

- [ ] **Step 2: Apply migration**

```bash
cd /Users/cedric/Desktop/Desktop\ -\ Cedric\'s\ MacBook\ Pro\ -\ 1/PROJECT/TEST/GPS_Tracker
supabase db push --linked
```

- [ ] **Step 3: Verify column exists**

```sql
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_name = 'shifts' AND column_name = 'work_body_id';
-- Expected: work_body_id | uuid | NO | gen_random_uuid()
```

- [ ] **Step 4: Verify all rows have work_body_id**

```sql
SELECT COUNT(*) AS total, COUNT(work_body_id) AS with_wbid FROM shifts;
-- Expected: both counts equal (~581+)
```

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260316000001_add_work_body_id_to_shifts.sql
git commit -m "feat(db): add work_body_id column to shifts for lunch-as-shift-split"
```

---

### Task 2: Retroactive data migration — convert lunch breaks to shift splits

**Files:**
- Create: `supabase/migrations/20260316000002_retroactive_lunch_to_shift_split.sql`

**Context:** 56 lunch breaks exist (54 completed, 2 open). Edge cases:
- Jessy Mainville: open lunch on completed shift → close lunch at shift.clocked_out_at first
- Fatima Zahra Rechka: open lunch on active shift → skip (handled by new app logic)
- Kouma Baraka, Irene Pepin: 2+ lunch breaks per shift → iterative split (N+1 segments)

- [ ] **Step 1: Write migration SQL**

```sql
-- =============================================================================
-- Retroactive migration: Convert lunch_breaks into shift splits.
-- For each completed lunch break:
--   1. Close pre-lunch shift segment at lunch.started_at with clock_out_reason='lunch'
--   2. Create post-lunch shift segment from lunch.ended_at to original clocked_out_at
--   3. Both segments share the same work_body_id
--   4. Redistribute child records between segments by timestamp
-- =============================================================================

DO $$
DECLARE
    v_shift RECORD;
    v_lunch RECORD;
    v_lunches RECORD[];
    v_lunch_arr RECORD;
    v_new_shift_id UUID;
    v_prev_segment_id UUID;
    v_original_clocked_out_at TIMESTAMPTZ;
    v_original_clock_out_reason TEXT;
    v_original_clock_out_location JSONB;
    v_original_clock_out_accuracy DECIMAL;
    v_original_clock_out_cluster_id UUID := NULL;
    v_original_clock_out_location_id UUID := NULL;
    v_work_body_id UUID;
    v_segment_start TIMESTAMPTZ;
    v_count INTEGER := 0;
BEGIN
    -- =========================================================================
    -- Step 0: Close orphan open lunches on completed shifts
    -- (Jessy Mainville case: lunch open, shift completed)
    -- =========================================================================
    UPDATE lunch_breaks lb
    SET ended_at = s.clocked_out_at
    FROM shifts s
    WHERE lb.shift_id = s.id
      AND lb.ended_at IS NULL
      AND s.status = 'completed'
      AND s.clocked_out_at IS NOT NULL;

    -- =========================================================================
    -- Step 1: Process each shift that has completed lunch breaks
    -- =========================================================================
    FOR v_shift IN
        SELECT DISTINCT s.id AS shift_id, s.work_body_id, s.employee_id,
               s.clocked_out_at, s.clock_out_reason,
               s.clock_out_location, s.clock_out_accuracy,
               s.clock_out_cluster_id, s.clock_out_location_id,
               s.shift_type, s.shift_type_source, s.app_version,
               s.clocked_in_at,
               s.status
        FROM shifts s
        JOIN lunch_breaks lb ON lb.shift_id = s.id
        WHERE lb.ended_at IS NOT NULL
        ORDER BY s.clocked_in_at
    LOOP
        -- Save original clock-out metadata (all columns)
        v_original_clocked_out_at := v_shift.clocked_out_at;
        v_original_clock_out_reason := v_shift.clock_out_reason;
        v_original_clock_out_location := v_shift.clock_out_location;
        v_original_clock_out_accuracy := v_shift.clock_out_accuracy;
        v_original_clock_out_cluster_id := v_shift.clock_out_cluster_id;
        v_original_clock_out_location_id := v_shift.clock_out_location_id;
        v_work_body_id := v_shift.work_body_id;
        v_prev_segment_id := v_shift.shift_id;
        v_segment_start := v_shift.clocked_in_at;

        -- Get all completed lunches for this shift, ordered by start time
        FOR v_lunch IN
            SELECT lb.id, lb.started_at, lb.ended_at
            FROM lunch_breaks lb
            WHERE lb.shift_id = v_shift.shift_id
              AND lb.ended_at IS NOT NULL
            ORDER BY lb.started_at ASC
        LOOP
            -- Close the current segment at lunch start
            UPDATE shifts
            SET clocked_out_at = v_lunch.started_at,
                clock_out_reason = 'lunch',
                clock_out_location = NULL,
                clock_out_accuracy = NULL,
                status = 'completed'
            WHERE id = v_prev_segment_id;

            -- Create post-lunch segment
            v_new_shift_id := gen_random_uuid();

            INSERT INTO shifts (
                id, employee_id, work_body_id, status,
                clocked_in_at, clocked_out_at,
                clock_out_reason,
                clock_out_location, clock_out_accuracy,
                shift_type, shift_type_source, app_version,
                created_at, updated_at
            ) VALUES (
                v_new_shift_id,
                v_shift.employee_id,
                v_work_body_id,
                v_shift.status,  -- preserve active/completed
                v_lunch.ended_at,
                NULL,  -- will be set below or by next lunch iteration
                NULL,
                NULL, NULL,
                v_shift.shift_type,
                v_shift.shift_type_source,
                v_shift.app_version,
                NOW(), NOW()
            );

            -- Redistribute child records: move post-lunch records to new segment
            -- GPS points: by captured_at
            UPDATE gps_points
            SET shift_id = v_new_shift_id
            WHERE shift_id = v_prev_segment_id
              AND captured_at >= v_lunch.ended_at;

            -- Stationary clusters: by started_at
            UPDATE stationary_clusters
            SET shift_id = v_new_shift_id
            WHERE shift_id = v_prev_segment_id
              AND started_at >= v_lunch.ended_at;

            -- Trips: by started_at
            UPDATE trips
            SET shift_id = v_new_shift_id
            WHERE shift_id = v_prev_segment_id
              AND started_at >= v_lunch.ended_at;

            -- GPS gaps: by started_at
            UPDATE gps_gaps
            SET shift_id = v_new_shift_id
            WHERE shift_id = v_prev_segment_id
              AND started_at >= v_lunch.ended_at;

            -- Work sessions: by started_at
            UPDATE work_sessions
            SET shift_id = v_new_shift_id
            WHERE shift_id = v_prev_segment_id
              AND started_at >= v_lunch.ended_at;

            -- Cleaning sessions: by started_at
            UPDATE cleaning_sessions
            SET shift_id = v_new_shift_id
            WHERE shift_id = v_prev_segment_id
              AND started_at >= v_lunch.ended_at;

            -- Maintenance sessions: by started_at
            UPDATE maintenance_sessions
            SET shift_id = v_new_shift_id
            WHERE shift_id = v_prev_segment_id
              AND started_at >= v_lunch.ended_at;

            -- shift_time_edits: remain on original shift (reference pre-split shift)
            -- No action needed

            v_prev_segment_id := v_new_shift_id;
            v_count := v_count + 1;
        END LOOP;

        -- Set final segment's clock-out to the original shift's clock-out
        -- Note: if shift is active (Fatima case), v_original_clocked_out_at is NULL
        -- and this block is safely skipped — the final segment stays active.
        IF v_original_clocked_out_at IS NOT NULL THEN
            UPDATE shifts
            SET clocked_out_at = v_original_clocked_out_at,
                clock_out_reason = v_original_clock_out_reason,
                clock_out_location = v_original_clock_out_location,
                clock_out_accuracy = v_original_clock_out_accuracy,
                clock_out_cluster_id = v_original_clock_out_cluster_id,
                clock_out_location_id = v_original_clock_out_location_id,
                status = 'completed'
            WHERE id = v_prev_segment_id;
        END IF;
    END LOOP;

    RAISE NOTICE 'Migrated % lunch breaks into shift splits', v_count;
END;
$$;
```

- [ ] **Step 2: Apply migration**

```bash
supabase db push --linked
```

- [ ] **Step 3: Verify migration results**

```sql
-- Check that shifts with lunch splits share work_body_ids
SELECT work_body_id, COUNT(*) AS segment_count,
       array_agg(id ORDER BY clocked_in_at) AS segment_ids,
       array_agg(clock_out_reason ORDER BY clocked_in_at) AS reasons
FROM shifts
WHERE work_body_id IN (
    SELECT work_body_id FROM shifts GROUP BY work_body_id HAVING COUNT(*) > 1
)
GROUP BY work_body_id
ORDER BY MIN(clocked_in_at) DESC;
-- Expected: ~54 work bodies with 2+ segments, first segment has clock_out_reason='lunch'
```

```sql
-- Verify child record redistribution
SELECT s.id, s.clocked_in_at, s.clocked_out_at, s.clock_out_reason,
       (SELECT COUNT(*) FROM gps_points gp WHERE gp.shift_id = s.id) AS gps_count,
       (SELECT COUNT(*) FROM stationary_clusters sc WHERE sc.shift_id = s.id) AS cluster_count,
       (SELECT COUNT(*) FROM trips t WHERE t.shift_id = s.id) AS trip_count
FROM shifts s
WHERE s.work_body_id IN (
    SELECT work_body_id FROM shifts GROUP BY work_body_id HAVING COUNT(*) > 1
)
ORDER BY s.work_body_id, s.clocked_in_at
LIMIT 20;
-- Expected: child records distributed between pre/post lunch segments
```

```sql
-- Verify no child records have timestamps outside their shift's time window
SELECT 'gps_points' AS table_name, COUNT(*) AS orphans
FROM gps_points gp
JOIN shifts s ON s.id = gp.shift_id
WHERE s.clocked_out_at IS NOT NULL
  AND (gp.captured_at < s.clocked_in_at - INTERVAL '1 minute'
       OR gp.captured_at > s.clocked_out_at + INTERVAL '1 minute')
UNION ALL
SELECT 'stationary_clusters', COUNT(*)
FROM stationary_clusters sc
JOIN shifts s ON s.id = sc.shift_id
WHERE s.clocked_out_at IS NOT NULL
  AND sc.started_at < s.clocked_in_at - INTERVAL '1 minute';
-- Expected: 0 orphans (or very few edge cases)
```

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260316000002_retroactive_lunch_to_shift_split.sql
git commit -m "feat(db): retroactive migration converting 56 lunch breaks to shift splits"
```

---

### Task 3: Update triggers

**Files:**
- Create: `supabase/migrations/20260316000003_update_triggers_for_lunch_shifts.sql`

Two triggers need adaptation:
1. `set_shift_type_on_insert` — inherit shift_type from existing work body segments
2. `auto_close_sessions_on_shift_complete` — skip when clock_out_reason='lunch'

- [ ] **Step 1: Write trigger migration**

```sql
-- =============================================================================
-- Update triggers for lunch-as-shift-split model
-- =============================================================================

-- =========================================================================
-- 1. set_shift_type_on_insert: If work_body_id already exists, inherit type
-- =========================================================================
CREATE OR REPLACE FUNCTION set_shift_type_on_insert()
RETURNS TRIGGER AS $$
DECLARE
    v_existing RECORD;
    local_hour INTEGER;
BEGIN
    -- Check if this work_body_id already has a shift (post-lunch segment)
    SELECT shift_type, shift_type_source
    INTO v_existing
    FROM shifts
    WHERE work_body_id = NEW.work_body_id
      AND id != NEW.id
    ORDER BY clocked_in_at ASC
    LIMIT 1;

    IF FOUND THEN
        -- Inherit from the first segment of the same work body
        NEW.shift_type := v_existing.shift_type;
        NEW.shift_type_source := v_existing.shift_type_source;
    ELSE
        -- First segment: auto-classify by Montreal hour
        local_hour := EXTRACT(HOUR FROM NEW.clocked_in_at AT TIME ZONE 'America/Montreal');
        IF local_hour >= 17 OR local_hour < 5 THEN
            NEW.shift_type := 'call';
            NEW.shift_type_source := 'auto';
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =========================================================================
-- 2. auto_close_sessions_on_shift_complete: Skip for lunch clock-outs
-- =========================================================================
CREATE OR REPLACE FUNCTION auto_close_sessions_on_shift_complete()
RETURNS TRIGGER AS $$
DECLARE
    v_session RECORD;
    v_duration NUMERIC;
    v_flags RECORD;
BEGIN
    -- Only fire when shift transitions TO completed
    IF NEW.status = 'completed' AND (OLD.status IS DISTINCT FROM 'completed') THEN

        -- SKIP auto-close when clocking out for lunch — employee is coming back
        IF NEW.clock_out_reason = 'lunch' THEN
            RETURN NEW;
        END IF;

        -- Auto-close cleaning sessions
        FOR v_session IN
            SELECT cs.id, cs.started_at, s.studio_type
            FROM cleaning_sessions cs
            JOIN studios s ON cs.studio_id = s.id
            WHERE cs.shift_id = NEW.id
              AND cs.employee_id = NEW.employee_id
              AND cs.status = 'in_progress'
        LOOP
            v_duration := EXTRACT(EPOCH FROM (COALESCE(NEW.clocked_out_at, NOW()) - v_session.started_at)) / 60.0;
            SELECT * INTO v_flags FROM _compute_cleaning_flags(v_session.studio_type, v_duration);

            UPDATE cleaning_sessions
            SET status = 'auto_closed',
                completed_at = COALESCE(NEW.clocked_out_at, NOW()),
                duration_minutes = ROUND(v_duration, 2),
                is_flagged = v_flags.is_flagged,
                flag_reason = v_flags.flag_reason,
                updated_at = NOW()
            WHERE id = v_session.id;
        END LOOP;

        -- Auto-close maintenance sessions
        UPDATE maintenance_sessions
        SET status = 'auto_closed',
            completed_at = COALESCE(NEW.clocked_out_at, NOW()),
            duration_minutes = ROUND(EXTRACT(EPOCH FROM (COALESCE(NEW.clocked_out_at, NOW()) - started_at)) / 60.0, 2),
            updated_at = NOW()
        WHERE shift_id = NEW.id
          AND employee_id = NEW.employee_id
          AND status = 'in_progress';

    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

- [ ] **Step 2: Apply migration**

```bash
supabase db push --linked
```

- [ ] **Step 3: Verify triggers**

```sql
-- Verify trigger functions exist with updated logic
SELECT prosrc FROM pg_proc WHERE proname = 'set_shift_type_on_insert';
-- Expected: contains 'work_body_id' check

SELECT prosrc FROM pg_proc WHERE proname = 'auto_close_sessions_on_shift_complete';
-- Expected: contains 'lunch' early return
```

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260316000003_update_triggers_for_lunch_shifts.sql
git commit -m "feat(db): update triggers to handle lunch-as-shift-split"
```

---

## Chunk 2: Database RPC Rewrites

### Task 4: Rewrite `_get_day_approval_detail_base` / `get_day_approval_detail`

**Files:**
- Create: `supabase/migrations/20260316000004_rewrite_rpcs_shift_lunch.sql`
- Reference: `supabase/migrations/20260312500003_approval_detail_time_corrections.sql` (current version, ~910 lines)

**What changes:**
- Replace `v_lunch_minutes` calculation from `lunch_breaks` → derive from shift gaps
- Replace `lunch_data` CTE (lines 544-581) → derive lunch activities from shift gaps where `clock_out_reason = 'lunch'`
- Replace `lunch_adj` lateral join (lines 376-384) → use shift gap detection for trip lunch adjacency
- Replace lunch in gap coverage (lines 746-752) → use shift gap periods
- Keep the `'lunch'` activity type in output (for dashboard compatibility)

The lunch derivation pattern used throughout (using LEAD() window function for performance):

```sql
-- CTE: Derive lunch periods from shift gaps
shift_with_next AS (
    SELECT id, employee_id, work_body_id, clocked_in_at, clocked_out_at,
           clock_out_reason, shift_id AS pre_lunch_shift_id,
           LEAD(id) OVER (PARTITION BY work_body_id ORDER BY clocked_in_at) AS post_lunch_shift_id,
           LEAD(clocked_in_at) OVER (PARTITION BY work_body_id ORDER BY clocked_in_at) AS next_clock_in
    FROM shifts
    WHERE status = 'completed' OR status = 'active'
),
lunch_periods AS (
    SELECT
        employee_id,
        id AS pre_lunch_shift_id,
        post_lunch_shift_id,
        work_body_id,
        clocked_out_at AS lunch_started_at,
        next_clock_in AS lunch_ended_at,
        EXTRACT(EPOCH FROM (next_clock_in - clocked_out_at))::INTEGER / 60 AS lunch_minutes
    FROM shift_with_next
    WHERE clock_out_reason = 'lunch'
      AND next_clock_in IS NOT NULL
)
```

- [ ] **Step 1: Write the full RPC rewrite migration**

This migration rewrites 5 RPCs. The file will be large (~800+ lines). Key changes per function:

**`get_day_approval_detail`:**
- Replace `FROM lunch_breaks lb` with `FROM lunch_periods` CTE (shift gaps)
- Lunch activity: `activity_id = s_pre.id || '-lunch'`, `shift_id = s_pre.id`, `started_at = lunch_started_at`, `ended_at = lunch_ended_at`
- Trip lunch adjacency: `LEFT JOIN LATERAL (SELECT lp.pre_lunch_shift_id FROM lunch_periods lp WHERE lp.employee_id = t.employee_id AND t.started_at < lp.lunch_ended_at + INTERVAL '2 minutes' AND t.ended_at > lp.lunch_started_at - INTERVAL '2 minutes' LIMIT 1) lunch_adj ON TRUE`
- Gap coverage: use `lunch_periods` instead of `lunch_breaks`

**`get_weekly_approval_summary`:**
- Replace `day_lunch` CTE using LEAD() pattern:
  ```sql
  day_lunch AS (
      SELECT employee_id,
             to_business_date(clocked_out_at) AS lunch_date,
             COALESCE(SUM(EXTRACT(EPOCH FROM (next_clock_in - clocked_out_at))::INTEGER / 60), 0) AS lunch_minutes
      FROM (
          SELECT employee_id, work_body_id, clocked_out_at, clock_out_reason,
                 LEAD(clocked_in_at) OVER (PARTITION BY work_body_id ORDER BY clocked_in_at) AS next_clock_in
          FROM shifts
          WHERE employee_id IN (SELECT employee_id FROM employee_list)
            AND to_business_date(clocked_in_at) BETWEEN p_week_start AND v_week_end
      ) s
      WHERE clock_out_reason = 'lunch' AND next_clock_in IS NOT NULL
      GROUP BY employee_id, to_business_date(clocked_out_at)
  )
  ```

**`get_weekly_breakdown_totals`:**
- Replace `lunch_adj` lateral join for trip classification (lines 550-556) with shift-gap-based detection

**`get_monitored_team`:**
- Replace `active_lunch` lateral join — detect "on lunch" from shift state:
  ```sql
  -- OLD: FROM lunch_breaks lb WHERE lb.shift_id = s.id AND lb.ended_at IS NULL
  -- NEW: Employee's most recent completed shift has clock_out_reason='lunch'
  --       with no subsequent segment in the same work_body_id
  LEFT JOIN LATERAL (
      SELECT s_lunch.id, s_lunch.clocked_out_at AS started_at
      FROM shifts s_lunch
      WHERE s_lunch.employee_id = ep.id
        AND s_lunch.clock_out_reason = 'lunch'
        AND s_lunch.status = 'completed'
        AND NOT EXISTS (
            SELECT 1 FROM shifts s_next
            WHERE s_next.work_body_id = s_lunch.work_body_id
              AND s_next.clocked_in_at > s_lunch.clocked_out_at
        )
      ORDER BY s_lunch.clocked_out_at DESC
      LIMIT 1
  ) active_lunch ON TRUE
  ```
  Note: NOT EXISTS is appropriate here since this is per-employee (not a bulk CTE over all shifts).

**`server_close_all_sessions`:**
- Remove the `UPDATE lunch_breaks SET ended_at = now() WHERE ended_at IS NULL` block
- Remove `v_lunch_closed` variable and output
- Add: if employee has a completed shift with `clock_out_reason = 'lunch'` and no next segment (employee is "on lunch"), create a minimal completed post-lunch segment to close the work body:
  ```sql
  INSERT INTO shifts (employee_id, work_body_id, status, clocked_in_at, clocked_out_at, clock_out_reason, shift_type, shift_type_source)
  SELECT s.employee_id, s.work_body_id, 'completed', now(), now(), 'server_reconciliation', s.shift_type, s.shift_type_source
  FROM shifts s
  WHERE s.employee_id = p_employee_id
    AND s.clock_out_reason = 'lunch'
    AND s.status = 'completed'
    AND NOT EXISTS (SELECT 1 FROM shifts s2 WHERE s2.work_body_id = s.work_body_id AND s2.clocked_in_at > s.clocked_out_at);
  ```

**`save_activity_override` and `remove_activity_override`:**
- These RPCs do NOT reference `lunch_breaks` table directly — no SQL changes needed.
- However, the `activity_overrides` CHECK constraint currently includes `'lunch_start'` and `'lunch_end'` types (from migration 132 era). These types will no longer be generated. Clean up the CHECK constraint to remove them while keeping `'lunch'`:
  ```sql
  ALTER TABLE activity_overrides DROP CONSTRAINT IF EXISTS activity_overrides_activity_type_check;
  ALTER TABLE activity_overrides ADD CONSTRAINT activity_overrides_activity_type_check
      CHECK (activity_type IN ('trip', 'stop', 'clock_in', 'clock_out', 'gap', 'lunch', 'stop_segment'));
  ```

Write the full migration file with all 5 function rewrites + CHECK constraint cleanup. Due to the size, this step involves writing a complete SQL migration file.

**IMPORTANT:** Read the latest version of each RPC from these source files before rewriting:
- `_get_day_approval_detail_base` / `get_day_approval_detail`: `supabase/migrations/20260312500003_approval_detail_time_corrections.sql`
- `get_weekly_approval_summary`: `supabase/migrations/20260312500005_weekly_rpcs_time_corrections.sql` (lines 1-425)
- `get_weekly_breakdown_totals`: `supabase/migrations/20260312500005_weekly_rpcs_time_corrections.sql` (lines 428-586)
- `get_monitored_team`: `supabase/migrations/20260312100000_monitoring_clock_in_location_name.sql`
- `server_close_all_sessions`: `supabase/migrations/20260310040000_server_close_all_sessions.sql`

For each function, copy the ENTIRE current function, then make ONLY the lunch-related changes. Do NOT change any non-lunch logic. This prevents regressions.

- [ ] **Step 2: Apply migration**

```bash
supabase db push --linked
```

- [ ] **Step 3: Verify RPCs return correct lunch data**

```sql
-- Test day approval detail — pick a day with known lunch break
SELECT jsonb_pretty(get_day_approval_detail(
    '<employee_id_with_lunch>',
    '<date_with_lunch>'::DATE
));
-- Expected: activities array includes activity_type='lunch', summary has lunch_minutes > 0
```

```sql
-- Test weekly summary
SELECT jsonb_pretty(get_weekly_approval_summary('<monday_date>'::DATE));
-- Expected: each day entry has lunch_minutes matching the shift gap duration
```

```sql
-- Test monitoring — check is_on_lunch detection
SELECT full_name, is_on_lunch, lunch_started_at
FROM get_monitored_team()
WHERE is_on_lunch = TRUE;
-- Expected: only employees currently between lunch shift segments
```

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260316000004_rewrite_rpcs_shift_lunch.sql
git commit -m "feat(db): rewrite 5 RPCs to derive lunch from shift gaps instead of lunch_breaks"
```

---

### Task 5: Drop lunch_breaks table (DEFERRED)

**Files:**
- Create: `supabase/migrations/20260316000005_drop_lunch_breaks_table.sql`

**IMPORTANT:** This migration should only be applied AFTER the Flutter app is updated and deployed (Phase 2). Old app versions still INSERT into `lunch_breaks`. Apply this migration as a separate step after confirming all users have updated.

- [ ] **Step 1: Write migration SQL**

```sql
-- =============================================================================
-- Drop lunch_breaks table — ONLY APPLY AFTER Flutter app v2.x is deployed
-- and all users have updated. Old app versions write to this table.
-- =============================================================================

-- Drop realtime publication (if enabled)
ALTER PUBLICATION supabase_realtime DROP TABLE IF EXISTS lunch_breaks;

-- Drop RLS policies
DROP POLICY IF EXISTS "Employees can view own lunch breaks" ON lunch_breaks;
DROP POLICY IF EXISTS "Employees can insert own lunch breaks" ON lunch_breaks;
DROP POLICY IF EXISTS "Employees can update own lunch breaks" ON lunch_breaks;
DROP POLICY IF EXISTS "Supervisors can view employee lunch breaks" ON lunch_breaks;
DROP POLICY IF EXISTS "Admins full access to lunch breaks" ON lunch_breaks;

-- Drop indexes
DROP INDEX IF EXISTS idx_lunch_breaks_shift_id;
DROP INDEX IF EXISTS idx_lunch_breaks_employee_date;

-- Drop table
DROP TABLE IF EXISTS lunch_breaks;
```

- [ ] **Step 2: Commit (DO NOT APPLY YET)**

```bash
git add supabase/migrations/20260316000005_drop_lunch_breaks_table.sql
git commit -m "feat(db): migration to drop lunch_breaks table (apply after Flutter update)"
```

---

## Chunk 3: Flutter App Changes

### Task 6: Update local_database.dart — schema changes

**Files:**
- Modify: `gps_tracker/lib/shared/services/local_database.dart`

- [ ] **Step 1: Add work_body_id to local_shifts table**

In the `CREATE TABLE IF NOT EXISTS local_shifts` statement, add:
```sql
work_body_id TEXT,
clock_out_reason TEXT,
```

Add a migration in the `_onUpgrade` method to add these columns to existing databases:
```dart
if (oldVersion < <next_version>) {
  await db.execute('ALTER TABLE local_shifts ADD COLUMN work_body_id TEXT');
  await db.execute('ALTER TABLE local_shifts ADD COLUMN clock_out_reason TEXT');
}
```

- [ ] **Step 2: Remove local_lunch_breaks table**

Remove the `CREATE TABLE IF NOT EXISTS local_lunch_breaks` statement (lines ~421-443).

Remove all 6 lunch break CRUD methods:
- `insertLunchBreak()` (~lines 1887-1901)
- `endLunchBreak()` (~lines 1904-1911)
- `getActiveLunchBreak()` (~lines 1914-1922)
- `getPendingLunchBreaks()` (~lines 1925-1931)
- `markLunchBreakSynced()` (~lines 1934-1941)
- `getLunchBreaksForShift()` (~lines 1944-1951)

Add a migration to drop the old table:
```dart
if (oldVersion < <next_version>) {
  await db.execute('DROP TABLE IF EXISTS local_lunch_breaks');
}
```

- [ ] **Step 3: Add helper methods for lunch detection from shifts**

```dart
/// Get the active lunch state: the employee has a completed shift with
/// clock_out_reason='lunch' and no subsequent active shift in the same work_body_id.
Future<Map<String, dynamic>?> getActiveLunchShift(String employeeId) async {
  final db = await database;
  final result = await db.rawQuery('''
    SELECT s1.id, s1.work_body_id, s1.clocked_out_at AS lunch_started_at
    FROM local_shifts s1
    WHERE s1.employee_id = ?
      AND s1.clock_out_reason = 'lunch'
      AND s1.status = 'completed'
      AND NOT EXISTS (
        SELECT 1 FROM local_shifts s2
        WHERE s2.work_body_id = s1.work_body_id
          AND s2.clocked_in_at > s1.clocked_out_at
      )
    ORDER BY s1.clocked_out_at DESC
    LIMIT 1
  ''', [employeeId]);
  return result.isNotEmpty ? result.first : null;
}

/// Get total lunch duration for a work body (sum of gaps between segments)
Future<Duration> getLunchDurationForWorkBody(String workBodyId) async {
  final db = await database;
  final result = await db.rawQuery('''
    SELECT s1.clocked_out_at, s2.clocked_in_at
    FROM local_shifts s1
    JOIN local_shifts s2 ON s2.work_body_id = s1.work_body_id
      AND s2.clocked_in_at > s1.clocked_out_at
    WHERE s1.work_body_id = ?
      AND s1.clock_out_reason = 'lunch'
    ORDER BY s1.clocked_out_at
  ''', [workBodyId]);

  var total = Duration.zero;
  for (final row in result) {
    final start = DateTime.parse(row['clocked_out_at'] as String);
    final end = DateTime.parse(row['clocked_in_at'] as String);
    total += end.difference(start);
  }
  return total;
}
```

- [ ] **Step 4: Build and verify**

```bash
cd gps_tracker && flutter analyze
```

- [ ] **Step 5: Commit**

```bash
git add gps_tracker/lib/shared/services/local_database.dart
git commit -m "feat(flutter): update local DB schema for lunch-as-shift-split"
```

---

### Task 7: Rewrite lunch_break_provider.dart

**Files:**
- Modify: `gps_tracker/lib/features/shifts/providers/lunch_break_provider.dart`

The provider's interface stays the same (startLunchBreak/endLunchBreak) but the implementation changes completely.

- [ ] **Step 1: Rewrite LunchBreakState**

Replace the state class to track lunch via shift state rather than a LunchBreak model:

```dart
@immutable
class LunchBreakState {
  final bool isOnLunch;
  final DateTime? lunchStartedAt;  // = clocked_out_at of the lunch-closed shift
  final String? workBodyId;        // to resume with same work_body_id
  final bool isStarting;
  final bool isEnding;
  final String? error;

  const LunchBreakState({
    this.isOnLunch = false,
    this.lunchStartedAt,
    this.workBodyId,
    this.isStarting = false,
    this.isEnding = false,
    this.error,
  });
}
```

- [ ] **Step 2: Rewrite startLunchBreak()**

```dart
Future<void> startLunchBreak() async {
  state = state.copyWith(isStarting: true, error: null);
  try {
    final shiftState = _ref.read(shiftProvider);
    final activeShift = shiftState.activeShift;
    if (activeShift == null) throw Exception('No active shift');

    final now = DateTime.now().toUtc();
    final workBodyId = activeShift.workBodyId;

    // 1. Close the active shift with clock_out_reason='lunch'
    await _ref.read(shiftProvider.notifier).clockOutForLunch(now);

    // 2. Pause GPS tracking
    await _ref.read(trackingProvider.notifier).pauseForLunch();

    // 3. Update state
    state = LunchBreakState(
      isOnLunch: true,
      lunchStartedAt: now,
      workBodyId: workBodyId,
    );

    // 4. Update Live Activity
    await _updateLiveActivity(isOnLunch: true, lunchStartedAt: now);

    // 5. Trigger sync
    await _ref.read(syncServiceProvider).syncAll();
  } catch (e) {
    state = state.copyWith(isStarting: false, error: e.toString());
  }
}
```

- [ ] **Step 3: Rewrite endLunchBreak()**

```dart
Future<void> endLunchBreak() async {
  state = state.copyWith(isEnding: true, error: null);
  try {
    final workBodyId = state.workBodyId;
    if (workBodyId == null) throw Exception('No work body ID for lunch');

    // 1. Create a new shift with the same work_body_id
    await _ref.read(shiftProvider.notifier).clockInFromLunch(workBodyId);

    // 2. Resume GPS tracking
    await _ref.read(trackingProvider.notifier).ensureGpsAlive();

    // 3. Clear lunch state
    state = const LunchBreakState();

    // 4. Update Live Activity
    await _updateLiveActivity(isOnLunch: false);

    // 5. Trigger sync
    await _ref.read(syncServiceProvider).syncAll();
  } catch (e) {
    state = state.copyWith(isEnding: false, error: e.toString());
  }
}
```

- [ ] **Step 4: Rewrite _init() for state restoration**

```dart
Future<void> _init() async {
  // Check if employee is currently on lunch (shift closed with reason='lunch',
  // no subsequent segment in same work body)
  final employee = _ref.read(authProvider).employee;
  if (employee == null) return;

  final localDb = _ref.read(localDatabaseProvider);
  final lunchShift = await localDb.getActiveLunchShift(employee.id);

  if (lunchShift != null) {
    state = LunchBreakState(
      isOnLunch: true,
      lunchStartedAt: DateTime.parse(lunchShift['lunch_started_at'] as String),
      workBodyId: lunchShift['work_body_id'] as String,
    );
  }
}
```

- [ ] **Step 5: Remove providers that reference LunchBreak model**

Remove or update:
- `lunchBreaksForShiftProvider` — replace with `lunchDurationForWorkBodyProvider`
- `totalLunchDurationProvider` — replace to derive from shift gaps

```dart
final lunchDurationForWorkBodyProvider = FutureProvider.family<Duration, String>((ref, workBodyId) async {
  final localDb = ref.read(localDatabaseProvider);
  return localDb.getLunchDurationForWorkBody(workBodyId);
});
```

- [ ] **Step 6: Delete lunch_break.dart model**

```bash
rm gps_tracker/lib/features/shifts/models/lunch_break.dart
```

- [ ] **Step 7: Build and verify**

```bash
cd gps_tracker && flutter analyze
```

- [ ] **Step 8: Commit**

```bash
git add -u gps_tracker/lib/features/shifts/
git commit -m "feat(flutter): rewrite lunch_break_provider to close/open shifts"
```

---

### Task 8: Update shift_provider.dart

**Files:**
- Modify: `gps_tracker/lib/features/shifts/providers/shift_provider.dart`

- [ ] **Step 1: Add work_body_id to Shift model/local handling**

Ensure the Shift model includes `workBodyId` and `clockOutReason` fields. Update `fromMap`/`toMap` serialization.

- [ ] **Step 2: Add clockOutForLunch() method**

```dart
/// Close the active shift for lunch — sets clock_out_reason='lunch'
Future<void> clockOutForLunch(DateTime lunchStartAt) async {
  final activeShift = state.activeShift;
  if (activeShift == null) throw Exception('No active shift to close for lunch');

  // Close shift locally
  await _localDb.updateShift(activeShift.id, {
    'clocked_out_at': lunchStartAt.toIso8601String(),
    'clock_out_reason': 'lunch',
    'status': 'completed',
    'sync_status': 'pending',
  });

  state = state.copyWith(activeShift: null);
}
```

- [ ] **Step 3: Add clockInFromLunch() method**

```dart
/// Create a new shift segment resuming from lunch with the same work_body_id
Future<void> clockInFromLunch(String workBodyId) async {
  final employee = _ref.read(authProvider).employee;
  if (employee == null) throw Exception('No employee');

  final now = DateTime.now().toUtc();
  final newShiftId = const Uuid().v4();

  final newShift = Shift(
    id: newShiftId,
    employeeId: employee.id,
    workBodyId: workBodyId,  // inherit from pre-lunch segment
    status: 'active',
    clockedInAt: now,
    syncStatus: SyncStatus.pending,
  );

  await _localDb.insertShift(newShift.toMap());
  state = state.copyWith(activeShift: newShift);
}
```

- [ ] **Step 4: Remove auto-close lunch on shift end**

In the `clockOut()` method (~lines 310-320), remove the block that auto-closes lunch breaks:
```dart
// REMOVE THIS BLOCK:
// final lunchState = _ref.read(lunchBreakProvider);
// if (lunchState.isOnLunch) {
//   final lunchBreak = lunchState.activeLunchBreak!;
//   await localDb.endLunchBreak(lunchBreak.id, DateTime.now().toUtc());
//   _ref.read(lunchBreakProvider.notifier).clearOnShiftEnd();
// }
```

Instead, if the user clocks out while on lunch, just clear the lunch state:
```dart
// Clear lunch state if clocking out while on lunch
final lunchState = _ref.read(lunchBreakProvider);
if (lunchState.isOnLunch) {
  _ref.read(lunchBreakProvider.notifier).clearOnShiftEnd();
}
```

- [ ] **Step 5: Build and verify**

```bash
cd gps_tracker && flutter analyze
```

- [ ] **Step 6: Commit**

```bash
git add gps_tracker/lib/features/shifts/providers/shift_provider.dart
git commit -m "feat(flutter): add clockOutForLunch/clockInFromLunch to shift_provider"
```

---

### Task 9: Update sync_service.dart and remaining Flutter files

**Files:**
- Modify: `gps_tracker/lib/features/shifts/services/sync_service.dart`
- Modify: `gps_tracker/lib/features/shifts/widgets/lunch_break_button.dart`
- Modify: `gps_tracker/lib/features/shifts/widgets/shift_status_card.dart`
- Modify: `gps_tracker/lib/features/shifts/widgets/shift_timer.dart`
- Modify: `gps_tracker/lib/features/shifts/widgets/shift_summary_card.dart`
- Modify: `gps_tracker/lib/features/shifts/widgets/shift_card.dart`
- Modify: `gps_tracker/lib/features/shifts/screens/shift_detail_screen.dart`
- Modify: `gps_tracker/lib/features/work_sessions/widgets/work_session_history_list.dart`
- Modify: `gps_tracker/lib/features/work_sessions/widgets/active_work_session_card.dart`

- [ ] **Step 1: Remove _syncLunchBreaks from sync_service.dart**

Remove the `_syncLunchBreaks()` method (~lines 496-525) and its call in `syncAll()` (~line 167-168).

Ensure shifts sync includes `work_body_id` and `clock_out_reason` in the upsert payload.

- [ ] **Step 2: Update shift_status_card.dart**

Replace lunch detection from `lunchBreakProvider` / `lunchBreaksForShiftProvider` to use the new `lunchBreakProvider` (which now tracks lunch via shift state) and `lunchDurationForWorkBodyProvider`.

```dart
// OLD: watches lunchBreaksForShiftProvider(activeShift.id)
// NEW: watches lunchDurationForWorkBodyProvider(activeShift.workBodyId)
final lunchDuration = ref.watch(lunchDurationForWorkBodyProvider(activeShift.workBodyId));
final isOnLunch = ref.watch(isOnLunchProvider);
```

- [ ] **Step 3: Update shift_timer.dart**

Replace `_calculateTotalLunch()` to derive lunch from shift gaps:

```dart
Duration _calculateTotalLunch() {
  final lunchState = ref.read(lunchBreakProvider);
  final activeShift = ref.read(shiftProvider).activeShift;
  if (activeShift == null) return Duration.zero;

  // Get completed lunch duration from work body gaps
  final completedLunch = ref.read(lunchDurationForWorkBodyProvider(activeShift.workBodyId));
  var total = completedLunch.valueOrNull ?? Duration.zero;

  // Add active lunch time
  if (lunchState.isOnLunch && lunchState.lunchStartedAt != null) {
    total += DateTime.now().toUtc().difference(lunchState.lunchStartedAt!);
  }

  return total;
}
```

- [ ] **Step 4: Update shift_summary_card.dart**

Replace `totalLunchDurationProvider(shift.id)` with `lunchDurationForWorkBodyProvider(shift.workBodyId)`.

- [ ] **Step 4b: Update shift_card.dart**

Replace `totalLunchDurationProvider(shift.id)` with `lunchDurationForWorkBodyProvider(shift.workBodyId)`. The lunch display logic stays the same (show "Dîner" label with orange color if duration > 0).

- [ ] **Step 4c: Update shift_detail_screen.dart**

Remove import of `lunch_break_provider.dart` and `lunch_break.dart`. Replace any `lunchBreaksForShiftProvider(shiftId)` or `totalLunchDurationProvider(shiftId)` usage with `lunchDurationForWorkBodyProvider(shift.workBodyId)`.

- [ ] **Step 4d: Update lunch_break_button.dart**

The button still starts/ends lunch, but now calls the new provider methods. The import of `lunch_break.dart` must be removed. The button watches `lunchBreakProvider` (which is rewritten) — verify it reads `isOnLunch`, `isStarting`, `isEnding` from the new state class.

- [ ] **Step 5: Update work_session_history_list.dart**

Remove `_LunchBreakTile` widget and `_HistoryEntry.lunch()` variant. The timeline no longer shows lunch breaks as separate entries — lunch is just the gap between shift segments.

- [ ] **Step 6: Update active_work_session_card.dart**

Remove `_buildLunchCard()` method (~lines 240-374). The lunch state is now shown via the shift status card, not a separate work session card.

- [ ] **Step 7: Remove all imports of lunch_break.dart model**

Search for `import.*lunch_break.dart` across all Flutter files and remove those imports.

- [ ] **Step 8: Build and verify**

```bash
cd gps_tracker && flutter analyze
```

- [ ] **Step 9: Commit**

```bash
git add -u gps_tracker/
git commit -m "feat(flutter): remove lunch_breaks model/sync, update UI for shift-gap lunch"
```

---

## Chunk 4: Dashboard Changes

### Task 10: Update dashboard types

**Files:**
- Modify: `dashboard/src/types/mileage.ts`
- Modify: `dashboard/src/types/monitoring.ts`
- Modify: `dashboard/src/lib/utils/merge-clock-events.ts`

- [ ] **Step 1: Update mileage.ts types**

Add `work_body_id` to shift-related types. Keep `'lunch'` in `ApprovalActivity.activity_type` (the RPC still returns it). Keep `lunch_minutes` in summary types (still returned by RPC).

```typescript
// In the shift type or ApprovalActivity, add:
work_body_id?: string;
```

- [ ] **Step 2: Update monitoring.ts types**

No changes needed — `isOnLunch` and `lunchStartedAt` stay the same. The RPC now derives them from shifts instead of lunch_breaks, but the output format is identical.

- [ ] **Step 3: Update merge-clock-events.ts**

Keep `'lunch'` in `MergeableActivity` type — the RPC still emits lunch activities. No changes needed.

- [ ] **Step 4: Commit**

```bash
git add dashboard/src/types/ dashboard/src/lib/utils/merge-clock-events.ts
git commit -m "feat(dashboard): add work_body_id to types"
```

---

### Task 11: Update approval-utils.ts

**Files:**
- Modify: `dashboard/src/components/approvals/approval-utils.ts`

- [ ] **Step 1: Keep nestLunchActivities as-is**

The `nestLunchActivities()` function works with the `activity_type === 'lunch'` from the RPC response. Since the rewritten RPC still returns lunch activities (derived from shift gaps), this function continues to work without changes.

No changes needed to `approval-utils.ts`.

- [ ] **Step 2: Verify by reading the function**

Read `approval-utils.ts` and confirm that `nestLunchActivities` only checks `activity_type === 'lunch'` and time windows — it does NOT query the `lunch_breaks` table directly. The data comes from the RPC.

---

### Task 12: Update use-monitoring-badges.ts

**Files:**
- Modify: `dashboard/src/lib/hooks/use-monitoring-badges.ts`

- [ ] **Step 1: Change realtime subscription from lunch_breaks to shifts**

The current code subscribes to `lunch_breaks` table changes (lines 98-106). After dropping lunch_breaks, this subscription breaks. Change it to subscribe to `shifts` table changes instead:

```typescript
// OLD:
const lunchChannel = supabaseClient
  .channel('sidebar-lunch')
  .on(
    'postgres_changes',
    { event: '*', schema: 'public', table: 'lunch_breaks' },
    () => { fetchData(); }
  )
  .subscribe();

// NEW:
const shiftChannel = supabaseClient
  .channel('sidebar-shifts')
  .on(
    'postgres_changes',
    { event: '*', schema: 'public', table: 'shifts' },
    () => { fetchData(); }
  )
  .subscribe();
```

The `is_on_lunch` categorization logic (lines 42-44) doesn't change — it reads from the RPC response.

- [ ] **Step 2: Verify build**

```bash
cd dashboard && npx next build
```

- [ ] **Step 3: Commit**

```bash
git add dashboard/src/lib/hooks/use-monitoring-badges.ts
git commit -m "feat(dashboard): subscribe to shifts table instead of lunch_breaks for monitoring"
```

---

### Task 13: Verify dashboard components work without changes

**Files to verify (read-only):**
- `dashboard/src/components/approvals/approval-grid.tsx`
- `dashboard/src/components/approvals/day-approval-detail.tsx`
- `dashboard/src/components/approvals/approval-rows.tsx`
- `dashboard/src/components/monitoring/team-list.tsx`

- [ ] **Step 1: Verify approval-grid.tsx**

This file reads `day.lunch_minutes` from the RPC response. Since the rewritten RPC still returns `lunch_minutes`, no changes needed.

- [ ] **Step 2: Verify day-approval-detail.tsx**

This file uses `nestLunchActivities()` and renders `LunchGroupRow`. Since the RPC still returns `activity_type='lunch'` activities, the display logic works unchanged.

- [ ] **Step 3: Verify approval-rows.tsx**

`LunchGroupRow` renders based on `activity_type === 'lunch'` from the RPC. No changes needed.

- [ ] **Step 4: Verify team-list.tsx**

Reads `employee.isOnLunch` and `employee.lunchStartedAt` from the monitoring RPC. The RPC now derives this from shifts instead of lunch_breaks, but the output format is identical. No changes needed.

- [ ] **Step 5: Full build verification**

```bash
cd dashboard && npx next build
```

- [ ] **Step 6: Commit (if any minor fixes needed)**

```bash
git add dashboard/
git commit -m "fix(dashboard): minor adjustments for shift-gap lunch model"
```

---

## Deployment Order

### Phase A: Database + Dashboard (deploy together)
1. Apply migrations 20260316000001 through 20260316000004
2. Deploy dashboard to Vercel
3. Verify approval detail shows correct lunch data
4. Verify monitoring shows correct lunch status

### Phase B: Flutter App
1. Merge Flutter changes
2. Deploy to TestFlight + Google Play
3. Verify: start lunch → shift closes with reason='lunch'
4. Verify: end lunch → new shift opens with same work_body_id
5. Verify: lunch timer shows correct duration

### Phase C: Cleanup (after all users update)
1. Apply migration 20260316000005 (drop lunch_breaks table)
2. Verify no errors in Supabase logs

---

## Risk Checklist

- [ ] **Before applying migration 2 (retroactive):** Back up shifts + lunch_breaks tables via `pg_dump` or Supabase dashboard backup
- [ ] **Rollback plan:** If migration 2 corrupts data, restore from backup. If RPCs break, re-deploy previous versions from git. The `lunch_breaks` table is NOT dropped until Phase C, so reverting RPCs restores full functionality.
- [ ] **Before applying migration 4 (RPCs):** Verify all 5 RPCs compile without error
- [ ] **Before deploying dashboard:** Verify `next build` succeeds
- [ ] **Before deploying Flutter:** Verify `flutter analyze` passes
- [ ] **Before dropping lunch_breaks:** Confirm all active app users are on new version
- [ ] **After each phase:** Spot-check approval detail for an employee with historical lunch breaks (e.g., Irene Pepin who had multiple lunches per shift)
