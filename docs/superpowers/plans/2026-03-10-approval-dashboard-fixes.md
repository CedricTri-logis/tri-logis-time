# Approval Dashboard Fixes Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix missing clock-out icons, premature shift auto-close, duplicate same-location clusters, and restore lost gap detection in the approval dashboard.

**Architecture:** Single Supabase migration modifying 3 functions (`flag_gpsless_shifts`, `_get_day_approval_detail_base`, `detect_trips`) and adding 1 new function (`merge_same_location_clusters`). One small dashboard change to show GPS health badge. Data fix to rerun clustering for affected shifts.

**Tech Stack:** PostgreSQL/Supabase (plpgsql), TypeScript/Next.js (dashboard)

**Spec:** `docs/superpowers/specs/2026-03-10-approval-dashboard-fixes-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `supabase/migrations/148_approval_dashboard_fixes.sql` | Create | All DB changes: column, functions, cron, data fix |
| `dashboard/src/components/approvals/day-approval-detail.tsx` | Modify | Show GPS health badge when `gps_health = 'stale'` |

---

## Chunk 1: Database Migration

### Task 1: Add `gps_health` column to shifts table

**Files:**
- Create: `supabase/migrations/148_approval_dashboard_fixes.sql`

- [ ] **Step 1: Create migration file with ALTER TABLE**

```sql
-- Migration 148: Approval dashboard fixes
-- 1. Add gps_health column
-- 2. Rewrite flag_gpsless_shifts (non-destructive + midnight close)
-- 3. Add merge_same_location_clusters function
-- 4. Add step 9 to detect_trips
-- 5. Fix _get_day_approval_detail_base (clock events + gap detection)
-- 6. Data fix: rerun detect_trips for Celine March 9

-- ============================================================
-- 1. Add gps_health column to shifts
-- ============================================================
ALTER TABLE shifts ADD COLUMN IF NOT EXISTS gps_health TEXT DEFAULT 'ok';
COMMENT ON COLUMN shifts.gps_health IS 'GPS signal health: ok = normal, stale = no GPS points received for 10+ min while shift active';
```

- [ ] **Step 2: Verify column added**

Run via MCP `execute_sql`:
```sql
SELECT column_name, data_type, column_default FROM information_schema.columns
WHERE table_name = 'shifts' AND column_name = 'gps_health';
```
Expected: one row with `gps_health`, `text`, `'ok'::text`

---

### Task 2: Rewrite `flag_gpsless_shifts()` — non-destructive + midnight close

**Context:**
- Current function (migration 110): closes active shifts with 0 GPS after 10 min
- New behavior: flag `gps_health = 'stale'` instead of closing
- Add midnight close: close shifts where clock-in day has passed (EST timezone)
- Cron stays at `*/10 * * * *`

**Files:**
- Modify: `supabase/migrations/148_approval_dashboard_fixes.sql` (append)

- [ ] **Step 1: Add new flag_gpsless_shifts function**

```sql
-- ============================================================
-- 2. Rewrite flag_gpsless_shifts: flag instead of close + midnight close
-- ============================================================
CREATE OR REPLACE FUNCTION flag_gpsless_shifts()
RETURNS void AS $$
DECLARE
    v_shift RECORD;
    v_now_est TIMESTAMPTZ;
    v_today_est DATE;
