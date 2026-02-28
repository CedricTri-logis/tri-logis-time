# Design: Clock-in/out Event Cluster Linking

## Problem

Clock-in/out events (single GPS readings on `shifts`) are currently UNIONed directly into the suggestion pipeline (`get_unmatched_trip_clusters`). This causes:

1. **Noisy coordinates**: A single GPS reading (e.g., 39m accuracy) can place the event far from its true location, creating phantom suggestions near known locations.
2. **No deduplication**: When a stationary cluster already exists at the same spot, both the cluster's trip endpoints AND the clock-in/out appear as separate points in DBSCAN, inflating occurrence counts.
3. **No location association**: Clock-in/out events have no link to known locations, so the activity timeline can't show "Clocked in at AIM Recyclage".

Additionally, `detect_trips` has a centroid-drift bug: it uses cluster centroids for `match_trip_to_location`, but the centroid can be slightly offset from the actual GPS endpoint, causing trips to have `end_location_id = NULL` even when they should match.

## Solution: Structural Linking

### New columns on `shifts`

| Column | Type | Description |
|--------|------|-------------|
| `clock_in_cluster_id` | UUID FK → stationary_clusters | Cluster containing the clock-in GPS point (NULL if no nearby cluster) |
| `clock_out_cluster_id` | UUID FK → stationary_clusters | Cluster containing the clock-out GPS point (NULL if no nearby cluster) |
| `clock_in_location_id` | UUID FK → locations | Propagated from cluster's `matched_location_id` (NULL if unmatched) |
| `clock_out_location_id` | UUID FK → locations | Propagated from cluster's `matched_location_id` (NULL if unmatched) |

### Data flow

```
Clock-in GPS reading (single point, noisy)
    │
    ├─ Within 50m of a stationary cluster?
    │   YES → clock_in_cluster_id = cluster.id
    │          clock_in_location_id = cluster.matched_location_id (may be NULL)
    │          Canonical location = cluster centroid (accurate, multi-point average)
    │
    │   NO  → clock_in_cluster_id = NULL
    │          clock_in_location_id = match_trip_to_location(clock_in coords + accuracy)
    │          Canonical location = raw GPS reading
    │
    └─ Suggestion pipeline:
        - Has location_id? → Skip (known location)
        - Has cluster_id but no location_id? → Skip (cluster's trip endpoints already represent it)
        - No cluster_id AND no location_id? → Include as standalone suggestion
```

### Changes to `detect_trips`

After each stationary cluster is finalized (both current and tentative promoted to current), add a linking step:

```sql
-- Link clock-in if within 50m of this cluster
IF v_shift_clock_in_location IS NOT NULL
   AND v_clock_in_cluster_id IS NULL  -- not already linked
   AND ST_DWithin(clock_in_point, cluster_centroid, 50)
THEN
    UPDATE shifts SET
        clock_in_cluster_id = cluster.id,
        clock_in_location_id = cluster.matched_location_id
    WHERE id = p_shift_id;
END IF;

-- Same for clock-out
```

### Changes to `get_unmatched_trip_clusters`

1. **Clock-in/out blocks (C, D)**: Only include where `clock_in_cluster_id IS NULL AND clock_in_location_id IS NULL` (standalone, unmatched events).
2. **Trip endpoint blocks (A, B)**: Add spatial safety net — exclude endpoints within `radius + accuracy` of any active location, even if `end_location_id IS NULL`. This catches the centroid-drift matching bug.

### Changes to `get_cluster_occurrences`

Same filter: only show clock-in/out drill-down rows where the event is standalone (no cluster, no location).

### Backfill

The migration includes a one-time UPDATE to link existing shifts to their nearest cluster:

```sql
UPDATE shifts s SET
    clock_in_cluster_id = sc.id,
    clock_in_location_id = sc.matched_location_id
FROM stationary_clusters sc
WHERE sc.shift_id = s.id
  AND s.clock_in_location IS NOT NULL
  AND s.clock_in_cluster_id IS NULL
  AND ST_DWithin(clock_in_point, cluster_centroid, 50);
-- Same for clock_out
```

For shifts without a nearby cluster, also try direct location matching:

```sql
UPDATE shifts s SET
    clock_in_location_id = match_trip_to_location(lat, lng, accuracy)
WHERE s.clock_in_location IS NOT NULL
  AND s.clock_in_cluster_id IS NULL
  AND s.clock_in_location_id IS NULL;
```

### Impact on Activity Timeline

The `get_employee_activity` RPC (migration 078) currently returns clock-in/out events with raw GPS coords and no location name. With `clock_in_location_id` available, it can JOIN to `locations` to show the location name (e.g., "Pointage entrée — AIM Recyclage").

## Migration Plan

1. **Migration 081**: Add 4 columns to `shifts`, backfill existing data
2. **Migration 082**: Update `detect_trips` with cluster-linking step
3. **Migration 083**: Update `get_unmatched_trip_clusters` and `get_cluster_occurrences` with new filters + spatial safety net
4. **Optional**: Update `get_employee_activity` to show location names for clock events

## Files affected

| File | Change |
|------|--------|
| `supabase/migrations/081_*.sql` | Schema + backfill |
| `supabase/migrations/082_*.sql` | detect_trips update |
| `supabase/migrations/083_*.sql` | Suggestion RPCs update |
| Dashboard (optional) | Activity timeline location names |
