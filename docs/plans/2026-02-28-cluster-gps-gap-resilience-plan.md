# Cluster GPS Gap Resilience Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Stop GPS gaps from splitting stationary clusters, track missing GPS time per cluster, and show warnings in the dashboard.

**Architecture:** Remove the GPS gap handler that resets cluster state in `detect_trips`. Instead, let the spatial algorithm naturally continue or finalize clusters. Add `gps_gap_seconds`/`gps_gap_count` columns to `stationary_clusters` and `has_gps_gap` to `trips`. Update `get_employee_activity` RPC and dashboard UI to surface GPS gap warnings.

**Tech Stack:** PostgreSQL/Supabase (migrations), TypeScript/Next.js (dashboard), shadcn/ui (UI components)

---

### Task 1: Schema migration — add GPS gap columns

**Files:**
- Create: `supabase/migrations/085_cluster_gps_gap_columns.sql`

**Step 1: Write the migration**

```sql
-- Migration 085: Add GPS gap tracking columns
-- stationary_clusters: track total missing GPS time and gap count
-- trips: flag trips created across GPS gaps (no GPS trace)

ALTER TABLE stationary_clusters
  ADD COLUMN gps_gap_seconds INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN gps_gap_count INTEGER NOT NULL DEFAULT 0;

ALTER TABLE trips
  ADD COLUMN has_gps_gap BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN stationary_clusters.gps_gap_seconds IS 'Total seconds of GPS gaps > 5 min within this cluster (excess over 5-min grace period)';
COMMENT ON COLUMN stationary_clusters.gps_gap_count IS 'Number of individual GPS gaps > 5 min within this cluster';
COMMENT ON COLUMN trips.has_gps_gap IS 'TRUE when trip was created across a GPS gap with no/minimal GPS trace';
```

**Step 2: Apply the migration**

Run: `cd supabase && supabase db push`
Expected: Migration 085 applied successfully

**Step 3: Verify columns exist**

Run via Supabase SQL editor or MCP:
```sql
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_name = 'stationary_clusters' AND column_name LIKE 'gps_gap%';
```
Expected: Two rows — `gps_gap_seconds` (integer, 0) and `gps_gap_count` (integer, 0)

**Step 4: Commit**

```bash
git add supabase/migrations/085_cluster_gps_gap_columns.sql
git commit -m "feat: add gps_gap_seconds/count to clusters, has_gps_gap to trips (migration 085)"
```

---

### Task 2: Update detect_trips — remove gap reset, add gap tracking

**Files:**
- Create: `supabase/migrations/086_detect_trips_gps_gap_resilience.sql`
- Reference: `supabase/migrations/082_detect_trips_clock_linking.sql` (current version to copy and modify)

This is the core change. Copy the entire `detect_trips` function from migration 082 and make these modifications:

**Step 1: Write the migration**

The migration replaces `detect_trips` with these changes to the 082 version:

**A) Add gap tracking variables** (after line 124, in DECLARE block):

```sql
    -- GPS gap tracking
    v_gap_grace_seconds    CONSTANT INTEGER := 300;  -- 5 min grace period
    v_cluster_gap_seconds  INTEGER := 0;
    v_cluster_gap_count    INTEGER := 0;
```

**B) Replace the GPS gap handler** (lines 209-268 in 082). Remove the entire block that resets cluster state on gap > 15 min. Replace with gap accumulation:

```sql
        -- =================================================================
        -- GPS gap tracking: accumulate gaps > 5 min for the current cluster
        -- (No cluster reset — only clock-out breaks clusters)
        -- =================================================================
        IF v_has_prev_point THEN
            DECLARE
                v_gap_secs INTEGER;
            BEGIN
                v_gap_secs := EXTRACT(EPOCH FROM (v_point.captured_at - v_prev_point.captured_at))::INTEGER;
                IF v_gap_secs > v_gap_grace_seconds THEN
                    v_cluster_gap_seconds := v_cluster_gap_seconds + (v_gap_secs - v_gap_grace_seconds);
                    v_cluster_gap_count := v_cluster_gap_count + 1;
                END IF;
            END;
        END IF;
```

**C) Write gap fields on every cluster INSERT** — add `gps_gap_seconds` and `gps_gap_count` to all INSERT INTO stationary_clusters statements. There are 4 locations in the function:

Location 1 — First cluster confirmation (line 321):
```sql
INSERT INTO stationary_clusters (
    shift_id, employee_id,
    centroid_latitude, centroid_longitude, centroid_accuracy,
    started_at, ended_at, duration_seconds, gps_point_count,
    matched_location_id,
    gps_gap_seconds, gps_gap_count    -- NEW
) VALUES (
    ...existing values...,
    v_cluster_gap_seconds, v_cluster_gap_count    -- NEW
)
```

Location 2 — Edge case cluster (line 486):
Same pattern — add the two columns.

Location 3 — Tentative promoted to new cluster (line 557):
This is a NEW cluster starting from tentative points, so gap fields should be reset to 0 (the gap belongs to the previous cluster or inter-cluster period). Use `0, 0`.

Location 4 — End-of-loop finalization (lines 830, 874):
Add `gps_gap_seconds, gps_gap_count` columns with `v_cluster_gap_seconds, v_cluster_gap_count` values.

**D) Write gap fields on every cluster UPDATE** — add to all UPDATE stationary_clusters SET statements:

Location 1 — Gap handler finalization (line 228): REMOVED (gap handler is gone).

Location 2 — Ongoing cluster update (line 375):
```sql
UPDATE stationary_clusters SET
    ...existing fields...,
    gps_gap_seconds = v_cluster_gap_seconds,    -- NEW
    gps_gap_count = v_cluster_gap_count          -- NEW
WHERE id = v_cluster_id;
```

Location 3 — Departure cluster finalization (line 456):
Same pattern.

Location 4 — End-of-loop update (line 830):
Same pattern.

**E) Reset gap accumulator when starting a new cluster.** After promoting tentative to current cluster (the section that does `v_cluster_lats := v_tent_lats; ...`), reset:

```sql
v_cluster_gap_seconds := 0;
v_cluster_gap_count := 0;
```

This happens in the "promote tentative" section (around line 760-786 in 082).

**F) Flag trips with GPS gaps.** When creating a trip, check if the transit buffer is empty or very small relative to the trip duration. After the trip INSERT (line 638-663), add:

```sql
-- Flag trip if transit buffer is empty/minimal (GPS gap trip)
IF v_trip_point_count = 0 THEN
    UPDATE trips SET has_gps_gap = TRUE WHERE id = v_trip_id;
END IF;
```

**G) Remove the `v_gps_gap_minutes` constant** (line 47) — no longer needed.

**Step 2: Apply the migration**

Run: `cd supabase && supabase db push`

**Step 3: Test with Irene's shift**

Run via Supabase SQL:
```sql
SELECT detect_trips('e56aefd0-373d-4349-b73a-8a2b582d5b65');
```

Then verify:
```sql
SELECT id, started_at AT TIME ZONE 'America/Montreal' as start_local,
       ended_at AT TIME ZONE 'America/Montreal' as end_local,
       duration_seconds, gps_point_count, gps_gap_seconds, gps_gap_count,
       l.name as location_name
FROM stationary_clusters sc
LEFT JOIN locations l ON l.id = sc.matched_location_id
WHERE sc.shift_id = 'e56aefd0-373d-4349-b73a-8a2b582d5b65'
ORDER BY sc.started_at;
```

Expected: The two "45_Perreault-E" clusters (09:29-09:35 and 10:25-10:35) should now be ONE cluster from 09:29 to 10:35 with `gps_gap_seconds` ≈ 2700 (45 min) and `gps_gap_count` = 1.

**Step 4: Commit**

```bash
git add supabase/migrations/086_detect_trips_gps_gap_resilience.sql
git commit -m "feat: remove GPS gap cluster reset, add gap tracking in detect_trips (migration 086)"
```

---

### Task 3: Update get_employee_activity RPC — expose gap fields

**Files:**
- Create: `supabase/migrations/087_activity_gps_gap_fields.sql`
- Reference: `supabase/migrations/084_activity_clock_location_name.sql` (current version)

**Step 1: Write the migration**

Copy `get_employee_activity` from migration 084 and add:

A) Two new output columns in the RETURNS TABLE:
```sql
    -- Stop fields (after cluster_gps_point_count)
    gps_gap_seconds INTEGER,       -- NEW
    gps_gap_count INTEGER,         -- NEW
```

