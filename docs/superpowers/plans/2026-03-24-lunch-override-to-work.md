# Lunch Override to Work — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow supervisors to convert lunch breaks (full or partial) to work time via the existing override + segment system.

**Architecture:** Extend `save_activity_override`, `segment_activity`, `unsegment_activity`, and `get_day_approval_detail` RPCs to support `lunch`/`lunch_segment` types. Update dashboard `LunchGroupRow` to show approve/split buttons. No Flutter changes.

**Tech Stack:** PostgreSQL (Supabase migrations), TypeScript/React (Next.js dashboard with shadcn/ui)

**Spec:** `docs/superpowers/specs/2026-03-24-lunch-override-to-work-design.md`

---

### Task 1: Migration — CHECK constraints + RPC type whitelists

**Files:**
- Create: `supabase/migrations/20260324400000_lunch_override_support.sql`

This migration updates constraints and RPC type whitelists to allow `lunch`/`lunch_segment`.

- [ ] **Step 1: Create the migration file with constraint updates**

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

Append to the same migration file. The key changes vs the current version (in `20260319100000_universal_activity_segments.sql:1886-1948`):
1. Remove the `IF p_activity_type = 'lunch'` exception block (lines 1900-1903)
2. Add `'lunch_segment'` to the type whitelist (line 1916)

```sql
-- 3. save_activity_override — remove lunch block, add lunch_segment
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

    -- Validate activity type (lunch_segment added)
    IF p_activity_type NOT IN (
        'trip', 'stop', 'clock_in', 'clock_out', 'gap',
        'lunch_start', 'lunch_end', 'lunch',
        'stop_segment', 'trip_segment', 'gap_segment',
        'lunch_segment'
    ) THEN
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;
```

- [ ] **Step 3: Add remove_activity_override — add lunch_segment**

Append to the same migration. The only change vs current (in `20260319100000_universal_activity_segments.sql:1951-1988`): add `'lunch_segment'` to the type whitelist (line 1966).

```sql
-- 4. remove_activity_override — add lunch_segment
CREATE OR REPLACE FUNCTION remove_activity_override(
    p_employee_id UUID,
    p_date DATE,
    p_activity_type TEXT,
    p_activity_id UUID
)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
BEGIN
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can remove overrides';
    END IF;

    -- Validate activity type (lunch_segment added)
    IF p_activity_type NOT IN (
        'trip', 'stop', 'clock_in', 'clock_out', 'gap',
        'lunch_start', 'lunch_end', 'lunch',
        'stop_segment', 'trip_segment', 'gap_segment',
        'lunch_segment'
    ) THEN
        RAISE EXCEPTION 'Invalid activity type: %', p_activity_type;
    END IF;

    -- Check day is not already approved
    IF EXISTS(
        SELECT 1 FROM day_approvals
        WHERE employee_id = p_employee_id AND date = p_date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Cannot modify overrides on an already approved day';
    END IF;

    DELETE FROM activity_overrides ao
    USING day_approvals da
    WHERE ao.day_approval_id = da.id
      AND da.employee_id = p_employee_id
      AND da.date = p_date
      AND ao.activity_type = p_activity_type
      AND ao.activity_id = p_activity_id;

    RETURN get_day_approval_detail(p_employee_id, p_date);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;
```

- [ ] **Step 4: Add segment_activity — add lunch support**

Append to the same migration. The key change vs current (`20260319100000_universal_activity_segments.sql:51-204`):
1. Add `'lunch'` to the valid type check (line 80)
2. Add an `ELSIF p_activity_type = 'lunch'` branch to resolve bounds from `shifts` table

