# Untracked Time Gaps Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Show "Temps non suivi" activity rows in the approval timeline for periods where GPS data is missing, with full approve/reject support.

**Architecture:** Add gap detection as CTEs in `get_day_approval_detail()` SQL function. For each completed shift, walk the timeline from clock-in to clock-out and emit synthetic `'gap'` activities wherever no stop or trip covers a period > 5 minutes. Gaps get deterministic UUIDs so overrides persist. Frontend renders gaps with a distinct dashed style and WifiOff icon.

**Tech Stack:** PostgreSQL (Supabase migration), TypeScript/Next.js (dashboard), shadcn/ui

---

## Task 1: Schema — Allow 'gap' in activity_overrides CHECK constraint

**Files:**
- Create: `supabase/migrations/129_untracked_time_gaps.sql`

**Step 1: Write the ALTER TABLE for the CHECK constraint**

The `activity_overrides` table (migration 093) has:
```sql
activity_type TEXT NOT NULL CHECK (activity_type IN ('trip', 'stop', 'clock_in', 'clock_out'))
```

Add 'gap' to this constraint. Also update the validation in `save_activity_override` (migration 096).

```sql
-- Part 1: Schema — Allow 'gap' activity type in overrides
ALTER TABLE activity_overrides
  DROP CONSTRAINT IF EXISTS activity_overrides_activity_type_check;
ALTER TABLE activity_overrides
  ADD CONSTRAINT activity_overrides_activity_type_check
  CHECK (activity_type IN ('trip', 'stop', 'clock_in', 'clock_out', 'gap'));
```

**Step 2: Update save_activity_override validation**