BEGIN
    -- Current time in EST
    v_now_est := now() AT TIME ZONE 'America/Toronto';
    v_today_est := v_now_est::DATE;

    -- Part A: Flag stale GPS (active shifts with 0 GPS after 10 min)
    -- Does NOT close the shift — just sets gps_health = 'stale'
    UPDATE shifts SET gps_health = 'stale'
    WHERE status = 'active'
      AND gps_health = 'ok'
      AND clocked_in_at < NOW() - INTERVAL '10 minutes'
      AND NOT EXISTS (
          SELECT 1 FROM gps_points gp WHERE gp.shift_id = shifts.id
      );

    -- Reset stale flag if GPS points have arrived
    UPDATE shifts SET gps_health = 'ok'
    WHERE status = 'active'
      AND gps_health = 'stale'
      AND EXISTS (
          SELECT 1 FROM gps_points gp WHERE gp.shift_id = shifts.id
      );

    -- Part B: Midnight auto-close
    -- Close any active shift where the clock-in date (EST) is before today (EST)
    FOR v_shift IN
        SELECT s.id, s.employee_id, s.clocked_in_at
        FROM shifts s
        WHERE s.status = 'active'
          AND (s.clocked_in_at AT TIME ZONE 'America/Toronto')::DATE < v_today_est
    LOOP
        UPDATE shifts SET
            status = 'completed',
            clocked_out_at = (
                (v_shift.clocked_in_at AT TIME ZONE 'America/Toronto')::DATE + INTERVAL '23 hours 59 minutes 59 seconds'
            ) AT TIME ZONE 'America/Toronto',
            clock_out_reason = 'midnight_auto_close',
            gps_health = CASE
                WHEN EXISTS (SELECT 1 FROM gps_points gp WHERE gp.shift_id = v_shift.id)
                THEN 'ok' ELSE 'stale'
            END
        WHERE id = v_shift.id;

        -- Run trip/cluster detection for the closed shift
        PERFORM detect_trips(v_shift.id);

        RAISE NOTICE 'Midnight-closed shift % for employee %',
            v_shift.id, v_shift.employee_id;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

- [ ] **Step 2: Apply migration and verify function exists**

Run via MCP `execute_sql`:
```sql
SELECT proname FROM pg_proc WHERE proname = 'flag_gpsless_shifts';
```
Expected: one row

- [ ] **Step 3: Verify cron job still exists**

Run via MCP `execute_sql`:
```sql
SELECT jobid, schedule, command FROM cron.job WHERE jobname = 'flag-gpsless-shifts';
```
Expected: one row with `*/10 * * * *` schedule. If missing, re-create:
```sql
SELECT cron.schedule('flag-gpsless-shifts', '*/10 * * * *', $$SELECT flag_gpsless_shifts()$$);
```

---

### Task 3: Create `merge_same_location_clusters()` function

**Context:**
- After `detect_trips()` creates clusters and matches locations, consecutive clusters at the same `matched_location_id` with no real trip between them should be merged into one.
- Example: two "Home Celine" clusters 5 seconds apart → one cluster.
- The merged cluster keeps the earliest `started_at`, latest `ended_at`, combined `gps_point_count`, and recalculated `duration_seconds`.
- The `gps_gap_seconds` accumulates the gap time between the original clusters.

**Files:**
- Modify: `supabase/migrations/148_approval_dashboard_fixes.sql` (append)

- [ ] **Step 1: Add merge_same_location_clusters function**

