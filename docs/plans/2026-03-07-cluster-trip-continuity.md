# Cluster-Trip Continuity Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ensure every pair of consecutive clusters always has a visible trip between them, clock-in/out transitions show as movement lines, and OSRM estimates fill GPS gaps.

**Architecture:** Simplify `detect_trips` to completed-shifts-only, add post-processing for synthetic trips, extend OSRM Edge Function for route estimation, add gap entries to activity RPCs, and simplify trip display in dashboard.

**Tech Stack:** PostgreSQL (Supabase migrations), TypeScript/Next.js (dashboard), Deno (Edge Function)

**Design doc:** `docs/plans/2026-03-07-cluster-trip-continuity-design.md`

---

## Task 1: Simplify detect_trips to completed-shifts-only + synthetic trips

**Files:**
- Create: `supabase/migrations/129_detect_trips_completed_only.sql`

**What changes in detect_trips:**

1. **Remove active-shift branching:** Delete the `v_create_clusters` conditional logic. The function now always creates clusters and always does full re-detection (delete all existing trips/clusters for the shift first). If the shift is not `'completed'`, return early with no results.

2. **Add section 9 — synthetic trip post-processing:** After `compute_gps_gaps()`, scan consecutive cluster pairs and INSERT trips where none exist.

**Step 1: Read current detect_trips function**

Read the latest full function from `supabase/migrations/122_gps_gap_visibility.sql` (with patches from 123, 124, 126). Identify:
- All `v_create_clusters` conditionals to remove
- The active-shift partial deletion logic to remove
- The DECLARE block for adding `v_gap_rec RECORD`

**Step 2: Write the migration**

