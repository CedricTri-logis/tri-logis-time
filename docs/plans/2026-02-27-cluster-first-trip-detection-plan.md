# Cluster-First Trip Detection — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the trip-first state machine in `detect_trips` with a cluster-first algorithm that detects stationary clusters spatially (50m radius, 3+ min), then creates trips from the gaps between clusters.

**Architecture:** Single forward pass through GPS points. Two concurrent trackers: a "current cluster" (confirmed) and an optional "tentative cluster" (forming). When a tentative cluster reaches 3 min duration, it becomes the new current cluster and a trip is created between the two. All existing post-processing (transport mode classification, ghost trip filters, location matching) is preserved unchanged.

**Tech Stack:** PostgreSQL/plpgsql, PostGIS (`ST_DistanceSphere` or existing `haversine_km`), Supabase

---

## Context for implementer

### Design document
Read `docs/plans/2026-02-27-cluster-spatial-coherence-design.md` for the original spatial coherence design. The cluster-first approach generalizes that idea.

### What this replaces
Migration `069_cluster_spatial_coherence.sql` contains the current `detect_trips` function (~1031 lines). The new migration (071) will `CREATE OR REPLACE FUNCTION detect_trips(...)` with the same signature, completely replacing the function body.

### Existing infrastructure that stays the same
- **Tables:** `stationary_clusters` (migration 060), `trips`, `trip_gps_points`, `gps_points` (with `stationary_cluster_id` FK)
- **Helper functions:** `haversine_km(lat1, lng1, lat2, lng2)` → km, `classify_trip_transport_mode(trip_id)` → 'driving'|'walking'|'unknown', `match_trip_to_location(lat, lng, accuracy)` → location_id or NULL
- **Ghost trip filters** (from 050): driving displacement <50m, straightness ratio <10% for ≤10 point trips — these are applied AFTER trip creation
- **Trips table columns used:** `start_cluster_id`, `end_cluster_id`, `transport_mode`, `start_location_id`, `end_location_id`, `start_location_match_method`, `end_location_match_method`, `match_status`
- **Active shift handling:** preserve trips with `match_status IN ('matched', 'failed', 'anomalous')`, only delete `pending`/`processing`
- **`gps_points.stationary_cluster_id`**: FK tag linking each GPS point to its cluster

### Validation data
**Ginette's shift:** `3d891b10-b5ce-4d6c-9c14-79cf633b1340` (2026-02-27, 410 GPS points, 08:17→14:10 Eastern)

**Current result (BROKEN):** 3 trips (1 bogus 178-min trip `3888046e` with 36 pts)

**Expected result:** 6 clusters + 5 walking trips:

| # | Type | Time (Eastern) | Duration | Location | ~Pts |
|---|------|---------------|----------|----------|------|
| C1 | Cluster | 08:17→08:35 | 18 min | 110 Mgr Tessier | 33 |
| T1 | Trip | 08:35→08:37 | 2 min | walk ~100m | 4 |
| C2 | Cluster | 08:37→09:20 | 43 min | 96 Horne | 65 |
| T2 | Trip | 09:20→09:26 | 6 min | walk ~250m | 3 |
| C3 | Cluster | 09:26→11:07 | 101 min | 96 Horne ext | 80 |
| T3 | Trip | 11:07→11:09 | 2 min | walk ~100m | 6 |
| C4 | Cluster | 11:09→12:18 | 69 min | Building 4 | 72 |
| T4 | Trip | 12:18→12:23 | 5 min | walk ~200m | 10 |
| C5 | Cluster | 12:23→13:05 | 42 min | Café Van Houtte | 50 |
| T5 | Trip | 13:05→13:09 | 4 min | walk ~350m | 15 |
| C6 | Cluster | 13:09→14:10 | 61 min | Final loc | 69 |

### Supabase project
- Project ID: `xdyzdclwvhkfwbkrdsiz`
- Migration numbering: last applied is 070, next = **071**
- Duplicate-prefix migration workaround: files 039, 043, 044, 048, 053, 057 must be temporarily moved to `/tmp/dup_migrations/` before `supabase db push --linked`, then moved back

---

## Task 1: Write the cluster-first `detect_trips` migration

**File:** Create `supabase/migrations/071_cluster_first_trip_detection.sql`

### Step 1: Write the migration file

