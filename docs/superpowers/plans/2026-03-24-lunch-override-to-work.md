# Lunch Override to Work — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow supervisors to convert lunch breaks (full or partial) to work time via the existing override + segment system.

**Architecture:** Use `pg_proc`-based string replacement patches for `_get_day_approval_detail_base` and `get_weekly_approval_summary` (to avoid regressing downstream patches). Use full `CREATE OR REPLACE` for `save_activity_override`, `remove_activity_override`, `segment_activity`, and `unsegment_activity` (based on their latest versions from `20260320000000_gap_split_auto_segment_stop.sql`).

**Tech Stack:** PostgreSQL (Supabase migrations), TypeScript/React (Next.js dashboard with shadcn/ui)

**Spec:** `docs/superpowers/specs/2026-03-24-lunch-override-to-work-design.md`

**Important function lineage:**
- `_get_day_approval_detail_base`: base in `20260320000000`, patched by `20260324200000`, `20260324200003`, `20260324200004`, `20260324300000`, `20260326300000`, `20260326600000`, `20260327100000`
- `get_weekly_approval_summary`: base in `20260319100000`, patched by `20260324300000`, `20260326200000`
- `segment_activity`: latest version in `20260320000000` (includes auto-segment overlapping stops)
- `unsegment_activity`: latest version in `20260320000000` (includes auto-created stop cleanup)

---

### Task 1: Migration — CHECK constraints + override/segment RPCs

**Files:**
- Create: `supabase/migrations/20260324400000_lunch_override_support.sql`

- [ ] **Step 1: Create migration with constraint updates**

```sql
-- =============================================================
-- Lunch Override Support
-- Allow supervisors to approve lunch as work (full or partial via segments)
-- =============================================================

-- 1. Update activity_segments CHECK to include 'lunch'
ALTER TABLE activity_segments
    DROP CONSTRAINT IF EXISTS activity_segments_activity_type_check;
ALTER TABLE activity_segments
    ADD CONSTRAINT activity_segments_activity_type_check
    CHECK (activity_type IN ('stop', 'trip', 'gap', 'lunch'));

-- 2. Update activity_overrides CHECK to include 'lunch_segment'
ALTER TABLE activity_overrides
    DROP CONSTRAINT IF EXISTS activity_overrides_activity_type_check;
ALTER TABLE activity_overrides
    ADD CONSTRAINT activity_overrides_activity_type_check
    CHECK (activity_type IN (
        'trip', 'stop', 'clock_in', 'clock_out', 'gap',
        'lunch_start', 'lunch_end', 'lunch',
        'stop_segment', 'trip_segment', 'gap_segment',
        'lunch_segment'
    ));
```

- [ ] **Step 2: Add save_activity_override — remove lunch block + add lunch_segment**

Key changes vs current version (`20260319100000:1886-1948`):
1. Remove the `IF p_activity_type = 'lunch' THEN RAISE EXCEPTION` block
2. Add `'lunch_segment'` to the type whitelist

```sql
-- 3. save_activity_override — remove lunch block, add lunch_segment
CREATE OR REPLACE FUNCTION save_activity_override(
    p_employee_id UUID, p_date DATE, p_activity_type TEXT,
    p_activity_id UUID, p_status TEXT, p_reason TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
    v_day_approval_id UUID;
    v_result JSONB;
BEGIN
    -- NO MORE lunch block — lunch can now be overridden

    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can save overrides';
    END IF;

    IF p_status NOT IN ('approved', 'rejected') THEN
        RAISE EXCEPTION 'Override status must be approved or rejected';
    END IF;

    IF p_activity_type NOT IN (
        'trip', 'stop', 'clock_in', 'clock_out', 'gap',
        'lunch_start', 'lunch_end', 'lunch',
        'stop_segment', 'trip_segment', 'gap_segment',
        'lunch_segment'
    ) THEN
        RAISE EXCEPTION 'Invalid activity type: %', p_activity_type;
    END IF;

    INSERT INTO day_approvals (employee_id, date, status)
    VALUES (p_employee_id, p_date, 'pending')
    ON CONFLICT (employee_id, date) DO NOTHING;

    SELECT id INTO v_day_approval_id
    FROM day_approvals WHERE employee_id = p_employee_id AND date = p_date;

    IF (SELECT status FROM day_approvals WHERE id = v_day_approval_id) = 'approved' THEN
        RAISE EXCEPTION 'Cannot modify overrides on an approved day';
    END IF;

    INSERT INTO activity_overrides (day_approval_id, activity_type, activity_id, override_status, reason, created_by)
    VALUES (v_day_approval_id, p_activity_type, p_activity_id, p_status, p_reason, v_caller)
    ON CONFLICT (day_approval_id, activity_type, activity_id)
    DO UPDATE SET
        override_status = EXCLUDED.override_status,
        reason = EXCLUDED.reason,
        created_by = EXCLUDED.created_by,
        created_at = now();

    SELECT get_day_approval_detail(p_employee_id, p_date) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;
```

- [ ] **Step 3: Add remove_activity_override — add lunch_segment**

Only change vs current (`20260319100000:1951-1988`): add `'lunch_segment'` to the whitelist.

