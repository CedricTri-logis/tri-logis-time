# Manual Time Corrections Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow supervisors to edit shift clock-in/out times and segment stationary clusters into independently approvable parts.

**Architecture:** Two new tables (`shift_time_edits`, `cluster_segments`) layered on top of existing immutable data. A helper function `effective_shift_times()` centralizes edited time lookups. Three new RPCs + updates to 5 existing RPCs. Dashboard UI adds edit popovers on clock events and a split modal on stops.

**Tech Stack:** PostgreSQL (Supabase migrations), TypeScript/Next.js (dashboard), shadcn/ui components, Supabase RPC calls.

**Spec:** `docs/superpowers/specs/2026-03-12-manual-time-corrections-design.md`

---

## Chunk 1: Database Foundation

### Task 1: Create migration — tables, helper function, schema changes

**Files:**
- Create: `supabase/migrations/20260312500000_manual_time_corrections.sql`

This single migration creates everything the RPCs will need.

- [ ] **Step 1: Write the migration file**

```sql
-- ============================================================
-- Migration: Manual Time Corrections
-- Tables: shift_time_edits, cluster_segments
-- Helper: effective_shift_times()
-- Schema changes: activity_overrides CHECK, save_activity_override validation
-- ============================================================

-- 1. shift_time_edits table
CREATE TABLE shift_time_edits (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    shift_id UUID NOT NULL REFERENCES shifts(id) ON DELETE CASCADE,
    field TEXT NOT NULL CHECK (field IN ('clocked_in_at', 'clocked_out_at')),
    old_value TIMESTAMPTZ NOT NULL,
    new_value TIMESTAMPTZ NOT NULL,
    reason TEXT,
    changed_by UUID NOT NULL REFERENCES employee_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_shift_time_edits_shift_id ON shift_time_edits(shift_id);
CREATE INDEX idx_shift_time_edits_lookup ON shift_time_edits(shift_id, field, created_at DESC);

ALTER TABLE shift_time_edits ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage shift_time_edits"
    ON shift_time_edits
    FOR ALL
    USING (is_admin_or_super_admin(auth.uid()))
    WITH CHECK (is_admin_or_super_admin(auth.uid()));

-- 2. cluster_segments table
CREATE TABLE cluster_segments (
    id UUID PRIMARY KEY,  -- deterministic: md5(cluster_id || '-' || segment_index)::UUID
    stationary_cluster_id UUID NOT NULL REFERENCES stationary_clusters(id) ON DELETE CASCADE,
    segment_index INT NOT NULL,
    starts_at TIMESTAMPTZ NOT NULL,
    ends_at TIMESTAMPTZ NOT NULL,
    created_by UUID NOT NULL REFERENCES employee_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(stationary_cluster_id, segment_index)
);

CREATE INDEX idx_cluster_segments_cluster ON cluster_segments(stationary_cluster_id);

ALTER TABLE cluster_segments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage cluster_segments"
    ON cluster_segments
    FOR ALL
    USING (is_admin_or_super_admin(auth.uid()))
    WITH CHECK (is_admin_or_super_admin(auth.uid()));

-- 3. Helper function: effective_shift_times
CREATE OR REPLACE FUNCTION effective_shift_times(p_shift_id UUID)
RETURNS TABLE (
    effective_clocked_in_at TIMESTAMPTZ,
    effective_clocked_out_at TIMESTAMPTZ,
    clock_in_edited BOOLEAN,
    clock_out_edited BOOLEAN
) AS $$
    WITH latest_edits AS (
        SELECT DISTINCT ON (field)
            field,
            new_value
        FROM shift_time_edits
        WHERE shift_id = p_shift_id
        ORDER BY field, created_at DESC
    )
    SELECT
        COALESCE(
            (SELECT new_value FROM latest_edits WHERE field = 'clocked_in_at'),
            s.clocked_in_at
        ) AS effective_clocked_in_at,
        COALESCE(
            (SELECT new_value FROM latest_edits WHERE field = 'clocked_out_at'),
            s.clocked_out_at
        ) AS effective_clocked_out_at,
        EXISTS (SELECT 1 FROM latest_edits WHERE field = 'clocked_in_at') AS clock_in_edited,
        EXISTS (SELECT 1 FROM latest_edits WHERE field = 'clocked_out_at') AS clock_out_edited
    FROM shifts s
    WHERE s.id = p_shift_id;
$$ LANGUAGE sql STABLE;

-- 4. Update activity_overrides CHECK constraint to include 'stop_segment'
ALTER TABLE activity_overrides
    DROP CONSTRAINT IF EXISTS activity_overrides_activity_type_check;

ALTER TABLE activity_overrides
    ADD CONSTRAINT activity_overrides_activity_type_check
    CHECK (activity_type IN ('trip', 'stop', 'clock_in', 'clock_out', 'gap', 'lunch_start', 'lunch_end', 'lunch', 'stop_segment'));

-- 5. Update save_activity_override to accept 'stop_segment'
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
    v_caller UUID := auth.uid();
    v_day_approval_id UUID;
    v_result JSONB;
BEGIN
    -- Auth check
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can save overrides';
    END IF;

    -- Validate override status
    IF p_status NOT IN ('approved', 'rejected') THEN
        RAISE EXCEPTION 'Override status must be approved or rejected';
    END IF;

    -- Validate activity type (now includes stop_segment + lunch types)
    IF p_activity_type NOT IN ('trip', 'stop', 'clock_in', 'clock_out', 'gap', 'lunch_start', 'lunch_end', 'lunch', 'stop_segment') THEN
        RAISE EXCEPTION 'Invalid activity type: %', p_activity_type;
    END IF;

    -- Get or create day_approval
    INSERT INTO day_approvals (employee_id, date, status)
    VALUES (p_employee_id, p_date, 'pending')
    ON CONFLICT (employee_id, date) DO NOTHING;

    SELECT id INTO v_day_approval_id
    FROM day_approvals
    WHERE employee_id = p_employee_id AND date = p_date;

    -- Cannot override on approved days
    IF (SELECT status FROM day_approvals WHERE id = v_day_approval_id) = 'approved' THEN
        RAISE EXCEPTION 'Cannot modify overrides on an approved day';
    END IF;

    -- Upsert override
    INSERT INTO activity_overrides (day_approval_id, activity_type, activity_id, override_status, reason, created_by)
    VALUES (v_day_approval_id, p_activity_type, p_activity_id, p_status, p_reason, v_caller)
    ON CONFLICT (day_approval_id, activity_type, activity_id)
    DO UPDATE SET
        override_status = EXCLUDED.override_status,
        reason = EXCLUDED.reason,
        created_by = EXCLUDED.created_by,
        created_at = now();

    -- Return updated day detail
    SELECT get_day_approval_detail(p_employee_id, p_date) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 6. COMMENT ON for new tables
COMMENT ON TABLE shift_time_edits IS 'ROLE: Audit log of supervisor edits to shift clock-in/out times. STATUTS: Append-only — each row is a historical edit. REGLES: Effective value = latest edit by created_at per (shift_id, field). Original shifts table is never modified. RELATIONS: shift_id → shifts(id). TRIGGERS: None.';
COMMENT ON COLUMN shift_time_edits.field IS 'Which shift timestamp was edited: clocked_in_at or clocked_out_at';
COMMENT ON COLUMN shift_time_edits.old_value IS 'The value before this edit (effective value at time of edit, not necessarily original)';
COMMENT ON COLUMN shift_time_edits.new_value IS 'The new effective value after this edit';
COMMENT ON COLUMN shift_time_edits.changed_by IS 'The admin/supervisor who made the edit';

COMMENT ON TABLE cluster_segments IS 'ROLE: Stores segmentation of stationary clusters into independently approvable parts. STATUTS: Segments exist only when a cluster has been split by a supervisor. REGLES: Deterministic IDs via md5(cluster_id || segment_index). Each segment inherits parent auto_status. Overridable via activity_overrides with type stop_segment. RELATIONS: stationary_cluster_id → stationary_clusters(id). TRIGGERS: None.';
COMMENT ON COLUMN cluster_segments.id IS 'Deterministic UUID: md5(cluster_id || - || segment_index)::UUID for stable references';
COMMENT ON COLUMN cluster_segments.segment_index IS 'Order index: 0, 1, 2... from earliest to latest';
```