The function must have the **exact same signature** as the current one:

```sql
CREATE OR REPLACE FUNCTION detect_trips(p_shift_id UUID)
RETURNS TABLE (
    trip_id UUID,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    start_latitude DECIMAL(10, 8),
    start_longitude DECIMAL(11, 8),
    end_latitude DECIMAL(10, 8),
    end_longitude DECIMAL(11, 8),
    distance_km DECIMAL(8, 3),
    duration_minutes INTEGER,
    confidence_score DECIMAL(3, 2),
    gps_point_count INTEGER
) AS $$
```

### Algorithm pseudocode (implement this exactly)

```
DECLARE
  -- Constants
  v_cluster_radius_m     CONSTANT DECIMAL := 50.0;   -- cluster spatial radius
  v_cluster_min_duration CONSTANT INTEGER := 3;       -- minutes to confirm cluster
  v_max_accuracy         CONSTANT DECIMAL := 200.0;   -- skip GPS points above this
  v_correction_factor    CONSTANT DECIMAL := 1.3;     -- haversine→road distance factor
  v_min_distance_km      CONSTANT DECIMAL := 0.2;     -- min trip distance
  v_min_distance_driving CONSTANT DECIMAL := 0.5;     -- min trip distance for driving
  v_min_displacement_walking CONSTANT DECIMAL := 0.1; -- 100m straight-line for walking
  v_gps_gap_minutes      CONSTANT INTEGER := 15;      -- GPS gap threshold

  -- Current cluster state
  v_cluster_lats, v_cluster_lngs, v_cluster_accs DECIMAL[]
  v_cluster_point_ids UUID[]
  v_cluster_started_at TIMESTAMPTZ
  v_cluster_confirmed BOOLEAN := FALSE
  v_cluster_centroid_lat, v_cluster_centroid_lng, v_cluster_centroid_acc DECIMAL
  v_cluster_id UUID          -- DB id once persisted
  v_has_db_cluster BOOLEAN   -- whether persisted to stationary_clusters

  -- Tentative cluster state (same structure)
  v_tent_lats, v_tent_lngs, v_tent_accs DECIMAL[]
  v_tent_point_ids UUID[]
  v_tent_started_at TIMESTAMPTZ
  v_tent_centroid_lat, v_tent_centroid_lng DECIMAL
  v_has_tentative BOOLEAN := FALSE

  -- Transit buffer
  v_transit_point_ids UUID[]

  -- Trip tracking
  v_prev_cluster_id UUID     -- last finalized cluster (for trip.start_cluster_id)
  v_prev_trip_end_location_id UUID  -- for trip continuity optimization
  v_prev_trip_end_lat, v_prev_trip_end_lng DECIMAL

  -- For active shift incremental detection
  v_create_clusters BOOLEAN
  v_cutoff_time TIMESTAMPTZ

BEGIN
  -- 1. Validate shift, set up incremental mode (same as current lines 115-149)

  -- 2. Delete existing data:
  --    Completed shift → DELETE FROM trips WHERE shift_id = ...; DELETE FROM stationary_clusters WHERE shift_id = ...;
  --    Active shift → only delete pending/processing trips, find cutoff

  -- 3. Initialize: start first cluster attempt with first point
  v_cluster_lats := '{}'; v_cluster_lngs := '{}'; etc.

  -- 4. Main loop
  FOR v_point IN (SELECT ... FROM gps_points WHERE shift_id AND captured_at > cutoff ORDER BY captured_at)
  LOOP
    -- Skip poor accuracy (> 200m)
    IF v_point.accuracy > v_max_accuracy THEN CONTINUE; END IF;

    -- GPS gap check: if > 15 min since prev point AND we have a confirmed cluster,
    -- finalize it. If tentative exists, discard it. Reset state.
    -- (This handles the case where GPS data has a long gap mid-cluster)

    -- === CORE ALGORITHM ===

    -- Compute adjusted distance to current cluster centroid
    IF array_length(v_cluster_lats, 1) > 0 THEN
      -- Compute accuracy-weighted centroid of current cluster
      compute_weighted_centroid(v_cluster_lats, v_cluster_lngs, v_cluster_accs)
        → v_cluster_centroid_lat, v_cluster_centroid_lng

      v_dist_to_cluster := GREATEST(
        haversine_km(v_cluster_centroid_lat, v_cluster_centroid_lng,
                     v_point.latitude, v_point.longitude) * 1000.0
        - COALESCE(v_point.accuracy, 20.0),
        0
      );
    ELSE
      v_dist_to_cluster := 0;  -- First point, automatically in cluster
    END IF;

    IF v_dist_to_cluster <= v_cluster_radius_m THEN
      -- *** POINT WITHIN CURRENT CLUSTER ***
      Add point to current cluster arrays
      Update cluster end time

      -- Check if cluster just became confirmed (duration >= 3 min)
      IF NOT v_cluster_confirmed
         AND EXTRACT(EPOCH FROM (v_point.captured_at - v_cluster_started_at))/60 >= v_cluster_min_duration THEN
        v_cluster_confirmed := TRUE;
        -- Persist to stationary_clusters table (INSERT)
        -- Tag GPS points with stationary_cluster_id
      END IF;

      -- If already confirmed and persisted, UPDATE the cluster and tag this point

      -- Discard tentative cluster if one exists (false alarm)
      IF v_has_tentative THEN
        v_transit_point_ids := v_transit_point_ids || v_tent_point_ids;
        Reset tentative state
      END IF;

    ELSE
      -- *** POINT BEYOND CURRENT CLUSTER (> 50m adjusted) ***

      IF NOT v_has_tentative THEN
        -- Start tentative cluster with this point
        v_tent_lats := ARRAY[v_point.latitude];
        v_tent_lngs := ARRAY[v_point.longitude];
        v_tent_accs := ARRAY[COALESCE(v_point.accuracy, 20.0)];
        v_tent_point_ids := ARRAY[v_point.id];
        v_tent_started_at := v_point.captured_at;
        v_has_tentative := TRUE;

      ELSE
        -- Tentative exists: check distance to tentative centroid
        compute_weighted_centroid(v_tent_lats, v_tent_lngs, v_tent_accs)
          → v_tent_centroid_lat, v_tent_centroid_lng

        v_dist_to_tent := GREATEST(
          haversine_km(v_tent_centroid_lat, v_tent_centroid_lng,
                       v_point.latitude, v_point.longitude) * 1000.0
          - COALESCE(v_point.accuracy, 20.0),
          0
        );

        IF v_dist_to_tent <= v_cluster_radius_m THEN
          -- Point within tentative cluster
          Add point to tentative arrays

          -- Check if tentative just became confirmed (3 min)
          IF EXTRACT(EPOCH FROM (v_point.captured_at - v_tent_started_at))/60 >= v_cluster_min_duration THEN
            -- ★★★ NEW CLUSTER CONFIRMED ★★★
            -- This is the key moment: finalize current cluster, create trip, promote tentative

            -- A) Finalize current cluster (if confirmed)
            IF v_cluster_confirmed THEN
              Update stationary_clusters with final centroid, end time
              v_prev_cluster_id := v_cluster_id;
            ELSIF cluster duration >= 3 min THEN
              INSERT into stationary_clusters
              v_prev_cluster_id := v_cluster_id;
            END IF;

            -- B) Compute tentative centroid (for trip end coords)
            compute_weighted_centroid(v_tent_*) → centroid

            -- C) Persist tentative as new cluster
            INSERT INTO stationary_clusters (...) VALUES (...)
              RETURNING id INTO v_new_cluster_id;
            Tag tent GPS points with v_new_cluster_id

            -- D) Create trip from transit buffer
            call create_trip_between_clusters(
              departure_cluster_centroid,
              arrival_cluster_centroid,
              v_transit_point_ids,
              v_prev_cluster_id,
              v_new_cluster_id
            );

            -- E) Promote: tentative becomes current
            v_cluster_* := v_tent_*;
            v_cluster_id := v_new_cluster_id;
            v_cluster_confirmed := TRUE;
            v_has_db_cluster := TRUE;
            Reset tentative state
            v_transit_point_ids := '{}';
          END IF;

        ELSE
          -- Point beyond BOTH clusters → in transit
          v_transit_point_ids := v_transit_point_ids || v_tent_point_ids;
          -- Start new tentative with this point
          v_tent_lats := ARRAY[v_point.latitude]; ...
          v_tent_started_at := v_point.captured_at;
        END IF;
      END IF;
    END IF;

    v_prev_point := v_point;
  END LOOP;

  -- 5. End of data: finalize last cluster
  IF v_cluster_confirmed OR cluster duration >= 3 min THEN
    Persist/update last cluster in stationary_clusters
  END IF;

  -- 6. Handle trailing transit (points after last cluster, no arrival cluster)
  --    Create trip from last cluster to last transit point if significant
  --    Use actual GPS coordinates (no arrival centroid)
END;
```

