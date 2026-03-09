# Approval Stability & Cascade Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix three approval bugs — stabilize activity IDs across re-runs, cascade trip status from neighboring stops, and default unknown locations to rejected.

**Architecture:** Single Supabase migration (129) modifying three existing SQL functions (`detect_trips`, `get_day_approval_detail`, `get_weekly_approval_summary`) plus a one-time data cleanup. No Flutter or dashboard code changes needed — everything is backend SQL.

**Tech Stack:** PostgreSQL, Supabase migrations, uuid-ossp extension (already enabled)

---

### Task 1: Create migration file with deterministic UUID helper

**Files:**
- Create: `supabase/migrations/129_approval_stability_cascade.sql`

**Step 1: Write the migration header and helper function**

```sql
-- Migration 129: Approval stability & cascade
-- 1. Deterministic UUIDs for trips/clusters (overrides survive re-runs)
-- 2. Bidirectional trip cascade from neighboring stops
-- 3. Unknown locations default to 'rejected'
-- 4. One-time cleanup of orphaned overrides

-- =========================================================================
-- Part 1: Deterministic UUID helper
-- =========================================================================
-- Uses uuid_generate_v5 with a fixed namespace so that the same
-- shift + type + start_time always produces the same UUID.
CREATE OR REPLACE FUNCTION deterministic_activity_id(
    p_shift_id UUID,
    p_type TEXT,        -- 'trip' or 'cluster'
    p_started_at TIMESTAMPTZ
) RETURNS UUID AS $$
BEGIN
    RETURN uuid_generate_v5(
        'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::UUID,
        p_shift_id::TEXT || '|' || p_type || '|' || p_started_at::TEXT
    );
END;
$$ LANGUAGE plpgsql IMMUTABLE;
```

**Step 2: Verify helper works**

Run via Supabase MCP `execute_sql`:
```sql
SELECT deterministic_activity_id(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'trip',
    '2026-03-09 08:00:00+00'
);
-- Should return the same UUID every time
```

Expected: Returns a UUID. Running it twice returns the exact same value.

**Step 3: Commit**

```bash
git add supabase/migrations/129_approval_stability_cascade.sql
git commit -m "feat: deterministic UUID helper for stable activity IDs"
```

---

### Task 2: Update detect_trips to use deterministic IDs

**Files:**
- Modify: `supabase/migrations/129_approval_stability_cascade.sql` (append)

**Step 1: Copy the full detect_trips function from migration 122 (lines 111–1053) and make these targeted changes:**

Base: `supabase/migrations/122_gps_gap_visibility.sql:111-1053`

**Change A — Trip ID at line 617:**
```sql
-- BEFORE (line 617):
v_trip_id := gen_random_uuid();

-- AFTER:
v_trip_id := deterministic_activity_id(p_shift_id, 'trip', v_trip_started_at);
```

**Change B — Trip ID at line 919:**
```sql
-- BEFORE (line 919):
v_trip_id := gen_random_uuid();

-- AFTER:
v_trip_id := deterministic_activity_id(p_shift_id, 'trip', v_trip_started_at);
```

**Change C — Cluster INSERT at line 400 (first cluster creation, when confirmed):**
```sql
-- BEFORE (lines 400-416):
INSERT INTO stationary_clusters (
    shift_id, employee_id,
    centroid_latitude, centroid_longitude, centroid_accuracy,
    started_at, ended_at, duration_seconds, gps_point_count,
    matched_location_id
) VALUES (
    p_shift_id, v_employee_id,
    ...
)
RETURNING id INTO v_cluster_id;

-- AFTER:
v_cluster_id := deterministic_activity_id(p_shift_id, 'cluster', v_cluster_started_at);
INSERT INTO stationary_clusters (
    id, shift_id, employee_id,
    centroid_latitude, centroid_longitude, centroid_accuracy,
    started_at, ended_at, duration_seconds, gps_point_count,
    matched_location_id
) VALUES (
    v_cluster_id, p_shift_id, v_employee_id,
    ...
);
-- Remove RETURNING clause (id is already set)
```

