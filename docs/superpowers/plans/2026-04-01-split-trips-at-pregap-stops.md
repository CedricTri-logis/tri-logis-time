# Split Trips at Pre-Gap Stops Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When GPS dies while an employee is stationary, create a cluster at the last known position instead of absorbing the gap into a phantom trip.

**Architecture:** A new post-processing function `split_trips_at_pregap_stops(p_shift_id)` runs after `detect_trips` finishes. It scans each trip for GPS gaps > 5 min where the last points show the employee was stopped (speed < 2 km/h, accuracy < 20m). When found, it splits the trip by inserting a new stationary cluster at the stop point, shortening the original trip, and creating a new trip for any post-gap movement.

**Tech Stack:** PostgreSQL/Supabase migration, PL/pgSQL

---

### Task 1: Create `split_trips_at_pregap_stops` function

**Files:**
- Create: `supabase/migrations/20260401100000_split_trips_at_pregap_stops.sql`

- [ ] **Step 1: Write the migration file with the function**

```sql
-- =============================================================================
-- Split trips at pre-gap stops
-- =============================================================================
-- When GPS dies while an employee is stationary, detect_trips can't create a
-- cluster (needs 3 min of data). This post-processing step finds trips with
-- large GPS gaps where the last points show stationary behavior, and splits
-- them by inserting a synthetic cluster at the stop position.
--
-- Rule: speed < 0.56 m/s (2 km/h) AND accuracy < 20m for last 2 points
--       before a gap > 5 min.
-- =============================================================================

CREATE OR REPLACE FUNCTION split_trips_at_pregap_stops(p_shift_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, extensions
AS $$
DECLARE
  v_employee_id UUID;
  v_trip RECORD;
  v_gap RECORD;
  v_pregap RECORD;
  v_new_cluster_id UUID;
  v_new_trip_id UUID;
  v_cluster_centroid_lat DECIMAL(10,8);
  v_cluster_centroid_lng DECIMAL(11,8);
  v_cluster_centroid_acc DECIMAL;
  v_cluster_started_at TIMESTAMPTZ;
  v_cluster_ended_at TIMESTAMPTZ;
  v_cluster_location_id UUID;
  v_cluster_point_ids UUID[];
  v_cluster_duration_seconds INTEGER;
  v_cluster_gps_gap_seconds INTEGER;
  v_post_gap_has_movement BOOLEAN;
  v_post_gap_first_point RECORD;
  v_trip_distance DECIMAL;
  v_original_end_cluster_id UUID;
  v_original_end_location_id UUID;
  v_original_end_lat DECIMAL(10,8);
  v_original_end_lng DECIMAL(11,8);
  v_original_ended_at TIMESTAMPTZ;
BEGIN
  SELECT employee_id INTO v_employee_id FROM shifts WHERE id = p_shift_id;
  IF v_employee_id IS NULL THEN RETURN; END IF;

  -- Process each trip that has GPS gaps > 5 min
  FOR v_trip IN
    SELECT t.id, t.started_at, t.ended_at,
           t.start_cluster_id, t.end_cluster_id,
           t.start_location_id, t.end_location_id,
           t.start_latitude, t.start_longitude,
           t.end_latitude, t.end_longitude,
           t.gps_gap_seconds
    FROM trips t
    WHERE t.shift_id = p_shift_id
      AND t.gps_gap_seconds > 300  -- > 5 min gap
    ORDER BY t.started_at
  LOOP
    -- Find the largest GPS gap within this trip's points
    FOR v_gap IN
      WITH trip_pts AS (
        SELECT gp.id AS pt_id, gp.captured_at, gp.latitude, gp.longitude,
               gp.speed, gp.accuracy,
               lead(gp.captured_at) OVER (ORDER BY gp.captured_at) AS next_at,
               lead(gp.id) OVER (ORDER BY gp.captured_at) AS next_id
        FROM trip_gps_points tgp
        JOIN gps_points gp ON gp.id = tgp.gps_point_id
        WHERE tgp.trip_id = v_trip.id
      )
      SELECT pt_id AS last_before_id, captured_at AS before_gap_at,
             next_at AS after_gap_at, next_id AS first_after_id,
             EXTRACT(EPOCH FROM (next_at - captured_at))::INTEGER AS gap_secs
      FROM trip_pts
      WHERE next_at IS NOT NULL
        AND EXTRACT(EPOCH FROM (next_at - captured_at)) > 300
      ORDER BY EXTRACT(EPOCH FROM (next_at - captured_at)) DESC
      LIMIT 1
    LOOP
      -- Check: are the last 2 points before the gap stationary with good accuracy?
      SELECT INTO v_pregap
        count(*) FILTER (WHERE speed < 0.56 AND accuracy < 20) AS good_count,
        count(*) AS total_count
      FROM (
        SELECT gp.speed, gp.accuracy
        FROM trip_gps_points tgp
        JOIN gps_points gp ON gp.id = tgp.gps_point_id
        WHERE tgp.trip_id = v_trip.id
          AND gp.captured_at <= v_gap.before_gap_at
        ORDER BY gp.captured_at DESC
        LIMIT 2
      ) last_pts;

      -- Both points must be stationary with good accuracy
      IF v_pregap.good_count < 2 THEN
        CONTINUE;  -- skip this trip, not a pre-gap stop
      END IF;

      -- Collect ALL consecutive stationary points before the gap
      -- (walk backwards from the gap until we find a moving point)
      SELECT INTO v_cluster_point_ids
        array_agg(pt_id ORDER BY captured_at)
      FROM (
        SELECT gp.id AS pt_id, gp.captured_at, gp.speed, gp.accuracy
        FROM trip_gps_points tgp
        JOIN gps_points gp ON gp.id = tgp.gps_point_id
        WHERE tgp.trip_id = v_trip.id
          AND gp.captured_at <= v_gap.before_gap_at
          AND gp.speed < 0.56
          AND gp.accuracy < 20
        ORDER BY gp.captured_at DESC
      ) pts
      WHERE NOT EXISTS (
        -- Stop collecting if there's a moving point between this one and the gap
        SELECT 1
        FROM trip_gps_points tgp2
        JOIN gps_points gp2 ON gp2.id = tgp2.gps_point_id
        WHERE tgp2.trip_id = v_trip.id
          AND gp2.captured_at > pts.captured_at
          AND gp2.captured_at <= v_gap.before_gap_at
          AND (gp2.speed >= 0.56 OR gp2.accuracy >= 20)
      );

      IF v_cluster_point_ids IS NULL OR array_length(v_cluster_point_ids, 1) < 2 THEN
        CONTINUE;
      END IF;

      -- Compute accuracy-weighted centroid from pre-gap stationary points only
      SELECT
        SUM(gp.latitude / GREATEST(gp.accuracy, 1)) / SUM(1.0 / GREATEST(gp.accuracy, 1)),
        SUM(gp.longitude / GREATEST(gp.accuracy, 1)) / SUM(1.0 / GREATEST(gp.accuracy, 1)),
        1.0 / SQRT(SUM(1.0 / GREATEST(gp.accuracy * gp.accuracy, 1))),
        MIN(gp.captured_at)
      INTO v_cluster_centroid_lat, v_cluster_centroid_lng, v_cluster_centroid_acc, v_cluster_started_at
      FROM gps_points gp
      WHERE gp.id = ANY(v_cluster_point_ids);

      -- Cluster ends at the first point after the gap
      v_cluster_ended_at := v_gap.after_gap_at;
      v_cluster_duration_seconds := EXTRACT(EPOCH FROM (v_cluster_ended_at - v_cluster_started_at))::INTEGER;
      v_cluster_gps_gap_seconds := v_gap.gap_secs;

      -- Match cluster to a location
      v_cluster_location_id := COALESCE(
        match_trip_to_location(v_cluster_centroid_lat, v_cluster_centroid_lng, COALESCE(v_cluster_centroid_acc, 0)),
        match_cluster_by_point_voting(
          (SELECT array_agg(gp.latitude::DOUBLE PRECISION) FROM gps_points gp WHERE gp.id = ANY(v_cluster_point_ids)),
          (SELECT array_agg(gp.longitude::DOUBLE PRECISION) FROM gps_points gp WHERE gp.id = ANY(v_cluster_point_ids)),
          (SELECT array_agg(gp.accuracy::DOUBLE PRECISION) FROM gps_points gp WHERE gp.id = ANY(v_cluster_point_ids))
        )
      );

      -- Save original trip end info before modifying
      v_original_end_cluster_id := v_trip.end_cluster_id;
      v_original_end_location_id := v_trip.end_location_id;
      v_original_end_lat := v_trip.end_latitude;
      v_original_end_lng := v_trip.end_longitude;
      v_original_ended_at := v_trip.ended_at;

      -- =====================================================================
      -- 1. Create the new stationary cluster
      -- =====================================================================
      v_new_cluster_id := gen_random_uuid();

      INSERT INTO stationary_clusters (
        id, shift_id, employee_id,
        centroid_latitude, centroid_longitude, centroid_accuracy,
        started_at, ended_at, duration_seconds,
        gps_point_count, matched_location_id,
        gps_gap_seconds, gps_gap_count
      ) VALUES (
        v_new_cluster_id, p_shift_id, v_employee_id,
        v_cluster_centroid_lat, v_cluster_centroid_lng, v_cluster_centroid_acc,
        v_cluster_started_at, v_cluster_ended_at, v_cluster_duration_seconds,
        array_length(v_cluster_point_ids, 1), v_cluster_location_id,
        v_cluster_gps_gap_seconds, 1
      );

      -- Tag cluster points
      UPDATE gps_points SET stationary_cluster_id = v_new_cluster_id
      WHERE id = ANY(v_cluster_point_ids);

      -- Remove cluster points from the trip
      DELETE FROM trip_gps_points
      WHERE trip_id = v_trip.id
        AND gps_point_id = ANY(v_cluster_point_ids);

      -- =====================================================================
      -- 2. Shorten original trip to end at the new cluster
      -- =====================================================================
      UPDATE trips SET
        ended_at = v_cluster_started_at,
        end_cluster_id = v_new_cluster_id,
        end_latitude = v_cluster_centroid_lat,
        end_longitude = v_cluster_centroid_lng,
        end_location_id = v_cluster_location_id,
        duration_minutes = GREATEST(0, EXTRACT(EPOCH FROM (v_cluster_started_at - started_at)) / 60)::INTEGER,
        distance_km = ROUND(haversine_km(start_latitude, start_longitude, v_cluster_centroid_lat, v_cluster_centroid_lng) * 1.3, 3),
        gps_gap_seconds = 0,
        gps_gap_count = 0,
        has_gps_gap = FALSE
      WHERE id = v_trip.id;

      -- Remove post-gap points from original trip (they belong to a new trip)
      DELETE FROM trip_gps_points
      WHERE trip_id = v_trip.id
        AND gps_point_id IN (
          SELECT gp.id FROM gps_points gp
          WHERE gp.id IN (
            SELECT tgp.gps_point_id FROM trip_gps_points tgp WHERE tgp.trip_id = v_trip.id
          )
          AND gp.captured_at >= v_gap.after_gap_at
        );

      -- =====================================================================
      -- 3. Create new trip from cluster end to original trip end (if needed)
      -- =====================================================================
      -- Check if there are moving points after the gap
      SELECT EXISTS (
        SELECT 1 FROM gps_points gp
        WHERE gp.shift_id = p_shift_id
          AND gp.captured_at >= v_gap.after_gap_at
          AND gp.captured_at <= v_original_ended_at
          AND gp.speed >= 2.22  -- > 8 km/h
          AND gp.stationary_cluster_id IS NULL
      ) INTO v_post_gap_has_movement;

      IF v_post_gap_has_movement OR v_original_end_cluster_id IS NOT NULL THEN
        v_new_trip_id := gen_random_uuid();

        v_trip_distance := haversine_km(
          v_cluster_centroid_lat, v_cluster_centroid_lng,
          COALESCE(v_original_end_lat, v_cluster_centroid_lat),
          COALESCE(v_original_end_lng, v_cluster_centroid_lng)
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
          start_location_id, end_location_id,
          has_gps_gap
        ) VALUES (
          v_new_trip_id, p_shift_id, v_employee_id,
          v_cluster_ended_at, v_original_ended_at,
          v_cluster_centroid_lat, v_cluster_centroid_lng,
          v_original_end_lat, v_original_end_lng,
          ROUND(v_trip_distance * 1.3, 3),
          GREATEST(0, EXTRACT(EPOCH FROM (v_original_ended_at - v_cluster_ended_at)) / 60)::INTEGER,
          'business', 0.50,
          0, 0,
          'auto', 'unknown',
          v_new_cluster_id, v_original_end_cluster_id,
          v_cluster_location_id, v_original_end_location_id,
          FALSE
        );

        -- Assign post-gap GPS points to the new trip
        INSERT INTO trip_gps_points (trip_id, gps_point_id, sequence_order)
        SELECT v_new_trip_id, gp.id,
               row_number() OVER (ORDER BY gp.captured_at)
        FROM gps_points gp
        WHERE gp.shift_id = p_shift_id
          AND gp.captured_at >= v_gap.after_gap_at
          AND gp.captured_at <= v_original_ended_at
          AND gp.stationary_cluster_id IS NULL
        ON CONFLICT DO NOTHING;

        -- Update point count
        UPDATE trips SET gps_point_count = (
          SELECT count(*) FROM trip_gps_points WHERE trip_id = v_new_trip_id
        ) WHERE id = v_new_trip_id;
      END IF;

      -- Update original trip point count
      UPDATE trips SET gps_point_count = (
        SELECT count(*) FROM trip_gps_points WHERE trip_id = v_trip.id
      ) WHERE id = v_trip.id;

      -- Delete original trip if it has 0 duration (cluster started right at trip start)
      DELETE FROM trips WHERE id = v_trip.id AND duration_minutes = 0;

      -- Delete new post-gap trip if it has 0 points and 0 duration
      IF v_new_trip_id IS NOT NULL THEN
        DELETE FROM trips WHERE id = v_new_trip_id AND gps_point_count = 0 AND duration_minutes = 0;
      END IF;

    END LOOP;  -- v_gap
  END LOOP;  -- v_trip

  -- Recompute effective location types for any new clusters
  PERFORM compute_cluster_effective_types(p_shift_id, v_employee_id);

  -- Recompute GPS gaps
  PERFORM compute_gps_gaps(p_shift_id);
END;
$$;
```