```sql
CREATE OR REPLACE FUNCTION save_activity_override(
    p_employee_id UUID,
    p_date DATE,
    p_activity_type TEXT,
    p_activity_id UUID,
    p_status TEXT,
    p_reason TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_day_approval_id UUID;
    v_caller UUID := auth.uid();
BEGIN
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can save overrides';
    END IF;

    IF p_status NOT IN ('approved', 'rejected') THEN
        RAISE EXCEPTION 'Invalid override status: %. Must be approved or rejected', p_status;
    END IF;

    -- Updated: added 'gap'
    IF p_activity_type NOT IN ('trip', 'stop', 'clock_in', 'clock_out', 'gap') THEN
        RAISE EXCEPTION 'Invalid activity type: %', p_activity_type;
    END IF;

    IF EXISTS(
        SELECT 1 FROM day_approvals
        WHERE employee_id = p_employee_id AND date = p_date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Cannot override activities on an already approved day';
    END IF;

    INSERT INTO day_approvals (employee_id, date, status)
    VALUES (p_employee_id, p_date, 'pending')
    ON CONFLICT (employee_id, date) DO NOTHING
    RETURNING id INTO v_day_approval_id;

    IF v_day_approval_id IS NULL THEN
        SELECT id INTO v_day_approval_id
        FROM day_approvals
        WHERE employee_id = p_employee_id AND date = p_date;
    END IF;

    INSERT INTO activity_overrides (day_approval_id, activity_type, activity_id, override_status, reason, created_by)
    VALUES (v_day_approval_id, p_activity_type, p_activity_id, p_status, p_reason, v_caller)
    ON CONFLICT (day_approval_id, activity_type, activity_id)
    DO UPDATE SET
        override_status = EXCLUDED.override_status,
        reason = EXCLUDED.reason,
        created_by = EXCLUDED.created_by,
        created_at = now();

    RETURN get_day_approval_detail(p_employee_id, p_date);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

**Step 3: Apply migration to Supabase**

Run: `cd supabase && supabase db push`
Expected: Migration applied successfully

**Step 4: Commit**

```bash
git add supabase/migrations/129_untracked_time_gaps.sql
git commit -m "feat: allow 'gap' activity type in activity_overrides"
```

---

## Task 2: SQL — Add gap detection to get_day_approval_detail

**Files:**
- Modify: `supabase/migrations/129_untracked_time_gaps.sql` (append to same migration)

**Context:** The latest version of `get_day_approval_detail` is in migration 122. It builds activities from 4 sources (stops, trips, clock_in, clock_out) via `activity_data` CTE, then joins overrides in `classified` CTE.

**Step 1: Understand the gap detection algorithm**

For each completed shift on this day:
1. Get shift boundaries: `clocked_in_at` and `clocked_out_at`
2. Get all real activities (stops + trips) that belong to this shift (by `shift_id`)
3. Create timeline events: shift_start, each activity_start, each activity_end, shift_end
4. Order events chronologically
5. For each pair of consecutive events where `event_end_type → event_start_type` (i.e., shift_start→activity_start, activity_end→activity_start, activity_end→shift_end), compute the gap
6. If gap > 300 seconds (5 minutes), emit a `'gap'` activity

**Deterministic ID:** `md5(p_employee_id::TEXT || '/gap/' || gap_started_at::TEXT || '/' || gap_ended_at::TEXT)::UUID`

**Step 2: Write the updated get_day_approval_detail function**

Append to `129_untracked_time_gaps.sql`. The full function is a `CREATE OR REPLACE` that copies the latest version from migration 122, with these changes:

1. **Add `shift_boundaries` CTE** before `activity_data`:
```sql
shift_boundaries AS (
    SELECT s.id AS shift_id, s.clocked_in_at, s.clocked_out_at
    FROM shifts s
    WHERE s.employee_id = p_employee_id
      AND s.clocked_in_at::DATE = p_date
      AND s.status = 'completed'
      AND s.clocked_out_at IS NOT NULL
),
```

2. **After `activity_data` CTE, add gap detection CTEs:**
```sql
-- Only stops and trips (real activities with duration) for gap detection
real_activities AS (
    SELECT ad.shift_id, ad.started_at, ad.ended_at
    FROM activity_data ad
    WHERE ad.activity_type IN ('stop', 'trip')
),
-- Build timeline events per shift and detect gaps via window functions
shift_events AS (
    -- Shift start boundary
    SELECT sb.shift_id, sb.clocked_in_at AS event_time, 0 AS event_order
    FROM shift_boundaries sb
    UNION ALL
    -- Activity start (marks end of potential gap)
    SELECT ra.shift_id, ra.started_at, 2
    FROM real_activities ra
    UNION ALL
    -- Activity end (marks start of potential gap)
    SELECT ra.shift_id, ra.ended_at, 1
    FROM real_activities ra
    UNION ALL
    -- Shift end boundary
    SELECT sb.shift_id, sb.clocked_out_at, 3
    FROM shift_boundaries sb
),
ordered_events AS (
    SELECT
        shift_id,
        event_time,
        event_order,
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
    WHERE e1.event_order IN (0, 1) -- shift_start or activity_end
      AND e2.event_order IN (2, 3) -- activity_start or shift_end
      AND EXTRACT(EPOCH FROM (e2.event_time - e1.event_time)) > 300
),
-- Also handle shifts with zero activities
empty_shift_gaps AS (
    SELECT
        sb.shift_id,
        sb.clocked_in_at AS gap_started_at,
        sb.clocked_out_at AS gap_ended_at,
        EXTRACT(EPOCH FROM (sb.clocked_out_at - sb.clocked_in_at))::INTEGER AS gap_seconds
    FROM shift_boundaries sb
    WHERE NOT EXISTS (
        SELECT 1 FROM real_activities ra WHERE ra.shift_id = sb.shift_id
    )
    AND EXTRACT(EPOCH FROM (sb.clocked_out_at - sb.clocked_in_at)) > 300
),
all_gaps AS (
    SELECT * FROM gap_pairs
    UNION ALL
    SELECT * FROM empty_shift_gaps
),
```

3. **Add `UNION ALL` for gaps inside `activity_data`:**

Actually, better approach: add gaps as a separate CTE and UNION ALL into a new `all_activities` CTE that combines `activity_data` + gaps, then feed that into `classified`. The gap entries:

```sql
gap_activities AS (
    SELECT
        'gap'::TEXT AS activity_type,
        md5(p_employee_id::TEXT || '/gap/' || g.gap_started_at::TEXT || '/' || g.gap_ended_at::TEXT)::UUID AS activity_id,
        g.shift_id,
        g.gap_started_at AS started_at,
        g.gap_ended_at AS ended_at,
        (g.gap_seconds / 60)::INTEGER AS duration_minutes,
        NULL::UUID AS matched_location_id,
        NULL::TEXT AS location_name,
        NULL::TEXT AS location_type,
        NULL::DECIMAL AS latitude,
        NULL::DECIMAL AS longitude,
        0::INTEGER AS gps_gap_seconds,
        0::INTEGER AS gps_gap_count,
        'needs_review'::TEXT AS auto_status,
        'Temps non suivi'::TEXT AS auto_reason,
        NULL::DECIMAL AS distance_km,
        NULL::TEXT AS transport_mode,
        NULL::BOOLEAN AS has_gps_gap,
        NULL::UUID AS start_location_id,
        NULL::TEXT AS start_location_name,
        NULL::TEXT AS start_location_type,
        NULL::UUID AS end_location_id,
        NULL::TEXT AS end_location_name,
        NULL::TEXT AS end_location_type
    FROM all_gaps g
),
all_activity_data AS (
    SELECT * FROM activity_data
    UNION ALL
    SELECT * FROM gap_activities
),
```

4. **Update `classified` CTE** to use `all_activity_data` instead of `activity_data`:
```sql
classified AS (
    SELECT
        ad.*,
        ao.override_status,
        ao.reason AS override_reason,
        COALESCE(ao.override_status, ad.auto_status) AS final_status
    FROM all_activity_data ad  -- <-- changed from activity_data
    LEFT JOIN day_approvals da
        ON da.employee_id = p_employee_id AND da.date = p_date
    LEFT JOIN activity_overrides ao
        ON ao.day_approval_id = da.id
       AND ao.activity_type = ad.activity_type
       AND ao.activity_id = ad.activity_id
    ORDER BY ad.started_at ASC
)
```

5. **No changes needed to summary computation** — gaps with `final_status = 'needs_review'` are already counted. Gaps are NOT clock events, so the merged-clock exclusion doesn't affect them.

**Step 3: Write the complete migration file**

The full migration file includes:
- Part 1: ALTER TABLE for CHECK constraint (from Task 1)
- Part 2: Updated `save_activity_override` (from Task 1)
- Part 3: Updated `get_day_approval_detail` with gap detection (this task)

Write the COMPLETE `get_day_approval_detail` function (copy from migration 122 and add the gap CTEs).

**Step 4: Test with SQL query**

Run against Supabase to verify gaps appear:
```sql
SELECT * FROM get_day_approval_detail('<mario_employee_id>', '2026-03-04');
```

Look for `activity_type = 'gap'` entries. For Mario's March 4 data, expect a gap between ~09:54 and ~11:30.

**Step 5: Commit**

```bash
git add supabase/migrations/129_untracked_time_gaps.sql
git commit -m "feat: add gap detection to get_day_approval_detail"
```

---

## Task 3: TypeScript types — Add 'gap' to activity_type

**Files:**
- Modify: `dashboard/src/types/mileage.ts:230`
- Modify: `dashboard/src/lib/utils/merge-clock-events.ts:9`

**Step 1: Update ApprovalActivity type**

In `dashboard/src/types/mileage.ts`, line 230:
```typescript
// Before:
activity_type: 'trip' | 'stop' | 'clock_in' | 'clock_out';
// After:
activity_type: 'trip' | 'stop' | 'clock_in' | 'clock_out' | 'gap';
```

**Step 2: Update MergeableActivity type**

In `dashboard/src/lib/utils/merge-clock-events.ts`, line 9:
```typescript
// Before:
activity_type: 'trip' | 'stop' | 'clock_in' | 'clock_out';
// After:
activity_type: 'trip' | 'stop' | 'clock_in' | 'clock_out' | 'gap';
```

No logic changes needed in `mergeClockEvents()` — gaps are neither clock events nor stops, so they pass through unchanged.

**Step 3: Verify TypeScript compiles**

Run: `cd dashboard && npx tsc --noEmit`
Expected: No errors

**Step 4: Commit**

```bash
git add dashboard/src/types/mileage.ts dashboard/src/lib/utils/merge-clock-events.ts
git commit -m "feat: add 'gap' to activity_type union"
```

---

## Task 4: Frontend — Render gap activity rows

**Files:**
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx`

