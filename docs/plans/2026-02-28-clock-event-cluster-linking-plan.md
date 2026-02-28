# Clock-in/out Event Cluster Linking — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Link clock-in/out events to stationary clusters and propagate location matches, eliminating noisy standalone GPS suggestions.

**Architecture:** Add 4 FK columns to `shifts` (`clock_in_cluster_id`, `clock_out_cluster_id`, `clock_in_location_id`, `clock_out_location_id`). `detect_trips` links clock-in/out to nearby clusters after each cluster persist. The suggestion RPCs only include clock-in/out that have no cluster AND no location. A spatial safety net on trip endpoints catches the centroid-drift matching bug.

**Tech Stack:** PostgreSQL/PostGIS (Supabase), SQL migrations

---

## Reference Files

- `supabase/migrations/076_fix_prev_cluster_tracking.sql` — current `detect_trips` (898 lines)
- `supabase/migrations/080_tighten_cluster_eps.sql` — current `get_unmatched_trip_clusters` + `get_cluster_occurrences`
- `supabase/migrations/078_get_employee_activity.sql` — activity timeline RPC

## Key Code Locations in detect_trips (076)

Clusters are persisted in **4 places** — the clock-in/out linking must run after each:

1. **Line 420–444**: Current cluster persisted (INSERT or UPDATE) — when tentative becomes new cluster
2. **Line 468–488**: Tentative cluster persisted (INSERT) — arrival cluster for trip
3. **Line 713–725**: End-of-data: existing cluster UPDATE
4. **Line 729–748**: End-of-data: new cluster INSERT

---

### Task 1: Schema — Add columns to `shifts` + backfill

**Files:**
- Create: `supabase/migrations/081_clock_event_cluster_linking.sql`

**Step 1: Write the migration**

```sql
-- =============================================================================
-- Migration 081: Link clock-in/out events to stationary clusters + locations
-- =============================================================================
-- Adds structural linking between clock events and clusters. When a clock-in/out
-- GPS reading is within 50m of a stationary cluster, it uses the cluster's
-- centroid (multi-point average) instead of its own noisy single-point reading.
-- Location matches propagate from cluster → shift for quick lookup.
-- =============================================================================

-- 1. Add columns
ALTER TABLE shifts
  ADD COLUMN IF NOT EXISTS clock_in_cluster_id UUID REFERENCES stationary_clusters(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS clock_out_cluster_id UUID REFERENCES stationary_clusters(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS clock_in_location_id UUID REFERENCES locations(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS clock_out_location_id UUID REFERENCES locations(id) ON DELETE SET NULL;

-- 2. Index for suggestion query performance
CREATE INDEX IF NOT EXISTS idx_shifts_clock_in_cluster ON shifts(clock_in_cluster_id) WHERE clock_in_cluster_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_shifts_clock_out_cluster ON shifts(clock_out_cluster_id) WHERE clock_out_cluster_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_shifts_clock_in_location ON shifts(clock_in_location_id) WHERE clock_in_location_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_shifts_clock_out_location ON shifts(clock_out_location_id) WHERE clock_out_location_id IS NOT NULL;

-- 3. Backfill: link clock-in to nearest cluster within 50m (same shift)
UPDATE shifts s SET
  clock_in_cluster_id = sub.cluster_id,
  clock_in_location_id = sub.matched_location_id
FROM (
  SELECT DISTINCT ON (s2.id)
    s2.id AS shift_id,
    sc.id AS cluster_id,
    sc.matched_location_id
  FROM shifts s2
  JOIN stationary_clusters sc ON sc.shift_id = s2.id
  WHERE s2.clock_in_location IS NOT NULL
    AND ST_DWithin(
      ST_SetSRID(ST_MakePoint(
        (s2.clock_in_location->>'longitude')::DOUBLE PRECISION,
        (s2.clock_in_location->>'latitude')::DOUBLE PRECISION
      ), 4326)::geography,
      ST_SetSRID(ST_MakePoint(sc.centroid_longitude::DOUBLE PRECISION, sc.centroid_latitude::DOUBLE PRECISION), 4326)::geography,
      50
    )
  ORDER BY s2.id, ST_Distance(
    ST_SetSRID(ST_MakePoint(
      (s2.clock_in_location->>'longitude')::DOUBLE PRECISION,
      (s2.clock_in_location->>'latitude')::DOUBLE PRECISION
    ), 4326)::geography,
    ST_SetSRID(ST_MakePoint(sc.centroid_longitude::DOUBLE PRECISION, sc.centroid_latitude::DOUBLE PRECISION), 4326)::geography
  ) ASC
) sub
WHERE s.id = sub.shift_id;

-- 4. Backfill: link clock-out to nearest cluster within 50m (same shift)
UPDATE shifts s SET
  clock_out_cluster_id = sub.cluster_id,
  clock_out_location_id = sub.matched_location_id
FROM (
  SELECT DISTINCT ON (s2.id)
    s2.id AS shift_id,
    sc.id AS cluster_id,
    sc.matched_location_id
  FROM shifts s2
  JOIN stationary_clusters sc ON sc.shift_id = s2.id
  WHERE s2.clock_out_location IS NOT NULL
    AND s2.clocked_out_at IS NOT NULL
    AND ST_DWithin(
      ST_SetSRID(ST_MakePoint(
        (s2.clock_out_location->>'longitude')::DOUBLE PRECISION,
        (s2.clock_out_location->>'latitude')::DOUBLE PRECISION
      ), 4326)::geography,
      ST_SetSRID(ST_MakePoint(sc.centroid_longitude::DOUBLE PRECISION, sc.centroid_latitude::DOUBLE PRECISION), 4326)::geography,
      50
    )
  ORDER BY s2.id, ST_Distance(
    ST_SetSRID(ST_MakePoint(
      (s2.clock_out_location->>'longitude')::DOUBLE PRECISION,
      (s2.clock_out_location->>'latitude')::DOUBLE PRECISION
    ), 4326)::geography,
    ST_SetSRID(ST_MakePoint(sc.centroid_longitude::DOUBLE PRECISION, sc.centroid_latitude::DOUBLE PRECISION), 4326)::geography
  ) ASC
) sub
WHERE s.id = sub.shift_id;

-- 5. Backfill: for shifts WITHOUT a nearby cluster, try direct location match
UPDATE shifts s SET
  clock_in_location_id = match_trip_to_location(
    (s.clock_in_location->>'latitude')::DECIMAL,
    (s.clock_in_location->>'longitude')::DECIMAL,
    COALESCE(s.clock_in_accuracy, 20)
  )
WHERE s.clock_in_location IS NOT NULL
  AND s.clock_in_cluster_id IS NULL
  AND s.clock_in_location_id IS NULL;

UPDATE shifts s SET
  clock_out_location_id = match_trip_to_location(
    (s.clock_out_location->>'latitude')::DECIMAL,
    (s.clock_out_location->>'longitude')::DECIMAL,
    COALESCE(s.clock_out_accuracy, 20)
  )
WHERE s.clock_out_location IS NOT NULL
  AND s.clocked_out_at IS NOT NULL
  AND s.clock_out_cluster_id IS NULL
  AND s.clock_out_location_id IS NULL;
```