- [ ] **Step 2: In the same migration, inject the PERFORM call into detect_trips**

Append this after the function definition in the same migration file:

```sql
-- =============================================================================
-- Inject call into detect_trips after section 9 (synthetic trips)
-- =============================================================================
DO $$
DECLARE
  v_funcdef TEXT;
  v_modified TEXT;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_funcdef
  FROM pg_proc p
  WHERE p.proname = 'detect_trips'
    AND p.pronamespace = 'public'::regnamespace;

  IF v_funcdef IS NULL THEN
    RAISE EXCEPTION 'detect_trips function not found';
  END IF;

  v_modified := v_funcdef;

  -- Add the call right before the final END LOOP of section 9
  -- The pattern is the last "END LOOP;" before the final "END;"
  v_modified := replace(v_modified,
    E'END LOOP;\nEND;',
    E'END LOOP;\n\n    -- =========================================================================\n    -- 10. Post-processing: split trips at pre-gap stops\n    -- =========================================================================\n    PERFORM split_trips_at_pregap_stops(p_shift_id);\nEND;'
  );

  EXECUTE v_modified;
  RAISE NOTICE 'detect_trips updated: added split_trips_at_pregap_stops call';
END;
$$;
```

- [ ] **Step 3: Apply the migration**

```bash
cd /Users/cedric/Desktop/PROJECT/GPS_Tracker_repo
npx supabase migration up --linked 2>&1 | tail -5
```