### Trip creation subroutine (inline, not a separate function)

When creating a trip between two clusters:

```sql
-- Compute trip distance (centroid to centroid, with correction factor)
v_trip_distance := haversine_km(
  departure_centroid_lat, departure_centroid_lng,
  arrival_centroid_lat, arrival_centroid_lng
) * v_correction_factor;

-- Compute transit point count and low-accuracy count
v_trip_point_count := array_length(v_transit_point_ids, 1);
v_trip_low_accuracy := (count of transit points with accuracy > 50);

-- Trip timing
v_trip_started_at := departure cluster end_time (last point in departure cluster)
v_trip_ended_at := arrival cluster start_time (first point in arrival cluster)

-- Trip coordinates = cluster centroids
v_trip_start_lat := departure_centroid_lat
v_trip_start_lng := departure_centroid_lng
v_trip_end_lat := arrival_centroid_lat
v_trip_end_lng := arrival_centroid_lng

-- Min distance check
IF v_trip_distance < v_min_distance_km THEN skip END IF;

-- INSERT into trips (same columns as current)
INSERT INTO trips (
  id, shift_id, employee_id,
  started_at, ended_at,
  start_latitude, start_longitude,
  end_latitude, end_longitude,
  distance_km, duration_minutes,
  classification, confidence_score,
  gps_point_count, low_accuracy_segments,
  detection_method, transport_mode,
  start_cluster_id, end_cluster_id
) VALUES (...);

-- INSERT into trip_gps_points (transit buffer points)
FOR i IN 1..array_length(v_transit_point_ids, 1) LOOP
  INSERT INTO trip_gps_points (trip_id, gps_point_id, sequence_order)
  VALUES (v_trip_id, v_transit_point_ids[i], i)
  ON CONFLICT DO NOTHING;
END LOOP;

-- Post-processing (same as current):
-- 1. classify_trip_transport_mode(v_trip_id)
-- 2. Ghost trip filters:
--    - driving displacement < 50m → delete
--    - straightness ratio < 10% for ≤10 point trips → delete
--    - walking displacement < 100m → delete
--    - driving distance < 500m → delete
-- 3. Location matching:
--    - start_location: use prev_trip continuity if within 100m, else match_trip_to_location
--    - end_location: match_trip_to_location
-- 4. RETURN QUERY (same columns)
```

