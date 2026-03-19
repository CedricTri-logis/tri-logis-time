# Universal Activity Splitting — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable admins to split any approval activity (stop, trip, gap) into time-bounded segments for independent approval/rejection.

**Architecture:** Single `activity_segments` table replaces `cluster_segments`. Unified `segment_activity`/`unsegment_activity` RPCs. Updated `_get_day_approval_detail_base` with 3 new segment CTEs. Dashboard gets kebab menu (⋮) replacing scissors for cleaner UX.

**Tech Stack:** PostgreSQL/Supabase (migrations), Next.js/TypeScript (dashboard), Tailwind/shadcn (UI)

**Spec:** `docs/superpowers/specs/2026-03-19-universal-activity-splitting-design.md`

---

## Task 1: Database — Table + Constraints

**Files:**
- Create: `supabase/migrations/20260319000001_universal_activity_segments.sql`

- [ ] **Step 1: Write migration — drop `cluster_segments`, create `activity_segments`**

```sql
-- ============================================================
-- Universal Activity Splitting
-- 1. Drop cluster_segments (empty in prod — 0 rows)
-- 2. Create activity_segments (universal table for all types)
-- 3. Update activity_overrides CHECK constraint
-- ============================================================

-- 1. Drop old table
DROP TABLE IF EXISTS cluster_segments;

-- 2. Create universal table
CREATE TABLE activity_segments (
    id              UUID PRIMARY KEY,
    activity_type   TEXT NOT NULL CHECK (activity_type IN ('stop', 'trip', 'gap')),
    activity_id     UUID NOT NULL,
    employee_id     UUID NOT NULL REFERENCES employee_profiles(id),
    segment_index   INT NOT NULL,
    starts_at       TIMESTAMPTZ NOT NULL,
    ends_at         TIMESTAMPTZ NOT NULL,
    created_by      UUID NOT NULL REFERENCES employee_profiles(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(activity_type, activity_id, segment_index),
    CHECK (ends_at > starts_at)
);

CREATE INDEX idx_activity_segments_lookup
    ON activity_segments (activity_type, activity_id);

CREATE INDEX idx_activity_segments_employee_date
    ON activity_segments (employee_id, starts_at);

ALTER TABLE activity_segments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage activity_segments"
    ON activity_segments FOR ALL
    USING (is_admin_or_super_admin(auth.uid()));

COMMENT ON TABLE activity_segments IS 'ROLE: Stores time-bounded segments when an admin splits an approval activity (stop/trip/gap). STATUTS: Each segment gets independent approval via activity_overrides. REGLES: Max 2 cut points (3 segments). Segment minimum 1 minute. Parent activity disappears from approval timeline when segmented. RELATIONS: activity_type+activity_id references the parent (stationary_clusters, trips, or computed gap hash). employee_id denormalized for gap segments (no source table). TRIGGERS: None.';

-- 3. Update activity_overrides CHECK to include trip_segment and gap_segment
ALTER TABLE activity_overrides
    DROP CONSTRAINT IF EXISTS activity_overrides_activity_type_check;

ALTER TABLE activity_overrides
    ADD CONSTRAINT activity_overrides_activity_type_check
    CHECK (activity_type IN ('trip', 'stop', 'clock_in', 'clock_out', 'gap', 'lunch_start', 'lunch_end', 'lunch', 'stop_segment', 'trip_segment', 'gap_segment'));
```

- [ ] **Step 2: Apply migration**

Run: `cd supabase && supabase db push` or apply via Supabase MCP `apply_migration`.

- [ ] **Step 3: Verify table exists and constraint updated**