**Change D — Cluster INSERT at line 528 (edge case cluster):**
Same pattern: compute `v_cluster_id` with `deterministic_activity_id(p_shift_id, 'cluster', v_cluster_started_at)` before INSERT, add explicit `id` column.

**Change E — Cluster INSERT at line 565 (tentative promoted to new cluster):**
Same pattern: compute `v_new_cluster_id` with `deterministic_activity_id(p_shift_id, 'cluster', v_tent_started_at)` before INSERT, add explicit `id` column.

**Step 2: Verify by applying migration and testing**

Run via Supabase MCP `execute_sql`:
```sql
-- Pick a completed shift
SELECT id FROM shifts WHERE status = 'completed' ORDER BY clocked_in_at DESC LIMIT 1;

-- Run detect_trips — should produce deterministic IDs
SELECT * FROM detect_trips('<shift_id>');

-- Run again — should produce EXACTLY the same trip IDs
SELECT * FROM detect_trips('<shift_id>');
```

Expected: Both runs produce identical trip_id values.

**Step 3: Commit**

```bash
git add supabase/migrations/129_approval_stability_cascade.sql
git commit -m "feat: deterministic UUIDs in detect_trips for stable overrides"
```

---

### Task 3: Update get_day_approval_detail with cascade + unknown=rejected

**Files:**
- Modify: `supabase/migrations/129_approval_stability_cascade.sql` (append)

**Step 1: Rewrite get_day_approval_detail**

Base: `supabase/migrations/122_gps_gap_visibility.sql:1058-1450`

The function must be restructured from 2 CTEs (`activity_data` → `classified`) to 4 CTEs:

**CTE 1: `stop_data`** — Stops with auto_status (unknown → rejected)

```sql
stop_data AS (
    SELECT
        'stop'::TEXT AS activity_type,
        sc.id AS activity_id,
        sc.shift_id,
        sc.started_at,
        sc.ended_at,
        (sc.duration_seconds / 60)::INTEGER AS duration_minutes,
        sc.matched_location_id,
        l.name AS location_name,
        l.location_type::TEXT AS location_type,
        sc.centroid_latitude AS latitude,
        sc.centroid_longitude AS longitude,
        sc.gps_gap_seconds,
        sc.gps_gap_count,
        CASE
            WHEN l.location_type IN ('office', 'building') THEN 'approved'
            WHEN l.location_type IN ('vendor', 'gaz') THEN 'needs_review'
            WHEN l.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
            -- ★ FIX 3: unknown locations → rejected (was 'needs_review')
            ELSE 'rejected'
        END AS auto_status,
        CASE
            WHEN l.location_type = 'office' THEN 'Lieu de travail (bureau)'
            WHEN l.location_type = 'building' THEN 'Lieu de travail (immeuble)'
            WHEN l.location_type = 'vendor' THEN 'Fournisseur (à vérifier)'
            WHEN l.location_type = 'gaz' THEN 'Station-service (à vérifier)'
            WHEN l.location_type = 'home' THEN 'Domicile'
            WHEN l.location_type = 'cafe_restaurant' THEN 'Café / Restaurant'
            WHEN l.location_type = 'other' THEN 'Lieu non-professionnel'
            -- ★ FIX 3: updated label
            ELSE 'Lieu non autorisé (inconnu)'
        END AS auto_reason,
        NULL::DECIMAL AS distance_km,
        NULL::TEXT AS transport_mode,
        NULL::BOOLEAN AS has_gps_gap,
        NULL::UUID AS start_location_id,
        NULL::TEXT AS start_location_name,
        NULL::TEXT AS start_location_type,
        NULL::UUID AS end_location_id,
        NULL::TEXT AS end_location_name,
        NULL::TEXT AS end_location_type
    FROM stationary_clusters sc
    LEFT JOIN locations l ON l.id = sc.matched_location_id
    WHERE sc.employee_id = p_employee_id
      AND sc.started_at >= p_date::TIMESTAMPTZ
      AND sc.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
      AND sc.duration_seconds >= 180
),
```