**Step 1: Add WifiOff import**

Add `WifiOff` to the lucide-react import (line 13 area):
```typescript
import {
  // ... existing imports ...
  WifiOff,
} from 'lucide-react';
```

**Step 2: Update ApprovalActivityIcon function**

In the `ApprovalActivityIcon` function (~line 87), add gap handling at the top:
```typescript
function ApprovalActivityIcon({ activity }: { activity: ApprovalActivity }) {
  if (activity.activity_type === 'gap') {
    return <WifiOff className="h-4 w-4 text-purple-500" />;
  }
  if (activity.activity_type === 'trip') {
    // ... existing code
```

**Step 3: Update ActivityRow for gap rendering**

In the `ActivityRow` component (~line 853), add gap detection:
```typescript
const isGap = activity.activity_type === 'gap';
```

Update `canExpand` to exclude gaps (nothing to expand into):
```typescript
const canExpand = !isClock && !isGap;
```

In the "Details" cell (~line 1007), add gap rendering:
```typescript
) : isGap ? (
  <div className="space-y-1">
    <div className={`text-xs flex items-center gap-1.5 ${statusConfig.text}`}>
      <WifiOff className="h-3 w-3" />
      <span className="font-bold">Temps non suivi</span>
    </div>
    <span className={`text-[10px] leading-tight italic ${statusConfig.subtext}`}>
      Aucune donnee GPS durant cette periode
    </span>
  </div>
```