```sql
-- ============================================================
-- 3. Merge consecutive same-location clusters
-- ============================================================
CREATE OR REPLACE FUNCTION merge_same_location_clusters(p_shift_id UUID)
RETURNS void AS $$
DECLARE
    v_merge RECORD;
    v_keep_id UUID;
    v_remove_ids UUID[];
    v_new_ended_at TIMESTAMPTZ;
    v_total_points INTEGER;
    v_total_gap_seconds INTEGER;
    v_total_gap_count INTEGER;
BEGIN
    -- Find groups of consecutive clusters at the same location with no trip between them.
    -- A "consecutive pair" = two clusters ordered by started_at where:
    --   1. Same matched_location_id (non-null)
    --   2. No trip exists that starts between c1.ended_at and c2.started_at

    FOR v_merge IN
        WITH ordered AS (
            SELECT
                sc.id,
                sc.matched_location_id,
                sc.started_at,
                sc.ended_at,
                sc.duration_seconds,
                sc.gps_point_count,
                sc.gps_gap_seconds,
                sc.gps_gap_count,
                ROW_NUMBER() OVER (ORDER BY sc.started_at) AS rn
            FROM stationary_clusters sc
            WHERE sc.shift_id = p_shift_id
              AND sc.matched_location_id IS NOT NULL
        ),
        pairs AS (
            SELECT
                c1.id AS id1, c2.id AS id2,
                c1.matched_location_id,
                c1.started_at AS start1, c1.ended_at AS end1,
                c2.started_at AS start2, c2.ended_at AS end2,
                c1.gps_point_count AS points1, c2.gps_point_count AS points2,
                COALESCE(c1.gps_gap_seconds, 0) AS gap_sec1,
                COALESCE(c2.gps_gap_seconds, 0) AS gap_sec2,
                COALESCE(c1.gps_gap_count, 0) AS gap_cnt1,
                COALESCE(c2.gps_gap_count, 0) AS gap_cnt2,
                EXTRACT(EPOCH FROM (c2.started_at - c1.ended_at))::INTEGER AS between_gap_sec
            FROM ordered c1
            JOIN ordered c2 ON c2.rn = c1.rn + 1
            WHERE c1.matched_location_id = c2.matched_location_id
              AND NOT EXISTS (
                  SELECT 1 FROM trips t
                  WHERE t.shift_id = p_shift_id
                    AND t.started_at >= c1.ended_at - INTERVAL '30 seconds'
                    AND t.ended_at <= c2.started_at + INTERVAL '30 seconds'
              )
        )
        SELECT * FROM pairs
        ORDER BY start1
    LOOP
        -- Merge: keep the first cluster (id1), absorb the second (id2)
        v_keep_id := v_merge.id1;

        -- Update the kept cluster to span both
        v_total_points := COALESCE(v_merge.points1, 0) + COALESCE(v_merge.points2, 0);
        v_total_gap_seconds := v_merge.gap_sec1 + v_merge.gap_sec2 + GREATEST(v_merge.between_gap_sec, 0);
        v_total_gap_count := v_merge.gap_cnt1 + v_merge.gap_cnt2 + 1;

        UPDATE stationary_clusters SET
            ended_at = v_merge.end2,
            duration_seconds = EXTRACT(EPOCH FROM (v_merge.end2 - started_at))::INTEGER,
            gps_point_count = v_total_points,
            gps_gap_seconds = v_total_gap_seconds,
            gps_gap_count = v_total_gap_count
        WHERE id = v_keep_id;

        -- Move GPS points from absorbed cluster to kept cluster
        UPDATE gps_points SET stationary_cluster_id = v_keep_id
        WHERE stationary_cluster_id = v_merge.id2;

        -- Update any trips referencing the absorbed cluster
        UPDATE trips SET start_cluster_id = v_keep_id WHERE start_cluster_id = v_merge.id2;
        UPDATE trips SET end_cluster_id = v_keep_id WHERE end_cluster_id = v_merge.id2;

        -- Delete synthetic/ghost trips between the two clusters being merged
        DELETE FROM trip_gps_points WHERE trip_id IN (
            SELECT id FROM trips
            WHERE start_cluster_id = v_keep_id AND end_cluster_id = v_keep_id
        );
        DELETE FROM trips
        WHERE start_cluster_id = v_keep_id AND end_cluster_id = v_keep_id;

        -- Delete the absorbed cluster
        DELETE FROM stationary_clusters WHERE id = v_merge.id2;

        RAISE NOTICE 'Merged cluster % into % (same location)', v_merge.id2, v_keep_id;
    END LOOP;

    -- Re-run if more merges possible (chain of 3+ consecutive same-location clusters)
    IF FOUND THEN
        PERFORM merge_same_location_clusters(p_shift_id);
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

- [ ] **Step 2: Apply and verify function exists**

Run via MCP `execute_sql`:
```sql
SELECT proname FROM pg_proc WHERE proname = 'merge_same_location_clusters';
```

---

### Task 4: Add step 9 to `detect_trips()` — call merge after clustering

**Context:**
- `detect_trips()` is ~800 lines. We need to add 4 lines before the final `END;`.
- Current end: step 7 (`compute_cluster_effective_types`), step 8 (`compute_gps_gaps`), then `END;`.
- Add step 9: `PERFORM merge_same_location_clusters(p_shift_id);` after step 8, inside the `IF v_create_clusters` guard.

**Strategy:** Extract current function source via `pg_get_functiondef(oid)`, add the step 9 block before the final `END;`, then `CREATE OR REPLACE` with the modified source.

**Files:**
- Modify: `supabase/migrations/148_approval_dashboard_fixes.sql` (append)

- [ ] **Step 1: Get current detect_trips source and add step 9**

The migration must contain the full `CREATE OR REPLACE FUNCTION detect_trips(...)` with the step 9 addition. Use `pg_get_functiondef` to get the current source, then add before the final `END;`:

```sql
    -- =========================================================================
    -- 9. Post-processing: merge consecutive same-location clusters
    -- =========================================================================
    IF v_create_clusters THEN
        PERFORM merge_same_location_clusters(p_shift_id);
    END IF;