```sql
-- 5. segment_activity — add lunch support
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

    -- Validate activity type (lunch added)
    IF p_activity_type NOT IN ('stop', 'trip', 'gap', 'lunch') THEN
        RAISE EXCEPTION 'Invalid activity type: %. Must be stop, trip, gap, or lunch', p_activity_type;
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

    ELSIF p_activity_type = 'lunch' THEN
        SELECT employee_id, clocked_in_at, clocked_out_at
        INTO v_employee_id, v_started_at, v_ended_at
        FROM shifts WHERE id = p_activity_id AND is_lunch = true;
        IF v_employee_id IS NULL THEN
            RAISE EXCEPTION 'Lunch shift not found';
        END IF;
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;
```

- [ ] **Step 5: Add unsegment_activity — add lunch support**

Append to the same migration. The key change vs current (`20260319100000_universal_activity_segments.sql:209-287`): add an `ELSIF p_activity_type = 'lunch'` branch to resolve from `shifts` table.

```sql
-- 6. unsegment_activity — add lunch support
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
        SELECT employee_id, to_business_date(starts_at)
        INTO v_employee_id, v_date
        FROM activity_segments
        WHERE activity_type = 'gap' AND activity_id = p_activity_id
        LIMIT 1;

    ELSIF p_activity_type = 'lunch' THEN
        SELECT employee_id, to_business_date(clocked_in_at)
        INTO v_employee_id, v_date
        FROM shifts WHERE id = p_activity_id AND is_lunch = true;

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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;
```

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/20260324400000_lunch_override_support.sql
git commit -m "feat: add lunch override constraints and RPC support"
```

---

### Task 2: Migration — Update `get_day_approval_detail` lunch CTE + lunch segments + summary

**Files:**
- Modify: `supabase/migrations/20260324400000_lunch_override_support.sql` (append)

This is the most complex task. It rewrites the `lunch_data` CTE, adds `lunch_segments` CTE, and updates the summary calculation.

- [ ] **Step 1: Read the current get_day_approval_detail function**

Read the full function from `supabase/migrations/20260319100000_universal_activity_segments.sql` lines 296-1420 to understand the complete structure. Key sections to note:
- Lines 353-362: `v_lunch_minutes` calculation
- Lines 905-984: `lunch_data` CTE
- Lines 1374-1385: summary computation
- Lines 1340-1372: combined activities UNION

- [ ] **Step 2: Append the updated get_day_approval_detail to the migration**

The full `CREATE OR REPLACE FUNCTION get_day_approval_detail(...)` must be appended. The changes within the function are:

**Change A — `v_lunch_minutes` calculation (replaces lines 353-362):**

Replace the simple lunch minutes sum with override-aware logic:

```sql
    -- Calculate lunch minutes (only non-overridden, non-segmented lunches)
    SELECT COALESCE(SUM(
        EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at)) / 60
    )::INTEGER, 0)
    INTO v_lunch_minutes
    FROM shifts s
    LEFT JOIN day_approvals da ON da.employee_id = s.employee_id
        AND da.date = (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date
    LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
        AND ao.activity_type = 'lunch' AND ao.activity_id = s.id
    WHERE s.employee_id = p_employee_id
      AND s.is_lunch = true
      AND (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date = p_date
      AND s.clocked_out_at IS NOT NULL
      -- Exclude approved (converted to work)
      AND COALESCE(ao.override_status, 'rejected') != 'approved'
      -- Exclude segmented (handled below)
      AND s.id NOT IN (SELECT activity_id FROM activity_segments WHERE activity_type = 'lunch');

    -- Add non-approved segment durations for segmented lunches
    v_lunch_minutes := v_lunch_minutes + COALESCE((
        SELECT SUM(
            EXTRACT(EPOCH FROM (aseg.ends_at - aseg.starts_at)) / 60
        )::INTEGER
        FROM activity_segments aseg
        JOIN shifts s ON s.id = aseg.activity_id AND s.is_lunch = true
        LEFT JOIN day_approvals da ON da.employee_id = aseg.employee_id AND da.date = p_date
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'lunch_segment' AND ao.activity_id = aseg.id
        WHERE aseg.activity_type = 'lunch'
          AND aseg.employee_id = p_employee_id
          AND (aseg.starts_at AT TIME ZONE 'America/Montreal')::date = p_date
          AND COALESCE(ao.override_status, 'rejected') != 'approved'
    ), 0);
```

**Change B — `lunch_data` CTE (replaces lines 905-984):**

Join `activity_overrides` to get override status, and exclude segmented parent lunches:

```sql
    lunch_data AS (
        SELECT
            'lunch'::TEXT AS activity_type,
            s.id AS activity_id,
            s.id AS shift_id,
            s.clocked_in_at AS started_at,
            s.clocked_out_at AS ended_at,
            (EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at)) / 60)::INTEGER AS duration_minutes,
            NULL::UUID AS matched_location_id,
            NULL::TEXT AS location_name,
            NULL::TEXT AS location_type,
            NULL::DECIMAL AS latitude,
            NULL::DECIMAL AS longitude,
            NULL::INTEGER AS gps_gap_seconds,
            NULL::INTEGER AS gps_gap_count,
            'rejected'::TEXT AS auto_status,
            'Pause dîner (non payée)'::TEXT AS auto_reason,
            ao.override_status,
            NULL::TEXT AS override_reason,
            COALESCE(ao.override_status, 'rejected') AS final_status,
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
            -- Children: stops and trips during lunch (only when not approved)
            CASE WHEN COALESCE(ao.override_status, 'rejected') != 'approved' THEN
                (SELECT jsonb_agg(child ORDER BY child->>'started_at')
                 FROM (
                   SELECT jsonb_build_object(
                     'activity_id', sc.id,
                     'activity_type', 'stop',
                     'started_at', sc.started_at,
                     'ended_at', sc.ended_at,
                     'duration_minutes', sc.duration_seconds / 60,
                     'auto_status', 'rejected',
                     'auto_reason', 'Pendant la pause dîner',
                     'location_name', l.name,
                     'location_type', l.location_type::TEXT,
                     'latitude', sc.centroid_latitude,
                     'longitude', sc.centroid_longitude
                   ) AS child
                   FROM stationary_clusters sc
                   LEFT JOIN locations l ON l.id = sc.matched_location_id
                   WHERE sc.shift_id = s.id AND sc.duration_seconds >= 180
                   UNION ALL
                   SELECT jsonb_build_object(
                     'activity_id', t.id,
                     'activity_type', 'trip',
                     'started_at', t.started_at,
                     'ended_at', t.ended_at,
                     'duration_minutes', t.duration_minutes,
                     'distance_km', COALESCE(t.road_distance_km, t.distance_km),
                     'auto_status', 'rejected',
                     'auto_reason', 'Pendant la pause dîner',
                     'transport_mode', t.transport_mode::TEXT,
                     'start_location_name', sl2.name,
                     'end_location_name', el2.name
                   ) AS child
                   FROM trips t
                   LEFT JOIN locations sl2 ON sl2.id = t.start_location_id
                   LEFT JOIN locations el2 ON el2.id = t.end_location_id
                   WHERE t.shift_id = s.id
                 ) sub
                )
            ELSE NULL
            END AS children
        FROM shifts s
        LEFT JOIN day_approvals da
            ON da.employee_id = s.employee_id
            AND da.date = (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date
        LEFT JOIN activity_overrides ao
            ON ao.day_approval_id = da.id
            AND ao.activity_type = 'lunch'
            AND ao.activity_id = s.id
        WHERE s.employee_id = p_employee_id
          AND s.is_lunch = true
          AND (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date = p_date
          AND s.clocked_out_at IS NOT NULL
          -- Exclude segmented lunches (segments are shown instead)
          AND s.id NOT IN (SELECT activity_id FROM activity_segments WHERE activity_type = 'lunch')
    ),
```

**Change C — Add `lunch_segments` CTE (insert after `lunch_data`):**

```sql
    lunch_segments AS (
        SELECT
            'lunch_segment'::TEXT AS activity_type,
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
            'rejected'::TEXT AS auto_status,
            'Pause dîner (non payée)'::TEXT AS auto_reason,
            ao.override_status,
            NULL::TEXT AS override_reason,
            COALESCE(ao.override_status, 'rejected') AS final_status,
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
        LEFT JOIN day_approvals da ON da.employee_id = aseg.employee_id AND da.date = p_date
        LEFT JOIN activity_overrides ao
            ON ao.day_approval_id = da.id
            AND ao.activity_type = 'lunch_segment'
            AND ao.activity_id = aseg.id
        WHERE aseg.activity_type = 'lunch'
          AND aseg.employee_id = p_employee_id
          AND (aseg.starts_at AT TIME ZONE 'America/Montreal')::date = p_date
    ),
```

**Change D — Add lunch_segments to the combined activities UNION:**

In the section where all activities are combined (around line 1340), add:

```sql
        SELECT activity_type, activity_id, shift_id, started_at, ended_at, duration_minutes,
               matched_location_id, location_name, location_type, latitude, longitude,
               gps_gap_seconds, gps_gap_count, auto_status, auto_reason,
               override_status, override_reason, final_status,
               distance_km, road_distance_km, transport_mode, has_gps_gap,
               start_location_id, start_location_name, start_location_type,
               end_location_id, end_location_name, end_location_type,
               shift_type, shift_type_source, is_edited, original_value, children
        FROM lunch_segments
        UNION ALL
```

**Change E — Update summary calculation (replaces lines 1378-1383):**

Remove `'lunch'` from approved/rejected exclusion. Add `'lunch_segment'` to needs_review exclusion:

```sql
    SELECT
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (
            WHERE a->>'final_status' = 'approved' AND a->>'activity_type' NOT IN ('gap', 'gap_segment')
        ), 0),
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (
            WHERE a->>'final_status' = 'rejected' AND a->>'activity_type' NOT IN ('gap', 'gap_segment')
        ), 0),
        COALESCE(COUNT(*) FILTER (WHERE a->>'final_status' = 'needs_review'
            AND a->>'activity_type' NOT IN ('clock_in', 'clock_out', 'lunch', 'lunch_segment')
        ), 0)
    INTO v_approved_minutes, v_rejected_minutes, v_needs_review_count
    FROM jsonb_array_elements(COALESCE(v_activities, '[]'::JSONB)) a;