Place this after the trip block and before the stop block in the conditional chain:
```typescript
{isTrip ? (
  // ... existing trip rendering
) : isGap ? (
  // ... new gap rendering above
) : isStop ? (
  // ... existing stop rendering
) : isClock ? (
  // ... existing clock rendering
) : null}
```

In the "Horaire" (time range) cell, gaps render normally — `formatTime(started_at)` to `formatTime(ended_at)` works as-is since gaps have both timestamps.

In the "Distance" cell, gaps show `—` (same as stops). This already works since `isTrip` would be false.

**Step 4: Add gap row visual distinction**

Gaps should have a dashed left border to visually distinguish them. In the `statusConfig` for needs_review, the gap row will use the same amber style as other needs_review items. To add a dashed border specifically for gaps, update the `<tr>` className:

```typescript
<tr
  className={`${statusConfig.row} ${isGap ? 'border-l-dashed' : ''} ${canExpand ? 'cursor-pointer' : ''} transition-all duration-200 group border-b border-white/50`}
  onClick={canExpand ? onToggle : undefined}
>
```

Add a Tailwind custom style or use inline style for dashed border:
```typescript
style={isGap ? { borderLeftStyle: 'dashed' } : undefined}
```

**Step 5: Add gap duration to durationStats**

In the `durationStats` memo (~line 394), add gap tracking:
```typescript
const durationStats = useMemo(() => {
    if (!detail) return { totalTravelSeconds: 0, stopByType: {} as Record<string, number>, totalGapSeconds: 0 };
    const trips = detail.activities.filter(a => a.activity_type === 'trip');
    const stops = detail.activities.filter(a => a.activity_type === 'stop');
    const gaps = detail.activities.filter(a => a.activity_type === 'gap');
    const totalTravelSeconds = trips.reduce((sum, t) => sum + (t.duration_minutes || 0) * 60, 0);
    const totalGapSeconds = gaps.reduce((sum, g) => sum + (g.duration_minutes || 0) * 60, 0);
    const stopByType: Record<string, number> = {};
    for (const stop of stops) {
      const key = stop.location_type || '_unmatched';
      stopByType[key] = (stopByType[key] || 0) + (stop.duration_minutes || 0) * 60;
    }
    return { totalTravelSeconds, stopByType, totalGapSeconds };
  }, [detail]);
```