```sql
-- Migration 129: Simplify detect_trips to completed-shifts-only + synthetic trips
--
-- Changes:
-- 1. Return early if shift is not 'completed' (no more active-shift detection)
-- 2. Always create clusters (remove v_create_clusters branching)
-- 3. Post-processing: insert synthetic trips for consecutive cluster pairs without trips

CREATE OR REPLACE FUNCTION detect_trips(p_shift_id UUID)
RETURNS TABLE (
    trip_id UUID,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    start_lat DECIMAL(10,8),
    start_lng DECIMAL(11,8),
    end_lat DECIMAL(10,8),
    end_lng DECIMAL(11,8),
    distance DECIMAL,
    duration INTEGER,
    confidence DECIMAL,
    point_count INTEGER
) AS $$
DECLARE
    -- [all existing variables]
    v_gap_rec RECORD;  -- NEW: for synthetic trip loop
BEGIN
    -- Advisory lock
    PERFORM pg_advisory_xact_lock(hashtext(p_shift_id::text));

    -- Validate shift exists and is COMPLETED
    SELECT s.employee_id, s.status INTO v_employee_id, v_shift_status
    FROM shifts s WHERE s.id = p_shift_id;

    IF v_employee_id IS NULL THEN
        RAISE EXCEPTION 'Shift not found: %', p_shift_id;
    END IF;

    -- NEW: Only process completed shifts
    IF v_shift_status != 'completed' THEN
        RETURN;  -- No-op for active shifts
    END IF;

    -- Delete ALL existing trips and clusters (always full re-detection)
    DELETE FROM trip_gps_points WHERE trip_id IN (
        SELECT id FROM trips WHERE shift_id = p_shift_id
    );
    DELETE FROM trips WHERE shift_id = p_shift_id;
    DELETE FROM stationary_clusters WHERE shift_id = p_shift_id;
    UPDATE gps_points SET stationary_cluster_id = NULL
    WHERE shift_id = p_shift_id AND stationary_cluster_id IS NOT NULL;

    -- [... rest of detection algorithm unchanged, but remove all
    --  IF v_create_clusters THEN guards — always create clusters ...]

    -- =========================================================================
    -- 7. Post-processing: compute effective location types for clusters
    -- =========================================================================
    PERFORM compute_cluster_effective_types(p_shift_id, v_employee_id);

    -- =========================================================================
    -- 8. Post-processing: compute GPS gap metrics for clusters and trips
    -- =========================================================================
    PERFORM compute_gps_gaps(p_shift_id);

    -- =========================================================================
    -- 9. Post-processing: fill missing trips between consecutive clusters
    -- =========================================================================
    FOR v_gap_rec IN
        WITH ordered_clusters AS (
            SELECT
                id AS cluster_id,
                centroid_latitude,
                centroid_longitude,
                centroid_accuracy,
                started_at,
                ended_at,
                matched_location_id,
                ROW_NUMBER() OVER (ORDER BY started_at) AS seq
            FROM stationary_clusters
            WHERE shift_id = p_shift_id
        ),
        consecutive_pairs AS (
            SELECT
                c1.cluster_id AS from_cluster_id,
                c1.centroid_latitude AS from_lat,
                c1.centroid_longitude AS from_lng,
                c1.centroid_accuracy AS from_acc,
                c1.ended_at AS from_ended,
                c1.matched_location_id AS from_location_id,
                c2.cluster_id AS to_cluster_id,
                c2.centroid_latitude AS to_lat,
                c2.centroid_longitude AS to_lng,
                c2.centroid_accuracy AS to_acc,
                c2.started_at AS to_started,
                c2.matched_location_id AS to_location_id
            FROM ordered_clusters c1
            JOIN ordered_clusters c2 ON c2.seq = c1.seq + 1
        )
        SELECT cp.*
        FROM consecutive_pairs cp
        WHERE NOT EXISTS (
            SELECT 1 FROM trips t
            WHERE t.shift_id = p_shift_id
              AND t.start_cluster_id = cp.from_cluster_id
              AND t.end_cluster_id = cp.to_cluster_id
        )
    LOOP
        v_trip_id := gen_random_uuid();
        v_trip_distance := haversine_km(
            v_gap_rec.from_lat, v_gap_rec.from_lng,
            v_gap_rec.to_lat, v_gap_rec.to_lng
        );

        INSERT INTO trips (
            id, shift_id, employee_id,
            started_at, ended_at,
            start_latitude, start_longitude,
            end_latitude, end_longitude,
            distance_km, duration_minutes,
            classification, confidence_score,
            gps_point_count, low_accuracy_segments,
            detection_method, transport_mode,
            start_cluster_id, end_cluster_id,
            has_gps_gap,
            start_location_id, end_location_id
        ) VALUES (
            v_trip_id, p_shift_id, v_employee_id,
            v_gap_rec.from_ended,
            v_gap_rec.to_started,
            v_gap_rec.from_lat, v_gap_rec.from_lng,
            v_gap_rec.to_lat, v_gap_rec.to_lng,
            ROUND(v_trip_distance, 3),
            GREATEST(0, EXTRACT(EPOCH FROM (v_gap_rec.to_started - v_gap_rec.from_ended)) / 60)::INTEGER,
            'business', 0.00, 0, 0, 'auto', 'unknown',
            v_gap_rec.from_cluster_id, v_gap_rec.to_cluster_id,
            TRUE,
            COALESCE(v_gap_rec.from_location_id,
                match_trip_to_location(v_gap_rec.from_lat, v_gap_rec.from_lng, v_gap_rec.from_acc)),
            COALESCE(v_gap_rec.to_location_id,
                match_trip_to_location(v_gap_rec.to_lat, v_gap_rec.to_lng, v_gap_rec.to_acc))
        );

        UPDATE trips SET
            gps_gap_seconds = GREATEST(0, EXTRACT(EPOCH FROM (v_gap_rec.to_started - v_gap_rec.from_ended)))::INTEGER,
            gps_gap_count = 1
        WHERE id = v_trip_id;

        RETURN QUERY SELECT
            v_trip_id, v_gap_rec.from_ended, v_gap_rec.to_started,
            v_gap_rec.from_lat::DECIMAL(10,8), v_gap_rec.from_lng::DECIMAL(11,8),
            v_gap_rec.to_lat::DECIMAL(10,8), v_gap_rec.to_lng::DECIMAL(11,8),
            ROUND(v_trip_distance, 3),
            GREATEST(0, EXTRACT(EPOCH FROM (v_gap_rec.to_started - v_gap_rec.from_ended)) / 60)::INTEGER,
            0.00::DECIMAL, 0;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO public, extensions;
```

**Step 3: Apply migration**

Run: MCP `apply_migration`

**Step 4: Test with known shift**