```

**Implementation approach:** The subagent should:
1. Query `SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = 'detect_trips' AND pronargs = 1`
2. Find the last `END;` in the function body
3. Insert the step 9 block before it
4. Write the full `CREATE OR REPLACE FUNCTION` into the migration file
5. Apply via `apply_migration`

- [ ] **Step 2: Verify step 9 is in the deployed function**

Run via MCP `execute_sql`:
```sql
SELECT pg_get_functiondef(oid) LIKE '%merge_same_location_clusters%'
FROM pg_proc WHERE proname = 'detect_trips' AND pronargs = 1;
```
Expected: `true`

---

### Task 5: Fix `_get_day_approval_detail_base()` — clock events without location + gap detection

**Context:**
- Current `clock_data` CTE filters `s.clock_in_location IS NOT NULL` and `s.clock_out_location IS NOT NULL`
- These filters must be removed so clock events appear even without GPS location
- When location is NULL: show "Lieu inconnu", auto_status = 'needs_review'
- Restore gap detection CTEs from migration 144 (lost in migration 147)
- Add `has_stale_gps` to the result object

**Files:**
- Modify: `supabase/migrations/148_approval_dashboard_fixes.sql` (append)

- [ ] **Step 1: Write the updated `_get_day_approval_detail_base` function**

Key changes to the function:

**A) Clock-in: Remove `s.clock_in_location IS NOT NULL` filter.**
Replace the WHERE clause of the first `clock_data` SELECT with:
```sql
WHERE s.employee_id = p_employee_id
  AND s.clocked_in_at::DATE = p_date
  AND s.status = 'completed'
```
When `clock_in_location IS NULL`, the LATERAL join returns NULL for `ci_loc`, so:
- `location_name` = `'Lieu inconnu'`
- `auto_status` = `'needs_review'`
- `auto_reason` = `'Clock-in sans position GPS'`
Use COALESCE in the CASE statements to handle NULL ci_loc.

**B) Clock-out: Remove `s.clock_out_location IS NOT NULL` filter.**
Replace the WHERE clause with:
```sql
WHERE s.employee_id = p_employee_id
  AND s.clocked_out_at::DATE = p_date
  AND s.status = 'completed'
  AND s.clocked_out_at IS NOT NULL