**CTE 2: `stop_classified`** — Stops with overrides merged (gives us final_status per stop)

```sql
stop_classified AS (
    SELECT
        sd.*,
        ao.override_status,
        ao.reason AS override_reason,
        COALESCE(ao.override_status, sd.auto_status) AS final_status
    FROM stop_data sd
    LEFT JOIN day_approvals da
        ON da.employee_id = p_employee_id AND da.date = p_date
    LEFT JOIN activity_overrides ao
        ON ao.day_approval_id = da.id
       AND ao.activity_type = 'stop'
       AND ao.activity_id = sd.activity_id
),
```

**CTE 3: `trip_data`** — Trips with cascade status derived from neighboring stops

```sql
trip_data AS (
    SELECT
        'trip'::TEXT AS activity_type,
        t.id AS activity_id,
        t.shift_id,
        t.started_at,
        t.ended_at,
        t.duration_minutes,
        NULL::UUID AS matched_location_id,
        NULL::TEXT AS location_name,
        NULL::TEXT AS location_type,
        t.start_latitude AS latitude,
        t.start_longitude AS longitude,
        t.gps_gap_seconds,
        t.gps_gap_count,
        -- ★ FIX 2: Cascade from neighboring stops instead of endpoint locations
        CASE
            WHEN t.has_gps_gap = TRUE THEN 'needs_review'
            WHEN t.duration_minutes > 60 THEN 'needs_review'
            WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'rejected'
            WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'approved'
            ELSE 'needs_review'
        END AS auto_status,
        CASE
            WHEN t.has_gps_gap = TRUE THEN 'Données GPS incomplètes'
            WHEN t.duration_minutes > 60 THEN 'Trajet anormalement long (>' || t.duration_minutes || ' min)'
            WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'Trajet vers/depuis lieu non autorisé'
            WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'Déplacement professionnel'
            ELSE 'À vérifier'
        END AS auto_reason,
        t.distance_km,
        t.transport_mode::TEXT,
        t.has_gps_gap,
        COALESCE(t.start_location_id, dep_cluster.matched_location_id) AS start_location_id,
        COALESCE(sl.name, dep_loc.name)::TEXT AS start_location_name,
        COALESCE(sl.location_type, dep_loc.location_type)::TEXT AS start_location_type,
        COALESCE(t.end_location_id, arr_cluster.matched_location_id) AS end_location_id,
        COALESCE(el.name, arr_loc.name)::TEXT AS end_location_name,
        COALESCE(el.location_type, arr_loc.location_type)::TEXT AS end_location_type
    FROM trips t
    LEFT JOIN locations sl ON sl.id = t.start_location_id
    LEFT JOIN locations el ON el.id = t.end_location_id
    -- Cluster-based location fallback (existing logic)
    LEFT JOIN LATERAL (
        SELECT sc2.matched_location_id
        FROM stationary_clusters sc2
        WHERE sc2.employee_id = p_employee_id
          AND sc2.ended_at = t.started_at
        LIMIT 1
    ) dep_cluster ON t.start_location_id IS NULL
    LEFT JOIN locations dep_loc ON dep_loc.id = dep_cluster.matched_location_id
    LEFT JOIN LATERAL (
        SELECT sc3.matched_location_id
        FROM stationary_clusters sc3
        WHERE sc3.employee_id = p_employee_id
          AND sc3.started_at = t.ended_at
        LIMIT 1
    ) arr_cluster ON t.end_location_id IS NULL
    LEFT JOIN locations arr_loc ON arr_loc.id = arr_cluster.matched_location_id
    -- ★ FIX 2: Join to neighboring stops for cascade
    LEFT JOIN LATERAL (
        SELECT sc_dep.final_status
        FROM stop_classified sc_dep
        WHERE sc_dep.ended_at BETWEEN t.started_at - INTERVAL '2 minutes' AND t.started_at + INTERVAL '2 minutes'
        ORDER BY ABS(EXTRACT(EPOCH FROM (sc_dep.ended_at - t.started_at)))
        LIMIT 1
    ) dep_stop ON TRUE
    LEFT JOIN LATERAL (
        SELECT sc_arr.final_status
        FROM stop_classified sc_arr
        WHERE sc_arr.started_at BETWEEN t.ended_at - INTERVAL '2 minutes' AND t.ended_at + INTERVAL '2 minutes'
        ORDER BY ABS(EXTRACT(EPOCH FROM (sc_arr.started_at - t.ended_at)))
        LIMIT 1
    ) arr_stop ON TRUE
    WHERE t.employee_id = p_employee_id
      AND t.started_at >= p_date::TIMESTAMPTZ
      AND t.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
),
```