```sql
SELECT detect_trips('513c121b-e708-4c0f-8e0d-25e75457f151'::UUID);

-- Verify every consecutive cluster pair has a trip
WITH ordered AS (
  SELECT id, ROW_NUMBER() OVER (ORDER BY started_at) AS seq
  FROM stationary_clusters WHERE shift_id = '513c121b-e708-4c0f-8e0d-25e75457f151'
),
pairs AS (
  SELECT c1.id AS a, c2.id AS b
  FROM ordered c1 JOIN ordered c2 ON c2.seq = c1.seq + 1
)
SELECT p.a, p.b, t.id AS trip_id, t.has_gps_gap, t.gps_point_count
FROM pairs p
LEFT JOIN trips t ON t.start_cluster_id = p.a AND t.end_cluster_id = p.b;
-- Expected: every row has a trip_id, no NULLs
```

**Step 5: Verify active shifts are no-op**

```sql
-- Find an active shift
SELECT id FROM shifts WHERE status = 'active' LIMIT 1;
-- Run detect_trips on it — should return empty
SELECT * FROM detect_trips('<active_shift_id>'::UUID);
-- Expected: 0 rows, no trips/clusters created
```

**Step 6: Commit**

```bash
git add supabase/migrations/129_detect_trips_completed_only.sql
git commit -m "feat: detect_trips completed-only + synthetic trips for missing cluster pairs"
```

---

## Task 2: Clock-in/out gap entries in get_employee_activity

**Files:**
- Create: `supabase/migrations/130_activity_clock_gaps.sql`

**Step 1: Write the migration**

Add `clock_in_gap_data` and `clock_out_gap_data` CTEs to `get_employee_activity`. These emit `activity_type='gap'` rows when clock-in/out is > 60 sec from first/last cluster AND locations differ.

