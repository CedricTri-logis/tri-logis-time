# Cluster Spatial Coherence Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix `detect_trips` to split stationary clusters when GPS points drift beyond 50m (accuracy-adjusted), creating walking trips for the gap.

**Architecture:** Single migration (064) modifies `detect_trips()` to add a spatial coherence check in the pre-trip cluster accumulation block. When a stopped point is too far from the running centroid, the cluster is finalized, a trip is created from unclaimed intermediate points, and a new cluster begins. No frontend changes needed.

**Tech Stack:** PostgreSQL/PostGIS (Supabase), PL/pgSQL

---

### Task 1: Migration 064 — Add spatial coherence check to `detect_trips`

**Files:**
- Create: `supabase/migrations/064_cluster_spatial_coherence.sql`
- Reference: `supabase/migrations/061_detect_trips_with_clusters.sql` (current detect_trips, 842 lines)

**Step 1: Create migration file**

The migration is a `CREATE OR REPLACE FUNCTION detect_trips(...)` that copies the full function from migration 061 with these surgical additions:

**Addition A — New variables (after line 100):**

```sql
    -- Spatial coherence (064)
    v_cluster_max_drift CONSTANT DECIMAL := 50.0;  -- meters
    v_unclaimed_point_ids UUID[] := '{}';
    v_running_centroid_lat DECIMAL;
    v_running_centroid_lng DECIMAL;
    v_drift_distance DECIMAL;
    v_split_trip_id UUID;
    v_split_trip_distance DECIMAL;
    v_split_trip_start RECORD;
    v_split_trip_end RECORD;
    v_split_point_count INTEGER;
    v_split_low_accuracy INTEGER;
```

**Addition B — Spatial coherence check (replace lines 212-226):**

The existing cluster accumulation block:

```sql
            -- Accumulate into cluster (061)
            IF v_create_clusters THEN
                v_cluster_lats := v_cluster_lats || v_point.latitude;
                ...
            END IF;
```

Is replaced with:

```sql
            -- Accumulate into cluster with spatial coherence check (064)
            IF v_create_clusters THEN
                -- Check spatial coherence: is this stopped point too far from cluster?
                IF array_length(v_cluster_lats, 1) >= 3 THEN
                    -- Compute running centroid (simple average for distance check)
                    SELECT AVG(lat), AVG(lng)
                    INTO v_running_centroid_lat, v_running_centroid_lng
                    FROM unnest(v_cluster_lats, v_cluster_lngs) AS t(lat, lng);

                    v_drift_distance := haversine_km(
                        v_running_centroid_lat, v_running_centroid_lng,
                        v_point.latitude, v_point.longitude
                    ) * 1000.0;

                    -- Adjust for GPS accuracy: subtract accuracy (could be closer)
                    -- Clamp to 0 (high accuracy = can't conclude drift)
                    IF GREATEST(v_drift_distance - COALESCE(v_point.accuracy, 20.0), 0) > v_cluster_max_drift THEN
                        -- ==========================================================
                        -- SPLIT: Finalize current cluster, create trip, start new one
                        -- ==========================================================

                        -- 1. Finalize current cluster (same as pre-trip finalization)
                        SELECT
                            SUM(lat / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                            SUM(lng / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
                            1.0 / SQRT(SUM(1.0 / GREATEST(acc * acc, 1)))
                        INTO v_centroid_lat, v_centroid_lng, v_centroid_acc
                        FROM unnest(v_cluster_lats, v_cluster_lngs, v_cluster_accs) AS t(lat, lng, acc);

                        IF v_has_active_cluster THEN
                            UPDATE stationary_clusters SET
                                centroid_latitude = v_centroid_lat,
                                centroid_longitude = v_centroid_lng,
                                centroid_accuracy = v_centroid_acc,
                                ended_at = v_prev_point.captured_at,
                                duration_seconds = EXTRACT(EPOCH FROM (v_prev_point.captured_at - v_cluster_started_at))::INTEGER,
                                gps_point_count = array_length(v_cluster_point_ids, 1),
                                matched_location_id = match_trip_to_location(v_centroid_lat, v_centroid_lng, COALESCE(v_centroid_acc, 0))
                            WHERE id = v_cluster_id;
                            UPDATE gps_points SET stationary_cluster_id = v_cluster_id
                            WHERE id = ANY(v_cluster_point_ids) AND stationary_cluster_id IS NULL;
                            v_prev_cluster_id := v_cluster_id;
                        ELSIF v_cluster_started_at IS NOT NULL
                              AND EXTRACT(EPOCH FROM (v_prev_point.captured_at - v_cluster_started_at)) >= v_stationary_gap_minutes * 60 THEN
                            INSERT INTO stationary_clusters (
                                shift_id, employee_id,
                                centroid_latitude, centroid_longitude, centroid_accuracy,
                                started_at, ended_at, duration_seconds, gps_point_count,
                                matched_location_id
                            ) VALUES (
                                p_shift_id, v_employee_id,
                                v_centroid_lat, v_centroid_lng, v_centroid_acc,
                                v_cluster_started_at, v_prev_point.captured_at,
                                EXTRACT(EPOCH FROM (v_prev_point.captured_at - v_cluster_started_at))::INTEGER,
                                array_length(v_cluster_point_ids, 1),
                                match_trip_to_location(v_centroid_lat, v_centroid_lng, COALESCE(v_centroid_acc, 0))
                            )
                            RETURNING id INTO v_cluster_id;
                            UPDATE gps_points SET stationary_cluster_id = v_cluster_id
                            WHERE id = ANY(v_cluster_point_ids);
                            v_prev_cluster_id := v_cluster_id;
                        END IF;

                        -- 2. Create trip from unclaimed points (if any)
                        IF array_length(v_unclaimed_point_ids, 1) > 0 THEN
                            -- Compute trip start: use cluster centroid if available
                            v_eff_start_lat := COALESCE(v_centroid_lat, v_prev_point.latitude);
                            v_eff_start_lng := COALESCE(v_centroid_lng, v_prev_point.longitude);
                            v_eff_start_acc := COALESCE(v_centroid_acc, v_prev_point.accuracy, 0);

                            -- Trip end: the split point (current stopped point)
                            v_eff_end_lat := v_point.latitude;
                            v_eff_end_lng := v_point.longitude;
                            v_eff_end_acc := COALESCE(v_point.accuracy, 0);

                            -- Compute trip distance from unclaimed points
                            v_split_trip_distance := haversine_km(
                                v_eff_start_lat, v_eff_start_lng,
                                v_eff_end_lat, v_eff_end_lng
                            ) * v_correction_factor;
                            v_split_point_count := array_length(v_unclaimed_point_ids, 1);
                            v_split_low_accuracy := 0;

                            -- Get first and last unclaimed point timestamps for trip duration
                            SELECT gp.captured_at INTO v_split_trip_start
                            FROM gps_points gp WHERE gp.id = v_unclaimed_point_ids[1];
                            SELECT gp.captured_at INTO v_split_trip_end
                            FROM gps_points gp WHERE gp.id = v_unclaimed_point_ids[v_split_point_count];

                            IF v_split_trip_distance >= v_min_distance_km AND v_split_point_count >= 2 THEN
                                v_split_trip_id := gen_random_uuid();
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
                                ) VALUES (
                                    v_split_trip_id, p_shift_id, v_employee_id,
                                    v_split_trip_start.captured_at,
                                    v_split_trip_end.captured_at,
                                    v_eff_start_lat, v_eff_start_lng,
                                    v_eff_end_lat, v_eff_end_lng,
                                    ROUND(v_split_trip_distance, 3),
                                    GREATEST(1, EXTRACT(EPOCH FROM (v_split_trip_end.captured_at - v_split_trip_start.captured_at)) / 60)::INTEGER,
                                    'business',
                                    0.50,  -- lower confidence for split-detected trips
                                    v_split_point_count,
                                    v_split_low_accuracy,
                                    'auto',
                                    'unknown',
                                    v_prev_cluster_id,
                                    NULL  -- end_cluster_id set after new cluster is created
                                );

                                -- Insert junction records
                                FOR i IN 1..v_split_point_count LOOP
                                    INSERT INTO trip_gps_points (trip_id, gps_point_id, sequence_order)
                                    VALUES (v_split_trip_id, v_unclaimed_point_ids[i], i)
                                    ON CONFLICT DO NOTHING;
                                END LOOP;

                                -- Classify transport mode
                                v_transport_mode := classify_trip_transport_mode(v_split_trip_id);

                                -- Validate mode-specific constraints
                                v_displacement := haversine_km(
                                    v_eff_start_lat, v_eff_start_lng,
                                    v_eff_end_lat, v_eff_end_lng
                                );

                                IF v_transport_mode = 'walking' AND v_displacement < v_min_displacement_walking THEN
                                    DELETE FROM trip_gps_points WHERE trip_id = v_split_trip_id;
                                    DELETE FROM trips WHERE id = v_split_trip_id;
                                    v_split_trip_id := NULL;
                                ELSIF v_transport_mode = 'driving' AND v_split_trip_distance < v_min_distance_driving THEN
                                    DELETE FROM trip_gps_points WHERE trip_id = v_split_trip_id;
                                    DELETE FROM trips WHERE id = v_split_trip_id;
                                    v_split_trip_id := NULL;
                                ELSE
                                    UPDATE trips SET transport_mode = v_transport_mode WHERE id = v_split_trip_id;

                                    -- Location matching
                                    UPDATE trips SET
                                        start_location_id = match_trip_to_location(v_eff_start_lat, v_eff_start_lng, v_eff_start_acc),
                                        end_location_id = match_trip_to_location(v_eff_end_lat, v_eff_end_lng, v_eff_end_acc)
                                    WHERE id = v_split_trip_id;

                                    RETURN QUERY
                                    SELECT
                                        v_split_trip_id,
                                        v_split_trip_start.captured_at,
                                        v_split_trip_end.captured_at,
                                        v_eff_start_lat::DECIMAL(10,8),
                                        v_eff_start_lng::DECIMAL(11,8),
                                        v_eff_end_lat::DECIMAL(10,8),
                                        v_eff_end_lng::DECIMAL(11,8),
                                        ROUND(v_split_trip_distance, 3),
                                        GREATEST(1, EXTRACT(EPOCH FROM (v_split_trip_end.captured_at - v_split_trip_start.captured_at)) / 60)::INTEGER,
                                        0.50::DECIMAL(3,2),
                                        v_split_point_count;
                                END IF;
                            END IF;
                        END IF;

                        -- 3. Reset cluster state for new cluster
                        v_cluster_lats := '{}';
                        v_cluster_lngs := '{}';
                        v_cluster_accs := '{}';
                        v_cluster_point_ids := '{}';
                        v_cluster_started_at := NULL;
                        v_cluster_id := NULL;
                        v_has_active_cluster := FALSE;
                        v_unclaimed_point_ids := '{}';
                    END IF;  -- end split
                END IF;  -- end drift check

                -- Normal accumulation (point passes coherence check or cluster too small)
                v_cluster_lats := v_cluster_lats || v_point.latitude;
                v_cluster_lngs := v_cluster_lngs || v_point.longitude;
                v_cluster_accs := v_cluster_accs || COALESCE(v_point.accuracy, 20.0);
                v_cluster_point_ids := v_cluster_point_ids || v_point.id;
                IF v_cluster_started_at IS NULL THEN
                    v_cluster_started_at := v_point.captured_at;
                END IF;
                IF v_has_active_cluster THEN
                    UPDATE gps_points SET stationary_cluster_id = v_cluster_id WHERE id = v_point.id;
                END IF;

                -- Reset unclaimed: this stopped point joined the cluster successfully
                v_unclaimed_point_ids := '{}';
            END IF;
```