```sql
-- 4. remove_activity_override — add lunch_segment
CREATE OR REPLACE FUNCTION remove_activity_override(
    p_employee_id UUID, p_date DATE, p_activity_type TEXT, p_activity_id UUID
) RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
BEGIN
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can remove overrides';
    END IF;

    IF p_activity_type NOT IN (
        'trip', 'stop', 'clock_in', 'clock_out', 'gap',
        'lunch_start', 'lunch_end', 'lunch',
        'stop_segment', 'trip_segment', 'gap_segment',
        'lunch_segment'
    ) THEN
        RAISE EXCEPTION 'Invalid activity type: %', p_activity_type;
    END IF;

    IF EXISTS(
        SELECT 1 FROM day_approvals
        WHERE employee_id = p_employee_id AND date = p_date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Cannot modify overrides on an already approved day';
    END IF;

    DELETE FROM activity_overrides ao
    USING day_approvals da
    WHERE ao.day_approval_id = da.id
      AND da.employee_id = p_employee_id AND da.date = p_date
      AND ao.activity_type = p_activity_type AND ao.activity_id = p_activity_id;

    RETURN get_day_approval_detail(p_employee_id, p_date);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;
```

- [ ] **Step 4: Add segment_activity — based on `20260320000000` version with lunch support**

Base version: `20260320000000_gap_split_auto_segment_stop.sql:23-287`. Changes:
1. Add `'lunch'` to the valid type check (line 59)
2. Add `ELSIF p_activity_type = 'lunch'` branch after the gap branch (line 91)
All other logic (auto-segment overlapping stops for gaps, etc.) is preserved unchanged.