```
Same COALESCE handling for NULL co_loc.

**C) Add gap detection CTEs (from migration 144).**
Add these CTEs inside the main WITH block, after `lunch_data`:

```sql
-- Gap detection: find untracked time periods
real_activities AS (
    SELECT sd.shift_id, sd.started_at, sd.ended_at
    FROM stop_data sd
    UNION ALL
    SELECT td.shift_id, td.started_at, td.ended_at
    FROM trip_data td
    UNION ALL
    SELECT lb.shift_id, lb.started_at, lb.ended_at
    FROM lunch_breaks lb
    WHERE lb.employee_id = p_employee_id
      AND lb.ended_at IS NOT NULL
      AND lb.started_at::DATE = p_date
),
shift_boundaries AS (
    SELECT s.id AS shift_id, s.clocked_in_at, s.clocked_out_at
    FROM shifts s
    WHERE s.employee_id = p_employee_id
      AND s.clocked_in_at::DATE = p_date
      AND s.status = 'completed'
      AND s.clocked_out_at IS NOT NULL
),
shift_events AS (
    SELECT sb.shift_id, sb.clocked_in_at AS event_time, 0 AS event_order
    FROM shift_boundaries sb
    UNION ALL
    SELECT ra.shift_id, ra.started_at, 2
    FROM real_activities ra
    UNION ALL
    SELECT ra.shift_id, ra.ended_at, 1
    FROM real_activities ra
    UNION ALL
    SELECT sb.shift_id, sb.clocked_out_at, 3
    FROM shift_boundaries sb
),
ordered_events AS (
    SELECT
        shift_id, event_time, event_order,
        ROW_NUMBER() OVER (PARTITION BY shift_id ORDER BY event_time, event_order) AS rn
    FROM shift_events
),
gap_pairs AS (
    SELECT
        e1.shift_id,
        e1.event_time AS gap_started_at,
        e2.event_time AS gap_ended_at,
        EXTRACT(EPOCH FROM (e2.event_time - e1.event_time))::INTEGER AS gap_seconds
    FROM ordered_events e1
    JOIN ordered_events e2 ON e1.shift_id = e2.shift_id AND e2.rn = e1.rn + 1
    WHERE e1.event_order IN (0, 1)
      AND e2.event_order IN (2, 3)
      AND EXTRACT(EPOCH FROM (e2.event_time - e1.event_time)) > 300
),
empty_shift_gaps AS (
    SELECT
        sb.shift_id,
        sb.clocked_in_at AS gap_started_at,
        sb.clocked_out_at AS gap_ended_at,
        EXTRACT(EPOCH FROM (sb.clocked_out_at - sb.clocked_in_at))::INTEGER AS gap_seconds
    FROM shift_boundaries sb
    WHERE NOT EXISTS (SELECT 1 FROM real_activities ra WHERE ra.shift_id = sb.shift_id)
      AND NOT EXISTS (SELECT 1 FROM gap_pairs gp WHERE gp.shift_id = sb.shift_id)
      AND EXTRACT(EPOCH FROM (sb.clocked_out_at - sb.clocked_in_at)) > 300
),
all_gaps AS (
    SELECT * FROM gap_pairs
    UNION ALL
    SELECT * FROM empty_shift_gaps
),
gap_data AS (
    SELECT
        'gap'::TEXT AS activity_type,
        md5(p_employee_id::TEXT || '/gap/' || g.gap_started_at::TEXT || '/' || g.gap_ended_at::TEXT)::UUID AS activity_id,
        g.shift_id,
        g.gap_started_at AS started_at,
        g.gap_ended_at AS ended_at,
        (g.gap_seconds / 60)::INTEGER AS duration_minutes,
        -- Inherit location from adjacent stop if gap is at same location
        COALESCE(
            (SELECT sc.matched_location_id FROM stop_data sc
             WHERE sc.ended_at BETWEEN g.gap_started_at - INTERVAL '60 seconds' AND g.gap_started_at + INTERVAL '60 seconds'
             LIMIT 1),
            (SELECT sc.matched_location_id FROM stop_data sc
             WHERE sc.started_at BETWEEN g.gap_ended_at - INTERVAL '60 seconds' AND g.gap_ended_at + INTERVAL '60 seconds'
             LIMIT 1)
        ) AS matched_location_id,
        COALESCE(
            (SELECT l.name FROM stop_data sc JOIN locations l ON l.id = sc.matched_location_id
             WHERE sc.ended_at BETWEEN g.gap_started_at - INTERVAL '60 seconds' AND g.gap_started_at + INTERVAL '60 seconds'
             LIMIT 1),
            (SELECT l.name FROM stop_data sc JOIN locations l ON l.id = sc.matched_location_id
             WHERE sc.started_at BETWEEN g.gap_ended_at - INTERVAL '60 seconds' AND g.gap_ended_at + INTERVAL '60 seconds'
             LIMIT 1)
        ) AS location_name,
        COALESCE(
            (SELECT l.location_type::TEXT FROM stop_data sc JOIN locations l ON l.id = sc.matched_location_id
             WHERE sc.ended_at BETWEEN g.gap_started_at - INTERVAL '60 seconds' AND g.gap_started_at + INTERVAL '60 seconds'
             LIMIT 1),
            (SELECT l.location_type::TEXT FROM stop_data sc JOIN locations l ON l.id = sc.matched_location_id
             WHERE sc.started_at BETWEEN g.gap_ended_at - INTERVAL '60 seconds' AND g.gap_ended_at + INTERVAL '60 seconds'
             LIMIT 1)
        ) AS location_type,
        NULL::DECIMAL AS latitude,
        NULL::DECIMAL AS longitude,
        0::INTEGER AS gps_gap_seconds,
        0::INTEGER AS gps_gap_count,
        'needs_review'::TEXT AS auto_status,
        'Temps non suivi'::TEXT AS auto_reason,
        NULL::DECIMAL AS distance_km,
        NULL::TEXT AS transport_mode,
        NULL::BOOLEAN AS has_gps_gap,
        -- For mergeSameLocationGaps: set start/end location to adjacent stop location
        COALESCE(
            (SELECT sc.matched_location_id FROM stop_data sc
             WHERE sc.ended_at BETWEEN g.gap_started_at - INTERVAL '60 seconds' AND g.gap_started_at + INTERVAL '60 seconds'
             LIMIT 1)
        ) AS start_location_id,
        COALESCE(
            (SELECT l.name FROM stop_data sc JOIN locations l ON l.id = sc.matched_location_id
             WHERE sc.ended_at BETWEEN g.gap_started_at - INTERVAL '60 seconds' AND g.gap_started_at + INTERVAL '60 seconds'
             LIMIT 1)
        ) AS start_location_name,
        COALESCE(
            (SELECT l.location_type::TEXT FROM stop_data sc JOIN locations l ON l.id = sc.matched_location_id
             WHERE sc.ended_at BETWEEN g.gap_started_at - INTERVAL '60 seconds' AND g.gap_started_at + INTERVAL '60 seconds'
             LIMIT 1)
        ) AS start_location_type,
        COALESCE(
            (SELECT sc.matched_location_id FROM stop_data sc
             WHERE sc.started_at BETWEEN g.gap_ended_at - INTERVAL '60 seconds' AND g.gap_ended_at + INTERVAL '60 seconds'
             LIMIT 1)
        ) AS end_location_id,
        COALESCE(
            (SELECT l.name FROM stop_data sc JOIN locations l ON l.id = sc.matched_location_id
             WHERE sc.started_at BETWEEN g.gap_ended_at - INTERVAL '60 seconds' AND g.gap_ended_at + INTERVAL '60 seconds'
             LIMIT 1)
        ) AS end_location_name,
        COALESCE(
            (SELECT l.location_type::TEXT FROM stop_data sc JOIN locations l ON l.id = sc.matched_location_id
             WHERE sc.started_at BETWEEN g.gap_ended_at - INTERVAL '60 seconds' AND g.gap_ended_at + INTERVAL '60 seconds'
             LIMIT 1)
        ) AS end_location_type
    FROM all_gaps g
),
```

**D) Add gap_data to the classified UNION.**
In the `classified` CTE, add after the `lunch_data` UNION ALL:
```sql
UNION ALL