**Step 2: Apply migration**

Run: `supabase db push --linked` from project root, or apply via Supabase MCP `apply_migration`.

**Step 3: Verify backfill**

```sql
SELECT
  'clock_in' as type,
  COUNT(*) FILTER (WHERE clock_in_cluster_id IS NOT NULL) as linked_to_cluster,
  COUNT(*) FILTER (WHERE clock_in_location_id IS NOT NULL) as linked_to_location,
  COUNT(*) FILTER (WHERE clock_in_location IS NOT NULL AND clock_in_cluster_id IS NULL AND clock_in_location_id IS NULL) as standalone
FROM shifts
WHERE clock_in_location IS NOT NULL

UNION ALL

SELECT
  'clock_out',
  COUNT(*) FILTER (WHERE clock_out_cluster_id IS NOT NULL),
  COUNT(*) FILTER (WHERE clock_out_location_id IS NOT NULL),
  COUNT(*) FILTER (WHERE clock_out_location IS NOT NULL AND clock_out_cluster_id IS NULL AND clock_out_location_id IS NULL)
FROM shifts
WHERE clock_out_location IS NOT NULL;
```

**Step 4: Commit**

```bash
git add supabase/migrations/081_clock_event_cluster_linking.sql
git commit -m "feat: add clock event cluster/location linking columns with backfill (migration 081)"
```

---

### Task 2: Update `detect_trips` — link clock-in/out to clusters

**Files:**
- Create: `supabase/migrations/082_detect_trips_clock_linking.sql`

**Context:** The current `detect_trips` (076) persists clusters in 4 code locations. After each persist, we add a check: is the shift's clock-in/out within 50m of this cluster? If yes, link it.

**Step 1: Write the migration**

The migration recreates `detect_trips` with these additions:

1. **New variables** (add after line 115 declarations):
```sql
-- Clock-in/out linking
v_clock_in_lat DOUBLE PRECISION := NULL;
v_clock_in_lng DOUBLE PRECISION := NULL;
v_clock_in_acc DECIMAL := NULL;
v_clock_out_lat DOUBLE PRECISION := NULL;
v_clock_out_lng DOUBLE PRECISION := NULL;
v_clock_out_acc DECIMAL := NULL;
v_clock_in_linked BOOLEAN := FALSE;
v_clock_out_linked BOOLEAN := FALSE;
```