B) One new output column for trips:
```sql
    -- Trip fields (after gps_point_count)
    has_gps_gap BOOLEAN,           -- NEW
```

C) In the `trip_data` CTE SELECT: add `t.has_gps_gap`
D) In the `stop_data` CTE SELECT: add `sc.gps_gap_seconds, sc.gps_gap_count`
E) In the `clock_in` and `clock_out` CTEs: add `NULL::INTEGER, NULL::INTEGER` for the gap columns and `NULL::BOOLEAN` for has_gps_gap
F) Make sure all UNION ALL branches have matching column counts

**Step 2: Apply and test**

Run: `cd supabase && supabase db push`

Test:
```sql
SELECT activity_type, started_at, ended_at, gps_gap_seconds, gps_gap_count, has_gps_gap
FROM get_employee_activity(
    'c0dd8219-40c2-4c4c-92df-45394bb347b1',
    '2026-02-25', '2026-02-25'
)
ORDER BY started_at;
```

Expected: Stop rows show `gps_gap_seconds` and `gps_gap_count` values. Trip rows show `has_gps_gap`.

**Step 3: Commit**

```bash
git add supabase/migrations/087_activity_gps_gap_fields.sql
git commit -m "feat: expose gps_gap_seconds/count and has_gps_gap in get_employee_activity (migration 087)"
```

---

### Task 4: Backfill all existing shifts

**Files:**
- Create: `supabase/migrations/088_backfill_gps_gap_clusters.sql`

**Step 1: Write the backfill migration**

```sql
-- Migration 088: Backfill all completed shifts to merge split clusters
-- and populate gps_gap_seconds/gps_gap_count fields.
-- Re-runs detect_trips for every completed shift.

DO $$
DECLARE
    v_shift RECORD;
    v_count INTEGER := 0;
BEGIN
    FOR v_shift IN
        SELECT id FROM shifts WHERE status = 'completed' ORDER BY clocked_in_at ASC
    LOOP
        PERFORM detect_trips(v_shift.id);
        v_count := v_count + 1;
        IF v_count % 100 = 0 THEN
            RAISE NOTICE 'Processed % shifts', v_count;
        END IF;
    END LOOP;
    RAISE NOTICE 'Backfill complete: % shifts processed', v_count;
END $$;
```

**Step 2: Apply the migration**

Run: `cd supabase && supabase db push`

Note: This may take a while depending on the number of shifts. Monitor progress via NOTICE messages.

**Step 3: Verify Irene's data is fixed**

```sql
SELECT id, started_at AT TIME ZONE 'America/Montreal' as start_local,
       ended_at AT TIME ZONE 'America/Montreal' as end_local,
       duration_seconds, gps_point_count, gps_gap_seconds, gps_gap_count,
       l.name as location_name
FROM stationary_clusters sc
LEFT JOIN locations l ON l.id = sc.matched_location_id
WHERE sc.shift_id = 'e56aefd0-373d-4349-b73a-8a2b582d5b65'
ORDER BY sc.started_at;
```

Expected: Merged clusters, gap fields populated.

**Step 4: Commit**

```bash
git add supabase/migrations/088_backfill_gps_gap_clusters.sql
git commit -m "feat: backfill all shifts for GPS gap cluster merging (migration 088)"
```

---

### Task 5: Dashboard types — add gap fields

**Files:**
- Modify: `dashboard/src/types/mileage.ts:171-216`

**Step 1: Update ActivityTrip interface**

Add after `gps_point_count: number;` (line 193):
```typescript
  has_gps_gap: boolean;
```

**Step 2: Update ActivityStop interface**

Add after `matched_location_name: string | null;` (line 204):
```typescript
  gps_gap_seconds: number;
  gps_gap_count: number;
```

**Step 3: Commit**

```bash
git add dashboard/src/types/mileage.ts
git commit -m "feat: add GPS gap fields to ActivityTrip and ActivityStop types"
```

---

### Task 6: Dashboard UI — GPS gap warning badges

**Files:**
- Modify: `dashboard/src/components/mileage/activity-tab.tsx`

**Step 1: Add AlertTriangle import**

At the top of the file, add `AlertTriangle` to the lucide-react import.

**Step 2: Add warning badge to stop duration column**

In `ActivityTableRow` (line 879), find the duration cell (line 919):