SELECT
    gd.activity_type, gd.activity_id, gd.shift_id,
    gd.started_at, gd.ended_at, gd.duration_minutes,
    gd.matched_location_id, gd.location_name, gd.location_type,
    gd.latitude, gd.longitude, gd.gps_gap_seconds, gd.gps_gap_count,
    gd.auto_status, gd.auto_reason,
    gao.override_status, gao.reason AS override_reason,
    COALESCE(gao.override_status, gd.auto_status) AS final_status,
    gd.distance_km, gd.transport_mode, gd.has_gps_gap,
    gd.start_location_id, gd.start_location_name, gd.start_location_type,
    gd.end_location_id, gd.end_location_name, gd.end_location_type
FROM gap_data gd
LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
LEFT JOIN activity_overrides gao ON gao.day_approval_id = da.id
    AND gao.activity_type = 'gap' AND gao.activity_id = gd.activity_id
```

**E) Add `has_stale_gps` to the result.**
Before building `v_result`, add:
```sql
-- Check for stale GPS shifts
v_result := jsonb_build_object(
    ...existing fields...,
    'has_stale_gps', (
        SELECT EXISTS(
            SELECT 1 FROM shifts
            WHERE employee_id = p_employee_id
              AND clocked_in_at::DATE = p_date
              AND gps_health = 'stale'
        )
    ),
    ...
);
```

- [ ] **Step 2: Write the full CREATE OR REPLACE FUNCTION into migration**

The subagent should:
1. Read the current `_get_day_approval_detail_base` source from `pg_get_functiondef`
2. Apply changes A through E described above
3. Write the full function into the migration file
4. Apply via MCP `apply_migration`

- [ ] **Step 3: Verify the changes work**

Run via MCP `execute_sql`:
```sql
-- Should return clock events even without location
SELECT jsonb_array_length(
    (get_day_approval_detail(
        '25336644-fb83-4017-9cfd-e8155195fd10'::uuid,
        '2026-03-09'::date
    ))->'activities'
) AS activity_count;
```

Then check that clock_out events appear:
```sql
SELECT a->>'activity_type', a->>'location_name', a->>'auto_status'
FROM jsonb_array_elements(
    (get_day_approval_detail(
        '25336644-fb83-4017-9cfd-e8155195fd10'::uuid,
        '2026-03-09'::date
    ))->'activities'
) a
WHERE a->>'activity_type' IN ('clock_in', 'clock_out', 'gap')
ORDER BY (a->>'started_at');
```
Expected: clock_out events visible (may show "Lieu inconnu"), gap activities for untracked time

---

### Task 6: Data fix — rerun detect_trips for Celine's March 9 shifts

**Files:**
- Modify: `supabase/migrations/148_approval_dashboard_fixes.sql` (append)

- [ ] **Step 1: Add data fix SQL to migration**

```sql
-- ============================================================
-- 6. Data fix: rerun detect_trips for Celine March 9 shifts
-- ============================================================
-- Delete existing clusters and trips for these shifts, then re-detect
DO $$
DECLARE
    v_shift_id UUID;