**CTE 4: `clock_data`** — Clock events (same as before but unknown → rejected)

Keep the existing UNION ALL for clock_in and clock_out from migration 122 lines 1227-1350, but change:
- Line 1245: `WHEN ci_loc.id IS NULL THEN 'needs_review'` → `'rejected'`
- Line 1246: `ELSE 'needs_review'` → `'rejected'`
- Line 1254: `WHEN ci_loc.id IS NULL THEN 'Clock-in lieu inconnu'` → `'Clock-in lieu non autorisé'`
- Line 1308: `WHEN co_loc.id IS NULL THEN 'needs_review'` → `'rejected'`
- Line 1309: `ELSE 'needs_review'` → `'rejected'`
- Line 1317: Same label update for clock_out

**CTE 5: `classified`** — Merge all activities with trip overrides

```sql
classified AS (
    -- Stops already have override merged in stop_classified
    SELECT
        sc.activity_type, sc.activity_id, sc.shift_id,
        sc.started_at, sc.ended_at, sc.duration_minutes,
        sc.matched_location_id, sc.location_name, sc.location_type,
        sc.latitude, sc.longitude, sc.gps_gap_seconds, sc.gps_gap_count,
        sc.auto_status, sc.auto_reason,
        sc.override_status, sc.override_reason, sc.final_status,
        sc.distance_km, sc.transport_mode, sc.has_gps_gap,
        sc.start_location_id, sc.start_location_name, sc.start_location_type,
        sc.end_location_id, sc.end_location_name, sc.end_location_type
    FROM stop_classified sc

    UNION ALL

    -- Trips: merge with trip-specific overrides
    SELECT
        td.activity_type, td.activity_id, td.shift_id,
        td.started_at, td.ended_at, td.duration_minutes,
        td.matched_location_id, td.location_name, td.location_type,
        td.latitude, td.longitude, td.gps_gap_seconds, td.gps_gap_count,
        td.auto_status, td.auto_reason,
        tao.override_status,
        tao.reason AS override_reason,
        COALESCE(tao.override_status, td.auto_status) AS final_status,
        td.distance_km, td.transport_mode, td.has_gps_gap,
        td.start_location_id, td.start_location_name, td.start_location_type,
        td.end_location_id, td.end_location_name, td.end_location_type
    FROM trip_data td
    LEFT JOIN day_approvals da
        ON da.employee_id = p_employee_id AND da.date = p_date
    LEFT JOIN activity_overrides tao
        ON tao.day_approval_id = da.id
       AND tao.activity_type = 'trip'
       AND tao.activity_id = td.activity_id

    UNION ALL

    -- Clock events (with their own overrides)
    SELECT
        cd.activity_type, cd.activity_id, cd.shift_id,
        cd.started_at, cd.ended_at, cd.duration_minutes,
        cd.matched_location_id, cd.location_name, cd.location_type,
        cd.latitude, cd.longitude, cd.gps_gap_seconds, cd.gps_gap_count,
        cd.auto_status, cd.auto_reason,
        cao.override_status,
        cao.reason AS override_reason,
        COALESCE(cao.override_status, cd.auto_status) AS final_status,
        cd.distance_km, cd.transport_mode, cd.has_gps_gap,
        cd.start_location_id, cd.start_location_name, cd.start_location_type,
        cd.end_location_id, cd.end_location_name, cd.end_location_type
    FROM clock_data cd
    LEFT JOIN day_approvals da
        ON da.employee_id = p_employee_id AND da.date = p_date
    LEFT JOIN activity_overrides cao
        ON cao.day_approval_id = da.id
       AND cao.activity_type = cd.activity_type
       AND cao.activity_id = cd.activity_id

    ORDER BY started_at ASC
)
```