```

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260324400000_lunch_override_support.sql
git commit -m "feat: update get_day_approval_detail for lunch overrides and segments"
```

---

### Task 3: Migration — Update weekly summary `day_lunch` CTE

**Files:**
- Modify: `supabase/migrations/20260324400000_lunch_override_support.sql` (append)

- [ ] **Step 1: Read the full get_week_approval_summary function**

Read `supabase/migrations/20260319100000_universal_activity_segments.sql` from line 1420 to the end of the function to understand the full structure. The `day_lunch` CTE is at lines 1461-1470.

- [ ] **Step 2: Append the updated get_week_approval_summary**

The only CTE that changes is `day_lunch`. Replace the simple sum with override-aware logic. The full `CREATE OR REPLACE` must be appended.

The updated `day_lunch` CTE:

```sql
    day_lunch AS (
        SELECT
            s.employee_id,
            (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date AS lunch_date,
            COALESCE(SUM(
                CASE
                    -- Segmented lunch: exclude from this CTE (segments handled separately)
                    WHEN EXISTS (SELECT 1 FROM activity_segments aseg WHERE aseg.activity_type = 'lunch' AND aseg.activity_id = s.id)
                        THEN 0
                    -- Non-segmented, approved: exclude (converted to work)
                    WHEN COALESCE(ao.override_status, 'rejected') = 'approved'
                        THEN 0
                    -- Non-segmented, not approved: count as lunch
                    ELSE EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at))::INTEGER / 60
                END
            ), 0)
            -- Add non-approved segment minutes
            + COALESCE((
                SELECT SUM(EXTRACT(EPOCH FROM (aseg2.ends_at - aseg2.starts_at))::INTEGER / 60)
                FROM activity_segments aseg2
                JOIN shifts s2 ON s2.id = aseg2.activity_id AND s2.is_lunch = true AND s2.employee_id = s.employee_id
                LEFT JOIN day_approvals da2 ON da2.employee_id = aseg2.employee_id
                    AND da2.date = (aseg2.starts_at AT TIME ZONE 'America/Montreal')::date
                LEFT JOIN activity_overrides ao2 ON ao2.day_approval_id = da2.id
                    AND ao2.activity_type = 'lunch_segment' AND ao2.activity_id = aseg2.id
                WHERE aseg2.activity_type = 'lunch'
                  AND (aseg2.starts_at AT TIME ZONE 'America/Montreal')::date = (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date
                  AND COALESCE(ao2.override_status, 'rejected') != 'approved'
            ), 0) AS lunch_minutes
        FROM shifts s
        LEFT JOIN day_approvals da ON da.employee_id = s.employee_id
            AND da.date = (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'lunch' AND ao.activity_id = s.id
        WHERE s.is_lunch = true AND s.clocked_out_at IS NOT NULL
          AND (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date BETWEEN p_week_start AND v_week_end
          AND s.employee_id IN (SELECT employee_id FROM employee_list)
        GROUP BY s.employee_id, (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date
    ),
```

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260324400000_lunch_override_support.sql
git commit -m "feat: update weekly summary lunch calculation for overrides"
```

---

### Task 4: Dashboard — TypeScript types + `ActivitySegmentModal` lunch support

**Files:**
- Modify: `dashboard/src/types/mileage.ts:164,250` — add `'lunch_segment'` to type unions
- Modify: `dashboard/src/components/approvals/activity-segment-modal.tsx:21,30-34` — add `'lunch'` type + title

- [ ] **Step 1: Update ApprovalActivity type in mileage.ts**

At `dashboard/src/types/mileage.ts:250`, add `'lunch_segment'` to the `activity_type` union:

```typescript
// Before:
activity_type: 'trip' | 'stop' | 'stop_segment' | 'trip_segment' | 'gap_segment' | 'clock_in' | 'clock_out' | 'gap' | 'lunch';
// After:
activity_type: 'trip' | 'stop' | 'stop_segment' | 'trip_segment' | 'gap_segment' | 'lunch_segment' | 'clock_in' | 'clock_out' | 'gap' | 'lunch';
```

Also at line 164, if there's a separate base type, add `'lunch_segment'` there too.

- [ ] **Step 2: Update ActivitySegmentModal interface and TITLE_MAP**

At `dashboard/src/components/approvals/activity-segment-modal.tsx:21`:

```typescript
// Before:
activityType: 'stop' | 'trip' | 'gap';
// After:
activityType: 'stop' | 'trip' | 'gap' | 'lunch';
```

At line 30-34, add lunch to `TITLE_MAP`:

```typescript
const TITLE_MAP: Record<ActivitySegmentModalProps['activityType'], string> = {
  stop: "Diviser l'arrêt",
  trip: "Diviser le trajet",
  gap: "Diviser le temps non suivi",
  lunch: "Diviser la pause dîner",
};
```

- [ ] **Step 3: Verify build compiles**

Run: `cd dashboard && npx next build`
Expected: Build succeeds (or only pre-existing warnings).

- [ ] **Step 4: Commit**

```bash
git add dashboard/src/types/mileage.ts dashboard/src/components/approvals/activity-segment-modal.tsx
git commit -m "feat: add lunch_segment type and lunch support in segment modal"
```

---

### Task 5: Dashboard — `LunchGroupRow` approve + split buttons

**Files:**
- Modify: `dashboard/src/components/approvals/approval-rows.tsx:1122-1237` — add buttons to `LunchGroupRow`

- [ ] **Step 1: Update LunchGroupRow to show approve/split buttons**

The `LunchGroupRow` component (at `approval-rows.tsx:1122`) currently has no action buttons in the first `<td>` cell — just a "Pause" badge. Replace the action cell with conditional override buttons.

In the `<td className="px-3 py-3 text-center">` (the first cell, around line 1159), replace the static badge with:

```tsx
<td className="px-3 py-3 text-center" onClick={(e) => e.stopPropagation()}>
  {isApproved ? (
    <div className="flex justify-center">
      <Badge variant="outline" className="font-bold text-[10px] px-2.5 py-0.5 rounded-full bg-slate-100 text-slate-600 border-slate-200">
        <UtensilsCrossed className="h-3 w-3 mr-1" />
        Pause
      </Badge>
    </div>
  ) : (
    <div className="flex items-center justify-center gap-1">
      <Button
        variant="ghost"
        size="sm"
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

Also update the `<tr>` styling to use green border when approved:

```tsx
<tr
  className={`${
    activity.final_status === 'approved'
      ? 'bg-green-50/60 border-l-4 border-l-green-400'
      : 'bg-slate-50/80 border-l-4 border-l-slate-300'
  } hover:bg-slate-100/80 cursor-pointer transition-all duration-200 group border-b border-white/50`}
  onClick={() => setOpen(!open)}
>
```

Update the details cell label when approved:

```tsx
<div className="text-xs flex items-center gap-1.5 text-orange-700 font-medium">
  <UtensilsCrossed className="h-3 w-3" />
  <span className="font-bold">Pause dîner</span>
  {activity.final_status === 'approved' && (
    <Badge className="ml-1 bg-green-100 text-green-700 text-[9px] px-1.5 py-0 font-bold border-green-200">
      Converti en travail
    </Badge>
  )}
</div>
```

Add the `ActivitySegmentModal` (scissors button) in the last cell (expand/split cell, around line 1228), before the chevron:

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
        {open
          ? <ChevronUp className="h-4 w-4 text-primary" />
          : <ChevronDown className="h-4 w-4 text-muted-foreground" />
        }
      </div>
    )}
  </div>