- [ ] **Step 2: Apply the migration**

Run: `supabase migration apply` (via MCP)
Expected: Migration applies successfully, tables created, helper function available.

- [ ] **Step 3: Verify tables and function exist**

```sql
-- Verify shift_time_edits
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'shift_time_edits' ORDER BY ordinal_position;

-- Verify cluster_segments
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'cluster_segments' ORDER BY ordinal_position;

-- Verify helper function
SELECT effective_shift_times('00000000-0000-0000-0000-000000000000');

-- Verify CHECK constraint
SELECT conname, pg_get_constraintdef(oid)
FROM pg_constraint WHERE conrelid = 'activity_overrides'::regclass AND contype = 'c';
```

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260312500000_manual_time_corrections.sql
git commit -m "feat: add shift_time_edits, cluster_segments tables and effective_shift_times() helper"
```

---

## Chunk 2: New RPCs

### Task 2: Create `edit_shift_time` RPC

**Files:**
- Create: `supabase/migrations/20260312500001_edit_shift_time_rpc.sql`

- [ ] **Step 1: Write the migration**

```sql
CREATE OR REPLACE FUNCTION edit_shift_time(
    p_shift_id UUID,
    p_field TEXT,
    p_new_value TIMESTAMPTZ,
    p_reason TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
    v_employee_id UUID;
    v_shift_record RECORD;
    v_effective RECORD;
    v_current_date DATE;
    v_new_date DATE;
    v_effective_in TIMESTAMPTZ;
    v_effective_out TIMESTAMPTZ;
    v_result JSONB;
BEGIN
    -- Auth
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can edit shift times';
    END IF;

    -- Validate field
    IF p_field NOT IN ('clocked_in_at', 'clocked_out_at') THEN
        RAISE EXCEPTION 'Field must be clocked_in_at or clocked_out_at';
    END IF;

    -- Get shift
    SELECT id, employee_id, clocked_in_at, clocked_out_at, status
    INTO v_shift_record
    FROM shifts
    WHERE id = p_shift_id;

    IF v_shift_record IS NULL THEN
        RAISE EXCEPTION 'Shift not found';
    END IF;

    v_employee_id := v_shift_record.employee_id;

    -- Cannot edit clock_out on active shift
    IF p_field = 'clocked_out_at' AND v_shift_record.status = 'active' THEN
        RAISE EXCEPTION 'Cannot edit clock-out on an active shift';
    END IF;

    -- Get current effective times
    SELECT * INTO v_effective FROM effective_shift_times(p_shift_id);
    v_current_date := to_business_date(v_effective.effective_clocked_in_at);

    -- Check day not approved
    IF EXISTS (
        SELECT 1 FROM day_approvals
        WHERE employee_id = v_employee_id
        AND date = v_current_date
        AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Day is approved. Reopen it before editing shift times.';
    END IF;

    -- Date change guard (clocked_in_at only)
    IF p_field = 'clocked_in_at' THEN
        v_new_date := to_business_date(p_new_value);
        IF v_new_date != v_current_date THEN
            RAISE EXCEPTION 'Edit would move shift to a different day (% → %). Adjust to stay within the same calendar date.', v_current_date, v_new_date;
        END IF;
    END IF;

    -- Temporal consistency: clock_in < clock_out
    IF p_field = 'clocked_in_at' THEN
        v_effective_in := p_new_value;
        v_effective_out := v_effective.effective_clocked_out_at;
    ELSE
        v_effective_in := v_effective.effective_clocked_in_at;
        v_effective_out := p_new_value;
    END IF;

    IF v_effective_out IS NOT NULL AND v_effective_in >= v_effective_out THEN
        RAISE EXCEPTION 'Clock-in must be before clock-out';
    END IF;

    -- Overlap check with other shifts of same employee
    IF EXISTS (
        SELECT 1
        FROM shifts s
        CROSS JOIN LATERAL effective_shift_times(s.id) est
        WHERE s.employee_id = v_employee_id
        AND s.id != p_shift_id
        AND s.status = 'completed'
        AND est.effective_clocked_out_at IS NOT NULL
        AND tstzrange(est.effective_clocked_in_at, est.effective_clocked_out_at) &&
            tstzrange(v_effective_in, v_effective_out)
    ) THEN
        RAISE EXCEPTION 'Edited time would overlap with another shift';
    END IF;

    -- Get old value (effective, not necessarily original)
    DECLARE
        v_old_value TIMESTAMPTZ;
    BEGIN
        IF p_field = 'clocked_in_at' THEN
            v_old_value := v_effective.effective_clocked_in_at;
        ELSE
            v_old_value := v_effective.effective_clocked_out_at;
        END IF;

        -- Insert audit row
        INSERT INTO shift_time_edits (shift_id, field, old_value, new_value, reason, changed_by)
        VALUES (p_shift_id, p_field, v_old_value, p_new_value, p_reason, v_caller);
    END;

    -- Return updated day detail
    SELECT get_day_approval_detail(v_employee_id, v_current_date) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
```

- [ ] **Step 2: Apply migration**

Run via MCP `apply_migration`.

- [ ] **Step 3: Test with a real shift**

```sql
-- Find a completed shift to test with
SELECT id, employee_id, clocked_in_at, clocked_out_at
FROM shifts WHERE status = 'completed' ORDER BY clocked_in_at DESC LIMIT 1;

-- Test effective_shift_times before edit
SELECT * FROM effective_shift_times('<shift_id>');
```

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260312500001_edit_shift_time_rpc.sql
git commit -m "feat: add edit_shift_time RPC with audit trail and validation"
```

---

### Task 3: Create `segment_cluster` and `unsegment_cluster` RPCs

**Files:**
- Create: `supabase/migrations/20260312500002_segment_cluster_rpcs.sql`

- [ ] **Step 1: Write the migration**

```sql
-- ============================================================
-- segment_cluster: Split a stationary cluster into N segments
-- unsegment_cluster: Revert a cluster to its original single block
-- ============================================================

CREATE OR REPLACE FUNCTION segment_cluster(
    p_cluster_id UUID,
    p_cut_points TIMESTAMPTZ[]
)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
    v_cluster RECORD;
    v_employee_id UUID;
    v_date DATE;
    v_cut_points TIMESTAMPTZ[];
    v_segment_start TIMESTAMPTZ;
    v_segment_end TIMESTAMPTZ;
    v_seg_idx INT;
    v_day_approval_id UUID;
    v_result JSONB;
BEGIN
    -- Auth
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can segment clusters';
    END IF;

    -- Get cluster
    SELECT id, employee_id, started_at, ended_at
    INTO v_cluster
    FROM stationary_clusters
    WHERE id = p_cluster_id;

    IF v_cluster IS NULL THEN
        RAISE EXCEPTION 'Stationary cluster not found';
    END IF;

    v_employee_id := v_cluster.employee_id;
    v_date := to_business_date(v_cluster.started_at);

    -- Check day not approved
    IF EXISTS (
        SELECT 1 FROM day_approvals
        WHERE employee_id = v_employee_id AND date = v_date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Day is approved. Reopen it before segmenting.';
    END IF;

    -- Sort and validate cut points
    SELECT array_agg(cp ORDER BY cp) INTO v_cut_points FROM unnest(p_cut_points) cp;

    -- Validate all cut points within bounds
    FOR v_seg_idx IN 1..array_length(v_cut_points, 1) LOOP
        IF v_cut_points[v_seg_idx] <= v_cluster.started_at OR v_cut_points[v_seg_idx] >= v_cluster.ended_at THEN
            RAISE EXCEPTION 'Cut point % is outside cluster bounds [%, %]',
                v_cut_points[v_seg_idx], v_cluster.started_at, v_cluster.ended_at;
        END IF;
    END LOOP;

    -- Validate minimum 1 minute per segment
    v_segment_start := v_cluster.started_at;
    FOR v_seg_idx IN 1..array_length(v_cut_points, 1) LOOP
        IF (v_cut_points[v_seg_idx] - v_segment_start) < INTERVAL '1 minute' THEN
            RAISE EXCEPTION 'Segment % would be less than 1 minute', v_seg_idx - 1;
        END IF;
        v_segment_start := v_cut_points[v_seg_idx];
    END LOOP;
    -- Check last segment
    IF (v_cluster.ended_at - v_segment_start) < INTERVAL '1 minute' THEN
        RAISE EXCEPTION 'Last segment would be less than 1 minute';
    END IF;

    -- Delete existing segments and their overrides
    SELECT id INTO v_day_approval_id
    FROM day_approvals
    WHERE employee_id = v_employee_id AND date = v_date;

    IF v_day_approval_id IS NOT NULL THEN
        -- Delete overrides for existing segments
        DELETE FROM activity_overrides
        WHERE day_approval_id = v_day_approval_id
        AND activity_type = 'stop_segment'
        AND activity_id IN (
            SELECT id FROM cluster_segments WHERE stationary_cluster_id = p_cluster_id
        );

        -- Delete parent cluster override (if any)
        DELETE FROM activity_overrides
        WHERE day_approval_id = v_day_approval_id
        AND activity_type = 'stop'
        AND activity_id = p_cluster_id;
    END IF;

    DELETE FROM cluster_segments WHERE stationary_cluster_id = p_cluster_id;

    -- Create new segments
    v_segment_start := v_cluster.started_at;
    FOR v_seg_idx IN 0..array_length(v_cut_points, 1) LOOP
        IF v_seg_idx < array_length(v_cut_points, 1) THEN
            v_segment_end := v_cut_points[v_seg_idx + 1];
        ELSE
            v_segment_end := v_cluster.ended_at;
        END IF;

        INSERT INTO cluster_segments (id, stationary_cluster_id, segment_index, starts_at, ends_at, created_by)
        VALUES (
            md5(p_cluster_id::TEXT || '-' || v_seg_idx::TEXT)::UUID,
            p_cluster_id,
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

-- ============================================================

CREATE OR REPLACE FUNCTION unsegment_cluster(p_cluster_id UUID)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
    v_cluster RECORD;
    v_employee_id UUID;
    v_date DATE;
    v_day_approval_id UUID;
    v_result JSONB;
BEGIN
    -- Auth
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can unsegment clusters';
    END IF;

    -- Get cluster
    SELECT id, employee_id, started_at
    INTO v_cluster
    FROM stationary_clusters
    WHERE id = p_cluster_id;

    IF v_cluster IS NULL THEN
        RAISE EXCEPTION 'Stationary cluster not found';
    END IF;

    v_employee_id := v_cluster.employee_id;
    v_date := to_business_date(v_cluster.started_at);

    -- Check day not approved
    IF EXISTS (
        SELECT 1 FROM day_approvals
        WHERE employee_id = v_employee_id AND date = v_date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Day is approved. Reopen it before unsegmenting.';
    END IF;

    -- Delete overrides for segments
    SELECT id INTO v_day_approval_id
    FROM day_approvals
    WHERE employee_id = v_employee_id AND date = v_date;

    IF v_day_approval_id IS NOT NULL THEN
        DELETE FROM activity_overrides
        WHERE day_approval_id = v_day_approval_id
        AND activity_type = 'stop_segment'
        AND activity_id IN (
            SELECT id FROM cluster_segments WHERE stationary_cluster_id = p_cluster_id
        );
    END IF;

    -- Delete all segments
    DELETE FROM cluster_segments WHERE stationary_cluster_id = p_cluster_id;

    -- Return updated day detail
    SELECT get_day_approval_detail(v_employee_id, v_date) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
```

- [ ] **Step 2: Apply migration**

Run via MCP `apply_migration`.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260312500002_segment_cluster_rpcs.sql
git commit -m "feat: add segment_cluster and unsegment_cluster RPCs"
```

---

## Chunk 3: Update Existing RPCs

### Task 4: Update `_get_day_approval_detail_base` for segments + edited times

**Files:**
- Create: `supabase/migrations/20260312500003_approval_detail_time_corrections.sql`
- Reference: `supabase/migrations/20260312300000_lunch_rejected_commute_trips.sql` (current version, lines 14-817)

This is the largest task. The function must be rewritten to:
1. Use `effective_shift_times()` in clock_data CTE and shift_boundaries CTE
2. Emit `stop_segment` rows when cluster has segments
3. Union segments into `stop_classified` for trip adjacency
4. Update `needs_review_count` filter to match `'stop_segment'`
5. Add `is_edited`, `original_value` fields to clock activities

- [ ] **Step 1: Read the current `_get_day_approval_detail_base` function**

Find the latest version: `grep -rn 'CREATE OR REPLACE FUNCTION.*_get_day_approval_detail_base' supabase/migrations/ | tail -1`. Currently in `supabase/migrations/20260312300000_lunch_rejected_commute_trips.sql` (around line 14). Read the FULL function body — it's ~800 lines. You MUST understand the exact CTE structure before modifying.

- [ ] **Step 2: Write the migration with the updated function**

Key changes to make (search-and-replace guide for the function body):

**A. Shift query — add effective times:**
Where the function queries shifts, add a lateral join:
```sql
-- Before (in day_shifts or similar CTE):
s.clocked_in_at, s.clocked_out_at

-- After:
CROSS JOIN LATERAL effective_shift_times(s.id) est
-- Use est.effective_clocked_in_at, est.effective_clocked_out_at
-- Add: est.clock_in_edited, est.clock_out_edited
-- Also keep: s.clocked_in_at AS original_clocked_in_at, s.clocked_out_at AS original_clocked_out_at
```

**B. clock_data CTE — add edit indicators:**
```sql
-- Add to SELECT:
est.clock_in_edited AS is_edited,
s.clocked_in_at AS original_value  -- (for clock_in row)
-- And for clock_out:
est.clock_out_edited AS is_edited,
s.clocked_out_at AS original_value
```

**C. stop_classified CTE — union with segments:**
```sql
-- After the existing stop_classified CTE, add:
, segment_data AS (
    SELECT
        cs.id AS activity_id,
        'stop_segment'::TEXT AS activity_type,
        sc.shift_id,
        sc.employee_id,
        cs.starts_at AS started_at,
        cs.ends_at AS ended_at,
        EXTRACT(EPOCH FROM (cs.ends_at - cs.starts_at))::INT AS duration_seconds,
        sc.matched_location_id,
        sc.latitude,
        sc.longitude,
        -- Inherit parent auto_status (copy the EXACT same CASE expression from stop_classified)
        -- ... copy auto_status CASE from stop_classified ...
        -- CRITICAL: The column list MUST exactly match stop_classified for the UNION ALL to work.
        -- Read the stop_classified CTE columns carefully and replicate every column in segment_data.
        -- Include: location_name, location_type, latitude, longitude, matched_location_id, etc.
        ao.override_status,
        ao.reason AS override_reason,
        COALESCE(ao.override_status, /* same auto_status expression */) AS final_status
    FROM cluster_segments cs
    JOIN stationary_clusters sc ON sc.id = cs.stationary_cluster_id
    LEFT JOIN locations l ON l.id = sc.matched_location_id
    LEFT JOIN day_approvals da ON da.employee_id = sc.employee_id
        AND da.date = to_business_date(cs.starts_at)
    LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
        AND ao.activity_type = 'stop_segment'
        AND ao.activity_id = cs.id
    WHERE sc.employee_id = p_employee_id
    AND to_business_date(cs.starts_at) = p_date
)
-- Then in the stop_classified UNION, filter out segmented clusters:
, all_stops AS (
    SELECT * FROM stop_classified
    WHERE activity_id NOT IN (SELECT DISTINCT stationary_cluster_id FROM cluster_segments)
    UNION ALL
    SELECT * FROM segment_data
)
```

**D. shift_boundaries CTE — use effective times:**
```sql
-- Before:
SELECT s.id, s.clocked_in_at AS shift_start, s.clocked_out_at AS shift_end

-- After:
SELECT s.id, est.effective_clocked_in_at AS shift_start, est.effective_clocked_out_at AS shift_end
FROM shifts s
CROSS JOIN LATERAL effective_shift_times(s.id) est
```

**E. needs_review_count filter — add stop_segment:**
```sql
-- Before:
WHERE s->>'activity_type' = 'stop'

-- After:
WHERE s->>'activity_type' IN ('stop', 'stop_segment')
```

**F. Output JSON — add is_edited and original_value fields:**
Add `is_edited` and `original_value` to the activity JSON builder for clock_in/clock_out types.

- [ ] **Step 3: Apply migration**

Run via MCP `apply_migration`.

- [ ] **Step 4: Verify with a test query**

```sql
-- Should return same results as before (no edits/segments exist yet)
SELECT get_day_approval_detail('<employee_id>', '<date>');
```

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260312500003_approval_detail_time_corrections.sql
git commit -m "feat: update _get_day_approval_detail_base for time edits and cluster segments"
```

---

### Task 5: Update `get_day_approval_detail` (independent duplicate)

**Files:**
- Create: `supabase/migrations/20260312500004_day_detail_time_corrections.sql`
- Reference: Find the LATEST migration containing `get_day_approval_detail` by running: `grep -rn 'CREATE OR REPLACE FUNCTION.*get_day_approval_detail' supabase/migrations/ | tail -1`. The latest version is in `supabase/migrations/20260310010000_restore_lunch_in_approvals.sql` (around line 761).

**IMPORTANT:** `get_day_approval_detail` is a **completely separate function** from `_get_day_approval_detail_base`. It has its own inline activity pipeline. Apply the same 6 changes (A-F) from Task 4.

- [ ] **Step 1: Read the current `get_day_approval_detail`**

Find and read the latest version: `grep -rn 'CREATE OR REPLACE FUNCTION.*get_day_approval_detail[^_]' supabase/migrations/ | tail -1` — then read that file.

- [ ] **Step 2: Write the migration with identical changes as Task 4**

Same changes A-F but applied to this function's CTE structure. Pay attention to:
- This function has inline project sessions CTE — leave it unchanged
- The stop/trip classification may differ slightly in structure — adapt accordingly
- Must return `is_edited` and `original_value` in the activity JSON

- [ ] **Step 3: Apply migration**

Run via MCP `apply_migration`.

- [ ] **Step 4: Verify — compare output with base function**

```sql
-- Both should return consistent results
SELECT jsonb_array_length(d->'activities')
FROM (SELECT get_day_approval_detail('<emp>', '<date>') AS d) x;
```

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260312500004_day_detail_time_corrections.sql
git commit -m "feat: update get_day_approval_detail for time edits and cluster segments"
```

---

### Task 6: Update `get_weekly_approval_summary` and `get_weekly_breakdown_totals`

**Files:**
- Create: `supabase/migrations/20260312500005_weekly_rpcs_time_corrections.sql`
- Reference: Find the LATEST migration for each function. Both `get_weekly_approval_summary` and `get_weekly_breakdown_totals` were last rewritten in `supabase/migrations/20260312300000_lunch_rejected_commute_trips.sql` (summary at ~line 823, breakdown at ~line 1343). Always verify by running: `grep -rn 'CREATE OR REPLACE FUNCTION.*get_weekly_approval_summary' supabase/migrations/ | tail -1`

- [ ] **Step 1: Read current functions**

Find and read the latest versions of both functions. Do NOT use stale references — always grep for the latest migration containing each function.

- [ ] **Step 2: Write the migration**

**For `get_weekly_approval_summary`:**
- `day_shifts` CTE: replace `s.clocked_in_at`/`s.clocked_out_at` with `effective_shift_times(s.id)` via LATERAL join. Date grouping uses `to_business_date(est.effective_clocked_in_at)`.
- `day_lunch` CTE: no change (lunches have own timestamps)
- `day_calls_lagged`/`day_call_groups` CTEs: use effective times for callback window detection
- `shift_boundaries` CTE: use effective times for gap detection
- `live_stop_classification` CTE: add `stop_segment` to override lookups
- `live_trip_classification` CTE: join `all_stops` (stops + segments) for adjacency

**For `get_weekly_breakdown_totals`:**
- `classified_stops` CTE: check overrides for both `'stop'` and `'stop_segment'`
- Replace `shifts.clocked_in_at`/`clocked_out_at` with effective times if used in duration calc

- [ ] **Step 3: Apply migration**

Run via MCP `apply_migration`.

- [ ] **Step 4: Verify weekly summary still returns data**

```sql
SELECT jsonb_array_length(get_weekly_approval_summary('2026-03-10'));
```

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260312500005_weekly_rpcs_time_corrections.sql
git commit -m "feat: update weekly approval summary and breakdown for time corrections"
```

---

### Task 6b: Update `approve_day` and `remove_activity_override` for `stop_segment`

**Files:**
- Create: `supabase/migrations/20260312500006_approve_day_segments.sql`
- Reference: Find latest `approve_day` and `remove_activity_override` via grep

The `approve_day` RPC checks that all activities have `final_status != 'needs_review'` before freezing a day. It must also check `stop_segment` activities. Similarly, `remove_activity_override` must accept `'stop_segment'` as a valid type.

- [ ] **Step 1: Find and read current `approve_day` and `remove_activity_override`**

```bash
grep -rn 'CREATE OR REPLACE FUNCTION.*approve_day' supabase/migrations/ | tail -1
grep -rn 'CREATE OR REPLACE FUNCTION.*remove_activity_override' supabase/migrations/ | tail -1
```

Read both functions.

- [ ] **Step 2: Write migration updating both functions**

For `approve_day`:
- In the validation that checks for unresolved activities, ensure `stop_segment` type activities are included in the `needs_review_count` check

For `remove_activity_override`:
- Update its activity type validation to accept `'stop_segment'` (same pattern as `save_activity_override` fix in Task 1)

- [ ] **Step 3: Apply migration**

Run via MCP `apply_migration`.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260312500006_approve_day_segments.sql
git commit -m "feat: update approve_day and remove_activity_override for stop_segment support"
```

---

## Chunk 4: Dashboard — Types and Clock Edit UI

### Task 7: Update TypeScript types

**Files:**
- Modify: `dashboard/src/types/mileage.ts` (lines 249-280 for ApprovalActivity)

- [ ] **Step 1: Update ApprovalActivity interface**

At `dashboard/src/types/mileage.ts`, in the `ApprovalActivity` interface:

1. Add `'stop_segment'` to the `activity_type` union type:
```typescript
activity_type: 'trip' | 'stop' | 'clock_in' | 'clock_out' | 'gap' | 'lunch' | 'stop_segment';
```

2. Add new fields after existing fields (around line 280):
```typescript
is_edited?: boolean;
original_value?: string;  // ISO timestamp of original clock time
```

- [ ] **Step 2: Update MergeableActivity in merge-clock-events.ts**

At `dashboard/src/lib/utils/merge-clock-events.ts`, add `'stop_segment'` to the `MergeableActivity.activity_type` union (line 9):
```typescript
activity_type: 'trip' | 'stop' | 'clock_in' | 'clock_out' | 'gap' | 'lunch' | 'stop_segment';
```

Also at line 74, update the clock-merging filter to treat `stop_segment` like `stop`:
```typescript
// Before:
filtered[j].activity_type !== 'stop'
// After:
filtered[j].activity_type !== 'stop' && filtered[j].activity_type !== 'stop_segment'
```

- [ ] **Step 3: Commit**

```bash
git add dashboard/src/types/mileage.ts
git commit -m "feat: add is_edited and original_value to ApprovalActivity type"
```

---

### Task 8: Clock-in/Clock-out Edit Popover

**Files:**
- Create: `dashboard/src/components/approvals/clock-time-edit-popover.tsx`
- Modify: `dashboard/src/components/approvals/approval-rows.tsx` (ActivityRow, lines 673-967)

- [ ] **Step 1: Create the ClockTimeEditPopover component**

```typescript
// dashboard/src/components/approvals/clock-time-edit-popover.tsx
"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover";
import { Textarea } from "@/components/ui/textarea";
import { Pencil } from "lucide-react";
import { createClient } from "@/lib/supabase/client";

interface ClockTimeEditPopoverProps {
  shiftId: string;
  field: "clocked_in_at" | "clocked_out_at";
  currentTime: string; // ISO string
  originalTime?: string; // ISO string, if already edited
  isEdited: boolean;
  onUpdated: (newDetail: any) => void;
}

export function ClockTimeEditPopover({
  shiftId,
  field,
  currentTime,
  originalTime,
  isEdited,
  onUpdated,
}: ClockTimeEditPopoverProps) {
  const [open, setOpen] = useState(false);
  const [time, setTime] = useState(() => {
    const d = new Date(currentTime);
    return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  });
  const [reason, setReason] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleSave = async () => {
    setLoading(true);
    setError(null);

    // Build new timestamp: same date, new time
    const currentDate = new Date(currentTime);
    const [hours, minutes] = time.split(":").map(Number);
    const newDate = new Date(currentDate);
    newDate.setHours(hours, minutes, 0, 0);

    const supabase = createClient();
    const { data, error: rpcError } = await supabase.rpc("edit_shift_time", {
      p_shift_id: shiftId,
      p_field: field,
      p_new_value: newDate.toISOString(),
      p_reason: reason || null,
    });

    if (rpcError) {
      setError(rpcError.message);
      setLoading(false);
      return;
    }

    setLoading(false);
    setOpen(false);
    setReason("");
    onUpdated(data);
  };

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button variant="ghost" size="icon" className="h-6 w-6 ml-1">
          <Pencil className="h-3 w-3" />
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-64 p-3" align="start">
        <div className="space-y-3">
          <div className="text-sm font-medium">
            {field === "clocked_in_at" ? "Edit Clock-in" : "Edit Clock-out"}
          </div>

          <div>
            <label className="text-xs text-muted-foreground">Time</label>
            <input
              type="time"
              value={time}
              onChange={(e) => setTime(e.target.value)}
              className="w-full rounded-md border px-3 py-1.5 text-sm"
            />
          </div>

          <div>
            <label className="text-xs text-muted-foreground">
              Reason (optional)
            </label>
            <Textarea
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder="e.g. Employee forgot to clock in"
              className="h-16 text-sm"
            />
          </div>

          {error && (
            <div className="text-xs text-destructive">{error}</div>
          )}

          <div className="flex gap-2 justify-end">
            <Button
              variant="outline"
              size="sm"
              onClick={() => setOpen(false)}
              disabled={loading}
            >
              Cancel
            </Button>
            <Button
              size="sm"
              onClick={handleSave}
              disabled={loading}
            >
              {loading ? "Saving..." : "Save"}
            </Button>
          </div>
        </div>
      </PopoverContent>
    </Popover>
  );
}
```

- [ ] **Step 2: Add edit indicator display to ActivityRow**

In `dashboard/src/components/approvals/approval-rows.tsx`, in the `ActivityRow` component (around line 673), find where clock_in/clock_out times are displayed and add:

1. The `ClockTimeEditPopover` button next to the time
2. The struck-through original time when `is_edited` is true
3. A "Modified" badge

```typescript
// Import at top of file:
import { ClockTimeEditPopover } from "./clock-time-edit-popover";
import { Badge } from "@/components/ui/badge";

// In the time display section for clock_in/clock_out activities:
// Where formatTime(activity.started_at) is rendered, wrap it:
{activity.activity_type === 'clock_in' || activity.activity_type === 'clock_out' ? (
  <span className="flex items-center gap-1">
    {activity.is_edited && activity.original_value && (
      <span className="line-through text-muted-foreground text-xs">
        {formatTime(activity.original_value)}
      </span>
    )}
    <span>{formatTime(activity.started_at)}</span>
    {activity.is_edited && (
      <Badge variant="outline" className="text-[10px] px-1 py-0">Modified</Badge>
    )}
    <ClockTimeEditPopover
      shiftId={activity.shift_id}
      field={activity.activity_type === 'clock_in' ? 'clocked_in_at' : 'clocked_out_at'}
      currentTime={activity.started_at}
      originalTime={activity.original_value}
      isEdited={!!activity.is_edited}
      onUpdated={onDetailUpdated}
    />
  </span>
) : (
  <span>{formatTime(activity.started_at)}</span>
)}
```

Note: `onDetailUpdated` is a new callback prop that needs to be threaded from `day-approval-detail.tsx` through to `ActivityRow`. It should call `setDetail(newData)`.

- [ ] **Step 3: Thread `onDetailUpdated` callback**

In `dashboard/src/components/approvals/day-approval-detail.tsx`:
- Add `onDetailUpdated` to the props passed to `<ActivityRow>` (around line 637)
- The callback sets `setDetail(data)` — same pattern as `handleOverride`

```typescript
// In day-approval-detail.tsx, where ActivityRow is rendered:
<ActivityRow
  activity={item}
  onOverride={handleOverride}
  onRemoveOverride={handleRemoveOverride}
  onDetailUpdated={(data: DayApprovalDetail) => setDetail(data)}
  // ... other props
/>
```

- [ ] **Step 4: Verify it builds**

Run: `cd dashboard && npm run build`
Expected: No type errors.

- [ ] **Step 5: Commit**

```bash
git add dashboard/src/components/approvals/clock-time-edit-popover.tsx
git add dashboard/src/components/approvals/approval-rows.tsx
git add dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "feat: add clock-in/clock-out time edit popover in approval detail"
```

---

## Chunk 5: Dashboard — Cluster Segmentation UI

### Task 9: Cluster Segmentation Modal

**Files:**
- Create: `dashboard/src/components/approvals/cluster-segment-modal.tsx`
- Modify: `dashboard/src/components/approvals/approval-rows.tsx` (ActivityRow + MergedLocationRow)

- [ ] **Step 1: Create the ClusterSegmentModal component**

```typescript
// dashboard/src/components/approvals/cluster-segment-modal.tsx
"use client";

import { useState, useMemo } from "react";
import { Button } from "@/components/ui/button";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover";
import { Scissors, X, Undo2 } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { formatTime } from "@/lib/utils/activity-display";

interface ClusterSegmentModalProps {
  clusterId: string;
  startedAt: string;
  endedAt: string;
  isSegmented: boolean; // true if cluster already has segments
  onUpdated: (newDetail: any) => void;
}

export function ClusterSegmentModal({
  clusterId,
  startedAt,
  endedAt,
  isSegmented,
  onUpdated,
}: ClusterSegmentModalProps) {
  const [open, setOpen] = useState(false);
  const [cutPoints, setCutPoints] = useState<string[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const startTime = new Date(startedAt);
  const endTime = new Date(endedAt);

  // Compute default time for new cut point (midpoint of largest segment)
  const addCutPoint = () => {
    const midpoint = new Date((startTime.getTime() + endTime.getTime()) / 2);
    const timeStr = `${String(midpoint.getHours()).padStart(2, "0")}:${String(midpoint.getMinutes()).padStart(2, "0")}`;
    setCutPoints((prev) => [...prev, timeStr]);
  };

  const removeCutPoint = (index: number) => {
    setCutPoints((prev) => prev.filter((_, i) => i !== index));
  };

  const updateCutPoint = (index: number, value: string) => {
    setCutPoints((prev) => prev.map((cp, i) => (i === index ? value : cp)));
  };

  // Preview segments
  const segments = useMemo(() => {
    if (cutPoints.length === 0) return [];

    const cutTimestamps = cutPoints
      .map((cp) => {
        const [h, m] = cp.split(":").map(Number);
        const d = new Date(startedAt);
        d.setHours(h, m, 0, 0);
        return d;
      })
      .sort((a, b) => a.getTime() - b.getTime());

    const result: { start: Date; end: Date; minutes: number }[] = [];
    let segStart = startTime;

    for (const cp of cutTimestamps) {
      result.push({
        start: segStart,
        end: cp,
        minutes: Math.round((cp.getTime() - segStart.getTime()) / 60000),
      });
      segStart = cp;
    }
    result.push({
      start: segStart,
      end: endTime,
      minutes: Math.round((endTime.getTime() - segStart.getTime()) / 60000),
    });

    return result;
  }, [cutPoints, startedAt, endedAt]);

  const handleApply = async () => {
    setLoading(true);
    setError(null);

    const cutTimestamps = cutPoints
      .map((cp) => {
        const [h, m] = cp.split(":").map(Number);
        const d = new Date(startedAt);
        d.setHours(h, m, 0, 0);
        return d.toISOString();
      })
      .sort();

    const supabase = createClient();
    const { data, error: rpcError } = await supabase.rpc("segment_cluster", {
      p_cluster_id: clusterId,
      p_cut_points: cutTimestamps,
    });

    if (rpcError) {
      setError(rpcError.message);
      setLoading(false);
      return;
    }

    setLoading(false);
    setOpen(false);
    setCutPoints([]);
    onUpdated(data);
  };

  const handleUnsegment = async () => {
    setLoading(true);
    setError(null);

    const supabase = createClient();
    const { data, error: rpcError } = await supabase.rpc("unsegment_cluster", {
      p_cluster_id: clusterId,
    });

    if (rpcError) {
      setError(rpcError.message);
      setLoading(false);
      return;
    }

    setLoading(false);
    setOpen(false);
    onUpdated(data);
  };

  // If already segmented, show unsegment button with confirmation
  if (isSegmented) {
    return (
      <Button
        variant="ghost"
        size="icon"
        className="h-6 w-6 ml-1"
        onClick={() => {
          if (window.confirm("Remove segmentation? This will delete all per-segment approvals.")) {
            handleUnsegment();
          }
        }}
        disabled={loading}
        title="Remove segmentation"
      >
        <Undo2 className="h-3 w-3" />
      </Button>
    );
  }

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button variant="ghost" size="icon" className="h-6 w-6 ml-1" title="Split stop">
          <Scissors className="h-3 w-3" />
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-80 p-3" align="start">
        <div className="space-y-3">
          <div className="text-sm font-medium">
            Split Stop ({formatTime(startedAt)} — {formatTime(endedAt)})
          </div>

          {/* Visual bar */}
          <div className="relative h-3 bg-muted rounded-full">
            <div className="absolute inset-0 bg-primary/20 rounded-full" />
            {segments.length > 0 &&
              segments.map((seg, i) => {
                const totalMs = endTime.getTime() - startTime.getTime();
                const leftPct = ((seg.start.getTime() - startTime.getTime()) / totalMs) * 100;
                const widthPct = ((seg.end.getTime() - seg.start.getTime()) / totalMs) * 100;
                return (
                  <div
                    key={i}
                    className="absolute h-full rounded-full border-r-2 border-background"
                    style={{
                      left: `${leftPct}%`,
                      width: `${widthPct}%`,
                      backgroundColor: `hsl(${(i * 60 + 200) % 360}, 50%, 60%)`,
                    }}
                  />
                );
              })}
          </div>

          {/* Cut points */}
          <div className="space-y-2">
            {cutPoints.map((cp, i) => (
              <div key={i} className="flex items-center gap-2">
                <span className="text-xs text-muted-foreground w-12">Cut {i + 1}</span>
                <input
                  type="time"
                  value={cp}
                  onChange={(e) => updateCutPoint(i, e.target.value)}
                  className="flex-1 rounded-md border px-2 py-1 text-sm"
                />
                <Button
                  variant="ghost"
                  size="icon"
                  className="h-6 w-6"
                  onClick={() => removeCutPoint(i)}
                >
                  <X className="h-3 w-3" />
                </Button>
              </div>
            ))}
          </div>

          <Button variant="outline" size="sm" onClick={addCutPoint} className="w-full">
            + Add cut point
          </Button>

          {/* Segment preview */}
          {segments.length > 0 && (
            <div className="space-y-1 text-xs">
              <div className="text-muted-foreground font-medium">Preview:</div>
              {segments.map((seg, i) => (
                <div key={i} className="flex justify-between">
                  <span>
                    Segment {i + 1}/{segments.length}
                  </span>
                  <span>
                    {formatTime(seg.start.toISOString())} — {formatTime(seg.end.toISOString())} ({seg.minutes} min)
                  </span>
                </div>
              ))}
            </div>
          )}

          {error && <div className="text-xs text-destructive">{error}</div>}

          <div className="flex gap-2 justify-end">
            <Button variant="outline" size="sm" onClick={() => setOpen(false)} disabled={loading}>
              Cancel
            </Button>
            <Button size="sm" onClick={handleApply} disabled={loading || cutPoints.length === 0}>
              {loading ? "Applying..." : "Apply"}
            </Button>
          </div>
        </div>
      </PopoverContent>
    </Popover>
  );
}
```

- [ ] **Step 2: Add scissors button to stop activity rows**

In `dashboard/src/components/approvals/approval-rows.tsx`:

```typescript
// Import at top:
import { ClusterSegmentModal } from "./cluster-segment-modal";

// In ActivityRow, for 'stop' activity type, next to duration display:
{activity.activity_type === 'stop' && (
  <ClusterSegmentModal
    clusterId={activity.activity_id}
    startedAt={activity.started_at}
    endedAt={activity.ended_at}
    isSegmented={false}
    onUpdated={onDetailUpdated}
  />
)}

// For 'stop_segment' type, render with sub-index label:
{activity.activity_type === 'stop_segment' && (
  <Badge variant="outline" className="text-[10px] px-1 py-0 ml-1">
    Segment
  </Badge>
)}
```

- [ ] **Step 3: Handle `stop_segment` in activity icon and display**

In `approval-rows.tsx`, update the `ApprovalActivityIcon` function (lines 85-118) to handle `'stop_segment'` the same as `'stop'`.

In `merge-clock-events.ts`, ensure `stop_segment` is treated like `stop` for merging purposes.

In `approval-utils.ts`, ensure `mergeSameLocationGaps` handles `stop_segment` type (groups them separately from parent stops since they have different IDs).

- [ ] **Step 4: Verify it builds**

Run: `cd dashboard && npm run build`
Expected: No type errors.

- [ ] **Step 5: Commit**

```bash
git add dashboard/src/components/approvals/cluster-segment-modal.tsx
git add dashboard/src/components/approvals/approval-rows.tsx
git add dashboard/src/components/approvals/approval-utils.ts
git add dashboard/src/lib/utils/merge-clock-events.ts
git commit -m "feat: add cluster segmentation UI with split modal and segment display"
```

---

## Chunk 6: Integration and Testing

### Task 10: End-to-end verification

- [ ] **Step 1: Test clock-in edit flow**

1. Open dashboard → Approvals → click a pending day with a completed shift
2. Click pencil icon on clock-in time
3. Change time, add reason, save
4. Verify: original time struck-through, new time displayed, "Modified" badge
5. Verify: summary totals recalculated
6. Verify: audit row in `shift_time_edits` table

```sql
SELECT * FROM shift_time_edits ORDER BY created_at DESC LIMIT 5;
```

- [ ] **Step 2: Test clock-out edit flow**

Same as above but for clock-out.

- [ ] **Step 3: Test edit validations**

1. Try editing clock-in to after clock-out → expect error
2. Try editing on an approved day → expect error
3. Try editing clock-in to change business date → expect error

- [ ] **Step 4: Test cluster segmentation flow**

1. Find a stop with duration > 5 minutes in the approval detail
2. Click scissors icon
3. Add a cut point (midpoint)
4. Verify preview shows 2 segments with correct durations
5. Click Apply
6. Verify: 2 segment rows appear in timeline, each with approve/reject buttons
7. Approve one segment, reject the other
8. Verify: summary totals reflect the split

- [ ] **Step 5: Test unsegment flow**

1. Click undo button on a segmented stop
2. Verify: cluster reverts to single row
3. Verify: segment overrides are deleted

- [ ] **Step 6: Test weekly summary reflects changes**

1. Navigate to the weekly approval grid
2. Verify: the day where clock time was edited shows corrected total_shift_minutes
3. Verify: the day where a segment was rejected shows reduced approved_minutes

- [ ] **Step 7: Commit final state**

```bash
git add -A
git commit -m "feat: manual time corrections — complete integration"
```

---

## Task Dependencies

```
Task 1 (DB tables + helper)
  └→ Task 2 (edit_shift_time RPC)
  └→ Task 3 (segment/unsegment RPCs)
  └→ Task 4 (_get_day_approval_detail_base update)
     └→ Task 5 (get_day_approval_detail update)
        └→ Task 6 (weekly RPCs update)
        └→ Task 6b (approve_day + remove_activity_override)
  └→ Task 7 (TypeScript types) ← independent of DB tasks
     └→ Task 8 (Clock edit UI) ← needs Tasks 2, 5, 7
     └→ Task 9 (Segment UI) ← needs Tasks 3, 5, 6b, 7
        └→ Task 10 (E2E verification) ← needs all
```

**Parallelizable:**
- Tasks 2 + 3 (after Task 1)
- Tasks 4 + 7 (after Task 1)
- Tasks 6 + 6b (after Task 5)
- Tasks 8 + 9 (after Tasks 5 + 6b + 7)