Expected: Migration applied successfully.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260401100000_split_trips_at_pregap_stops.sql
git commit -m "feat: split trips at pre-gap stops when GPS dies during stationary"
```

---

### Task 2: Verify on 3 known cases

**Files:** None (SQL queries only)

- [ ] **Step 1: Re-run detect_trips on Jessy 03/27**

```sql
SELECT * FROM detect_trips('36772573-7ffa-4e8f-97dd-384776a4a03c');
```

Then verify the new cluster exists:

```sql
SELECT sc.id,
  to_char(sc.started_at AT TIME ZONE 'America/Toronto', 'HH24:MI') as start_edt,
  to_char(sc.ended_at AT TIME ZONE 'America/Toronto', 'HH24:MI') as end_edt,
  sc.duration_seconds / 60 as dur_min,
  sc.gps_gap_seconds / 60 as gap_min,
  sc.gps_point_count,
  l.name as location_name
FROM stationary_clusters sc
LEFT JOIN locations l ON l.id = sc.matched_location_id
WHERE sc.shift_id = '36772573-7ffa-4e8f-97dd-384776a4a03c'
ORDER BY sc.started_at;
```

Expected: A new cluster near 187-193_Principale, ~14:12 to ~16:10, with gps_gap ~118 min.

Verify trips are split:

```sql
SELECT t.id,
  to_char(t.started_at AT TIME ZONE 'America/Toronto', 'HH24:MI') as start_edt,
  to_char(t.ended_at AT TIME ZONE 'America/Toronto', 'HH24:MI') as end_edt,
  t.duration_minutes, round(t.distance_km::numeric, 2) as km,
  ls.name as from_loc, le.name as to_loc,
  t.gps_gap_seconds