**Addition C — Unclaimed point tracking (after the IF/ELSIF chain, before `v_prev_point := v_point`):**

After line 647 (`END IF;`), before line 650 (`v_prev_point := v_point;`), add:

```sql
            -- Track unclaimed points: NOT stopped, NOT in trip, speed below movement (064)
            IF v_create_clusters AND NOT v_in_trip AND NOT v_point_is_stopped
               AND v_speed < v_movement_speed AND array_length(v_cluster_lats, 1) > 0 THEN
                v_unclaimed_point_ids := v_unclaimed_point_ids || v_point.id;
            END IF;
```

**Addition D — Reset unclaimed on trip start (inside the `IF NOT v_in_trip` block at line 364):**

After the cluster finalization + trip start code (line 421), add to the cluster reset block:

```sql
                        v_unclaimed_point_ids := '{}';
```

**Step 2: Apply migration to Supabase**

```bash
cd /Users/cedric/Desktop/PROJECT/TEST/GPS_Tracker
supabase db push --linked
```

**Step 3: Verify on Ginette's shift**

Re-detect trips for Ginette's shift and verify the cluster is split:

```sql
-- Find Ginette's shift containing the problematic cluster
SELECT s.id, s.started_at, s.ended_at
FROM shifts s
JOIN employee_profiles ep ON ep.id = s.employee_id
WHERE ep.full_name = 'Ginette Ndoumou Damaris'
  AND s.started_at::date = '2026-02-27'
  AND s.status = 'completed';

-- Re-detect (replace SHIFT_ID with actual value)
SELECT * FROM detect_trips('SHIFT_ID');

-- Verify: should now have 2 clusters instead of 1 oversized one
SELECT id, centroid_latitude, centroid_longitude, centroid_accuracy,
       started_at, ended_at, duration_seconds, gps_point_count
FROM stationary_clusters
WHERE shift_id = 'SHIFT_ID'
ORDER BY started_at;

-- Verify: should have a walking trip between the two clusters
SELECT id, started_at, ended_at, transport_mode, distance_km,
       start_latitude, start_longitude, end_latitude, end_longitude
FROM trips
WHERE shift_id = 'SHIFT_ID'
ORDER BY started_at;
```