```tsx
<td className="px-4 py-3 whitespace-nowrap tabular-nums">
  {getActivityDuration(item)}
</td>
```

Replace with:
```tsx
<td className="px-4 py-3 whitespace-nowrap tabular-nums">
  <div className="flex items-center gap-1">
    {getActivityDuration(item)}
    {isStop && stop && stop.gps_gap_seconds > 0 && (
      <span title={`${Math.round(stop.gps_gap_seconds / 60)} min sans signal GPS (${stop.gps_gap_count} interruption${stop.gps_gap_count > 1 ? 's' : ''})`}>
        <AlertTriangle className="h-3.5 w-3.5 text-amber-500" />
      </span>
    )}
    {isTrip && trip && trip.has_gps_gap && (
      <span title="Trajet sans trace GPS">
        <AlertTriangle className="h-3.5 w-3.5 text-amber-500" />
      </span>
    )}
  </div>
</td>
```

**Step 3: Add warning to StopExpandDetail**

In the `StopExpandDetail` function (around line 687), add a warning banner when `gps_gap_seconds > 0`:

```tsx
{stop.gps_gap_seconds > 0 && (
  <div className="flex items-center gap-2 p-2 mb-2 bg-amber-50 border border-amber-200 rounded text-xs text-amber-700">
    <AlertTriangle className="h-4 w-4 flex-shrink-0" />
    <span>
      Signal GPS perdu pendant {Math.round(stop.gps_gap_seconds / 60)} min
      ({stop.gps_gap_count} interruption{stop.gps_gap_count > 1 ? 's' : ''})
    </span>
  </div>
)}
```

**Step 4: Add warning to TripExpandDetail**

In the `TripExpandDetail` function (around line 556), add a similar warning when `has_gps_gap`:

```tsx
{trip.has_gps_gap && (
  <div className="flex items-center gap-2 p-2 mb-2 bg-amber-50 border border-amber-200 rounded text-xs text-amber-700">
    <AlertTriangle className="h-4 w-4 flex-shrink-0" />
    <span>Trajet sans trace GPS — aucune donnée de parcours disponible</span>
  </div>
)}
```

**Step 5: Verify locally**

Run: `cd dashboard && npm run dev`
Navigate to the activity tab for Irene Pepin on 2026-02-25.
Expected: The merged "45_Perreault-E" cluster shows a yellow warning triangle with tooltip "45 min sans signal GPS (1 interruption)".

**Step 6: Commit**

```bash
git add dashboard/src/components/mileage/activity-tab.tsx
git commit -m "feat: add GPS gap warning badges to activity timeline stops and trips"
```

---

### Task 7: Verify end-to-end and final commit

**Step 1: Run full verification on Irene's shift**

Query clusters:
```sql
SELECT started_at AT TIME ZONE 'America/Montreal', ended_at AT TIME ZONE 'America/Montreal',
       duration_seconds, gps_gap_seconds, gps_gap_count, l.name
FROM stationary_clusters sc
LEFT JOIN locations l ON l.id = sc.matched_location_id
WHERE sc.shift_id = 'e56aefd0-373d-4349-b73a-8a2b582d5b65'
ORDER BY sc.started_at;
```

Expected:
- "45_Perreault-E" appears as ONE cluster (09:29 - 10:35), not two
- `gps_gap_seconds` ≈ 2700, `gps_gap_count` = 1
- Other clusters are unaffected

Query trips:
```sql
SELECT started_at AT TIME ZONE 'America/Montreal', ended_at AT TIME ZONE 'America/Montreal',
       distance_km, has_gps_gap
FROM trips
WHERE shift_id = 'e56aefd0-373d-4349-b73a-8a2b582d5b65'
ORDER BY started_at;
```

**Step 2: Dashboard visual check**

Open activity tab for Irene on 2026-02-25.
- Verify merged cluster with yellow warning
- Verify trip warning badges (if any)
- Verify tooltip text is correct

**Step 3: Check for other affected shifts**

```sql
SELECT sc.shift_id, COUNT(*) as cluster_count, SUM(sc.gps_gap_seconds) as total_gap_seconds
FROM stationary_clusters sc
WHERE sc.gps_gap_seconds > 0
GROUP BY sc.shift_id
ORDER BY total_gap_seconds DESC
LIMIT 20;
```

This shows which shifts benefited from the change.