FROM trips t
LEFT JOIN locations ls ON ls.id = t.start_location_id
LEFT JOIN locations le ON le.id = t.end_location_id
WHERE t.shift_id = '36772573-7ffa-4e8f-97dd-384776a4a03c'
ORDER BY t.started_at;
```

Expected: The old 120-min trip is gone. Now: short trip (~2 min) to the cluster + short trip from cluster to clock-out.

- [ ] **Step 2: Re-run detect_trips on Jessy 03/20**

```sql
SELECT * FROM detect_trips('5e4a26e7-5405-4d3b-8680-a05617869fff');
```

Verify with same cluster/trip queries using shift_id `5e4a26e7-5405-4d3b-8680-a05617869fff`.

Expected: New cluster at 234-238_Principale (~13:22 to ~14:13, gap ~47 min). Trip split into: short trip to 234-238 + cluster + short trip to 154_Charlebois.

- [ ] **Step 3: Re-run detect_trips on Rostang 03/17**

```sql
SELECT * FROM detect_trips('982e30f4-a0ce-4316-8e65-4f4c63f3555e');
```

Verify with same queries using shift_id `982e30f4-a0ce-4316-8e65-4f4c63f3555e`.

Expected: New cluster at 151-159_Principale (~17:30 to ~18:29, gap ~59 min). Trip split into: short trip to office + cluster + trip to Deschenes.

- [ ] **Step 4: Verify non-applicable cases are NOT affected**

```sql
-- Irene 03/18 - was moving at 14 km/h before gap, should NOT be split
-- Find her trip
SELECT t.id, t.duration_minutes, t.gps_gap_seconds,
  ls.name as from_loc, le.name as to_loc