The rest of the function (summary computation, result building) stays the same as migration 122 lines 1367-1450.

**Step 2: Verify the function**

Run via Supabase MCP `execute_sql`:
```sql
-- Pick an employee with shifts
SELECT DISTINCT employee_id, clocked_in_at::DATE
FROM shifts WHERE status = 'completed'
ORDER BY clocked_in_at DESC LIMIT 5;

-- Get day detail — check that:
-- 1. Unknown stops show auto_status='rejected' (not 'needs_review')
-- 2. Trips cascade from neighbor stops
SELECT * FROM get_day_approval_detail('<employee_id>', '<date>');
```

**Step 3: Commit**

```bash
git add supabase/migrations/129_approval_stability_cascade.sql
git commit -m "feat: trip cascade from stops + unknown locations auto-rejected"
```

---

### Task 4: Update get_weekly_approval_summary with same logic

**Files:**
- Modify: `supabase/migrations/129_approval_stability_cascade.sql` (append)

**Step 1: Rewrite get_weekly_approval_summary**

Base: `supabase/migrations/127_weekly_summary_live_classification.sql:5-180`

Restructure `live_activity_classification` CTE into two CTEs:

**CTE replacement — `live_stop_classification`:**
```sql
live_stop_classification AS (
    SELECT
        sc.employee_id,
        sc.started_at::DATE AS activity_date,
        sc.id AS activity_id,
        sc.started_at,
        sc.ended_at,
        (sc.duration_seconds / 60)::INTEGER AS duration_minutes,
        COALESCE(ao.override_status,
            CASE
                WHEN l.location_type IN ('office', 'building') THEN 'approved'
                WHEN l.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                WHEN l.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                -- ★ FIX 3: unknown → rejected
                ELSE 'rejected'
            END
        ) AS final_status
    FROM stationary_clusters sc
    LEFT JOIN locations l ON l.id = sc.matched_location_id
    LEFT JOIN day_approvals da ON da.employee_id = sc.employee_id AND da.date = sc.started_at::DATE
    LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
        AND ao.activity_type = 'stop' AND ao.activity_id = sc.id
    WHERE sc.started_at::DATE BETWEEN p_week_start AND v_week_end
      AND sc.employee_id IN (SELECT employee_id FROM employee_list)
      AND sc.duration_seconds >= 180
),
```

**CTE replacement — `live_trip_classification`:**
```sql
live_trip_classification AS (
    SELECT
        t.employee_id,
        t.started_at::DATE AS activity_date,
        t.duration_minutes,
        COALESCE(ao.override_status,
            CASE
                WHEN t.has_gps_gap = TRUE THEN 'needs_review'
                WHEN t.duration_minutes > 60 THEN 'needs_review'
                -- ★ FIX 2: cascade from neighboring stops
                WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'rejected'
                WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'approved'
                ELSE 'needs_review'
            END
        ) AS final_status
    FROM trips t
    -- ★ FIX 2: join to neighboring stops
    LEFT JOIN LATERAL (
        SELECT ls.final_status
        FROM live_stop_classification ls
        WHERE ls.employee_id = t.employee_id
          AND ls.ended_at BETWEEN t.started_at - INTERVAL '2 minutes' AND t.started_at + INTERVAL '2 minutes'
        ORDER BY ABS(EXTRACT(EPOCH FROM (ls.ended_at - t.started_at)))
        LIMIT 1
    ) dep_stop ON TRUE
    LEFT JOIN LATERAL (
        SELECT ls.final_status
        FROM live_stop_classification ls
        WHERE ls.employee_id = t.employee_id
          AND ls.started_at BETWEEN t.ended_at - INTERVAL '2 minutes' AND t.ended_at + INTERVAL '2 minutes'
        ORDER BY ABS(EXTRACT(EPOCH FROM (ls.started_at - t.ended_at)))
        LIMIT 1
    ) arr_stop ON TRUE
    LEFT JOIN day_approvals da ON da.employee_id = t.employee_id AND da.date = t.started_at::DATE
    LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
        AND ao.activity_type = 'trip' AND ao.activity_id = t.id
    WHERE t.started_at::DATE BETWEEN p_week_start AND v_week_end
      AND t.employee_id IN (SELECT employee_id FROM employee_list)
),
```