```sql
-- Migration 130: Clock-in/out gap entries in get_employee_activity

DROP FUNCTION IF EXISTS get_employee_activity(UUID, DATE, DATE, TEXT, INTEGER);

CREATE OR REPLACE FUNCTION get_employee_activity(
    p_employee_id UUID, p_date_from DATE, p_date_to DATE,
    p_type TEXT DEFAULT 'all', p_min_duration_seconds INTEGER DEFAULT 180
)
RETURNS TABLE (
    -- [same return signature as migration 102]
) AS $$
BEGIN
    RETURN QUERY
    WITH
    trip_data AS ( /* unchanged from 102 */ ),
    stop_data AS ( /* unchanged from 102 */ ),
    clock_in_data AS ( /* unchanged from 102 */ ),
    clock_out_data AS ( /* unchanged from 102 */ ),

    -- NEW: Clock-in gap
    clock_in_gap_data AS (
        SELECT
            'gap'::TEXT AS v_type,
            s.id, s.id AS shift_id,
            s.clocked_in_at AS started_at,
            first_cluster.started_at AS ended_at,
            (s.clock_in_location->>'latitude')::DECIMAL AS start_latitude,
            (s.clock_in_location->>'longitude')::DECIMAL AS start_longitude,
            NULL::TEXT AS start_address,
            s.clock_in_location_id AS start_location_id,
            ci_loc.name::TEXT AS start_location_name,
            first_cluster.centroid_latitude AS end_latitude,
            first_cluster.centroid_longitude AS end_longitude,
            NULL::TEXT AS end_address,
            first_cluster.matched_location_id AS end_location_id,
            fc_loc.name::TEXT AS end_location_name,
            ROUND((111.045 * SQRT(
                POWER(first_cluster.centroid_latitude - (s.clock_in_location->>'latitude')::DECIMAL, 2) +
                POWER((first_cluster.centroid_longitude - (s.clock_in_location->>'longitude')::DECIMAL)
                    * COS(RADIANS(((s.clock_in_location->>'latitude')::DECIMAL
                        + first_cluster.centroid_latitude) / 2)), 2)
            ))::DECIMAL, 3) AS distance_km,
            NULL::DECIMAL AS road_distance_km,
            GREATEST(0, EXTRACT(EPOCH FROM (first_cluster.started_at - s.clocked_in_at)) / 60)::INTEGER
                AS duration_minutes,
            NULL::TEXT, NULL::TEXT, NULL::DECIMAL, NULL::TEXT,
            NULL::UUID AS start_cluster_id,
            first_cluster.id AS end_cluster_id,
            NULL::TEXT, 0::INTEGER, TRUE,
            NULL::DECIMAL, NULL::DECIMAL, NULL::DECIMAL, NULL::INTEGER, NULL::INTEGER,
            NULL::UUID, NULL::TEXT, NULL::INTEGER, NULL::INTEGER, NULL::TEXT,
            (s.clock_in_location->>'latitude')::DECIMAL AS clock_latitude,
            (s.clock_in_location->>'longitude')::DECIMAL AS clock_longitude,
            s.clock_in_accuracy, NULL::TEXT
        FROM shifts s
        CROSS JOIN LATERAL (
            SELECT sc.id, sc.started_at, sc.centroid_latitude,
                   sc.centroid_longitude, sc.matched_location_id
            FROM stationary_clusters sc WHERE sc.shift_id = s.id
            ORDER BY sc.started_at ASC LIMIT 1
        ) first_cluster
        LEFT JOIN locations ci_loc ON ci_loc.id = s.clock_in_location_id
        LEFT JOIN locations fc_loc ON fc_loc.id = first_cluster.matched_location_id
        WHERE s.employee_id = p_employee_id
          AND s.clocked_in_at >= p_date_from::TIMESTAMPTZ
          AND s.clocked_in_at < (p_date_to + INTERVAL '1 day')::TIMESTAMPTZ
          AND s.clock_in_location IS NOT NULL
          AND EXTRACT(EPOCH FROM (first_cluster.started_at - s.clocked_in_at)) > 60
          AND (s.clock_in_location_id IS DISTINCT FROM first_cluster.matched_location_id
               OR s.clock_in_location_id IS NULL
               OR first_cluster.matched_location_id IS NULL)
    ),

    -- NEW: Clock-out gap
    clock_out_gap_data AS (
        SELECT
            'gap'::TEXT AS v_type,
            s.id, s.id AS shift_id,
            last_cluster.ended_at AS started_at,
            s.clocked_out_at AS ended_at,
            last_cluster.centroid_latitude AS start_latitude,
            last_cluster.centroid_longitude AS start_longitude,
            NULL::TEXT AS start_address,
            last_cluster.matched_location_id AS start_location_id,
            lc_loc.name::TEXT AS start_location_name,
            (s.clock_out_location->>'latitude')::DECIMAL AS end_latitude,
            (s.clock_out_location->>'longitude')::DECIMAL AS end_longitude,
            NULL::TEXT AS end_address,
            s.clock_out_location_id AS end_location_id,
            co_loc.name::TEXT AS end_location_name,
            ROUND((111.045 * SQRT(
                POWER((s.clock_out_location->>'latitude')::DECIMAL - last_cluster.centroid_latitude, 2) +
                POWER(((s.clock_out_location->>'longitude')::DECIMAL - last_cluster.centroid_longitude)
                    * COS(RADIANS((last_cluster.centroid_latitude
                        + (s.clock_out_location->>'latitude')::DECIMAL) / 2)), 2)
            ))::DECIMAL, 3) AS distance_km,
            NULL::DECIMAL AS road_distance_km,
            GREATEST(0, EXTRACT(EPOCH FROM (s.clocked_out_at - last_cluster.ended_at)) / 60)::INTEGER
                AS duration_minutes,
            NULL::TEXT, NULL::TEXT, NULL::DECIMAL, NULL::TEXT,
            last_cluster.id AS start_cluster_id,
            NULL::UUID AS end_cluster_id,
            NULL::TEXT, 0::INTEGER, TRUE,
            NULL::DECIMAL, NULL::DECIMAL, NULL::DECIMAL, NULL::INTEGER, NULL::INTEGER,
            NULL::UUID, NULL::TEXT, NULL::INTEGER, NULL::INTEGER, NULL::TEXT,
            (s.clock_out_location->>'latitude')::DECIMAL AS clock_latitude,
            (s.clock_out_location->>'longitude')::DECIMAL AS clock_longitude,
            s.clock_out_accuracy, NULL::TEXT
        FROM shifts s
        CROSS JOIN LATERAL (
            SELECT sc.id, sc.ended_at, sc.centroid_latitude,
                   sc.centroid_longitude, sc.matched_location_id
            FROM stationary_clusters sc WHERE sc.shift_id = s.id
            ORDER BY sc.started_at DESC LIMIT 1
        ) last_cluster
        LEFT JOIN locations co_loc ON co_loc.id = s.clock_out_location_id
        LEFT JOIN locations lc_loc ON lc_loc.id = last_cluster.matched_location_id
        WHERE s.employee_id = p_employee_id
          AND s.clocked_out_at >= p_date_from::TIMESTAMPTZ
          AND s.clocked_out_at < (p_date_to + INTERVAL '1 day')::TIMESTAMPTZ
          AND s.clock_out_location IS NOT NULL
          AND s.clocked_out_at IS NOT NULL
          AND EXTRACT(EPOCH FROM (s.clocked_out_at - last_cluster.ended_at)) > 60
          AND (last_cluster.matched_location_id IS DISTINCT FROM s.clock_out_location_id
               OR last_cluster.matched_location_id IS NULL
               OR s.clock_out_location_id IS NULL)
    )

    SELECT td.* FROM (
        SELECT * FROM trip_data
        UNION ALL SELECT * FROM stop_data
        UNION ALL SELECT * FROM clock_in_data
        UNION ALL SELECT * FROM clock_out_data
        UNION ALL SELECT * FROM clock_in_gap_data
        UNION ALL SELECT * FROM clock_out_gap_data
    ) td
    ORDER BY td.started_at ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

**Step 2: Apply migration**

Run: MCP `apply_migration`

**Step 3: Test**

```sql
SELECT activity_type, started_at, ended_at, distance_km, has_gps_gap,
       start_location_name, end_location_name
