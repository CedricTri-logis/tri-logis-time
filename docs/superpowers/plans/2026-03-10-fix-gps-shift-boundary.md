# Fix GPS Points Outside Shift Boundaries — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate GPS points, clusters, and trips that fall outside their assigned shift's time window — clean existing data, prevent future occurrences, and make the RPC resilient even if bad data slips through.

**Architecture:** Three layers of defense: (1) data cleanup migration removes 3,554 bad GPS points, 33 bad clusters, 14 bad trips; (2) BEFORE INSERT trigger on `gps_points` silently drops points whose `captured_at` is >10 min outside their shift window; (3) RPC `_get_day_approval_detail_base` adds shift-window filtering to stop/trip queries so bad data never reaches the dashboard.

**Tech Stack:** PostgreSQL (Supabase migrations), PL/pgSQL triggers

---

## Chunk 1: Data Cleanup + Prevention Trigger

### Task 1: Create data cleanup and prevention migration

**Files:**
- Create: `supabase/migrations/20260311000000_fix_gps_shift_boundary.sql`

**Context:** The `gps_points.shift_id` column is NOT NULL with FK to `shifts.id`. The `stationary_clusters` and `trips` tables also have `shift_id` FK. GPS points captured between shifts sometimes get assigned to the wrong shift_id during sync, causing overlapping "quarts" in the approval dashboard. Current data corruption: 3,554 bad GPS points (47 shifts, 16 employees), 33 bad clusters (27 shifts), 14 bad trips (10 shifts).

- [ ] **Step 1: Create the migration file**

```sql
-- Migration: Fix GPS points outside shift boundaries
-- Problem: GPS points captured between shifts get assigned to wrong shift_id,
-- causing overlapping activities in the approval dashboard.
-- Scope: 3,554 bad GPS points, 33 bad clusters, 14 bad trips.

BEGIN;

-- ============================================================
-- PART 1: Data cleanup — delete GPS data outside shift windows
-- ============================================================

-- 1a. Delete bad trips first (depends on clusters via start_cluster_id/end_cluster_id)
DELETE FROM trips t
USING shifts s
WHERE s.id = t.shift_id
  AND (t.started_at < s.clocked_in_at - interval '10 minutes'
    OR t.ended_at > s.clocked_out_at + interval '10 minutes');

-- 1b. Delete bad stationary_clusters
DELETE FROM stationary_clusters sc
USING shifts s
WHERE s.id = sc.shift_id
  AND (sc.started_at < s.clocked_in_at - interval '10 minutes'
    OR sc.ended_at > s.clocked_out_at + interval '10 minutes');

-- 1c. Delete bad GPS points
DELETE FROM gps_points gp
USING shifts s
WHERE s.id = gp.shift_id
  AND (gp.captured_at < s.clocked_in_at - interval '10 minutes'
    OR gp.captured_at > s.clocked_out_at + interval '10 minutes');

-- ============================================================
-- PART 2: Prevention trigger — silently drop future bad inserts
-- ============================================================

CREATE OR REPLACE FUNCTION validate_gps_point_shift_boundary()
RETURNS TRIGGER AS $$
DECLARE
    v_clocked_in  TIMESTAMPTZ;
    v_clocked_out TIMESTAMPTZ;
BEGIN
    -- Look up the shift's time window
    SELECT clocked_in_at, clocked_out_at
    INTO v_clocked_in, v_clocked_out
    FROM shifts
    WHERE id = NEW.shift_id;

    -- If shift not found, allow insert (FK constraint will catch invalid shift_id)
    IF NOT FOUND THEN
        RETURN NEW;
    END IF;

    -- For active shifts (no clock-out yet), only validate against clock-in
    IF v_clocked_out IS NULL THEN
        IF NEW.captured_at < v_clocked_in - interval '10 minutes' THEN
            RETURN NULL; -- silently drop
        END IF;
        RETURN NEW;
    END IF;

    -- For completed shifts, validate both boundaries
    IF NEW.captured_at < v_clocked_in - interval '10 minutes'
       OR NEW.captured_at > v_clocked_out + interval '10 minutes' THEN
        RETURN NULL; -- silently drop
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER gps_point_shift_boundary_check
    BEFORE INSERT ON gps_points
    FOR EACH ROW
    EXECUTE FUNCTION validate_gps_point_shift_boundary();

COMMIT;
```