**Replace `live_activity_classification`:**
```sql
live_activity_classification AS (
    SELECT employee_id, activity_date, duration_minutes, final_status
    FROM live_stop_classification
    UNION ALL
    SELECT employee_id, activity_date, duration_minutes, final_status
    FROM live_trip_classification
),
```

Everything else (`live_day_totals`, `pending_day_stats`, final SELECT) stays identical.

**Step 2: Verify**

```sql
SELECT * FROM get_weekly_approval_summary('2026-03-03'::DATE);
-- Check that needs_review_count is lower (unknowns now auto-rejected)
```

**Step 3: Commit**

```bash
git add supabase/migrations/129_approval_stability_cascade.sql
git commit -m "feat: weekly summary uses cascade + unknown=rejected"
```

---

### Task 5: One-time cleanup of orphaned overrides

**Files:**
- Modify: `supabase/migrations/129_approval_stability_cascade.sql` (append)

**Step 1: Write the cleanup DO block**

Append to the migration:

```sql
-- =========================================================================
-- Part 5: One-time cleanup — reconnect orphaned overrides
-- =========================================================================
-- After switching to deterministic IDs, existing overrides reference old
-- random UUIDs. This block matches them to current activities by time.
DO $$
DECLARE
    v_fixed INTEGER := 0;
    v_orphan RECORD;
    v_new_id UUID;
BEGIN
    -- Find orphaned stop overrides
    FOR v_orphan IN
        SELECT ao.id AS override_id, ao.activity_id AS old_id,
               ao.activity_type, da.employee_id, da.date
        FROM activity_overrides ao
        JOIN day_approvals da ON da.id = ao.day_approval_id
        WHERE ao.activity_type = 'stop'
          AND NOT EXISTS (
              SELECT 1 FROM stationary_clusters sc WHERE sc.id = ao.activity_id
          )
    LOOP
        -- Find matching current cluster by employee + date + closest time
        SELECT sc.id INTO v_new_id
        FROM stationary_clusters sc
        WHERE sc.employee_id = v_orphan.employee_id
          AND sc.started_at::DATE = v_orphan.date
          AND sc.duration_seconds >= 180
        ORDER BY sc.started_at
        LIMIT 1;

        -- Try harder: use the override's day_approval to find any cluster
        -- that was created around the same shift
        IF v_new_id IS NULL THEN
            CONTINUE;
        END IF;

        -- Check for conflict before updating
        IF NOT EXISTS (
            SELECT 1 FROM activity_overrides
            WHERE day_approval_id = v_orphan.override_id
              AND activity_type = 'stop'
              AND activity_id = v_new_id
        ) THEN
            UPDATE activity_overrides
            SET activity_id = v_new_id
            WHERE id = v_orphan.override_id;
            v_fixed := v_fixed + 1;
        END IF;
    END LOOP;

    -- Find orphaned trip overrides
    FOR v_orphan IN
        SELECT ao.id AS override_id, ao.activity_id AS old_id,
               ao.activity_type, da.employee_id, da.date
        FROM activity_overrides ao
        JOIN day_approvals da ON da.id = ao.day_approval_id
        WHERE ao.activity_type = 'trip'
          AND NOT EXISTS (
              SELECT 1 FROM trips t WHERE t.id = ao.activity_id
          )
    LOOP
        SELECT t.id INTO v_new_id
        FROM trips t
        WHERE t.employee_id = v_orphan.employee_id
          AND t.started_at::DATE = v_orphan.date
        ORDER BY t.started_at
        LIMIT 1;

        IF v_new_id IS NULL THEN
            CONTINUE;
        END IF;

        IF NOT EXISTS (
            SELECT 1 FROM activity_overrides
            WHERE day_approval_id = (SELECT day_approval_id FROM activity_overrides WHERE id = v_orphan.override_id)
              AND activity_type = 'trip'
              AND activity_id = v_new_id
        ) THEN
            UPDATE activity_overrides
            SET activity_id = v_new_id
            WHERE id = v_orphan.override_id;
            v_fixed := v_fixed + 1;
        END IF;
    END LOOP;

    RAISE NOTICE 'Fixed % orphaned overrides', v_fixed;
END $$;
```