</td>
```

Import `Button` and `CheckCircle2` if not already imported at top of file. `CheckCircle2` is already imported (line 6), `Button` needs to be imported from `@/components/ui/button`.

- [ ] **Step 2: Verify build compiles**

Run: `cd dashboard && npx next build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add dashboard/src/components/approvals/approval-rows.tsx
git commit -m "feat: add approve and split buttons to LunchGroupRow"
```

---

### Task 6: Dashboard — `nestLunchActivities` skip approved lunches + handle `lunch_segment` in `ActivityRow`

**Files:**
- Modify: `dashboard/src/components/approvals/approval-utils.ts:356-437` — skip approved lunches
- Modify: `dashboard/src/components/approvals/approval-rows.tsx` — handle `lunch_segment` in `ActivityRow`

- [ ] **Step 1: Update nestLunchActivities to skip approved lunches and segmented lunches**

At `approval-utils.ts:360-368`, update the lunch detection to skip approved and segmented lunches:

```typescript
  items.forEach((item, i) => {
    if (item.type === 'activity' && item.pa.item.activity_type === 'lunch') {
      // Don't nest approved lunches (they're converted to work) or segmented ones
      if (item.pa.item.final_status === 'approved') return;
      lunchRanges.push({
        index: i,
        start: new Date(item.pa.item.started_at).getTime(),
        end: new Date(item.pa.item.ended_at).getTime(),
        pa: item.pa,
      });
    }
  });