### Key implementation details

1. **Accuracy-weighted centroid formula** (same as current migration 069, lines 246-250):
```sql
SELECT
  SUM(lat / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
  SUM(lng / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
  1.0 / SQRT(SUM(1.0 / GREATEST(acc * acc, 1)))
INTO v_centroid_lat, v_centroid_lng, v_centroid_acc
FROM unnest(v_lats, v_lngs, v_accs) AS t(lat, lng, acc);
```

2. **Adjusted distance formula** (same as migration 069, line 239):
```sql
GREATEST(haversine_km(centroid_lat, centroid_lng, point_lat, point_lng) * 1000.0
         - COALESCE(v_point.accuracy, 20.0), 0)
```

3. **Trips with 0 transit points** are valid (very short transitions where walking points are absorbed into the arrival cluster). Set `gps_point_count = 0`, skip trip_gps_points INSERT.

4. **Active shift incremental detection**: Use the same cutoff logic as current (lines 128-143). For active shifts, `v_create_clusters := FALSE` — skip cluster persistence but still track clusters in memory for trip detection.

5. **GPS gap > 15 min during cluster**: Cluster continues (long gaps are normal during stationary with adaptive GPS frequency). Do NOT split clusters on time gaps.

6. **GPS gap > 15 min during transit**: Trip spans the gap. No special handling.

7. **First point**: Starts the first cluster attempt. No special casing needed.

8. **No speed thresholds**: The algorithm does NOT use `v_movement_speed`, `v_sensor_stop_threshold`, `v_stationary_speed`, `v_point_is_stopped`, or `v_in_trip`. All of these are REMOVED.

