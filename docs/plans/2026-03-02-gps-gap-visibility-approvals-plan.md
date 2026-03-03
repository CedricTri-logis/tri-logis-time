# GPS Gap Visibility in Approvals — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make GPS data gaps visible in the approvals dashboard — both as a day-level summary and per-activity detail — so admins can make informed approval decisions.

**Architecture:** A new `compute_gps_gaps()` PostgreSQL function computes gap data post-hoc from existing GPS points (no changes to detect_trips' core loop). It runs after detect_trips and populates gap columns on both clusters and trips. The dashboard shows a 5th summary card and per-line gap details under duration.

**Tech Stack:** PostgreSQL (Supabase migration), TypeScript/Next.js (dashboard components)

---

## Context

**Critical finding:** GPS gap tracking was removed from `detect_trips` in migration 113 (optimization). The columns `gps_gap_seconds`/`gps_gap_count` exist on `stationary_clusters` but are always 0 for data created after migration 113. `has_gps_gap` on trips is also not being set. All gap visibility in the dashboard is broken for recent data.

**Approach:** Instead of modifying the 900+ line `detect_trips` core loop (high regression risk), we create a separate `compute_gps_gaps()` function that runs post-hoc, computing gaps from existing GPS point timestamps. This function is called at the end of `detect_trips` via a single `PERFORM` line.

**Key files:**
- Migration: `supabase/migrations/122_gps_gap_visibility.sql` (NEW)
- Dashboard component: `dashboard/src/components/approvals/day-approval-detail.tsx` (MODIFY)
- Types: `dashboard/src/types/mileage.ts` (no change needed — already has gps_gap fields)

---

### Task 1: Create migration — schema + compute_gps_gaps function

**Files:**
- Create: `supabase/migrations/122_gps_gap_visibility.sql`

**Step 1: Write the migration file**

```sql
-- =============================================================================
-- 122: GPS gap visibility for approvals
-- =============================================================================
-- Restores GPS gap tracking (removed in 113) via post-hoc computation.
-- Adds gps_gap_seconds/gps_gap_count columns to trips table.
-- Creates compute_gps_gaps() function called after detect_trips.
-- Updates get_day_approval_detail to return trip gap data.
-- =============================================================================

-- 1. Add gap columns to trips table
ALTER TABLE trips
  ADD COLUMN IF NOT EXISTS gps_gap_seconds INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS gps_gap_count INTEGER NOT NULL DEFAULT 0;

COMMENT ON COLUMN trips.gps_gap_seconds IS 'Total seconds of GPS gaps > 5 min within this trip (excess over 5-min grace period)';
COMMENT ON COLUMN trips.gps_gap_count IS 'Number of individual GPS gaps > 5 min within this trip';

-- 2. Create compute_gps_gaps function
CREATE OR REPLACE FUNCTION compute_gps_gaps(p_shift_id UUID)
RETURNS VOID AS $$
DECLARE
    v_cluster RECORD;
    v_trip RECORD;
    v_gap_seconds INTEGER;
    v_gap_count INTEGER;
    v_grace_seconds CONSTANT INTEGER := 300; -- 5 min grace period
BEGIN
    -- =========================================================================
    -- Compute gaps for stationary clusters
    -- =========================================================================
    FOR v_cluster IN
        SELECT sc.id
        FROM stationary_clusters sc
        WHERE sc.shift_id = p_shift_id
    LOOP
        SELECT
            COALESCE(SUM(GREATEST(0, gap_secs - v_grace_seconds)), 0),
            COALESCE(COUNT(*) FILTER (WHERE gap_secs > v_grace_seconds), 0)
        INTO v_gap_seconds, v_gap_count
        FROM (
            SELECT EXTRACT(EPOCH FROM (
                captured_at - LAG(captured_at) OVER (ORDER BY captured_at)
            ))::INTEGER AS gap_secs
            FROM gps_points
            WHERE stationary_cluster_id = v_cluster.id
        ) gaps
        WHERE gap_secs IS NOT NULL;

        UPDATE stationary_clusters SET
            gps_gap_seconds = v_gap_seconds,
            gps_gap_count = v_gap_count
        WHERE id = v_cluster.id;
    END LOOP;

    -- =========================================================================
    -- Compute gaps for trips
    -- =========================================================================
    FOR v_trip IN
        SELECT t.id, t.started_at, t.ended_at, t.gps_point_count
        FROM trips t
        WHERE t.shift_id = p_shift_id
    LOOP
        IF v_trip.gps_point_count = 0 THEN
            -- No GPS points at all — entire trip duration is one gap
            v_gap_seconds := GREATEST(0,
                EXTRACT(EPOCH FROM (v_trip.ended_at - v_trip.started_at))::INTEGER
                - v_grace_seconds
            );
            v_gap_count := CASE WHEN v_gap_seconds > 0 THEN 1 ELSE 0 END;
        ELSE
            -- Include trip start/end as boundary timestamps to catch
            -- gaps at cluster-to-trip and trip-to-cluster transitions
            SELECT
                COALESCE(SUM(GREATEST(0, gap_secs - v_grace_seconds)), 0),
                COALESCE(COUNT(*) FILTER (WHERE gap_secs > v_grace_seconds), 0)
            INTO v_gap_seconds, v_gap_count
            FROM (
                SELECT EXTRACT(EPOCH FROM (
                    ts - LAG(ts) OVER (ORDER BY ts)
                ))::INTEGER AS gap_secs
                FROM (
                    SELECT v_trip.started_at AS ts
                    UNION ALL
                    SELECT gp.captured_at
                    FROM gps_points gp
                    JOIN trip_gps_points tgp ON tgp.gps_point_id = gp.id
                    WHERE tgp.trip_id = v_trip.id
                    UNION ALL
                    SELECT v_trip.ended_at
                ) all_times
            ) gaps
            WHERE gap_secs IS NOT NULL;
        END IF;

        UPDATE trips SET
            gps_gap_seconds = v_gap_seconds,
            gps_gap_count = v_gap_count,
            has_gps_gap = (v_trip.gps_point_count = 0)
        WHERE id = v_trip.id;
    END LOOP;
END;
$$ LANGUAGE plpgsql
SET search_path TO public, extensions;
```

**Step 2: Commit**

```bash
git add supabase/migrations/122_gps_gap_visibility.sql
git commit -m "feat: add compute_gps_gaps function and trip gap columns"
```

---

### Task 2: Add PERFORM call at end of detect_trips

**Files:**
- Modify: `supabase/migrations/122_gps_gap_visibility.sql` (append to same file)

**Step 1: Append detect_trips redefinition to migration**

Copy the ENTIRE `detect_trips` function from `supabase/migrations/119_lower_driving_ghost_threshold.sql` and add one line before the final `END;`:

The only change from migration 119 is adding this block after line 944 (after `PERFORM compute_cluster_effective_types`) and before `END;`:

```sql
    -- =========================================================================
    -- 8. Post-processing: compute GPS gap metrics for clusters and trips
    -- =========================================================================
    PERFORM compute_gps_gaps(p_shift_id);
```

Copy the full function from migration 119 (lines 11-948) into migration 122, inserting the PERFORM line above at the appropriate position (after step 7, before `END;`).

**Important:** The function must be `CREATE OR REPLACE FUNCTION detect_trips(...)` with the exact same signature and return type as migration 119.

**Step 2: Commit**

```bash
git add supabase/migrations/122_gps_gap_visibility.sql
git commit -m "feat: call compute_gps_gaps at end of detect_trips"
```

---

### Task 3: Update get_day_approval_detail to return trip gaps

**Files:**
- Modify: `supabase/migrations/122_gps_gap_visibility.sql` (append)

**Step 1: Append get_day_approval_detail redefinition**

Copy the ENTIRE function from `supabase/migrations/121_exclude_merged_clocks_from_review_count.sql` and make ONE change:

**Line 116-117 (in the TRIPS SELECT)** — change from:
```sql
            NULL::INTEGER AS gps_gap_seconds,
            NULL::INTEGER AS gps_gap_count,
```

to:
```sql
            t.gps_gap_seconds,
            t.gps_gap_count,
```

Everything else stays identical to migration 121.

**Step 2: Commit**

```bash
git add supabase/migrations/122_gps_gap_visibility.sql
git commit -m "feat: return trip gps_gap_seconds/count in approval detail RPC"
```

---

### Task 4: Backfill GPS gaps for existing shifts

**Files:**
- Modify: `supabase/migrations/122_gps_gap_visibility.sql` (append)

**Step 1: Append backfill query**

```sql
-- =========================================================================
-- Backfill: compute GPS gaps for all completed shifts
-- =========================================================================
DO $$
DECLARE
    v_shift RECORD;
    v_count INTEGER := 0;
BEGIN
    FOR v_shift IN
        SELECT id FROM shifts
        WHERE status = 'completed'
        ORDER BY clocked_in_at DESC
    LOOP
        PERFORM compute_gps_gaps(v_shift.id);
        v_count := v_count + 1;
    END LOOP;
    RAISE NOTICE 'Backfilled GPS gaps for % shifts', v_count;
END $$;
```

**Step 2: Commit**

```bash
git add supabase/migrations/122_gps_gap_visibility.sql
git commit -m "feat: backfill GPS gaps for all completed shifts"
```

---

### Task 5: Apply migration to Supabase

**Step 1: Apply the migration**

```bash
cd /Users/cedric/Desktop/PROJECT/TEST/GPS_Tracker
npx supabase db push --project-ref xdyzdclwvhkfwbkrdsiz
```

**Step 2: Verify migration applied**

```sql
-- Check that trips now have gap columns
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_name = 'trips' AND column_name LIKE 'gps_gap%';

-- Check backfill worked — should see non-zero values for some shifts
SELECT COUNT(*) AS trips_with_gaps
FROM trips WHERE gps_gap_seconds > 0;

SELECT COUNT(*) AS clusters_with_gaps
FROM stationary_clusters WHERE gps_gap_seconds > 0;
```

**Step 3: Commit** (nothing to commit, migration was already committed)

---

### Task 6: Dashboard — Summary bar GPS gap metric

**Files:**
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx`

**Step 1: Add GPS gap totals computation**

Find the `useMemo` or area where `processedActivities` is computed. Add a computed value for total GPS gaps. Add this after the existing summary computations (near the top of the component body, near other `useMemo` calls):

```tsx
const gpsGapTotals = useMemo(() => {
  if (!detail?.activities) return { seconds: 0, count: 0 };
  return detail.activities.reduce(
    (acc, a) => ({
      seconds: acc.seconds + (a.gps_gap_seconds ?? 0),
      count: acc.count + (a.gps_gap_count ?? 0),
    }),
    { seconds: 0, count: 0 }
  );
}, [detail?.activities]);
```

**Step 2: Add 5th card to summary bar**

Find the summary bar grid (currently `grid-cols-2 sm:grid-cols-4 gap-4`, around line 579). Make the grid responsive to GPS gap presence:

```tsx
<div className={`grid grid-cols-2 ${gpsGapTotals.seconds > 0 ? 'sm:grid-cols-5' : 'sm:grid-cols-4'} gap-4`}>
  {/* ... existing 4 cards unchanged ... */}

  {gpsGapTotals.seconds > 0 && (
    <div className={`group relative overflow-hidden flex flex-col p-4 rounded-2xl border shadow-sm transition-all hover:shadow-md ${
      gpsGapTotals.seconds >= 300
        ? 'bg-amber-50/50 border-amber-200'
        : 'bg-amber-50/30 border-amber-100'
    }`}>
      <div className={`absolute top-0 right-0 p-3 group-hover:scale-110 transition-transform ${
        gpsGapTotals.seconds >= 300 ? 'text-amber-300/50' : 'text-amber-200/30'
      }`}>
        <AlertTriangle className="h-12 w-12" />
      </div>
      <span className="text-[10px] uppercase tracking-[0.1em] text-amber-700/60 font-bold mb-1">GPS perdu</span>
      <div className="flex items-baseline gap-1 mt-auto">
        <span className={`text-2xl font-black tracking-tight ${
          gpsGapTotals.seconds >= 300 ? 'text-amber-700' : 'text-amber-600'
        }`}>
          {Math.round(gpsGapTotals.seconds / 60)} min
        </span>
      </div>
      <span className="text-[10px] text-amber-600/60 font-medium">
        {gpsGapTotals.count} interruption{gpsGapTotals.count > 1 ? 's' : ''}
      </span>
    </div>
  )}
</div>
```

**Step 3: Commit**

```bash
git add dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "feat: add GPS gap summary card in approvals"
```

---

### Task 7: Dashboard — Per-line GPS gap detail under duration

**Files:**
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx`

**Step 1: Add gap detail under duration in activity rows**

Find the Duration `<td>` in the activity table (around line 945-953). Currently:

```tsx
<td className="px-3 py-3 whitespace-nowrap">
  <div className={`flex items-center gap-1.5 tabular-nums text-xs ${statusConfig.text}`}>
    {isClock ? '—' : formatDurationMinutes(activity.duration_minutes)}
    {((isStop && (activity.gps_gap_seconds ?? 0) > 0) || (isTrip && activity.has_gps_gap)) ? (
      <AlertTriangle className="h-3.5 w-3.5 text-amber-600 animate-pulse" />
    ) : null}
  </div>
</td>
```

Replace with:

```tsx
<td className="px-3 py-3 whitespace-nowrap">
  <div className={`flex items-center gap-1.5 tabular-nums text-xs ${statusConfig.text}`}>
    {isClock ? '—' : formatDurationMinutes(activity.duration_minutes)}
    {((activity.gps_gap_seconds ?? 0) > 0 || (isTrip && activity.has_gps_gap && (activity.gps_gap_seconds ?? 0) === 0)) ? (
      <AlertTriangle className="h-3.5 w-3.5 text-amber-600 animate-pulse" />
    ) : null}
  </div>
  {(activity.gps_gap_seconds ?? 0) > 0 && (
    <div className={`text-[10px] mt-0.5 ${
      (activity.gps_gap_seconds ?? 0) >= 300
        ? 'text-amber-600 font-medium'
        : 'text-muted-foreground'
    }`}>
      {Math.round((activity.gps_gap_seconds ?? 0) / 60)} min perdues ({activity.gps_gap_count ?? 0} gap{(activity.gps_gap_count ?? 0) > 1 ? 's' : ''})
    </div>
  )}
  {isTrip && activity.has_gps_gap && (activity.gps_gap_seconds ?? 0) === 0 && (
    <div className="text-[10px] mt-0.5 text-amber-600 font-medium">
      Sans trace GPS
    </div>
  )}
</td>
```

The logic:
- If `gps_gap_seconds > 0`: show "X min perdues (Y gaps)" — amber if >= 5 min, grey if < 5 min
- If trip has `has_gps_gap = true` but `gps_gap_seconds = 0` (legacy pre-backfill): show "Sans trace GPS"
- The pulsing triangle stays for quick visual scan

**Step 2: Update the trip expand detail GPS gap display**

Find the trip expand detail's GPS gap display (around line 194-198). Currently:

```tsx
{activity.has_gps_gap && (
  <div className="col-span-2 flex items-center gap-2 p-2 mb-2 bg-amber-50 border border-amber-200 rounded text-xs text-amber-700">
    <AlertTriangle className="h-4 w-4 flex-shrink-0" />
    <span>Trajet sans trace GPS — aucune donnée de parcours disponible</span>
  </div>
)}
```

Replace with:

```tsx
{(activity.has_gps_gap || (activity.gps_gap_seconds ?? 0) > 0) && (
  <div className="col-span-2 flex items-center gap-2 p-2 mb-2 bg-amber-50 border border-amber-200 rounded text-xs text-amber-700">
    <AlertTriangle className="h-4 w-4 flex-shrink-0" />
    <span>
      {activity.has_gps_gap && (activity.gps_gap_seconds ?? 0) === 0
        ? 'Trajet sans trace GPS — aucune donnée de parcours disponible'
        : `Signal GPS perdu pendant ${Math.round((activity.gps_gap_seconds ?? 0) / 60)} min (${activity.gps_gap_count ?? 0} interruption${(activity.gps_gap_count ?? 0) > 1 ? 's' : ''})`
      }
    </span>
  </div>
)}
```

**Step 3: Commit**

```bash
git add dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "feat: show GPS gap detail under duration in activity rows"
```

---

### Task 8: Verify on live dashboard

**Step 1: Start the dashboard locally**

```bash
cd /Users/cedric/Desktop/PROJECT/TEST/GPS_Tracker/dashboard
npm run dev
```

**Step 2: Navigate to approvals page**

Open `http://localhost:3000/dashboard/approvals` and:
- Select a week with known data
- Click on a day cell to open the detail sheet
- Verify the 5th summary card appears when GPS gaps exist
- Verify per-line gap details appear under duration
- Verify the expand detail shows gap info for both trips and stops
- Check a day with no gaps — the 5th card should not appear

**Step 3: Commit final state**

```bash
git add -A
git commit -m "feat: GPS gap visibility in approvals — complete"
```