BEGIN
    FOR v_shift_id IN
        SELECT id FROM shifts
        WHERE employee_id = '25336644-fb83-4017-9cfd-e8155195fd10'
          AND clocked_in_at::DATE = '2026-03-09'
    LOOP
        -- Clean existing detection data
        DELETE FROM trip_gps_points WHERE trip_id IN (
            SELECT id FROM trips WHERE shift_id = v_shift_id
        );
        DELETE FROM trips WHERE shift_id = v_shift_id;
        UPDATE gps_points SET stationary_cluster_id = NULL WHERE shift_id = v_shift_id;
        DELETE FROM stationary_clusters WHERE shift_id = v_shift_id;

        -- Re-run detection (will now include step 9 merge)
        PERFORM detect_trips(v_shift_id);

        RAISE NOTICE 'Re-ran detect_trips for shift %', v_shift_id;
    END LOOP;
END;
$$;
```

- [ ] **Step 2: Verify Celine now has one Home cluster instead of two**

Run via MCP `execute_sql`:
```sql
SELECT sc.id, l.name, sc.started_at, sc.ended_at, sc.duration_seconds/60 as min,
       sc.gps_gap_seconds, sc.gps_gap_count
FROM stationary_clusters sc
LEFT JOIN locations l ON l.id = sc.matched_location_id
WHERE sc.employee_id = '25336644-fb83-4017-9cfd-e8155195fd10'
  AND sc.started_at::DATE = '2026-03-09'
  AND l.name = 'Home Celine';
```
Expected: ONE row (instead of two), with `gps_gap_count >= 1`

---

## Chunk 2: Dashboard Changes

### Task 7: Show GPS health badge in approval detail

**Context:**
- The RPC now returns `has_stale_gps` boolean at the top level
- When true, show an orange warning badge in the day approval detail view
- Small change — just add a conditional banner

**Files:**
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx`

- [ ] **Step 1: Read current file**

Read `dashboard/src/components/approvals/day-approval-detail.tsx` to find where the approval header/summary is rendered.

- [ ] **Step 2: Add GPS health badge**

After the existing header/status display, add:

```tsx
{data?.has_stale_gps && (
  <div className="flex items-center gap-2 rounded-md bg-orange-50 border border-orange-200 px-3 py-2 text-sm text-orange-700">
    <AlertTriangle className="h-4 w-4" />
    <span>GPS manquant — un ou plusieurs quarts n&apos;ont pas reçu de signal GPS</span>
  </div>
)}
```

- [ ] **Step 3: Verify build passes**

```bash
cd dashboard && npx next build
```
Expected: build succeeds with no errors

- [ ] **Step 4: Commit all changes**

```bash
git add supabase/migrations/148_approval_dashboard_fixes.sql dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "fix: approval dashboard — clock events without location, gap detection, cluster merging, GPS health flag"
```

---

## Execution Checklist

After all tasks complete, verify:

1. [ ] Celine March 9 shows ONE "Home Celine" cluster (not two)
2. [ ] Clock-out icons visible for both shifts
3. [ ] Gap activities appear for untracked time (>5 min)
4. [ ] `flag_gpsless_shifts()` no longer auto-closes shifts
5. [ ] Midnight close works for shifts from previous day
6. [ ] `has_stale_gps` badge shows when applicable
7. [ ] Dashboard build passes