```sql
-- 5. segment_activity — based on 20260320000000 version + lunch support
CREATE OR REPLACE FUNCTION segment_activity(
    p_activity_type TEXT, p_activity_id UUID, p_cut_points TIMESTAMPTZ[],
    p_employee_id UUID DEFAULT NULL, p_starts_at TIMESTAMPTZ DEFAULT NULL,
    p_ends_at TIMESTAMPTZ DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
    v_employee_id UUID; v_started_at TIMESTAMPTZ; v_ended_at TIMESTAMPTZ;
    v_date DATE; v_cut_points TIMESTAMPTZ[];
    v_segment_start TIMESTAMPTZ; v_segment_end TIMESTAMPTZ; v_seg_idx INT;
    v_day_approval_id UUID; v_result JSONB; v_segment_type TEXT;
    v_stop RECORD; v_stop_seg_start TIMESTAMPTZ; v_stop_seg_end TIMESTAMPTZ;
    v_stop_seg_idx INT; v_clamped_cuts TIMESTAMPTZ[]; v_cp TIMESTAMPTZ;
BEGIN
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can segment activities';
    END IF;

    IF p_activity_type NOT IN ('stop', 'trip', 'gap', 'lunch') THEN
        RAISE EXCEPTION 'Invalid activity type: %. Must be stop, trip, gap, or lunch', p_activity_type;
    END IF;

    IF array_length(p_cut_points, 1) > 2 THEN
        RAISE EXCEPTION 'Maximum 2 cut points allowed (3 segments)';
    END IF;

    IF p_activity_type = 'stop' THEN
        SELECT employee_id, started_at, ended_at INTO v_employee_id, v_started_at, v_ended_at
        FROM stationary_clusters WHERE id = p_activity_id;
        IF v_employee_id IS NULL THEN RAISE EXCEPTION 'Stationary cluster not found'; END IF;
    ELSIF p_activity_type = 'trip' THEN
        SELECT employee_id, started_at, ended_at INTO v_employee_id, v_started_at, v_ended_at
        FROM trips WHERE id = p_activity_id;
        IF v_employee_id IS NULL THEN RAISE EXCEPTION 'Trip not found'; END IF;
    ELSIF p_activity_type = 'gap' THEN
        IF p_employee_id IS NULL OR p_starts_at IS NULL OR p_ends_at IS NULL THEN
            RAISE EXCEPTION 'Gap segmentation requires p_employee_id, p_starts_at, p_ends_at';
        END IF;
        v_employee_id := p_employee_id; v_started_at := p_starts_at; v_ended_at := p_ends_at;
    ELSIF p_activity_type = 'lunch' THEN
        SELECT employee_id, clocked_in_at, clocked_out_at INTO v_employee_id, v_started_at, v_ended_at
        FROM shifts WHERE id = p_activity_id AND is_lunch = true;
        IF v_employee_id IS NULL THEN RAISE EXCEPTION 'Lunch shift not found'; END IF;
    END IF;

    v_date := to_business_date(v_started_at);

    IF EXISTS (SELECT 1 FROM day_approvals WHERE employee_id = v_employee_id AND date = v_date AND status = 'approved') THEN
        RAISE EXCEPTION 'Day is approved. Reopen it before segmenting.';
    END IF;

    SELECT array_agg(cp ORDER BY cp) INTO v_cut_points FROM unnest(p_cut_points) cp;

    FOR v_seg_idx IN 1..array_length(v_cut_points, 1) LOOP
        IF v_cut_points[v_seg_idx] <= v_started_at OR v_cut_points[v_seg_idx] >= v_ended_at THEN
            RAISE EXCEPTION 'Cut point % is outside activity bounds [%, %]', v_cut_points[v_seg_idx], v_started_at, v_ended_at;
        END IF;
    END LOOP;

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

    v_segment_type := p_activity_type || '_segment';

    SELECT id INTO v_day_approval_id FROM day_approvals WHERE employee_id = v_employee_id AND date = v_date;

    IF v_day_approval_id IS NOT NULL THEN
        DELETE FROM activity_overrides WHERE day_approval_id = v_day_approval_id
          AND activity_type = v_segment_type
          AND activity_id IN (SELECT id FROM activity_segments WHERE activity_type = p_activity_type AND activity_id = p_activity_id);
        DELETE FROM activity_overrides WHERE day_approval_id = v_day_approval_id
          AND activity_type = p_activity_type AND activity_id = p_activity_id;
    END IF;

    DELETE FROM activity_segments WHERE activity_type = p_activity_type AND activity_id = p_activity_id;

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
            p_activity_type, p_activity_id, v_employee_id, v_seg_idx,
            v_segment_start, v_segment_end, v_caller
        );
        v_segment_start := v_segment_end;
    END LOOP;

    -- Auto-segment overlapping stops when splitting a gap (preserved from 20260320000000)
    IF p_activity_type = 'gap' THEN
        FOR v_stop IN
            SELECT sc.id, sc.started_at, sc.ended_at
            FROM stationary_clusters sc
            WHERE sc.employee_id = v_employee_id
              AND sc.started_at < v_ended_at AND sc.ended_at > v_started_at
              AND sc.duration_seconds >= 180
              AND sc.id NOT IN (SELECT aseg.activity_id FROM activity_segments aseg WHERE aseg.activity_type = 'stop' AND aseg.auto_created_from IS NULL)
              AND sc.id NOT IN (SELECT aseg.activity_id FROM activity_segments aseg WHERE aseg.activity_type = 'stop' AND aseg.auto_created_from = p_activity_id)
        LOOP
            IF v_day_approval_id IS NOT NULL THEN
                DELETE FROM activity_overrides WHERE day_approval_id = v_day_approval_id
                  AND activity_type = 'stop_segment'
                  AND activity_id IN (SELECT id FROM activity_segments WHERE activity_type = 'stop' AND activity_id = v_stop.id);
                DELETE FROM activity_overrides WHERE day_approval_id = v_day_approval_id
                  AND activity_type = 'stop' AND activity_id = v_stop.id;
            END IF;
            DELETE FROM activity_segments WHERE activity_type = 'stop' AND activity_id = v_stop.id;

            v_clamped_cuts := ARRAY[]::TIMESTAMPTZ[];
            FOREACH v_cp IN ARRAY v_cut_points LOOP
                IF v_cp > v_stop.started_at + INTERVAL '1 minute' AND v_cp < v_stop.ended_at - INTERVAL '1 minute' THEN
                    v_clamped_cuts := array_append(v_clamped_cuts, v_cp);
                END IF;
            END LOOP;

            IF array_length(v_clamped_cuts, 1) IS NOT NULL AND array_length(v_clamped_cuts, 1) > 0 THEN
                v_stop_seg_start := v_stop.started_at;
                v_stop_seg_idx := 0;
                FOR v_seg_idx IN 1..array_length(v_clamped_cuts, 1) LOOP
                    v_stop_seg_end := v_clamped_cuts[v_seg_idx];
                    IF (v_stop_seg_end - v_stop_seg_start) >= INTERVAL '1 minute' THEN
                        INSERT INTO activity_segments (id, activity_type, activity_id, employee_id, segment_index, starts_at, ends_at, created_by, auto_created_from)
                        VALUES (md5('stop:' || v_stop.id::TEXT || ':' || v_stop_seg_idx::TEXT)::UUID,
                            'stop', v_stop.id, v_employee_id, v_stop_seg_idx, v_stop_seg_start, v_stop_seg_end, v_caller, p_activity_id);
                        v_stop_seg_idx := v_stop_seg_idx + 1;
                    END IF;
                    v_stop_seg_start := v_stop_seg_end;
                END LOOP;
                v_stop_seg_end := v_stop.ended_at;
                IF (v_stop_seg_end - v_stop_seg_start) >= INTERVAL '1 minute' THEN
                    INSERT INTO activity_segments (id, activity_type, activity_id, employee_id, segment_index, starts_at, ends_at, created_by, auto_created_from)
                    VALUES (md5('stop:' || v_stop.id::TEXT || ':' || v_stop_seg_idx::TEXT)::UUID,
                        'stop', v_stop.id, v_employee_id, v_stop_seg_idx, v_stop_seg_start, v_stop_seg_end, v_caller, p_activity_id);
                END IF;
            END IF;
        END LOOP;
    END IF;

    SELECT get_day_approval_detail(v_employee_id, v_date) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;
```

- [ ] **Step 5: Add unsegment_activity — based on `20260320000000` version with lunch support**

Base version: `20260320000000_gap_split_auto_segment_stop.sql:290-386`. Only change: add `ELSIF p_activity_type = 'lunch'` branch.