FROM trips t
LEFT JOIN locations ls ON ls.id = t.start_location_id
LEFT JOIN locations le ON le.id = t.end_location_id
WHERE t.id = '1ba14be7-a5f4-48fb-9a27-6a30d0bf99f9';
```

Expected: Trip unchanged (still a single 89-min trip).

```sql
-- Karo-Lyn 03/25 - was moving at 59 km/h, should NOT be split
SELECT t.id, t.duration_minutes, t.gps_gap_seconds,
  ls.name as from_loc, le.name as to_loc
FROM trips t
LEFT JOIN locations ls ON ls.id = t.start_location_id
LEFT JOIN locations le ON le.id = t.end_location_id
WHERE t.id = 'e6d82532-f418-482d-9ff9-984a8fddf927';
```

Expected: Trip unchanged (still a single 18-min trip).

- [ ] **Step 5: Verify the approval page renders correctly**

Open the dashboard approval page for each of the 3 employees on their respective dates and confirm:
- The phantom long trip is gone
- A new stop appears with the location name and `-Xmin GPS` indicator
- Short trips surround the new stop
- Approval auto-classification is correct (building = approved)

---

### Task 3: Edge case — delete zero-length trips

**Files:**
- Modify: `supabase/migrations/20260401100000_split_trips_at_pregap_stops.sql`

- [ ] **Step 1: Test that a trip starting exactly at the cluster gets deleted**

If the employee stopped immediately after leaving the previous cluster (no driving), the original trip would have `duration_minutes = 0` after shortening. The function already handles this with:

```sql
DELETE FROM trips WHERE id = v_trip.id AND duration_minutes = 0;
```

Verify by checking if any 0-duration trips exist after re-running detect_trips on the 3 test shifts:

```sql
SELECT t.id, t.duration_minutes, t.distance_km
FROM trips t
WHERE t.shift_id IN (
  '36772573-7ffa-4e8f-97dd-384776a4a03c',
  '5e4a26e7-5405-4d3b-8680-a05617869fff',
  '982e30f4-a0ce-4316-8e65-4f4c63f3555e'
)
AND t.duration_minutes = 0;
```

Expected: No rows returned.

- [ ] **Step 2: Commit verification results**

```bash
git add -A
git commit -m "test: verify split_trips_at_pregap_stops on 3 known cases"
```