Add a badge in the "Repartition" section after the travel badge:
```typescript
{durationStats.totalGapSeconds > 0 && (
  <span
    className="inline-flex items-center gap-1 rounded-full bg-purple-50 px-2 py-0.5 text-xs font-medium text-purple-700 border border-purple-100"
    title="Temps non suivi"
  >
    <WifiOff className="h-3 w-3" />
    {formatDuration(durationStats.totalGapSeconds)}
  </span>
)}
```

**Step 6: Verify in browser**

Open `https://time.trilogis.ca/dashboard/approvals`, navigate to Mario Leclerc, March 4 2026. Verify:
- Gap row appears between RONA (09:54) and 628-636_Ste-Bernadette (11:30)
- Shows "Temps non suivi" with WifiOff icon
- Has approve/reject buttons
- Duration shows ~1h36min
- Dashed left border distinguishes it from regular activities

**Step 7: Commit**

```bash
git add dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "feat: render untracked time gaps in approval timeline"
```

---

## Task 5: Update weekly summary to include gaps in needs_review_count

**Files:**
- Modify: `supabase/migrations/129_untracked_time_gaps.sql` (append)

**Context:** `get_weekly_approval_summary` (migration 127) computes `live_needs_review_count` for non-approved days by classifying stops and trips directly. It does NOT call `get_day_approval_detail`, so it won't see gaps unless we add gap detection there too.

**Impact:** Without this, a day with only gap items as needs_review would show as "pending" in the weekly view instead of "needs_review". Not blocking but misleading.

**Step 1: Add gap detection to get_weekly_approval_summary**

This mirrors the gap detection from Task 2 but in the weekly summary context. Add gap counting to `live_activity_classification`:

```sql
UNION ALL

-- GAPS (untracked time within shifts)
SELECT
    sb.employee_id,
    sb.clocked_in_at::DATE AS activity_date,
    (g.gap_seconds / 60)::INTEGER AS duration_minutes,
    COALESCE(ao.override_status, 'needs_review') AS final_status
FROM (
    -- Per-shift gap detection (same logic as get_day_approval_detail)
    -- ... inline the shift_events / gap_pairs logic per employee per day
) g
JOIN shift_boundaries sb ON ...
LEFT JOIN day_approvals da ON ...
LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
    AND ao.activity_type = 'gap'
    AND ao.activity_id = md5(sb.employee_id::TEXT || '/gap/' || g.gap_started_at::TEXT || '/' || g.gap_ended_at::TEXT)::UUID
```

**Note:** This is complex to inline. An alternative is to extract gap detection into a reusable helper function. However, for simplicity and to match the existing pattern (weekly summary duplicates classification logic from detail), inline it.

**Step 2: Write the complete updated function**

Copy migration 127's `get_weekly_approval_summary` and add gap classification to `live_activity_classification` CTE.

**Step 3: Apply and test**

Run: `supabase db push`
Verify: Weekly summary shows correct needs_review_count for days with gaps.

**Step 4: Commit**

```bash
git add supabase/migrations/129_untracked_time_gaps.sql
git commit -m "feat: include gaps in weekly summary needs_review_count"
```

---

## Follow-up (not in scope)

- **Gap expand detail:** Show a mini-map with the last known GPS point and where GPS reappeared (if both exist). Deferred — gaps have no GPS data to show.
- **Bulk gap actions:** "Approve all gaps" button for days with many gaps. Evaluate after real-world usage.
- **Notification:** Alert supervisors when employees have significant untracked time (>30 min). Future feature.