```sql
-- 6. unsegment_activity — based on 20260320000000 version + lunch support
CREATE OR REPLACE FUNCTION unsegment_activity(
    p_activity_type TEXT, p_activity_id UUID
) RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
    v_employee_id UUID; v_date DATE; v_day_approval_id UUID;
    v_segment_type TEXT; v_result JSONB;
BEGIN
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can unsegment activities';
    END IF;

    IF p_activity_type = 'stop' THEN
        SELECT employee_id, to_business_date(started_at) INTO v_employee_id, v_date
        FROM stationary_clusters WHERE id = p_activity_id;
    ELSIF p_activity_type = 'trip' THEN
        SELECT employee_id, to_business_date(started_at) INTO v_employee_id, v_date
        FROM trips WHERE id = p_activity_id;
    ELSIF p_activity_type = 'gap' THEN
        SELECT employee_id, to_business_date(starts_at) INTO v_employee_id, v_date
        FROM activity_segments WHERE activity_type = 'gap' AND activity_id = p_activity_id LIMIT 1;
    ELSIF p_activity_type = 'lunch' THEN
        SELECT employee_id, to_business_date(clocked_in_at) INTO v_employee_id, v_date
        FROM shifts WHERE id = p_activity_id AND is_lunch = true;
    ELSE
        RAISE EXCEPTION 'Invalid activity type: %', p_activity_type;
    END IF;

    IF v_employee_id IS NULL THEN RAISE EXCEPTION 'Activity not found'; END IF;

    IF EXISTS (SELECT 1 FROM day_approvals WHERE employee_id = v_employee_id AND date = v_date AND status = 'approved') THEN
        RAISE EXCEPTION 'Day is approved. Reopen it before unsegmenting.';
    END IF;

    v_segment_type := p_activity_type || '_segment';
    SELECT id INTO v_day_approval_id FROM day_approvals WHERE employee_id = v_employee_id AND date = v_date;

    IF v_day_approval_id IS NOT NULL THEN
        DELETE FROM activity_overrides WHERE day_approval_id = v_day_approval_id
          AND activity_type = v_segment_type
          AND activity_id IN (SELECT id FROM activity_segments WHERE activity_type = p_activity_type AND activity_id = p_activity_id);
        -- Clean up auto-created stop segments when unsegmenting a gap (preserved from 20260320000000)
        IF p_activity_type = 'gap' THEN
            DELETE FROM activity_overrides WHERE day_approval_id = v_day_approval_id
              AND activity_type = 'stop_segment'
              AND activity_id IN (SELECT id FROM activity_segments WHERE auto_created_from = p_activity_id);
        END IF;
    END IF;

    DELETE FROM activity_segments WHERE activity_type = p_activity_type AND activity_id = p_activity_id;
    IF p_activity_type = 'gap' THEN
        DELETE FROM activity_segments WHERE auto_created_from = p_activity_id;
    END IF;

    SELECT get_day_approval_detail(v_employee_id, v_date) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;
```

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/20260324400000_lunch_override_support.sql
git commit -m "feat: add lunch override constraints and RPC support"
```

---

### Task 2: Migration — Patch `_get_day_approval_detail_base` via `pg_proc` string replacement

**Files:**
- Modify: `supabase/migrations/20260324400000_lunch_override_support.sql` (append)

Uses `pg_proc`-based string replacement to avoid regressing downstream patches from migrations `20260324200000` through `20260327100000`.

- [ ] **Step 1: Read the current live function to understand what strings exist**

The current live state (after all patches) has these patterns we need to replace:
- Lunch minutes: `INTO v_lunch_minutes` followed by `FROM shifts s WHERE ... AND s.is_lunch = true` (simple sum, no override awareness)
- Lunch data CTE: `'rejected'::TEXT AS final_status` (hardcoded, no override join)
- Summary approved filter: `a->>''activity_type'' <> ''lunch''` (from `20260326600000` patch)
- Summary rejected filter: `a->>''activity_type'' <> ''lunch''` (from `20260326600000` patch)
- Summary needs_review: `NOT IN (''clock_in'', ''clock_out'', ''lunch'')` (from base)

- [ ] **Step 2: Append pg_proc patch for _get_day_approval_detail_base**

The approach: 5 targeted string replacements + 2 injections for the new lunch_segments CTE and its UNION.

```sql
-- =============================================================
-- 7. Patch _get_day_approval_detail_base via pg_proc
--    Adds: lunch override awareness, lunch_segments CTE, summary fixes
-- =============================================================
DO $patch_detail$
DECLARE
    v_src TEXT;
    v_original TEXT;