```

Also in the same function (line 387-391), add `'lunch_segment'` to the list of types that should never be absorbed:

```typescript
      if (item.type === 'activity' && (
        item.pa.item.activity_type === 'stop_segment' ||
        item.pa.item.activity_type === 'trip_segment' ||
        item.pa.item.activity_type === 'gap_segment' ||
        item.pa.item.activity_type === 'lunch_segment'
      )) return;
```

- [ ] **Step 2: Handle lunch_segment in ActivityRow**

In the `ActivityRow` component (`approval-rows.tsx`), the existing row already handles various activity types. The `lunch_segment` type needs to be rendered similarly to `stop_segment`. Find the section where `isStop`, `isTrip`, `isGap`, etc. are defined and add:

```typescript
const isLunchSegment = activity.activity_type === 'lunch_segment';
```

Then in the icon/badge rendering, add lunch_segment alongside the existing segment types. Lunch segments should show:
- The utensils icon (like lunch)
- A segment badge indicator (like other segments)
- Approve/reject buttons (already handled by existing override button logic)

The existing `ActivityRow` component already renders approve/reject buttons for any non-clock/non-lunch activity. Since `lunch_segment` is not in the `isLunch` check (`activity.activity_type === 'lunch'`), it will automatically get buttons. Just make sure the icon rendering handles it.

In the type icon cell, add a case for `lunch_segment`:

```typescript
{isLunchSegment && (
  <div className="flex justify-center bg-white/80 rounded-lg p-1.5 shadow-sm border border-black/5">
    <UtensilsCrossed className="h-4 w-4 text-orange-500" />
  </div>
)}
```

- [ ] **Step 3: Verify build compiles**

Run: `cd dashboard && npx next build`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add dashboard/src/components/approvals/approval-utils.ts dashboard/src/components/approvals/approval-rows.tsx
git commit -m "feat: skip nesting for approved lunches and render lunch_segment rows"
```