**Expected results:**
- Cluster 1: centroid near (48.2393, -79.0235), ~44 min, ~30 GPS points
- Walking trip: ~285m, ~5 min, transport_mode = 'walking'
- Cluster 2: centroid near (48.2380, -79.0195), ~61 min, ~70 GPS points
- No cluster with centroid at IRIS (48.2389, -79.0218)

**Step 4: Commit**

```bash
git add supabase/migrations/064_cluster_spatial_coherence.sql
git commit -m "feat: add spatial coherence check to detect_trips cluster accumulation

Split stationary clusters when a stopped GPS point drifts beyond 50m
(accuracy-adjusted) from the running centroid. Creates a trip from
unclaimed intermediate points. Fixes clusters whose centroid landed
between two real locations where nobody actually was."
```

---

### Task 2: Re-detect affected shifts and deploy

**Step 1: Re-detect all completed shifts that had oversized clusters**

Run on Supabase to find and re-detect shifts that may have been affected:

```sql
-- Find shifts with clusters spanning >100m (likely affected)
WITH cluster_spreads AS (
    SELECT
        sc.shift_id,
        sc.id AS cluster_id,
        sc.gps_point_count,
        sc.duration_seconds,
        MAX(ST_Distance(
            ST_SetSRID(ST_MakePoint(sc.centroid_longitude, sc.centroid_latitude), 4326)::geography,
            ST_SetSRID(ST_MakePoint(gp.longitude::DOUBLE PRECISION, gp.latitude::DOUBLE PRECISION), 4326)::geography
        )) AS max_point_distance_m
    FROM stationary_clusters sc
    JOIN gps_points gp ON gp.stationary_cluster_id = sc.id
    GROUP BY sc.shift_id, sc.id, sc.gps_point_count, sc.duration_seconds
    HAVING MAX(ST_Distance(
        ST_SetSRID(ST_MakePoint(sc.centroid_longitude, sc.centroid_latitude), 4326)::geography,
        ST_SetSRID(ST_MakePoint(gp.longitude::DOUBLE PRECISION, gp.latitude::DOUBLE PRECISION), 4326)::geography
    )) > 100
)
SELECT DISTINCT shift_id FROM cluster_spreads;
```

Then re-detect each affected shift:

```sql
SELECT * FROM detect_trips('SHIFT_ID_1');
SELECT * FROM detect_trips('SHIFT_ID_2');
-- ... for each affected shift
```

**Step 2: Push and deploy**

Use the `/push` skill to commit, push, apply migration, and deploy to Vercel.