```sql
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'activity_segments' ORDER BY ordinal_position;

SELECT conname, consrc FROM pg_constraint
WHERE conrelid = 'activity_overrides'::regclass AND conname LIKE '%activity_type%';
```

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260319000001_universal_activity_segments.sql
git commit -m "feat: create activity_segments table, drop cluster_segments"
```

---

## Task 2: Database — `segment_activity` and `unsegment_activity` RPCs

**Files:**
- Modify: `supabase/migrations/20260319000001_universal_activity_segments.sql` (append)

**Reference:** Current `segment_cluster` at `supabase/migrations/20260312500002_segment_cluster_rpcs.sql:6-122`

- [ ] **Step 1: Write `segment_activity` RPC**

Append to migration file. Key differences from `segment_cluster`:
- Accepts `p_activity_type`, resolves bounds per type
- `p_employee_id` / `p_starts_at` / `p_ends_at` for gaps
- Max 2 cut points enforced
- Deletes overrides for both parent type and segment type
- `employee_id` stored in every segment row

```sql
-- ============================================================
-- 4. segment_activity — unified split RPC
-- ============================================================
CREATE OR REPLACE FUNCTION segment_activity(
    p_activity_type TEXT,
    p_activity_id   UUID,
    p_cut_points    TIMESTAMPTZ[],
    p_employee_id   UUID DEFAULT NULL,
    p_starts_at     TIMESTAMPTZ DEFAULT NULL,
    p_ends_at       TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
    v_employee_id UUID;
    v_started_at TIMESTAMPTZ;
    v_ended_at TIMESTAMPTZ;
    v_date DATE;
    v_cut_points TIMESTAMPTZ[];
    v_segment_start TIMESTAMPTZ;
    v_segment_end TIMESTAMPTZ;
    v_seg_idx INT;
    v_day_approval_id UUID;
    v_result JSONB;
    v_segment_type TEXT;
BEGIN
    -- Auth
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can segment activities';
    END IF;

    -- Validate activity type
    IF p_activity_type NOT IN ('stop', 'trip', 'gap') THEN
        RAISE EXCEPTION 'Invalid activity type: %. Must be stop, trip, or gap', p_activity_type;
    END IF;

    -- Max 2 cut points
    IF array_length(p_cut_points, 1) > 2 THEN
        RAISE EXCEPTION 'Maximum 2 cut points allowed (3 segments)';
    END IF;

    -- Resolve bounds and employee_id per type
    IF p_activity_type = 'stop' THEN
        SELECT employee_id, started_at, ended_at
        INTO v_employee_id, v_started_at, v_ended_at
        FROM stationary_clusters WHERE id = p_activity_id;
        IF v_employee_id IS NULL THEN
            RAISE EXCEPTION 'Stationary cluster not found';
        END IF;

    ELSIF p_activity_type = 'trip' THEN
        SELECT employee_id, started_at, ended_at
        INTO v_employee_id, v_started_at, v_ended_at
        FROM trips WHERE id = p_activity_id;
        IF v_employee_id IS NULL THEN
            RAISE EXCEPTION 'Trip not found';
        END IF;

    ELSIF p_activity_type = 'gap' THEN
        IF p_employee_id IS NULL OR p_starts_at IS NULL OR p_ends_at IS NULL THEN
            RAISE EXCEPTION 'Gap segmentation requires p_employee_id, p_starts_at, p_ends_at';
        END IF;
        v_employee_id := p_employee_id;
        v_started_at := p_starts_at;
        v_ended_at := p_ends_at;
    END IF;

    v_date := to_business_date(v_started_at);

    -- Check day not approved
    IF EXISTS (
        SELECT 1 FROM day_approvals
        WHERE employee_id = v_employee_id AND date = v_date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Day is approved. Reopen it before segmenting.';
    END IF;

    -- Sort cut points
    SELECT array_agg(cp ORDER BY cp) INTO v_cut_points FROM unnest(p_cut_points) cp;

    -- Validate all cut points within bounds
    FOR v_seg_idx IN 1..array_length(v_cut_points, 1) LOOP
        IF v_cut_points[v_seg_idx] <= v_started_at OR v_cut_points[v_seg_idx] >= v_ended_at THEN
            RAISE EXCEPTION 'Cut point % is outside activity bounds [%, %]',
                v_cut_points[v_seg_idx], v_started_at, v_ended_at;
        END IF;
    END LOOP;

    -- Validate minimum 1 minute per segment
    v_segment_start := v_started_at;
    FOR v_seg_idx IN 1..array_length(v_cut_points, 1) LOOP
        IF (v_cut_points[v_seg_idx] - v_segment_start) < INTERVAL '1 minute' THEN
            RAISE EXCEPTION 'Segment % would be less than 1 minute', v_seg_idx - 1;
        END IF;
        v_segment_start := v_cut_points[v_seg_idx];
    END LOOP;
    IF (v_ended_at - v_segment_start) < INTERVAL '1 minute' THEN
        RAISE EXCEPTION 'Last segment would be less than 1 minute';
    END IF;

    -- Determine segment type suffix
    v_segment_type := p_activity_type || '_segment';

    -- Delete existing segments and overrides
    SELECT id INTO v_day_approval_id
    FROM day_approvals
    WHERE employee_id = v_employee_id AND date = v_date;

    IF v_day_approval_id IS NOT NULL THEN
        -- Delete overrides for existing segments
        DELETE FROM activity_overrides
        WHERE day_approval_id = v_day_approval_id
          AND activity_type = v_segment_type
          AND activity_id IN (
              SELECT id FROM activity_segments
              WHERE activity_type = p_activity_type AND activity_id = p_activity_id
          );

        -- Delete parent activity override
        DELETE FROM activity_overrides
        WHERE day_approval_id = v_day_approval_id
          AND activity_type = p_activity_type
          AND activity_id = p_activity_id;
    END IF;

    DELETE FROM activity_segments
    WHERE activity_type = p_activity_type AND activity_id = p_activity_id;

    -- Create new segments
    v_segment_start := v_started_at;
    FOR v_seg_idx IN 0..array_length(v_cut_points, 1) LOOP
        IF v_seg_idx < array_length(v_cut_points, 1) THEN
            v_segment_end := v_cut_points[v_seg_idx + 1];
        ELSE
            v_segment_end := v_ended_at;
        END IF;

        INSERT INTO activity_segments (id, activity_type, activity_id, employee_id, segment_index, starts_at, ends_at, created_by)
        VALUES (
            md5(p_activity_type || ':' || p_activity_id::TEXT || ':' || v_seg_idx::TEXT)::UUID,
            p_activity_type,
            p_activity_id,
            v_employee_id,
            v_seg_idx,
            v_segment_start,
            v_segment_end,
            v_caller
        );

        v_segment_start := v_segment_end;
    END LOOP;

    -- Return updated day detail
    SELECT get_day_approval_detail(v_employee_id, v_date) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
```

- [ ] **Step 2: Write `unsegment_activity` RPC**

```sql
-- ============================================================
-- 5. unsegment_activity — unified unsplit RPC
-- ============================================================
CREATE OR REPLACE FUNCTION unsegment_activity(
    p_activity_type TEXT,
    p_activity_id   UUID
)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
    v_employee_id UUID;
    v_date DATE;
    v_day_approval_id UUID;
    v_segment_type TEXT;
    v_result JSONB;
BEGIN
    -- Auth
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can unsegment activities';
    END IF;

    -- Resolve employee_id and date
    IF p_activity_type = 'stop' THEN
        SELECT employee_id, to_business_date(started_at)
        INTO v_employee_id, v_date
        FROM stationary_clusters WHERE id = p_activity_id;

    ELSIF p_activity_type = 'trip' THEN
        SELECT employee_id, to_business_date(started_at)
        INTO v_employee_id, v_date
        FROM trips WHERE id = p_activity_id;

    ELSIF p_activity_type = 'gap' THEN
        -- Gaps have no source table — read from activity_segments
        SELECT employee_id, to_business_date(starts_at)
        INTO v_employee_id, v_date
        FROM activity_segments
        WHERE activity_type = 'gap' AND activity_id = p_activity_id
        LIMIT 1;

    ELSE
        RAISE EXCEPTION 'Invalid activity type: %', p_activity_type;
    END IF;

    IF v_employee_id IS NULL THEN
        RAISE EXCEPTION 'Activity not found';
    END IF;

    -- Check day not approved
    IF EXISTS (
        SELECT 1 FROM day_approvals
        WHERE employee_id = v_employee_id AND date = v_date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Day is approved. Reopen it before unsegmenting.';
    END IF;

    v_segment_type := p_activity_type || '_segment';

    -- Delete overrides for segments
    SELECT id INTO v_day_approval_id
    FROM day_approvals
    WHERE employee_id = v_employee_id AND date = v_date;

    IF v_day_approval_id IS NOT NULL THEN
        DELETE FROM activity_overrides
        WHERE day_approval_id = v_day_approval_id
          AND activity_type = v_segment_type
          AND activity_id IN (
              SELECT id FROM activity_segments
              WHERE activity_type = p_activity_type AND activity_id = p_activity_id
          );
    END IF;

    -- Delete all segments
    DELETE FROM activity_segments
    WHERE activity_type = p_activity_type AND activity_id = p_activity_id;

    -- Return updated day detail
    SELECT get_day_approval_detail(v_employee_id, v_date) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
```

- [ ] **Step 3: Drop old RPCs**

```sql
-- ============================================================
-- 6. Drop old segment RPCs
-- ============================================================
DROP FUNCTION IF EXISTS segment_cluster(UUID, TIMESTAMPTZ[]);
DROP FUNCTION IF EXISTS unsegment_cluster(UUID);
```

- [ ] **Step 4: Apply migration and test RPCs**

Test with a real cluster:
```sql
-- Find a test cluster
SELECT id, employee_id, started_at, ended_at, duration_seconds/60 AS minutes
FROM stationary_clusters
WHERE started_at >= now() - INTERVAL '1 day' AND duration_seconds >= 600
LIMIT 1;

-- Test segment (replace IDs)
SELECT segment_activity('stop', '<cluster_id>', ARRAY['<midpoint_timestamp>']::TIMESTAMPTZ[]);

-- Verify segments exist
SELECT * FROM activity_segments;

-- Test unsegment
SELECT unsegment_activity('stop', '<cluster_id>');

-- Verify cleaned up
SELECT COUNT(*) FROM activity_segments;  -- should be 0
```

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260319000001_universal_activity_segments.sql
git commit -m "feat: add segment_activity/unsegment_activity RPCs, drop old segment_cluster RPCs"
```

---

## Task 3: Database — Update `_get_day_approval_detail_base`

**Files:**
- Modify: `supabase/migrations/20260319000001_universal_activity_segments.sql` (append)

**Reference:** Current function at `supabase/migrations/20260317000005_lunch_rpc_rewrites.sql:708-1660`

This is the largest task. The full function must be rewritten with:
- `stop_segment_data` CTE using `activity_segments` instead of `cluster_segments`
- `trip_segment_data` CTE (new) with GPS point redistribution
- `gap_segment_data` handled in second phase (alongside `v_gaps`)
- Exclusion of segmented parents in `all_stops`, `trip_data`, and `gap_candidates`

- [ ] **Step 1: Read the full current function**

Read `supabase/migrations/20260317000005_lunch_rpc_rewrites.sql` lines 708-1660 to get the complete current implementation.

- [ ] **Step 2: Write the updated function**

Key changes (marked with `-- [CHANGE]` comments):

1. **`segment_data` CTE** (currently lines 887-952): Replace `cluster_segments` with `activity_segments WHERE activity_type = 'stop'`. Column mapping: `stationary_cluster_id` → `activity_id`. Same joins and logic otherwise.

2. **`all_stops` CTE** (currently lines 954-958): Change exclusion filter from `SELECT DISTINCT stationary_cluster_id FROM cluster_segments` to `SELECT activity_id FROM activity_segments WHERE activity_type = 'stop'`.

3. **`trip_data` CTE** (currently starts at line 960): Add exclusion: `AND t.id NOT IN (SELECT activity_id FROM activity_segments WHERE activity_type = 'trip')`.

4. **New `trip_segment_data` CTE**: After `trip_data`, add CTE with GPS point redistribution per segment. Use LATERAL joins for first/last GPS point, distance calculation, and location matching. See spec for full SQL.

5. **`classified` UNION ALL** (currently lines 1321-1400): Add `trip_segment_data` to the union.

6. **Gap exclusion** (currently lines 1553-1595 in `gap_candidates` output): Add filter: `AND md5(...)::UUID NOT IN (SELECT activity_id FROM activity_segments WHERE activity_type = 'gap')`.

7. **New `v_gap_segments` block**: After `v_gaps` computation, query `activity_segments WHERE activity_type = 'gap'` with overrides. Merge into `v_activities`.

8. **Summary computation** (currently lines 1608-1624): Already includes `stop_segment` — verify `trip_segment` and `gap_segment` are counted toward `needs_review_count` (they are, since the filter excludes only `trip`, not `trip_segment`).

- [ ] **Step 3: Apply and test**

```sql
-- Create test segments for a trip
INSERT INTO activity_segments (id, activity_type, activity_id, employee_id, segment_index, starts_at, ends_at, created_by)
SELECT
    md5('trip:' || t.id || ':0')::UUID, 'trip', t.id, t.employee_id, 0, t.started_at, t.started_at + (t.ended_at - t.started_at)/2, t.employee_id
FROM trips t WHERE started_at >= now() - INTERVAL '1 day' LIMIT 1;

-- Call the function, verify trip_segment appears
SELECT a->>'activity_type', a->>'activity_id', a->>'started_at'
FROM jsonb_array_elements(
    (get_day_approval_detail('<employee_id>', '<date>'))->'activities'
) a
WHERE a->>'activity_type' LIKE '%segment%';

-- Clean up
DELETE FROM activity_segments;
```

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260319000001_universal_activity_segments.sql
git commit -m "feat: update _get_day_approval_detail_base for universal segments"
```

---

## Task 4: Database — Update `get_weekly_approval_summary`

**Files:**
- Modify: `supabase/migrations/20260319000001_universal_activity_segments.sql` (append)

**Reference:** Current function at `supabase/migrations/20260317000005_lunch_rpc_rewrites.sql:276-702`. The `live_segment_classification` CTE (lines 397-423) and `live_all_stops` (lines 425-429) reference `cluster_segments`.

- [ ] **Step 1: Rewrite `live_segment_classification` CTE**

Change `FROM cluster_segments cs JOIN stationary_clusters sc ON sc.id = cs.stationary_cluster_id` to `FROM activity_segments aseg JOIN stationary_clusters sc ON sc.id = aseg.activity_id WHERE aseg.activity_type = 'stop'`.

- [ ] **Step 2: Rewrite `live_all_stops` exclusion**

Change `WHERE activity_id NOT IN (SELECT DISTINCT stationary_cluster_id FROM cluster_segments)` to `WHERE activity_id NOT IN (SELECT activity_id FROM activity_segments WHERE activity_type = 'stop')`.

- [ ] **Step 3: Add trip segment and gap segment support to weekly summary**

Add `live_trip_segment_classification` and `live_gap_segment_classification` CTEs. Include them in the summary computation.

- [ ] **Step 4: Apply and verify**

```sql
-- Call weekly summary, verify no errors
SELECT get_weekly_approval_summary('<supervisor_id>', '<week_start_date>');
```

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260319000001_universal_activity_segments.sql
git commit -m "feat: update get_weekly_approval_summary for activity_segments"
```

---

## Task 5: Database — Update `save_activity_override` and `remove_activity_override`

**Files:**
- Modify: `supabase/migrations/20260319000001_universal_activity_segments.sql` (append)

**Reference:** Current `save_activity_override` at `supabase/migrations/20260317000005_lunch_rpc_rewrites.sql:17-80`. Current `remove_activity_override` at `supabase/migrations/20260312500006_approve_day_segments.sql:11-48`.

- [ ] **Step 1: Update `save_activity_override` lunch guard**

The current function only blocks `'lunch'`. No changes needed — it accepts any type that passes the `activity_overrides` CHECK constraint (already updated in Task 1). Verify no explicit type whitelist exists in the function body.

- [ ] **Step 2: Update `remove_activity_override` type validation**

Current function (line 26 of `20260312500006`) validates type includes `'stop_segment'`. Add `'trip_segment'` and `'gap_segment'`:

```sql
CREATE OR REPLACE FUNCTION remove_activity_override(
    p_employee_id UUID,
    p_date DATE,
    p_activity_type TEXT,
    p_activity_id UUID
)
RETURNS JSONB AS $$
-- ... (same body, update type validation to include trip_segment, gap_segment)
```

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260319000001_universal_activity_segments.sql
git commit -m "feat: update override RPCs for trip_segment and gap_segment"
```

---

## Task 6: Frontend — Type Updates

**Files:**
- Modify: `dashboard/src/types/mileage.ts:250` (ApprovalActivity activity_type union)
- Modify: `dashboard/src/lib/utils/merge-clock-events.ts:9` (MergeableActivity activity_type union)

- [ ] **Step 1: Update `ApprovalActivity` type**

In `dashboard/src/types/mileage.ts` line 250, change:
```typescript
activity_type: 'trip' | 'stop' | 'stop_segment' | 'clock_in' | 'clock_out' | 'gap' | 'lunch';
```
to:
```typescript
activity_type: 'trip' | 'stop' | 'stop_segment' | 'trip_segment' | 'gap_segment' | 'clock_in' | 'clock_out' | 'gap' | 'lunch';
```

- [ ] **Step 2: Update `MergeableActivity` type**

In `dashboard/src/lib/utils/merge-clock-events.ts` line 9, change:
```typescript
activity_type: 'trip' | 'stop' | 'stop_segment' | 'clock_in' | 'clock_out' | 'gap' | 'lunch';
```
to:
```typescript
activity_type: 'trip' | 'stop' | 'stop_segment' | 'trip_segment' | 'gap_segment' | 'clock_in' | 'clock_out' | 'gap' | 'lunch';
```

- [ ] **Step 3: Verify build**

Run: `cd dashboard && npm run build`

- [ ] **Step 4: Commit**

```bash
git add dashboard/src/types/mileage.ts dashboard/src/lib/utils/merge-clock-events.ts
git commit -m "feat: add trip_segment and gap_segment to activity type unions"
```

---

## Task 7: Frontend — `ActivitySegmentModal` Component

**Files:**
- Rename: `dashboard/src/components/approvals/cluster-segment-modal.tsx` → `activity-segment-modal.tsx`
- Modify: `dashboard/src/components/approvals/approval-rows.tsx` (update imports)

**Reference:** Current component at `dashboard/src/components/approvals/cluster-segment-modal.tsx` (247 lines)

- [ ] **Step 1: Create `activity-segment-modal.tsx`**

Copy and adapt `cluster-segment-modal.tsx`:
- Rename component to `ActivitySegmentModal`
- Change props interface:
  ```typescript
  interface ActivitySegmentModalProps {
    activityType: 'stop' | 'trip' | 'gap';
    activityId: string;
    startedAt: string;
    endedAt: string;
    isSegmented: boolean;
    employeeId?: string;  // required for gaps
    onUpdated: (newDetail: any) => void;
  }
  ```
- Change RPC call from `segment_cluster` to `segment_activity`:
  ```typescript
  const { data, error } = await supabase.rpc("segment_activity", {
    p_activity_type: activityType,
    p_activity_id: activityId,
    p_cut_points: cutTimestamps,
    ...(activityType === 'gap' ? {
      p_employee_id: employeeId,
      p_starts_at: startedAt,
      p_ends_at: endedAt,
    } : {}),
  });
  ```
- Change unsegment RPC from `unsegment_cluster` to `unsegment_activity`:
  ```typescript
  const { data, error } = await supabase.rpc("unsegment_activity", {
    p_activity_type: activityType,
    p_activity_id: activityId,
  });
  ```

- [ ] **Step 2: Delete old file**

Delete `dashboard/src/components/approvals/cluster-segment-modal.tsx`.

- [ ] **Step 3: Update imports in `approval-rows.tsx`**

Replace `import { ClusterSegmentModal } from './cluster-segment-modal'` with `import { ActivitySegmentModal } from './activity-segment-modal'`.

- [ ] **Step 4: Verify build**

Run: `cd dashboard && npm run build`

- [ ] **Step 5: Commit**

```bash
git add dashboard/src/components/approvals/activity-segment-modal.tsx
git add dashboard/src/components/approvals/approval-rows.tsx
git rm dashboard/src/components/approvals/cluster-segment-modal.tsx
git commit -m "feat: rename ClusterSegmentModal to ActivitySegmentModal, support all activity types"
```

---

## Task 8: Frontend — Kebab Menu + Segment Rendering

**Files:**
- Modify: `dashboard/src/components/approvals/approval-rows.tsx`

**Reference:** Current scissors at lines 855-864, `ApprovalActivityIcon` at lines 91-124, expand chevron at lines 1056-1065

- [ ] **Step 1: Add kebab menu dropdown component**

Add a `RowKebabMenu` component inside `approval-rows.tsx`:

```typescript
function RowKebabMenu({
  activityType,
  activityId,
  startedAt,
  endedAt,
  isSegmented,
  isApproved,
  employeeId,
  onDetailUpdated,
}: {
  activityType: 'stop' | 'trip' | 'gap';
  activityId: string;
  startedAt: string;
  endedAt: string;
  isSegmented: boolean;
  isApproved: boolean;
  employeeId?: string;
  onDetailUpdated: (data: any) => void;
}) {
  // Uses shadcn DropdownMenu
  // Menu items:
  // - "Diviser l'activité" → opens ActivitySegmentModal popover
  // - "Retirer la division" → calls unsegment_activity with confirm
}
```

- [ ] **Step 2: Remove inline scissors from `ActivityRow`**

In `ActivityRow` (around line 855), remove the `ClusterSegmentModal` inline rendering. Replace with nothing — the kebab menu will be in the last column.

- [ ] **Step 3: Add kebab menu to the last column of `ActivityRow`**

Before the expand chevron (line 1056), add the kebab menu for stops, gaps, and segments. Only show when `!isApproved && onDetailUpdated`.

- [ ] **Step 4: Add kebab menu to `TripConnectorRow`**

In `TripConnectorRow` (around line 172-256), add the kebab menu in the last column for trips.

- [ ] **Step 5: Add kebab menu to `MergedLocationRow`**

In `MergedLocationRow`, add the kebab menu for the primary stop.

- [ ] **Step 6: Update `ApprovalActivityIcon`**

In `ApprovalActivityIcon` (lines 91-124), add cases for `trip_segment` and `gap_segment`:
```typescript
if (activity.activity_type === 'trip_segment') {
  // Same as trip icon logic
  return activity.transport_mode === 'walking'
    ? <Footprints className="h-4 w-4 text-blue-500" />
    : <Car className="h-4 w-4 text-blue-500" />;
}
if (activity.activity_type === 'gap_segment') {
  return <WifiOff className="h-4 w-4 text-purple-500" />;
}
```

- [ ] **Step 7: Update segment badge rendering in `ActivityRow`**

Current badge at line 866-868 only shows for `isSegment` (stop_segment). Extend to also show for `trip_segment` and `gap_segment`:
```typescript
const isAnySegment = ['stop_segment', 'trip_segment', 'gap_segment'].includes(activity.activity_type);
```

- [ ] **Step 8: Verify build**

Run: `cd dashboard && npm run build`

- [ ] **Step 9: Commit**

```bash
git add dashboard/src/components/approvals/approval-rows.tsx
git commit -m "feat: add kebab menu for activity splitting, update segment rendering"
```

---

## Task 9: Frontend — Bug Fixes + Processing Pipeline

**Files:**
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx`
- Modify: `dashboard/src/components/approvals/approval-utils.ts`

- [ ] **Step 1: Fix `durationStats` in `day-approval-detail.tsx`**

At line 157, change:
```typescript
const stops = detail.activities.filter(a => a.activity_type === 'stop');
```
to:
```typescript
const stops = detail.activities.filter(a => a.activity_type === 'stop' || a.activity_type === 'stop_segment');
```

- [ ] **Step 2: Fix `visibleNeedsReviewCount`**

At lines 146-151, the current filter excludes `trip`. Verify `trip_segment` is NOT excluded (it should count toward review). Current code:
```typescript
pa.item.activity_type !== 'trip'
```
This correctly excludes `trip` but includes `trip_segment`. No change needed — just verify.

- [ ] **Step 3: Update `mergeSameLocationGaps` in `approval-utils.ts`**

At line 169, the function already handles `stop_segment`. Verify it also handles `trip_segment` and `gap_segment` correctly. These segment types should NOT trigger merge start (they have no `matched_location_id`). Current check:
```typescript
if (pa.item.activity_type !== 'stop' && pa.item.activity_type !== 'stop_segment')
```
This already skips trip_segment and gap_segment (they're not stop/stop_segment), so they'll be emitted as standalone activities. No change needed.

- [ ] **Step 4: Update `nestLunchActivities` in `approval-utils.ts`**

At line 370, add protection for `trip_segment` and `gap_segment`:
```typescript
if (item.type === 'activity' && (
  item.pa.item.activity_type === 'stop_segment' ||
  item.pa.item.activity_type === 'trip_segment' ||
  item.pa.item.activity_type === 'gap_segment'
)) return;
```

- [ ] **Step 5: Verify build**

Run: `cd dashboard && npm run build`

- [ ] **Step 6: Commit**

```bash
git add dashboard/src/components/approvals/day-approval-detail.tsx dashboard/src/components/approvals/approval-utils.ts
git commit -m "fix: include segments in durationStats, protect segments from lunch nesting"
```

---

## Task 10: Integration Testing

- [ ] **Step 1: Test stop splitting end-to-end**

Open dashboard → Approbation → pick an employee day → find a stop → click ⋮ → "Diviser l'activité" → add 1 cut point → "Appliquer". Verify:
- Two `stop_segment` rows appear
- Each has approve/reject buttons
- Each has "Segment" badge
- Original stop is gone
- ⋮ menu on segments shows "Retirer la division"

- [ ] **Step 2: Test unsegment**

Click ⋮ → "Retirer la division" on a segment. Verify original stop reappears.

- [ ] **Step 3: Test gap splitting**

Find a day with a gap (amber "Temps non suivi" row) → ⋮ → "Diviser" → add cut point → Apply. Verify two `gap_segment` rows appear.

- [ ] **Step 4: Test trip splitting**

Find a trip row → ⋮ → "Diviser" → Apply. Verify `trip_segment` rows appear with GPS data.

- [ ] **Step 5: Test approval flow**

After splitting, approve/reject individual segments. Then verify "Approuver la journée" works when all segments are resolved.

- [ ] **Step 6: Final commit**

```bash
git add -A
git commit -m "feat: universal activity splitting - complete implementation"
```