- [ ] **Step 2: Verify migration locally (dry run counts)**

Run these queries against production to confirm expected deletions before applying:

```sql
-- Expected: ~14 trips
SELECT COUNT(*) FROM trips t JOIN shifts s ON s.id = t.shift_id
WHERE t.started_at < s.clocked_in_at - interval '10 minutes'
   OR t.ended_at > s.clocked_out_at + interval '10 minutes';

-- Expected: ~33 clusters
SELECT COUNT(*) FROM stationary_clusters sc JOIN shifts s ON s.id = sc.shift_id
WHERE sc.started_at < s.clocked_in_at - interval '10 minutes'
   OR sc.ended_at > s.clocked_out_at + interval '10 minutes';

-- Expected: ~3554 GPS points
SELECT COUNT(*) FROM gps_points gp JOIN shifts s ON s.id = gp.shift_id
WHERE gp.captured_at < s.clocked_in_at - interval '10 minutes'
   OR gp.captured_at > s.clocked_out_at + interval '10 minutes';
```

- [ ] **Step 3: Apply migration via MCP**

- [ ] **Step 4: Verify cleanup succeeded**

```sql
-- Should all return 0
SELECT COUNT(*) FROM gps_points gp JOIN shifts s ON s.id = gp.shift_id
WHERE gp.captured_at < s.clocked_in_at - interval '10 minutes'
   OR gp.captured_at > s.clocked_out_at + interval '10 minutes';

SELECT COUNT(*) FROM stationary_clusters sc JOIN shifts s ON s.id = sc.shift_id
WHERE sc.started_at < s.clocked_in_at - interval '10 minutes'
   OR sc.ended_at > s.clocked_out_at + interval '10 minutes';

SELECT COUNT(*) FROM trips t JOIN shifts s ON s.id = t.shift_id
WHERE t.started_at < s.clocked_in_at - interval '10 minutes'
   OR t.ended_at > s.clocked_out_at + interval '10 minutes';
```

- [ ] **Step 5: Verify trigger works**

```sql
-- Test: insert a GPS point 2 hours before shift start (should be silently dropped)
-- Pick an existing completed shift for testing
WITH test_shift AS (
    SELECT id, employee_id, clocked_in_at FROM shifts
    WHERE status = 'completed' LIMIT 1
)
INSERT INTO gps_points (id, client_id, shift_id, employee_id, latitude, longitude, accuracy, captured_at, received_at, device_id)
SELECT gen_random_uuid(), gen_random_uuid(), ts.id, ts.employee_id, 0, 0, 10,
       ts.clocked_in_at - interval '2 hours', now(), 'test-trigger'
FROM test_shift ts;

-- Verify: should return 0 rows (the insert was silently dropped)
SELECT COUNT(*) FROM gps_points WHERE device_id = 'test-trigger';

-- Cleanup test data if any slipped through
DELETE FROM gps_points WHERE device_id = 'test-trigger';
```

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/20260311000000_fix_gps_shift_boundary.sql
git commit -m "fix: cleanup GPS data outside shift boundaries and add prevention trigger