FROM get_employee_activity('<employee_id>'::UUID, '2026-03-06', '2026-03-06')
ORDER BY started_at;
-- Expected: 'gap' rows between clock_in and first stop, last stop and clock_out
```

**Step 4: Commit**

```bash
git add supabase/migrations/130_activity_clock_gaps.sql
git commit -m "feat: clock-in/out gap entries in get_employee_activity"
```

---

## Task 3: Clock-in/out gaps in get_day_approval_detail

**Files:**
- Create: `supabase/migrations/131_approval_detail_clock_gaps.sql`

**Step 1: Write the migration**

Add the same `clock_in_gap_data` and `clock_out_gap_data` CTEs to `get_day_approval_detail`. Gap rows get:
- `auto_status = 'needs_review'`
- `auto_reason = 'Deplacement sans trace GPS entre clock-in/out et premier/dernier arret'`

Follow the existing pattern in `get_day_approval_detail` where each activity row gets auto-classification.

**Step 2: Apply and test**

```sql
SELECT jsonb_pretty(get_day_approval_detail('<employee_id>'::UUID, '2026-03-06'::DATE));
-- Check activities array contains 'gap' entries with needs_review status
```

**Step 3: Commit**

```bash
git add supabase/migrations/131_approval_detail_clock_gaps.sql
git commit -m "feat: clock-in/out gap entries in day approval detail"
```

---

## Task 4: OSRM route estimation for synthetic & gap trips

**Files:**
- Modify: `supabase/functions/match-trip-route/index.ts` (Edge Function)

**Step 1: Read current Edge Function**

Read the existing OSRM match Edge Function to understand:
- How it's triggered (webhook? cron? manual?)
- How it calls OSRM `/match`
- How it stores `route_geometry` and `road_distance_km`
- The OSRM server URL and config

**Step 2: Add routing logic for 3 scenarios**

```typescript
// Detect trip type and choose OSRM strategy:
if (trip.gps_point_count === 0) {
  // SYNTHETIC TRIP: use /route endpoint (A → B shortest path)
  const result = await osrmRoute(
    trip.start_latitude, trip.start_longitude,
    trip.end_latitude, trip.end_longitude
  );
  // Store route_geometry + road_distance_km
  // Set match_status = 'matched', match_confidence based on route quality
} else if (trip.has_gps_gap) {
  // TRIP WITH GPS GAP: hybrid /match + /route
  // 1. Get GPS points for this trip
  // 2. Identify gap segments (consecutive points > 5 min apart)
  // 3. For each contiguous GPS segment: call /match
  // 4. For each gap between segments: call /route (last point → first point)
  // 5. Compose geometries: real segments + estimated gap segments
  // 6. Sum distances: matched_distance + estimated_distance
  // 7. Store composite route_geometry + road_distance_km
  //    Store estimated_distance_km in metadata or new column
} else {
  // NORMAL TRIP: existing /match logic (unchanged)
}
```

**Step 3: Add estimated distance tracking**

Add a new column `estimated_distance_km` to the trips table (or use metadata) to track how much of the road distance is estimated vs measured:

```sql
ALTER TABLE trips ADD COLUMN IF NOT EXISTS estimated_distance_km DECIMAL(8,3) DEFAULT 0;
```

This allows displaying `"18.3 km (dont 4.2 km estimes)"`.

**Step 4: OSRM /route helper function**

```typescript
async function osrmRoute(
  startLat: number, startLng: number,
  endLat: number, endLng: number
): Promise<{ geometry: string; distance_km: number }> {
  const url = `${OSRM_URL}/route/v1/driving/${startLng},${startLat};${endLng},${endLat}`
    + `?overview=full&geometries=polyline6`;
  const res = await fetch(url);
  const data = await res.json();
  if (data.code !== 'Ok' || !data.routes?.length) {
    throw new Error(`OSRM route failed: ${data.code}`);
  }
  return {
    geometry: data.routes[0].geometry,
    distance_km: data.routes[0].distance / 1000,
  };
}
```

**Step 5: Test**

```bash
# Test OSRM /route directly
curl "http://localhost:5000/route/v1/driving/-72.05,46.35;-72.03,46.34?overview=full&geometries=polyline6"