**Note:** This is a best-effort cleanup. Overrides that can't be matched (e.g., multiple orphans for the same day) are left as-is — they'll be harmlessly ignored.

**Step 2: Commit**

```bash
git add supabase/migrations/129_approval_stability_cascade.sql
git commit -m "feat: one-time cleanup of orphaned activity overrides"
```

---

### Task 6: Apply migration and verify end-to-end

**Step 1: Apply the migration**

```bash
# Via Supabase MCP apply_migration, or:
cd supabase && supabase db push
```

**Step 2: Verify deterministic IDs**

```sql
-- Pick a completed shift
SELECT id FROM shifts WHERE status = 'completed' ORDER BY clocked_in_at DESC LIMIT 1;

-- Get current trip IDs
SELECT id, started_at FROM trips WHERE shift_id = '<shift_id>' ORDER BY started_at;

-- Re-run detection
SELECT * FROM detect_trips('<shift_id>');

-- Verify same IDs
SELECT id, started_at FROM trips WHERE shift_id = '<shift_id>' ORDER BY started_at;
-- IDs should be identical to the first query
```

**Step 3: Verify cascade logic**

```sql
-- Find a day with overrides
SELECT da.employee_id, da.date, ao.activity_type, ao.override_status
FROM activity_overrides ao
JOIN day_approvals da ON da.id = ao.day_approval_id
WHERE ao.override_status = 'rejected' AND ao.activity_type = 'stop'
LIMIT 5;

-- Get day detail and check trip statuses
SELECT * FROM get_day_approval_detail('<employee_id>', '<date>');
-- Trips adjacent to rejected stops should show auto_status='rejected'
```

**Step 4: Verify unknown = rejected**

```sql
-- Find a stop with no matched location
SELECT sc.id, sc.matched_location_id, sc.started_at
FROM stationary_clusters sc
WHERE sc.matched_location_id IS NULL
LIMIT 5;

-- Get the day detail
SELECT * FROM get_day_approval_detail('<employee_id>', '<date>');
-- That stop should show auto_status='rejected', auto_reason='Lieu non autorisé (inconnu)'
```

**Step 5: Verify weekly summary**

```sql
SELECT * FROM get_weekly_approval_summary('2026-03-03'::DATE);
-- needs_review_count should be lower (unknowns no longer count as needs_review)
```

**Step 6: Final commit**

```bash
git add -A
git commit -m "chore: verify approval stability & cascade migration"
```

---

## Summary of Changes

| What | Where | Change |
|------|-------|--------|
| Deterministic UUIDs | `detect_trips()` lines 617, 919 + cluster INSERTs | `gen_random_uuid()` → `deterministic_activity_id()` |
| Unknown → rejected | `get_day_approval_detail()` stop/clock CTEs | `'needs_review'` → `'rejected'` for NULL location |
| Trip cascade | `get_day_approval_detail()` trip CTE | Replace endpoint-location classification with neighbor-stop cascade |
| Weekly summary sync | `get_weekly_approval_summary()` | Mirror cascade + unknown=rejected changes |
| Orphan cleanup | One-time DO block | Match orphaned overrides to current activities by time |
| Helper function | New `deterministic_activity_id()` | Wraps `uuid_generate_v5` for stable IDs |