2. **Load clock-in/out coords** (add after `v_create_clusters` assignment, ~line 152):
```sql
-- Load clock-in/out coordinates for cluster linking
SELECT
  (s.clock_in_location->>'latitude')::DOUBLE PRECISION,
  (s.clock_in_location->>'longitude')::DOUBLE PRECISION,
  COALESCE(s.clock_in_accuracy, 20),
  (s.clock_out_location->>'latitude')::DOUBLE PRECISION,
  (s.clock_out_location->>'longitude')::DOUBLE PRECISION,
  COALESCE(s.clock_out_accuracy, 20)
INTO v_clock_in_lat, v_clock_in_lng, v_clock_in_acc,
     v_clock_out_lat, v_clock_out_lng, v_clock_out_acc
FROM shifts s
WHERE s.id = p_shift_id;
```

3. **Helper block** — add after EACH of the 4 cluster persist locations (after the `RETURNING id INTO ...` or `WHERE id = ...` line). Use the cluster's ID and centroid variables available in that scope:

```sql
-- Link clock-in/out to this cluster if within 50m
IF v_create_clusters THEN
    IF NOT v_clock_in_linked AND v_clock_in_lat IS NOT NULL THEN
        IF ST_DWithin(
            ST_SetSRID(ST_MakePoint(v_clock_in_lng, v_clock_in_lat), 4326)::geography,
            ST_SetSRID(ST_MakePoint(<cluster_lng_var>::DOUBLE PRECISION, <cluster_lat_var>::DOUBLE PRECISION), 4326)::geography,
            50
        ) THEN
            UPDATE shifts SET
                clock_in_cluster_id = <cluster_id_var>,
                clock_in_location_id = (SELECT matched_location_id FROM stationary_clusters WHERE id = <cluster_id_var>)
            WHERE id = p_shift_id;
            v_clock_in_linked := TRUE;
        END IF;
    END IF;

    IF NOT v_clock_out_linked AND v_clock_out_lat IS NOT NULL THEN
        IF ST_DWithin(
            ST_SetSRID(ST_MakePoint(v_clock_out_lng, v_clock_out_lat), 4326)::geography,
            ST_SetSRID(ST_MakePoint(<cluster_lng_var>::DOUBLE PRECISION, <cluster_lat_var>::DOUBLE PRECISION), 4326)::geography,
            50
        ) THEN
            UPDATE shifts SET
                clock_out_cluster_id = <cluster_id_var>,
                clock_out_location_id = (SELECT matched_location_id FROM stationary_clusters WHERE id = <cluster_id_var>)
            WHERE id = p_shift_id;
            v_clock_out_linked := TRUE;
        END IF;
    END IF;
END IF;
```

The variable substitutions for each of the 4 locations:

| # | Code location (076 line) | cluster_id_var | cluster_lat_var | cluster_lng_var |
|---|--------------------------|----------------|-----------------|-----------------|
| 1 | ~442 (current cluster INSERT/UPDATE) | `v_cluster_id` | `v_cluster_centroid_lat` | `v_cluster_centroid_lng` |
| 2 | ~485 (tentative → new arrival cluster INSERT) | `v_new_cluster_id` | `v_arr_centroid_lat` | `v_arr_centroid_lng` |
| 3 | ~725 (end-of-data cluster UPDATE) | `v_cluster_id` | `v_cluster_centroid_lat` | `v_cluster_centroid_lng` |
| 4 | ~745 (end-of-data cluster INSERT) | `v_cluster_id` | `v_cluster_centroid_lat` | `v_cluster_centroid_lng` |

4. **Post-loop direct match** — at the end of the function (before final `END;`), for unlinked clock events, try direct location matching:

```sql
-- Direct location match for clock-in/out that didn't match any cluster
IF v_create_clusters THEN
    IF NOT v_clock_in_linked AND v_clock_in_lat IS NOT NULL THEN
        UPDATE shifts SET
            clock_in_location_id = match_trip_to_location(v_clock_in_lat::DECIMAL, v_clock_in_lng::DECIMAL, v_clock_in_acc)
        WHERE id = p_shift_id AND clock_in_location_id IS NULL;
    END IF;
    IF NOT v_clock_out_linked AND v_clock_out_lat IS NOT NULL THEN
        UPDATE shifts SET
            clock_out_location_id = match_trip_to_location(v_clock_out_lat::DECIMAL, v_clock_out_lng::DECIMAL, v_clock_out_acc)
        WHERE id = p_shift_id AND clock_out_location_id IS NULL;
    END IF;
END IF;
```

**Step 2: Apply migration**

Run via Supabase MCP or `supabase db push --linked`.

**Step 3: Verify on a real shift**