# Trigger route matching on a synthetic trip
# Check that route_geometry and road_distance_km are populated
```

**Step 6: Commit**

```bash
git add supabase/functions/match-trip-route/index.ts
git add supabase/migrations/132_estimated_distance_column.sql
git commit -m "feat: OSRM route estimation for synthetic and GPS-gap trips"
```

---

## Task 5: Dashboard - Remove from/to on trips + render gap type + amber style

**Files:**
- Modify: `dashboard/src/components/mileage/activity-tab.tsx`
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx`

**Step 1: Remove from/to location names on trip rows**

In `activity-tab.tsx`, find the trip row rendering. Remove the `start_location_name → end_location_name` display. Keep:
- Duration
- Distance (with estimated portion if applicable)
- Transport mode icon
- GPS gap warning (amber triangle)

The stops above/below already show location context.

**Step 2: Add gap activity type rendering**

```tsx
// Handle activity_type === 'gap'
// Determine if it's clock-in or clock-out gap:
//   - If started_at matches shift's clocked_in_at → clock-in gap
//   - If ended_at matches shift's clocked_out_at → clock-out gap
// (Or check: start_cluster_id is null → clock-in gap, end_cluster_id is null → clock-out gap)

// Visual:
// - Icon: LogIn (lucide) for clock-in gap, LogOut for clock-out gap
// - Background: bg-amber-50/30
// - Left border: dashed amber
// - Label: "Deplacement non trace"
// - Show: duration, distance
// - Keep from/to names on gap rows (no stop context on one side)
```

**Step 3: Amber/dashed style for GPS-gap trips**

For trip rows where `has_gps_gap === true`:
- Left border: dashed amber (instead of solid)
- Subtle amber background
- This applies to both synthetic trips (0 GPS points) and trips with partial GPS

For trip rows where `has_gps_gap === false`:
- Normal solid style (unchanged)

**Step 4: Show estimated distance**

When `estimated_distance_km > 0`:
```tsx
<span>{road_distance_km} km</span>
<span className="text-amber-600 text-xs">(dont {estimated_distance_km} km estimes)</span>
```

**Step 5: Same changes in day-approval-detail.tsx**

Apply identical rendering for gap type and amber style. The approval actions (approve/reject) already work for any activity type.

**Step 6: Test in browser**

- Navigate to Activity tab for employees with known gaps
- Verify: no from/to on trip rows, gap rows with clock icons, amber style on GPS-gap trips
- Navigate to Approvals → day detail for same employees
- Verify: gap rows appear with needs_review status

**Step 7: Commit**

```bash
git add dashboard/src/components/mileage/activity-tab.tsx
git add dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "feat: simplified trip display, gap rendering, amber GPS-gap style"
```

---

## Task 6: Backfill all completed shifts

**Files:**
- Create: `supabase/migrations/133_backfill_synthetic_trips.sql`

**Step 1: Write backfill migration**

```sql
-- Migration 133: Backfill - re-run detect_trips on all completed shifts
-- Creates synthetic trips for all missing cluster pairs.
-- Safe: detect_trips deletes and re-creates everything for completed shifts.

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
        PERFORM detect_trips(v_shift.id);
        v_count := v_count + 1;
        IF v_count % 50 = 0 THEN
            RAISE NOTICE 'Processed % shifts', v_count;
        END IF;
    END LOOP;
    RAISE NOTICE 'Backfill complete: % shifts processed', v_count;
END $$;
```