### Ghost trip filters to preserve

After creating each trip and classifying transport mode, apply these filters (same as current):

```sql
-- Filter 1: Walking displacement < 100m
IF v_transport_mode = 'walking' AND v_displacement < 0.1 THEN
  DELETE trip; CONTINUE;
END IF;

-- Filter 2: Driving distance < 500m
IF v_transport_mode = 'driving' AND v_trip_distance < 0.5 THEN
  DELETE trip; CONTINUE;
END IF;

-- Filter 3: Driving displacement < 50m (ghost trip)
IF v_transport_mode = 'driving' AND v_displacement < 0.05 THEN
  DELETE trip; CONTINUE;
END IF;

-- Filter 4: Straightness ratio < 10% for ≤10 point driving trips
IF v_transport_mode = 'driving' AND v_trip_point_count <= 10 THEN
  v_straightness := v_displacement / NULLIF(v_trip_distance, 0);
  IF v_straightness < 0.10 THEN
    DELETE trip; CONTINUE;
  END IF;
END IF;
```

### Step 2: Verify migration file compiles

Run: `cd /Users/cedric/Desktop/PROJECT/TEST/GPS_Tracker && supabase db lint --linked` or check syntax by reading the file.

### Step 3: Commit

```bash
git add supabase/migrations/071_cluster_first_trip_detection.sql
git commit -m "feat: cluster-first trip detection algorithm

Replace trip-first state machine (speed thresholds, sensor stops) with
spatial cluster detection. Clusters = GPS points within 50m radius for
3+ min. Trips = gaps between consecutive clusters. Fixes bogus multi-hour
trips that absorbed walking points due to GPS jitter preventing the
stationary timer from completing.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 2: Deploy migration and validate on Ginette's shift

**Depends on:** Task 1

### Step 1: Apply migration to Supabase

```bash
cd /Users/cedric/Desktop/PROJECT/TEST/GPS_Tracker

# Move duplicate-prefix files temporarily
mkdir -p /tmp/dup_migrations
for f in 039 043 044 048 053 057; do
  mv supabase/migrations/${f}_*.sql /tmp/dup_migrations/ 2>/dev/null
done

# Push migration
supabase db push --linked