```sql
-- Pick a shift that has clock-in + stationary clusters
SELECT s.id, s.clock_in_cluster_id, s.clock_in_location_id,
       s.clock_out_cluster_id, s.clock_out_location_id
FROM shifts s
WHERE s.clock_in_location IS NOT NULL
  AND EXISTS (SELECT 1 FROM stationary_clusters sc WHERE sc.shift_id = s.id)
ORDER BY s.clocked_in_at DESC LIMIT 5;
```

**Step 4: Commit**

```bash
git add supabase/migrations/082_detect_trips_clock_linking.sql
git commit -m "feat: link clock-in/out to clusters in detect_trips (migration 082)"
```

---

### Task 3: Update suggestion RPCs — new filters + spatial safety net

**Files:**
- Create: `supabase/migrations/083_suggestion_clock_filter.sql`

**Step 1: Write the migration**

Drop and recreate both RPCs with these changes:

**`get_unmatched_trip_clusters` changes:**

- **Blocks A & B (trip endpoints):** Add spatial safety net — exclude endpoints within `radius + accuracy` of any active location, even if `location_id IS NULL`:
```sql
-- After the existing WHERE t.start_location_id IS NULL clause, add:
AND NOT EXISTS (
    SELECT 1 FROM locations l
    WHERE l.is_active = TRUE
      AND ST_DWithin(
          ST_SetSRID(ST_MakePoint(t.start_longitude::DOUBLE PRECISION, t.start_latitude::DOUBLE PRECISION), 4326)::geography,
          l.location,
          l.radius_meters + COALESCE(
              (SELECT gp.accuracy FROM trip_gps_points tgp
               JOIN gps_points gp ON gp.id = tgp.gps_point_id
               WHERE tgp.trip_id = t.id
               ORDER BY tgp.sequence_order ASC LIMIT 1),
              0
          )
      )
)
```

- **Blocks C & D (clock-in/out):** Replace existing filter with new column-based filter:
```sql
-- Clock-in: only standalone, unmatched events
WHERE s.clock_in_location IS NOT NULL
  AND s.clocked_in_at >= NOW() - INTERVAL '90 days'
  AND s.clock_in_cluster_id IS NULL     -- not linked to a cluster
  AND s.clock_in_location_id IS NULL    -- not matched to a location
  AND COALESCE(s.clock_in_accuracy, 20) <= 50   -- accuracy filter

-- Clock-out: same pattern
WHERE s.clock_out_location IS NOT NULL
  AND s.clocked_out_at IS NOT NULL
  AND s.clocked_out_at >= NOW() - INTERVAL '90 days'
  AND s.clock_out_cluster_id IS NULL
  AND s.clock_out_location_id IS NULL
  AND COALESCE(s.clock_out_accuracy, 20) <= 50
```

**`get_cluster_occurrences` changes:**

Same filter on blocks C & D: only show clock-in/out where `cluster_id IS NULL AND location_id IS NULL`.

**Step 2: Apply migration**

Run via Supabase MCP or `supabase db push --linked`.

**Step 3: Verify suggestion count dropped**

```sql
-- Before should have been 80+76=156 clock events, now much less
SELECT endpoint_type, COUNT(*)
FROM get_unmatched_trip_clusters(1) u
CROSS JOIN LATERAL get_cluster_occurrences(u.centroid_latitude, u.centroid_longitude, 100) o
GROUP BY endpoint_type;
```

**Step 4: Commit**

```bash
git add supabase/migrations/083_suggestion_clock_filter.sql
git commit -m "feat: filter suggestions using clock-event linking + spatial safety net (migration 083)"
```

---

### Task 4: Update activity timeline RPC (optional but recommended)

**Files:**
- Create: `supabase/migrations/084_activity_clock_location_name.sql`

**Step 1: Write the migration**

Update `get_employee_activity` (078) to JOIN `locations` for clock-in/out events:

In the clock_in and clock_out CTEs, add:
```sql
-- In the clock_in SELECT, add:
s.clock_in_location_id AS location_id,
l_in.name AS location_name,
-- JOIN:
LEFT JOIN locations l_in ON l_in.id = s.clock_in_location_id

-- Same for clock_out:
s.clock_out_location_id AS location_id,
l_out.name AS location_name,
LEFT JOIN locations l_out ON l_out.id = s.clock_out_location_id
```

Add `location_id UUID` and `location_name TEXT` to the return type.

**Step 2: Apply and verify**

**Step 3: Commit**

```bash
git add supabase/migrations/084_activity_clock_location_name.sql
git commit -m "feat: show location names for clock events in activity timeline (migration 084)"
```

---

### Task 5: Push & deploy

**Step 1:** Run `/push` to commit all migrations, push, merge to main, and deploy.

**Step 2:** Verify on the dashboard that:
- Suggested locations count dropped significantly (156 clock events → much fewer standalone ones)
- Clicking a cluster no longer shows clock events that are near known locations
- Activity timeline shows location names for clock events (if Task 4 done)