Deletes 3,554 GPS points, 33 clusters, and 14 trips that were incorrectly
assigned to shifts outside their time window. Adds BEFORE INSERT trigger
on gps_points to silently drop future out-of-bounds inserts (10 min buffer)."
```

---

## Chunk 2: RPC Defense in Depth

### Task 2: Add shift-window filtering to approval detail RPC

**Files:**
- Create: `supabase/migrations/20260311010000_approval_detail_shift_window_filter.sql`

**Context:** The `_get_day_approval_detail_base` function builds the activity timeline from `stationary_clusters`, `trips`, `shifts`, and `lunch_breaks`. Currently, stops and trips are filtered only by date range and employee_id — NOT by their shift's actual time window. This means if bad data gets past the trigger (e.g., trigger didn't exist yet, race conditions), the dashboard would still show overlapping activities. Adding a JOIN to `shifts` for the stop/trip CTEs provides defense in depth.

**CRITICAL:** The function currently has lunch_breaks support (CTE `lunch_data`), call shift billing logic, and cluster-based location fallback for trips. ALL of these must be preserved exactly. Only the `stop_data` and `trip_data` WHERE clauses change.

- [ ] **Step 1: Create the migration file**

The ONLY changes vs. the current function are (marked with `-- NEW`):

In `stop_data` CTE:
- Add: `JOIN shifts s_stop ON s_stop.id = sc.shift_id`
- Add: `AND sc.started_at >= s_stop.clocked_in_at - interval '10 minutes'`

In `trip_data` CTE:
- Add: `JOIN shifts s_trip ON s_trip.id = t.shift_id`
- Add: `AND t.started_at >= s_trip.clocked_in_at - interval '10 minutes'`

The full migration rewrites `_get_day_approval_detail_base` with CREATE OR REPLACE, keeping everything identical except those 4 lines.

```sql
-- Migration: Add shift-window filtering to approval detail RPC
-- Defense in depth: even if bad GPS data exists, the dashboard won't show
-- activities that fall outside their shift's actual time window.
CREATE OR REPLACE FUNCTION _get_day_approval_detail_base(p_employee_id uuid, p_date date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_result JSONB;
    v_activities JSONB;
    v_day_approval RECORD;
    v_total_shift_minutes INTEGER;
    v_lunch_minutes INTEGER := 0;
    v_approved_minutes INTEGER := 0;
    v_rejected_minutes INTEGER := 0;
    v_needs_review_count INTEGER := 0;
    v_has_active_shift BOOLEAN := FALSE;
    v_call_count INTEGER := 0;
    v_call_billed_minutes INTEGER := 0;
    v_call_bonus_minutes INTEGER := 0;
BEGIN
    SELECT EXISTS(
        SELECT 1 FROM shifts
        WHERE employee_id = p_employee_id
          AND clocked_in_at::DATE = p_date
          AND status = 'active'
    ) INTO v_has_active_shift;

    SELECT * INTO v_day_approval
    FROM day_approvals
    WHERE employee_id = p_employee_id AND date = p_date;

    IF v_day_approval.status = 'approved' THEN
        NULL;
    END IF;

    SELECT COALESCE(SUM(
        EXTRACT(EPOCH FROM (COALESCE(clocked_out_at, now()) - clocked_in_at)) / 60
    )::INTEGER, 0)
    INTO v_total_shift_minutes
    FROM shifts
    WHERE employee_id = p_employee_id
      AND clocked_in_at::DATE = p_date
      AND status = 'completed';

    SELECT COALESCE(SUM(
        EXTRACT(EPOCH FROM (lb.ended_at - lb.started_at)) / 60
    )::INTEGER, 0)
    INTO v_lunch_minutes
    FROM lunch_breaks lb
    WHERE lb.employee_id = p_employee_id
      AND lb.started_at::DATE = p_date
      AND lb.ended_at IS NOT NULL;

    v_total_shift_minutes := GREATEST(v_total_shift_minutes - v_lunch_minutes, 0);

    WITH call_shifts_ordered AS (
        SELECT
            id,
            clocked_in_at,
            clocked_out_at,
            ROW_NUMBER() OVER (ORDER BY clocked_in_at) AS rn
        FROM shifts
        WHERE employee_id = p_employee_id
          AND clocked_in_at::DATE = p_date
          AND shift_type = 'call'
          AND status = 'completed'
    ),
    call_with_groups AS (
        SELECT
            cs.*,
            SUM(CASE
                WHEN cs.rn = 1 THEN 1
                WHEN cs.clocked_in_at >= (
                    SELECT GREATEST(
                        prev.clocked_in_at + INTERVAL '3 hours',
                        COALESCE(prev.clocked_out_at, prev.clocked_in_at + INTERVAL '3 hours')
                    )
                    FROM call_shifts_ordered prev
                    WHERE prev.rn = cs.rn - 1
                ) THEN 1
                ELSE 0
            END) OVER (ORDER BY cs.rn) AS group_id
        FROM call_shifts_ordered cs
    ),
    call_group_billing AS (
        SELECT
            group_id,
            COUNT(*) AS shifts_in_group,
            GREATEST(
                EXTRACT(EPOCH FROM (MAX(clocked_out_at) - MIN(clocked_in_at))) / 60,
                180
            )::INTEGER AS group_billed_minutes,
            GREATEST(0, 180 - EXTRACT(EPOCH FROM (MAX(clocked_out_at) - MIN(clocked_in_at))) / 60)::INTEGER AS group_bonus_minutes
        FROM call_with_groups
        GROUP BY group_id
    )
    SELECT
        COALESCE(SUM(shifts_in_group), 0)::INTEGER,
        COALESCE(SUM(group_billed_minutes), 0)::INTEGER,
        COALESCE(SUM(group_bonus_minutes), 0)::INTEGER
    INTO v_call_count, v_call_billed_minutes, v_call_bonus_minutes
    FROM call_group_billing;

    WITH stop_data AS (
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
            NULL::TEXT AS end_location_type,
            NULL::TEXT AS shift_type,
            NULL::TEXT AS shift_type_source
        FROM stationary_clusters sc
        JOIN shifts s_stop ON s_stop.id = sc.shift_id  -- NEW: join to shift
        LEFT JOIN locations l ON l.id = sc.matched_location_id
        WHERE sc.employee_id = p_employee_id
          AND sc.started_at >= p_date::TIMESTAMPTZ
          AND sc.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
          AND sc.duration_seconds >= 180
          AND sc.started_at >= s_stop.clocked_in_at - interval '10 minutes'  -- NEW: shift boundary
    ),
    stop_classified AS (
        SELECT
            sd.*,
            ao.override_status,
            ao.reason AS override_reason,
            COALESCE(ao.override_status, sd.auto_status) AS final_status
        FROM stop_data sd
        LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'stop' AND ao.activity_id = sd.activity_id
    ),
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
            CASE
                WHEN t.has_gps_gap = TRUE THEN
                    CASE
                        WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'rejected'
                        WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'approved'
                        WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL THEN dep_stop.final_status
                        WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL THEN arr_stop.final_status
                        ELSE 'needs_review'
                    END
                WHEN t.duration_minutes > 60 THEN 'needs_review'
                WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'rejected'
                WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'approved'
                WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL THEN dep_stop.final_status
                WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL THEN arr_stop.final_status
                ELSE 'needs_review'
            END AS auto_status,
            CASE
                WHEN t.has_gps_gap = TRUE THEN
                    CASE
                        WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'Trajet vers/depuis lieu non autorisé'
                        WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'Déplacement professionnel'
                        WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL THEN
                            CASE WHEN dep_stop.final_status = 'approved' THEN 'Déplacement professionnel' ELSE 'Trajet vers/depuis lieu non autorisé' END
                        WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL THEN
                            CASE WHEN arr_stop.final_status = 'approved' THEN 'Déplacement professionnel' ELSE 'Trajet vers/depuis lieu non autorisé' END
                        ELSE 'Données GPS incomplètes'
                    END
                WHEN t.duration_minutes > 60 THEN 'Trajet anormalement long (>' || t.duration_minutes || ' min)'
                WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'Trajet vers/depuis lieu non autorisé'
                WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'Déplacement professionnel'
                WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL THEN
                    CASE WHEN dep_stop.final_status = 'approved' THEN 'Déplacement professionnel' ELSE 'Trajet vers/depuis lieu non autorisé' END
                WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL THEN
                    CASE WHEN arr_stop.final_status = 'approved' THEN 'Déplacement professionnel' ELSE 'Trajet vers/depuis lieu non autorisé' END
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
            COALESCE(el.location_type, arr_loc.location_type)::TEXT AS end_location_type,
            NULL::TEXT AS shift_type,
            NULL::TEXT AS shift_type_source
        FROM trips t
        JOIN shifts s_trip ON s_trip.id = t.shift_id  -- NEW: join to shift
        LEFT JOIN locations sl ON sl.id = t.start_location_id
        LEFT JOIN locations el ON el.id = t.end_location_id
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
          AND t.started_at >= s_trip.clocked_in_at - interval '10 minutes'  -- NEW: shift boundary
    ),
    clock_data AS (
        SELECT
            'clock_in'::TEXT AS activity_type,
            s.id AS activity_id,
            s.id AS shift_id,
            s.clocked_in_at AS started_at,
            s.clocked_in_at AS ended_at,
            0 AS duration_minutes,
            ci_loc.id AS matched_location_id,
            ci_loc.name AS location_name,
            ci_loc.location_type::TEXT AS location_type,
            (s.clock_in_location->>'latitude')::DECIMAL AS latitude,
            (s.clock_in_location->>'longitude')::DECIMAL AS longitude,
            NULL::INTEGER AS gps_gap_seconds,
            NULL::INTEGER AS gps_gap_count,
            CASE
                WHEN ci_loc.location_type IN ('office', 'building') THEN 'approved'
                WHEN ci_loc.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                WHEN ci_loc.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN ci_loc.id IS NULL THEN 'rejected'
                ELSE 'rejected'
            END AS auto_status,
            CASE
                WHEN ci_loc.location_type IN ('office', 'building') THEN 'Clock-in sur lieu de travail'
                WHEN ci_loc.location_type = 'vendor' THEN 'Clock-in chez fournisseur (à vérifier)'
                WHEN ci_loc.location_type = 'gaz' THEN 'Clock-in station-service (à vérifier)'
                WHEN ci_loc.location_type = 'home' THEN 'Clock-in depuis le domicile'
                WHEN ci_loc.location_type IN ('cafe_restaurant', 'other') THEN 'Clock-in hors lieu de travail'
                WHEN ci_loc.id IS NULL THEN 'Clock-in lieu non autorisé'
                ELSE 'Clock-in lieu non autorisé'
            END AS auto_reason,
            NULL::DECIMAL AS distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type,
            s.shift_type::TEXT AS shift_type,
            s.shift_type_source::TEXT AS shift_type_source
        FROM shifts s
        LEFT JOIN LATERAL (
            SELECT l.id, l.name, l.location_type
            FROM locations l
            WHERE l.is_active = TRUE
              AND s.clock_in_location IS NOT NULL
              AND ST_DWithin(
                  l.location::geography,
                  ST_SetSRID(ST_MakePoint(
                      (s.clock_in_location->>'longitude')::DOUBLE PRECISION,
                      (s.clock_in_location->>'latitude')::DOUBLE PRECISION
                  ), 4326)::geography,
                  GREATEST(l.radius_meters, COALESCE(s.clock_in_accuracy, 0))
              )
            ORDER BY ST_Distance(
                l.location::geography,
                ST_SetSRID(ST_MakePoint(
                    (s.clock_in_location->>'longitude')::DOUBLE PRECISION,
                    (s.clock_in_location->>'latitude')::DOUBLE PRECISION
                ), 4326)::geography
            )
            LIMIT 1
        ) ci_loc ON TRUE
        WHERE s.employee_id = p_employee_id
          AND s.clocked_in_at::DATE = p_date
          AND s.status = 'completed'
          AND s.clock_in_location IS NOT NULL

        UNION ALL

        SELECT
            'clock_out'::TEXT,
            s.id,
            s.id AS shift_id,
            s.clocked_out_at,
            s.clocked_out_at,
            0 AS duration_minutes,
            co_loc.id AS matched_location_id,
            co_loc.name AS location_name,
            co_loc.location_type::TEXT AS location_type,
            (s.clock_out_location->>'latitude')::DECIMAL,
            (s.clock_out_location->>'longitude')::DECIMAL,
            NULL::INTEGER,
            NULL::INTEGER,
            CASE
                WHEN co_loc.location_type IN ('office', 'building') THEN 'approved'
                WHEN co_loc.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                WHEN co_loc.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN co_loc.id IS NULL THEN 'rejected'
                ELSE 'rejected'
            END,
            CASE
                WHEN co_loc.location_type IN ('office', 'building') THEN 'Clock-out sur lieu de travail'
                WHEN co_loc.location_type = 'vendor' THEN 'Clock-out chez fournisseur (à vérifier)'
                WHEN co_loc.location_type = 'gaz' THEN 'Clock-out station-service (à vérifier)'
                WHEN co_loc.location_type = 'home' THEN 'Clock-out au domicile'
                WHEN co_loc.location_type IN ('cafe_restaurant', 'other') THEN 'Clock-out hors lieu de travail'
                WHEN co_loc.id IS NULL THEN 'Clock-out lieu non autorisé'
                ELSE 'Clock-out lieu non autorisé'
            END,
            NULL::DECIMAL,
            NULL::TEXT,
            NULL::BOOLEAN,
            NULL::UUID,
            NULL::TEXT,
            NULL::TEXT,
            NULL::UUID,
            NULL::TEXT,
            NULL::TEXT,
            s.shift_type::TEXT,
            s.shift_type_source::TEXT
        FROM shifts s
        LEFT JOIN LATERAL (
            SELECT l.id, l.name, l.location_type
            FROM locations l
            WHERE l.is_active = TRUE
              AND s.clock_out_location IS NOT NULL
              AND ST_DWithin(
                  l.location::geography,
                  ST_SetSRID(ST_MakePoint(
                      (s.clock_out_location->>'longitude')::DOUBLE PRECISION,
                      (s.clock_out_location->>'latitude')::DOUBLE PRECISION
                  ), 4326)::geography,
                  GREATEST(l.radius_meters, COALESCE(s.clock_out_accuracy, 0))
              )
            ORDER BY ST_Distance(
                l.location::geography,
                ST_SetSRID(ST_MakePoint(
                    (s.clock_out_location->>'longitude')::DOUBLE PRECISION,
                    (s.clock_out_location->>'latitude')::DOUBLE PRECISION
                ), 4326)::geography
            )
            LIMIT 1
        ) co_loc ON TRUE
        WHERE s.employee_id = p_employee_id
          AND s.clocked_out_at::DATE = p_date
          AND s.status = 'completed'
          AND s.clock_out_location IS NOT NULL
          AND s.clocked_out_at IS NOT NULL
    ),
    lunch_data AS (
        SELECT
            'lunch'::TEXT AS activity_type,
            lb.id AS activity_id,
            lb.shift_id,
            lb.started_at,
            lb.ended_at,
            (EXTRACT(EPOCH FROM (lb.ended_at - lb.started_at)) / 60)::INTEGER AS duration_minutes,
            NULL::UUID AS matched_location_id,
            NULL::TEXT AS location_name,
            NULL::TEXT AS location_type,
            NULL::DECIMAL AS latitude,
            NULL::DECIMAL AS longitude,
            NULL::INTEGER AS gps_gap_seconds,
            NULL::INTEGER AS gps_gap_count,
            'approved'::TEXT AS auto_status,
            'Pause dîner'::TEXT AS auto_reason,
            NULL::TEXT AS override_status,
            NULL::TEXT AS override_reason,
            'approved'::TEXT AS final_status,
            NULL::DECIMAL AS distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type,
            NULL::TEXT AS shift_type,
            NULL::TEXT AS shift_type_source
        FROM lunch_breaks lb
        WHERE lb.employee_id = p_employee_id
          AND lb.started_at::DATE = p_date
          AND lb.ended_at IS NOT NULL
    ),
    classified AS (
        SELECT
            sc.activity_type, sc.activity_id, sc.shift_id,
            sc.started_at, sc.ended_at, sc.duration_minutes,
            sc.matched_location_id, sc.location_name, sc.location_type,
            sc.latitude, sc.longitude, sc.gps_gap_seconds, sc.gps_gap_count,
            sc.auto_status, sc.auto_reason,
            sc.override_status, sc.override_reason, sc.final_status,
            sc.distance_km, sc.transport_mode, sc.has_gps_gap,
            sc.start_location_id, sc.start_location_name, sc.start_location_type,
            sc.end_location_id, sc.end_location_name, sc.end_location_type,
            sc.shift_type, sc.shift_type_source
        FROM stop_classified sc

        UNION ALL

        SELECT
            td.activity_type, td.activity_id, td.shift_id,
            td.started_at, td.ended_at, td.duration_minutes,
            td.matched_location_id, td.location_name, td.location_type,
            td.latitude, td.longitude, td.gps_gap_seconds, td.gps_gap_count,
            td.auto_status, td.auto_reason,
            tao.override_status, tao.reason AS override_reason,
            COALESCE(tao.override_status, td.auto_status) AS final_status,
            td.distance_km, td.transport_mode, td.has_gps_gap,
            td.start_location_id, td.start_location_name, td.start_location_type,
            td.end_location_id, td.end_location_name, td.end_location_type,
            td.shift_type, td.shift_type_source
        FROM trip_data td
        LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides tao ON tao.day_approval_id = da.id
            AND tao.activity_type = 'trip' AND tao.activity_id = td.activity_id

        UNION ALL

        SELECT
            cd.activity_type, cd.activity_id, cd.shift_id,
            cd.started_at, cd.ended_at, cd.duration_minutes,
            cd.matched_location_id, cd.location_name, cd.location_type,
            cd.latitude, cd.longitude, cd.gps_gap_seconds, cd.gps_gap_count,
            cd.auto_status, cd.auto_reason,
            cao.override_status, cao.reason AS override_reason,
            COALESCE(cao.override_status, cd.auto_status) AS final_status,
            cd.distance_km, cd.transport_mode, cd.has_gps_gap,
            cd.start_location_id, cd.start_location_name, cd.start_location_type,
            cd.end_location_id, cd.end_location_name, cd.end_location_type,
            cd.shift_type, cd.shift_type_source
        FROM clock_data cd
        LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides cao ON cao.day_approval_id = da.id
            AND cao.activity_type = cd.activity_type AND cao.activity_id = cd.activity_id

        UNION ALL

        SELECT
            ld.activity_type, ld.activity_id, ld.shift_id,
            ld.started_at, ld.ended_at, ld.duration_minutes,
            ld.matched_location_id, ld.location_name, ld.location_type,
            ld.latitude, ld.longitude, ld.gps_gap_seconds, ld.gps_gap_count,
            ld.auto_status, ld.auto_reason,
            ld.override_status, ld.override_reason, ld.final_status,
            ld.distance_km, ld.transport_mode, ld.has_gps_gap,
            ld.start_location_id, ld.start_location_name, ld.start_location_type,
            ld.end_location_id, ld.end_location_name, ld.end_location_type,
            ld.shift_type, ld.shift_type_source
        FROM lunch_data ld

        ORDER BY started_at ASC
    )
    SELECT jsonb_agg(
        jsonb_build_object(
            'activity_type', c.activity_type,
            'activity_id', c.activity_id,
            'shift_id', c.shift_id,
            'started_at', c.started_at,
            'ended_at', c.ended_at,
            'duration_minutes', c.duration_minutes,
            'auto_status', c.auto_status,
            'auto_reason', c.auto_reason,
            'override_status', c.override_status,
            'override_reason', c.override_reason,
            'final_status', c.final_status,
            'matched_location_id', c.matched_location_id,
            'location_name', c.location_name,
            'location_type', c.location_type,
            'latitude', c.latitude,
            'longitude', c.longitude,
            'distance_km', c.distance_km,
            'transport_mode', c.transport_mode,
            'has_gps_gap', c.has_gps_gap,
            'start_location_id', c.start_location_id,
            'start_location_name', c.start_location_name,
            'start_location_type', c.start_location_type,
            'end_location_id', c.end_location_id,
            'end_location_name', c.end_location_name,
            'end_location_type', c.end_location_type,
            'gps_gap_seconds', c.gps_gap_seconds,
            'gps_gap_count', c.gps_gap_count,
            'shift_type', c.shift_type,
            'shift_type_source', c.shift_type_source
        )
        ORDER BY c.started_at ASC
    )
    INTO v_activities
    FROM classified c;

    SELECT
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (WHERE a->>'final_status' = 'approved' AND a->>'activity_type' != 'lunch'), 0),
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (WHERE a->>'final_status' = 'rejected'), 0),
        COALESCE(COUNT(*) FILTER (WHERE a->>'final_status' = 'needs_review'
            AND NOT (
                a->>'activity_type' IN ('clock_in', 'clock_out', 'lunch')
                AND EXISTS (
                    SELECT 1 FROM jsonb_array_elements(COALESCE(v_activities, '[]'::JSONB)) s
                    WHERE s->>'activity_type' = 'stop'
                      AND (a->>'started_at')::TIMESTAMPTZ >= ((s->>'started_at')::TIMESTAMPTZ - INTERVAL '60 seconds')
                      AND (a->>'started_at')::TIMESTAMPTZ <= ((s->>'ended_at')::TIMESTAMPTZ + INTERVAL '60 seconds')
                )
            )
        ), 0)
    INTO v_approved_minutes, v_rejected_minutes, v_needs_review_count
    FROM jsonb_array_elements(COALESCE(v_activities, '[]'::JSONB)) a;

    IF v_day_approval.status = 'approved' THEN
        v_approved_minutes := v_day_approval.approved_minutes;
        v_rejected_minutes := v_day_approval.rejected_minutes;
        v_needs_review_count := 0;
    END IF;

    v_result := jsonb_build_object(
        'employee_id', p_employee_id,
        'date', p_date,
        'has_active_shift', v_has_active_shift,
        'approval_status', COALESCE(v_day_approval.status, 'pending'),
        'approved_by', v_day_approval.approved_by,
        'approved_at', v_day_approval.approved_at,
        'notes', v_day_approval.notes,
        'activities', COALESCE(v_activities, '[]'::JSONB),
        'summary', jsonb_build_object(
            'total_shift_minutes', v_total_shift_minutes,
            'approved_minutes', v_approved_minutes,
            'rejected_minutes', v_rejected_minutes,
            'needs_review_count', v_needs_review_count,
            'lunch_minutes', v_lunch_minutes,
            'call_count', v_call_count,
            'call_billed_minutes', v_call_billed_minutes,
            'call_bonus_minutes', v_call_bonus_minutes
        )
    );

    RETURN v_result;
END;
$function$;
```

- [ ] **Step 2: Apply migration via MCP**

- [ ] **Step 3: Verify Cedric Lajoie's March 9 no longer shows overlap**

```sql
SELECT * FROM get_day_approval_detail(
    'c10e567e-1fc2-4cbe-b481-d43a72a1f4fd'::uuid,
    '2026-03-09'::date
);
```

Verify: The last 2 activities should NOT both start at 18:06. They should start at their actual shift clock-in times (20:35 and 21:39).

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260311010000_approval_detail_shift_window_filter.sql
git commit -m "fix: add shift-window filtering to approval detail RPC

Defense in depth: stops and trips are now filtered to only include
activities whose started_at falls within their shift's clocked_in_at
to clocked_out_at window (10 min buffer). Prevents overlapping
activities in the dashboard even if bad GPS data exists."
```