---

### Task 7: Apply migration to Supabase + end-to-end verification

**Files:**
- No new files — apply existing migration via MCP

- [ ] **Step 1: Apply the migration to Supabase**

Use the Supabase MCP `apply_migration` tool to apply `20260324400000_lunch_override_support.sql`.

- [ ] **Step 2: Verify migration applied**

Query to verify the constraints are updated:

```sql
SELECT conname, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid IN ('activity_segments'::regclass, 'activity_overrides'::regclass)
  AND contype = 'c';
```

Expected: Both constraints include the new types.

- [ ] **Step 3: Test override RPC manually**

Find an employee with a lunch break and test:

```sql
-- Find a lunch shift for testing
SELECT id, employee_id, clocked_in_at::date, clocked_in_at, clocked_out_at
FROM shifts WHERE is_lunch = true AND clocked_out_at IS NOT NULL
ORDER BY clocked_in_at DESC LIMIT 5;
```

Then call `save_activity_override` with the lunch shift ID to verify it no longer throws.

- [ ] **Step 4: Test segmentation RPC manually**

Call `segment_activity` with a lunch shift to verify segmentation works:

```sql
SELECT segment_activity('lunch', '<lunch_shift_id>', ARRAY['<midpoint_timestamp>']::timestamptz[]);
```

- [ ] **Step 5: Verify dashboard build**

Run: `cd dashboard && npx next build`
Expected: Build succeeds with no type errors.

- [ ] **Step 6: Commit any fixes from verification**

If any issues were found and fixed, commit them.

---

### Task 8: Final integration check + commit

- [ ] **Step 1: Test full approval flow in dashboard**

Open the dashboard, navigate to an employee with a lunch break:
1. Verify lunch row shows approve button
2. Click approve → verify row turns green with "Converti en travail" badge
3. Verify summary `approved_minutes` increases and `lunch_minutes` decreases
4. Test split: click scissors on a different lunch → verify segments appear
5. Approve one segment → verify partial minutes work
6. Unsegment → verify it reverts

- [ ] **Step 2: Final commit if any adjustments needed**

```bash
git add -A
git commit -m "fix: adjustments from integration testing"
```