# Restore files
mv /tmp/dup_migrations/*.sql supabase/migrations/
```

### Step 2: Re-detect Ginette's shift

```sql
SELECT * FROM detect_trips('3d891b10-b5ce-4d6c-9c14-79cf633b1340');
```

### Step 3: Verify clusters

```sql
SELECT id,
  centroid_latitude, centroid_longitude,
  started_at AT TIME ZONE 'America/Montreal' AS start_local,
  ended_at AT TIME ZONE 'America/Montreal' AS end_local,
  duration_seconds / 60 AS duration_min,
  gps_point_count,
  matched_location_id
FROM stationary_clusters
WHERE shift_id = '3d891b10-b5ce-4d6c-9c14-79cf633b1340'
ORDER BY started_at;
```

**Expected:** 6 clusters, durations matching the table above (±2 min tolerance).

### Step 4: Verify trips

```sql
SELECT id,
  started_at AT TIME ZONE 'America/Montreal' AS start_local,
  ended_at AT TIME ZONE 'America/Montreal' AS end_local,
  start_latitude, start_longitude,
  end_latitude, end_longitude,
  distance_km, transport_mode,
  (SELECT COUNT(*) FROM trip_gps_points WHERE trip_id = trips.id) AS pts
FROM trips
WHERE shift_id = '3d891b10-b5ce-4d6c-9c14-79cf633b1340'
ORDER BY started_at;
```

**Expected:** 4-5 walking trips (some very short ones may be filtered by 100m displacement). No bogus multi-hour trips. Trip start/end coordinates should be cluster centroids (not individual GPS points).

### Step 5: Verify the bogus 178-min trip is gone

```sql
-- Should return 0 rows — no trips longer than 30 min
SELECT id, duration_minutes, transport_mode, distance_km
FROM trips
WHERE shift_id = '3d891b10-b5ce-4d6c-9c14-79cf633b1340'
  AND duration_minutes > 30;
```

### Step 6: Commit if adjustments were needed

Only if the migration file was modified to fix issues found during validation.

---

## Task 3: Batch re-detect all completed shifts

**Depends on:** Task 2

### Step 1: Count current trips (baseline)

```sql
SELECT COUNT(*) AS total_trips,
  COUNT(*) FILTER (WHERE transport_mode = 'driving') AS driving,
  COUNT(*) FILTER (WHERE transport_mode = 'walking') AS walking
FROM trips t
JOIN shifts s ON s.id = t.shift_id
WHERE s.status = 'completed';
```

### Step 2: Re-detect all completed shifts

```sql
-- Re-detect all completed shifts
SELECT s.id AS shift_id, dt.*
FROM shifts s
CROSS JOIN LATERAL detect_trips(s.id) dt
WHERE s.status = 'completed'
ORDER BY s.id;
```

Note: This may take a few minutes for many shifts. If it times out, batch in groups:

```sql
-- Batch approach: get shift IDs first
SELECT id FROM shifts WHERE status = 'completed' ORDER BY started_at;

-- Then re-detect in batches of 10-20
SELECT detect_trips(id) FROM shifts WHERE status = 'completed' AND id IN (...batch...);
```

### Step 3: Count new trips (comparison)

```sql
SELECT COUNT(*) AS total_trips,
  COUNT(*) FILTER (WHERE transport_mode = 'driving') AS driving,
  COUNT(*) FILTER (WHERE transport_mode = 'walking') AS walking
FROM trips t
JOIN shifts s ON s.id = t.shift_id
WHERE s.status = 'completed';
```

**Expected:** More walking trips detected. Driving trips should be similar or slightly fewer (some former "driving" trips were actually bogus). No trips with duration > 3 hours unless they're genuine long drives.

### Step 4: Sanity check — no bogus multi-hour trips

```sql
-- Should return 0 or very few results
SELECT t.id, t.duration_minutes, t.distance_km, t.transport_mode,
  t.started_at AT TIME ZONE 'America/Montreal',
  t.ended_at AT TIME ZONE 'America/Montreal'
FROM trips t
JOIN shifts s ON s.id = t.shift_id
WHERE s.status = 'completed'
  AND t.duration_minutes > 180
  AND t.distance_km < 5
ORDER BY t.duration_minutes DESC
LIMIT 10;
```

### Step 5: Run rematch_all_trip_locations

```sql
SELECT * FROM rematch_all_trip_locations();
```

---

## Task 4: Push and deploy

**Depends on:** Task 3

### Step 1: Commit any final adjustments

If any changes were made during validation.

### Step 2: Push to remote

```bash
git push
```

---

## What changes vs. what stays the same

### REMOVED (from current detect_trips)
- `v_movement_speed = 8.0` — speed-based trip start threshold
- `v_sensor_stop_threshold = 0.28` — sensor speed stop detection
- `v_stationary_speed = 3.0` — stationary speed threshold
- `v_point_is_stopped` — sensor-based stop detection
- `v_in_trip` — trip-first state variable
- `v_stationary_since` / `v_stationary_center_*` — 3-min stationary timer
- The entire 3-branch PATH system (fast movement / stopped in trip / medium speed)
- `v_unclaimed_point_ids` — no longer needed (all non-cluster points are implicitly transit)
- Split trip special case — all trips are now inter-cluster transitions

### PRESERVED (same as current)
- Function signature (`RETURNS TABLE (...)`)
- Active shift incremental detection (cutoff logic)
- `stationary_clusters` table persistence + `gps_points.stationary_cluster_id` tagging
- `trips.start_cluster_id` / `end_cluster_id` FK references
- Accuracy-weighted centroid formula
- `classify_trip_transport_mode()` post-processing
- Ghost trip filters (displacement, straightness, min distance)
- Location matching (`match_trip_to_location`, prev-trip continuity optimization)
- Trip continuity tracking (`v_prev_trip_end_location_id`)
- `v_correction_factor = 1.3` for road distance estimation
- Low-accuracy point counting (`accuracy > 50`)
- `RETURN QUERY` for each created trip

### NEW
- Tentative cluster tracking (concurrent with current cluster)
- Transit buffer (`v_transit_point_ids`) — collects points between clusters
- Cluster-to-cluster trip creation (centroids as start/end coordinates)
- Trips can have 0 GPS points (very short transitions)