BEGIN
    SELECT prosrc INTO v_src
    FROM pg_proc
    WHERE proname = '_get_day_approval_detail_base'
      AND pronamespace = 'public'::regnamespace;

    IF v_src IS NULL THEN
        RAISE EXCEPTION '_get_day_approval_detail_base not found';
    END IF;

    v_original := v_src;

    -- PATCH A: Replace v_lunch_minutes calculation with override-aware version
    -- Find the existing lunch minutes block and replace it
    v_src := replace(v_src,
        'INTO v_lunch_minutes
    FROM shifts s
    WHERE s.employee_id = p_employee_id
      AND s.is_lunch = true
      AND (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date = p_date
      AND s.clocked_out_at IS NOT NULL;',
        'INTO v_lunch_minutes
    FROM shifts s
    LEFT JOIN day_approvals da ON da.employee_id = s.employee_id
        AND da.date = (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date
    LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
        AND ao.activity_type = ''lunch'' AND ao.activity_id = s.id
    WHERE s.employee_id = p_employee_id
      AND s.is_lunch = true
      AND (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date = p_date
      AND s.clocked_out_at IS NOT NULL
      AND COALESCE(ao.override_status, ''rejected'') != ''approved''
      AND s.id NOT IN (SELECT activity_id FROM activity_segments WHERE activity_type = ''lunch'');

    -- Add non-approved segment durations for segmented lunches
    v_lunch_minutes := v_lunch_minutes + COALESCE((
        SELECT SUM(EXTRACT(EPOCH FROM (aseg.ends_at - aseg.starts_at)) / 60)::INTEGER
        FROM activity_segments aseg
        JOIN shifts s2 ON s2.id = aseg.activity_id AND s2.is_lunch = true
        LEFT JOIN day_approvals da2 ON da2.employee_id = aseg.employee_id AND da2.date = p_date
        LEFT JOIN activity_overrides ao2 ON ao2.day_approval_id = da2.id
            AND ao2.activity_type = ''lunch_segment'' AND ao2.activity_id = aseg.id
        WHERE aseg.activity_type = ''lunch''
          AND aseg.employee_id = p_employee_id
          AND (aseg.starts_at AT TIME ZONE ''America/Montreal'')::date = p_date
          AND COALESCE(ao2.override_status, ''rejected'') != ''approved''
    ), 0);'
    );

    -- PATCH B: Replace lunch_data CTE — add override join + exclude segmented parents
    -- Replace the hardcoded final_status line
    v_src := replace(v_src,
        '''rejected''::TEXT AS override_status,
            NULL::TEXT AS override_reason,
            ''rejected''::TEXT AS final_status,',
        'ao.override_status,
            NULL::TEXT AS override_reason,
            COALESCE(ao.override_status, ''rejected'') AS final_status,'
    );

    -- Replace FROM shifts s WHERE (lunch query) to add the override JOIN
    v_src := replace(v_src,
        'FROM shifts s
        WHERE s.employee_id = p_employee_id
          AND s.is_lunch = true
          AND (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date = p_date
          AND s.clocked_out_at IS NOT NULL
    ),',
        'FROM shifts s
        LEFT JOIN day_approvals da ON da.employee_id = s.employee_id
            AND da.date = (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = ''lunch'' AND ao.activity_id = s.id
        WHERE s.employee_id = p_employee_id
          AND s.is_lunch = true
          AND (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date = p_date
          AND s.clocked_out_at IS NOT NULL
          AND s.id NOT IN (SELECT activity_id FROM activity_segments WHERE activity_type = ''lunch'')
    ),
    -- Lunch segments CTE
    lunch_segments AS (
        SELECT
            ''lunch_segment''::TEXT AS activity_type,
            aseg.id AS activity_id,
            s.id AS shift_id,
            aseg.starts_at AS started_at,
            aseg.ends_at AS ended_at,
            (EXTRACT(EPOCH FROM (aseg.ends_at - aseg.starts_at)) / 60)::INTEGER AS duration_minutes,
            NULL::UUID AS matched_location_id,
            NULL::TEXT AS location_name,
            NULL::TEXT AS location_type,
            NULL::DECIMAL AS latitude,
            NULL::DECIMAL AS longitude,
            NULL::INTEGER AS gps_gap_seconds,
            NULL::INTEGER AS gps_gap_count,
            ''rejected''::TEXT AS auto_status,
            ''Pause dîner (non payée)''::TEXT AS auto_reason,
            ao2.override_status,
            NULL::TEXT AS override_reason,
            COALESCE(ao2.override_status, ''rejected'') AS final_status,
            NULL::DECIMAL AS distance_km,
            NULL::DECIMAL AS road_distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type,
            NULL::TEXT AS shift_type,
            NULL::TEXT AS shift_type_source,
            FALSE AS is_edited,
            NULL::TIMESTAMPTZ AS original_value,
            NULL::JSONB AS children
        FROM activity_segments aseg
        JOIN shifts s ON s.id = aseg.activity_id AND s.is_lunch = true
        LEFT JOIN day_approvals da2 ON da2.employee_id = aseg.employee_id AND da2.date = p_date
        LEFT JOIN activity_overrides ao2 ON ao2.day_approval_id = da2.id
            AND ao2.activity_type = ''lunch_segment'' AND ao2.activity_id = aseg.id
        WHERE aseg.activity_type = ''lunch''
          AND aseg.employee_id = p_employee_id
          AND (aseg.starts_at AT TIME ZONE ''America/Montreal'')::date = p_date
    ),'
    );

    -- PATCH C: Add lunch_segments to the combined activities UNION
    -- Insert before the lunch_data SELECT in the UNION
    v_src := replace(v_src,
        'SELECT activity_type, activity_id, shift_id, started_at, ended_at, duration_minutes,
               matched_location_id, location_name, location_type, latitude, longitude,
               gps_gap_seconds, gps_gap_count, auto_status, auto_reason,
               override_status, override_reason, final_status,
               distance_km, road_distance_km, transport_mode, has_gps_gap,
               start_location_id, start_location_name, start_location_type,
               end_location_id, end_location_name, end_location_type,
               shift_type, shift_type_source, is_edited, original_value, children
        FROM lunch_data',
        'SELECT activity_type, activity_id, shift_id, started_at, ended_at, duration_minutes,
               matched_location_id, location_name, location_type, latitude, longitude,
               gps_gap_seconds, gps_gap_count, auto_status, auto_reason,
               override_status, override_reason, final_status,
               distance_km, road_distance_km, transport_mode, has_gps_gap,
               start_location_id, start_location_name, start_location_type,
               end_location_id, end_location_name, end_location_type,
               shift_type, shift_type_source, is_edited, original_value, children
        FROM lunch_segments
        UNION ALL
        SELECT activity_type, activity_id, shift_id, started_at, ended_at, duration_minutes,
               matched_location_id, location_name, location_type, latitude, longitude,
               gps_gap_seconds, gps_gap_count, auto_status, auto_reason,
               override_status, override_reason, final_status,
               distance_km, road_distance_km, transport_mode, has_gps_gap,
               start_location_id, start_location_name, start_location_type,
               end_location_id, end_location_name, end_location_type,
               shift_type, shift_type_source, is_edited, original_value, children
        FROM lunch_data'
    );

    -- PATCH D: Update summary — remove lunch exclusion from approved/rejected
    -- Current (post-gap-inclusion patch): a->>'activity_type' <> 'lunch'
    -- New: no exclusion (lunch/lunch_segment now counted when approved)
    v_src := replace(v_src,
        'a->>''activity_type'' <> ''lunch'')',
        '1=1)'
    );

    -- PATCH E: Update needs_review — add lunch_segment to exclusion
    v_src := replace(v_src,
        'NOT IN (''clock_in'', ''clock_out'', ''lunch'')',
        'NOT IN (''clock_in'', ''clock_out'', ''lunch'', ''lunch_segment'')'
    );

    IF v_src = v_original THEN
        RAISE NOTICE 'No changes made — patterns not found (may already be patched)';
        RETURN;
    END IF;

    EXECUTE format(
        'CREATE OR REPLACE FUNCTION _get_day_approval_detail_base(p_employee_id UUID, p_date DATE) RETURNS JSONB AS %s LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions',
        quote_literal(v_src)
    );

    RAISE NOTICE 'Patched _get_day_approval_detail_base for lunch override support';
END;
$patch_detail$;
```

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260324400000_lunch_override_support.sql
git commit -m "feat: patch _get_day_approval_detail_base for lunch overrides"
```

---

### Task 3: Migration — Patch `get_weekly_approval_summary` via `pg_proc`

**Files:**
- Modify: `supabase/migrations/20260324400000_lunch_override_support.sql` (append)

- [ ] **Step 1: Read the current day_lunch CTE pattern**

The current live `get_weekly_approval_summary` function has a `day_lunch` CTE that does a simple sum from `shifts WHERE is_lunch = true`. We need to replace it with an override-aware version.

- [ ] **Step 2: Append pg_proc patch for get_weekly_approval_summary**

```sql
-- =============================================================
-- 8. Patch get_weekly_approval_summary — override-aware day_lunch
-- =============================================================
DO $patch_weekly$
DECLARE
    v_src TEXT;
    v_original TEXT;
BEGIN
    SELECT prosrc INTO v_src
    FROM pg_proc
    WHERE proname = 'get_weekly_approval_summary'
      AND pronamespace = 'public'::regnamespace;

    IF v_src IS NULL THEN
        RAISE EXCEPTION 'get_weekly_approval_summary not found';
    END IF;

    v_original := v_src;

    -- Replace simple day_lunch CTE with override-aware version
    v_src := replace(v_src,
        'day_lunch AS (
        SELECT
            s.employee_id,
            (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date AS lunch_date,
            COALESCE(SUM(EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at))::INTEGER / 60), 0) AS lunch_minutes
        FROM shifts s
        WHERE s.is_lunch = true AND s.clocked_out_at IS NOT NULL
          AND (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date BETWEEN p_week_start AND v_week_end
          AND s.employee_id IN (SELECT employee_id FROM employee_list)
        GROUP BY s.employee_id, (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date
    ),',
        'day_lunch AS (
        SELECT
            s.employee_id,
            (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date AS lunch_date,
            COALESCE(SUM(
                CASE
                    WHEN EXISTS (SELECT 1 FROM activity_segments aseg WHERE aseg.activity_type = ''lunch'' AND aseg.activity_id = s.id)
                        THEN 0
                    WHEN COALESCE(ao.override_status, ''rejected'') = ''approved''
                        THEN 0
                    ELSE EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at))::INTEGER / 60
                END
            ), 0)
            + COALESCE((
                SELECT SUM(EXTRACT(EPOCH FROM (aseg2.ends_at - aseg2.starts_at))::INTEGER / 60)
                FROM activity_segments aseg2
                JOIN shifts s2 ON s2.id = aseg2.activity_id AND s2.is_lunch = true AND s2.employee_id = s.employee_id
                LEFT JOIN day_approvals da2 ON da2.employee_id = aseg2.employee_id
                    AND da2.date = (aseg2.starts_at AT TIME ZONE ''America/Montreal'')::date
                LEFT JOIN activity_overrides ao2 ON ao2.day_approval_id = da2.id
                    AND ao2.activity_type = ''lunch_segment'' AND ao2.activity_id = aseg2.id
                WHERE aseg2.activity_type = ''lunch''
                  AND (aseg2.starts_at AT TIME ZONE ''America/Montreal'')::date = (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date
                  AND COALESCE(ao2.override_status, ''rejected'') != ''approved''
            ), 0) AS lunch_minutes
        FROM shifts s
        LEFT JOIN day_approvals da ON da.employee_id = s.employee_id
            AND da.date = (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = ''lunch'' AND ao.activity_id = s.id
        WHERE s.is_lunch = true AND s.clocked_out_at IS NOT NULL
          AND (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date BETWEEN p_week_start AND v_week_end
          AND s.employee_id IN (SELECT employee_id FROM employee_list)
        GROUP BY s.employee_id, (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date
    ),'
    );

    IF v_src = v_original THEN
        RAISE NOTICE 'No changes made to get_weekly_approval_summary';
        RETURN;
    END IF;

    EXECUTE format(
        'CREATE OR REPLACE FUNCTION get_weekly_approval_summary(p_week_start DATE) RETURNS JSONB AS %s LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions',
        quote_literal(v_src)
    );

    RAISE NOTICE 'Patched get_weekly_approval_summary for lunch override support';
END;
$patch_weekly$;
```

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260324400000_lunch_override_support.sql
git commit -m "feat: patch weekly summary for lunch override support"
```

---

### Task 4: Dashboard — TypeScript types + ActivitySegmentModal lunch support

**Files:**
- Modify: `dashboard/src/types/mileage.ts:250` — add `'lunch_segment'`
- Modify: `dashboard/src/components/approvals/activity-segment-modal.tsx:21,30-34` — add `'lunch'`

- [ ] **Step 1: Add 'lunch_segment' to ApprovalActivity type**

At `dashboard/src/types/mileage.ts:250`:
```typescript
// Before:
activity_type: 'trip' | 'stop' | 'stop_segment' | 'trip_segment' | 'gap_segment' | 'clock_in' | 'clock_out' | 'gap' | 'lunch';
// After:
activity_type: 'trip' | 'stop' | 'stop_segment' | 'trip_segment' | 'gap_segment' | 'lunch_segment' | 'clock_in' | 'clock_out' | 'gap' | 'lunch';
```

Note: Do NOT modify line 164 (`ActivityItemBase`) — it doesn't include any segment types, so `lunch_segment` shouldn't be added there either.

- [ ] **Step 2: Add 'lunch' to ActivitySegmentModal**

At `dashboard/src/components/approvals/activity-segment-modal.tsx:21`:
```typescript
activityType: 'stop' | 'trip' | 'gap' | 'lunch';
```

At line 30-34, add lunch entry:
```typescript
const TITLE_MAP: Record<ActivitySegmentModalProps['activityType'], string> = {
  stop: "Diviser l'arrêt",
  trip: "Diviser le trajet",
  gap: "Diviser le temps non suivi",
  lunch: "Diviser la pause dîner",
};
```

No other changes needed — the RPC call at line 115 doesn't need extra params for lunch (unlike gap).

- [ ] **Step 3: Commit**

```bash
git add dashboard/src/types/mileage.ts dashboard/src/components/approvals/activity-segment-modal.tsx
git commit -m "feat: add lunch_segment type and lunch support in segment modal"
```

---

### Task 5: Dashboard — `LunchGroupRow` approve + split buttons

**Files:**
- Modify: `dashboard/src/components/approvals/approval-rows.tsx:1122-1237`

- [ ] **Step 1: Add Button import if not present**

Check if `Button` is already imported from `@/components/ui/button`. If not, add it. `CheckCircle2` is already imported (line 6).

- [ ] **Step 2: Update LunchGroupRow `<tr>` to be green when approved**

Replace the static class at line 1155:
```tsx
// Before:
className="bg-slate-50/80 border-l-4 border-l-slate-300 hover:bg-slate-100/80 cursor-pointer transition-all duration-200 group border-b border-white/50"
// After:
className={`${activity.final_status === 'approved' ? 'bg-green-50/60 border-l-4 border-l-green-400' : 'bg-slate-50/80 border-l-4 border-l-slate-300'} hover:bg-slate-100/80 cursor-pointer transition-all duration-200 group border-b border-white/50`}
```

- [ ] **Step 3: Replace action cell (first `<td>`) with approve button**

Replace lines 1158-1166 (the static "Pause" badge) with:
```tsx
<td className="px-3 py-3 text-center" onClick={(e) => e.stopPropagation()}>
  {isApproved ? (
    <Badge variant="outline" className="font-bold text-[10px] px-2.5 py-0.5 rounded-full bg-slate-100 text-slate-600 border-slate-200">
      <UtensilsCrossed className="h-3 w-3 mr-1" />Pause
    </Badge>
  ) : (
    <div className="flex items-center justify-center gap-1">
      <Button variant="ghost" size="sm"
        className={`h-7 px-2 text-[10px] rounded-full transition-all ${
          activity.final_status === 'approved'
            ? 'bg-green-100 text-green-700 ring-1 ring-green-300'
            : 'text-muted-foreground hover:text-green-600 hover:bg-green-50'
        }`}
        onClick={() => onOverride(activity, 'approved')}
        disabled={isSaving}
      >
        <CheckCircle2 className="h-3 w-3 mr-1" />
        {activity.final_status === 'approved' ? 'Travail' : 'Approuver'}
      </Button>
    </div>
  )}
</td>
```

- [ ] **Step 4: Add "Converti en travail" badge in details cell**

After the "Pause dîner" label (around line 1194), add:
```tsx
{activity.final_status === 'approved' && (
  <Badge className="ml-1 bg-green-100 text-green-700 text-[9px] px-1.5 py-0 font-bold border-green-200">
    Converti en travail
  </Badge>
)}
```

- [ ] **Step 5: Add scissors button in expand/chevron cell**

Replace the last `<td>` (lines 1228-1237) with:
```tsx
<td className="px-3 py-3 text-center">
  <div className="flex items-center justify-center gap-0.5">
    {!isApproved && onDetailUpdated && (
      <span onClick={(e) => e.stopPropagation()}>
        <ActivitySegmentModal
          activityType="lunch"
          activityId={activity.activity_id}
          startedAt={activity.started_at}
          endedAt={activity.ended_at}
          isSegmented={false}
          onUpdated={onDetailUpdated}
        />
      </span>
    )}
    {childItems.length > 0 && (
      <div className={`rounded-full p-1 transition-colors ${open ? 'bg-muted' : 'group-hover:bg-muted'}`}>
        {open ? <ChevronUp className="h-4 w-4 text-primary" /> : <ChevronDown className="h-4 w-4 text-muted-foreground" />}
      </div>
    )}
  </div>
</td>
```

- [ ] **Step 6: Commit**

```bash
git add dashboard/src/components/approvals/approval-rows.tsx
git commit -m "feat: add approve and split buttons to LunchGroupRow"
```

---

### Task 6: Dashboard — `nestLunchActivities` + `lunch_segment` rendering in `ActivityRow`

**Files:**
- Modify: `dashboard/src/components/approvals/approval-utils.ts:356-391`
- Modify: `dashboard/src/components/approvals/approval-rows.tsx` (ActivityRow)

- [ ] **Step 1: Skip approved lunches in nestLunchActivities**

At `approval-utils.ts:361`, after the `activity_type === 'lunch'` check, add:
```typescript
if (item.pa.item.final_status === 'approved') return;
```

This means approved lunches won't be grouped — they'll render as standalone `ActivityRow` items, where the existing approve/reject button logic will handle them. After the user clicks "approve" on a `LunchGroupRow`, the data refreshes, and the now-approved lunch appears as a regular `ActivityRow`.

- [ ] **Step 2: Add 'lunch_segment' to never-absorb list**

At `approval-utils.ts:387-391`, add `'lunch_segment'`:
```typescript
if (item.type === 'activity' && (
  item.pa.item.activity_type === 'stop_segment' ||
  item.pa.item.activity_type === 'trip_segment' ||
  item.pa.item.activity_type === 'gap_segment' ||
  item.pa.item.activity_type === 'lunch_segment'
)) return;
```

- [ ] **Step 3: Handle lunch_segment and approved lunch in ActivityRow**

In the `ActivityRow` component, find where `isLunch` is defined (the check `activity.activity_type === 'lunch'`). This check currently causes lunch to render without approve/reject buttons. We need:

1. `lunch_segment` should NOT be treated as `isLunch` (it needs override buttons)
2. Approved standalone lunch should show a "Travail" badge

Add `isLunchSegment` detection:
```typescript
const isLunchSegment = activity.activity_type === 'lunch_segment';
```

For the icon cell, add lunch_segment rendering:
```tsx
{isLunchSegment && (
  <div className="flex justify-center bg-white/80 rounded-lg p-1.5 shadow-sm border border-black/5">
    <UtensilsCrossed className="h-4 w-4 text-orange-500" />
  </div>
)}
```

For the details cell, add lunch_segment label:
```tsx
{isLunchSegment && (
  <span className="text-xs font-bold text-orange-700">
    <UtensilsCrossed className="h-3 w-3 inline mr-1" />
    Segment pause dîner
  </span>
)}
```

- [ ] **Step 4: Verify build**

Run: `cd dashboard && npx next build`

- [ ] **Step 5: Commit**

```bash
git add dashboard/src/components/approvals/approval-utils.ts dashboard/src/components/approvals/approval-rows.tsx
git commit -m "feat: skip nesting for approved lunches and render lunch_segment rows"
```

---

### Task 7: Apply migration + end-to-end verification

**Files:** None — apply and test existing migration

- [ ] **Step 1: Apply migration to Supabase**

Use Supabase MCP `apply_migration` to apply `20260324400000_lunch_override_support.sql`.

- [ ] **Step 2: Verify constraints**

```sql
SELECT conname, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid IN ('activity_segments'::regclass, 'activity_overrides'::regclass)
  AND contype = 'c';
```

- [ ] **Step 3: Test override — find a lunch and approve it**

```sql
SELECT id, employee_id, clocked_in_at::date, clocked_in_at, clocked_out_at
FROM shifts WHERE is_lunch = true AND clocked_out_at IS NOT NULL
ORDER BY clocked_in_at DESC LIMIT 5;
```

- [ ] **Step 4: Test segmentation — split a lunch**

```sql
SELECT segment_activity('lunch', '<lunch_shift_id>', ARRAY['<midpoint>']::timestamptz[]);
```

- [ ] **Step 5: Verify dashboard build**

Run: `cd dashboard && npx next build`

- [ ] **Step 6: Test full flow in browser**

1. Open day approval detail for an employee with a lunch
2. Verify approve button appears on lunch row
3. Click approve → verify green styling + "Converti en travail"
4. Verify summary numbers update (approved_minutes up, lunch_minutes down)
5. Test split on a different lunch → verify segments appear with approve buttons
6. Approve one segment → verify partial conversion works

- [ ] **Step 7: Commit any fixes**

```bash
git add -A && git commit -m "fix: adjustments from integration testing"
```