**Step 2: Apply migration**

Run via MCP `apply_migration`. May take a few minutes.

**Step 3: Verify zero missing trips**

```sql
WITH ordered AS (
  SELECT id, shift_id, ROW_NUMBER() OVER (PARTITION BY shift_id ORDER BY started_at) AS seq
  FROM stationary_clusters
),
pairs AS (
  SELECT c1.shift_id, c1.id AS a, c2.id AS b
  FROM ordered c1 JOIN ordered c2 ON c1.shift_id = c2.shift_id AND c2.seq = c1.seq + 1
)
SELECT COUNT(*) AS missing_trips
FROM pairs p
WHERE NOT EXISTS (
  SELECT 1 FROM trips t WHERE t.start_cluster_id = p.a AND t.end_cluster_id = p.b
);
-- Expected: 0
```

**Step 4: Verify synthetic trip flags**

```sql
SELECT COUNT(*) AS synthetic_trips,
       AVG(distance_km)::NUMERIC(8,3) AS avg_distance,
       AVG(EXTRACT(EPOCH FROM (ended_at - started_at)) / 60)::INTEGER AS avg_duration_min
FROM trips
WHERE has_gps_gap = TRUE AND gps_point_count = 0;
```

**Step 5: Commit**

```bash
git add supabase/migrations/133_backfill_synthetic_trips.sql
git commit -m "chore: backfill synthetic trips for all completed shifts"
```

---

## Task 7: Final verification

**Step 1: Audit query — zero missing cluster pairs**

```sql
WITH shift_clusters AS (
  SELECT id, shift_id, ROW_NUMBER() OVER (PARTITION BY shift_id ORDER BY started_at) AS seq
  FROM stationary_clusters
),
pairs AS (
  SELECT c1.shift_id, c1.id AS a, c2.id AS b
  FROM shift_clusters c1
  JOIN shift_clusters c2 ON c1.shift_id = c2.shift_id AND c2.seq = c1.seq + 1
)
SELECT COUNT(*) FROM pairs p
WHERE NOT EXISTS (
  SELECT 1 FROM trips t WHERE t.start_cluster_id = p.a AND t.end_cluster_id = p.b
);
-- Expected: 0
```

**Step 2: Verify active shift detection is disabled**

```sql
SELECT id FROM shifts WHERE status = 'active' LIMIT 1;
-- If any: SELECT * FROM detect_trips('<id>'); should return 0 rows
```

**Step 3: Dashboard visual check**

Open activity tab for: Cedric, Gerald, Irene, Vincent, Anthony. Verify:
- Every stop has a trip before/after it (no holes)
- Trip rows show duration + distance only (no from/to names)
- Synthetic trips have amber/dashed style
- Clock-in/out gaps show with clock icons
- Estimated distances show "(dont X km estimes)" when OSRM has processed

**Step 4: Approval workflow check**

Open day approval for same employees. Verify:
- Synthetic trips and gaps show as needs_review
- Approve/reject works on them
- Summary counts include gap durations

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: complete cluster-trip continuity - all transitions visible"
```

---

## Summary

| # | Migration | What it does |
|---|-----------|-------------|
| 1 | 129 | `detect_trips` completed-only + synthetic trips post-processing |
| 2 | 130 | `get_employee_activity` clock-in/out gap entries |
| 3 | 131 | `get_day_approval_detail` clock-in/out gap entries |
| 4 | 132 | `estimated_distance_km` column + OSRM Edge Function `/route` support |
| 5 | — | Dashboard: remove from/to on trips, render gaps, amber style |
| 6 | 133 | Backfill: re-run detect_trips on all completed shifts |
| 7 | — | Final verification |

## Key Design Decisions

1. **detect_trips = completed shifts only** — no more active-shift detection (monitoring uses raw GPS)
2. **Synthetic trips are real trips** — stored in `trips` table, visible everywhere
3. **No minimum distance** — if two clusters exist, the movement happened
4. **Clock-in/out gaps are virtual** — query-time only, not stored (avoids polluting mileage)
5. **OSRM `/route`** — estimates shortest path for synthetic trips; composite for GPS-gap trips
6. **No from/to on trip rows** — stops provide context; eliminates location mismatch problem
7. **Two visual styles** — solid (GPS trace) vs amber/dashed (estimated)
