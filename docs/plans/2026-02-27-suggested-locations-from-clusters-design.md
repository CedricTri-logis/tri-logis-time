# Suggested Locations from Stationary Clusters — Design

## Problem

`get_unmatched_trip_clusters()` computes suggested location centroids using a naive `AVG()` over raw trip endpoint coordinates. Meanwhile, `detect_trips()` (migration 061) already computes accuracy-weighted centroids for stationary clusters. The suggested locations feature should use these precise centroids as its source of truth instead of re-averaging raw trip coordinates.

## Decision: Source from `stationary_clusters` directly (Approach A)

Rewrite `get_unmatched_trip_clusters()` and `get_cluster_occurrences()` to query `stationary_clusters` instead of `trips`. This eliminates the measurement gap between what trips store and what the dashboard shows.

**Why not the alternatives:**
- Approach B (JOIN trips to clusters): Double-layer grouping — DBSCAN on cluster centroids that are already grouped. Needless complexity.
- Approach C (client-side grouping): Inconsistent, slow on large volumes, duplicates logic.

## Design

### RPC 1: `get_unmatched_trip_clusters` (replaced)

**Source:** `stationary_clusters WHERE matched_location_id IS NULL`

**Pipeline:**
1. Filter unmatched clusters
2. Group by proximity via `ST_ClusterDBSCAN(centroid, eps ~111m, minpoints=1)`
3. Compute group centroid: accuracy-weighted mean of individual cluster centroids
   - `lat = SUM(centroid_lat / GREATEST(centroid_accuracy, 1)) / SUM(1 / GREATEST(centroid_accuracy, 1))`
4. Aggregate metrics per group

**Returns:**
- `cluster_id` (INTEGER) — DBSCAN group ID
- `centroid_latitude`, `centroid_longitude` — weighted centroid of group
- `occurrence_count` — number of individual stationary clusters
- `employee_names` — distinct employees
- `first_seen`, `last_seen` — temporal range
- `total_duration_seconds` — sum of all cluster durations
- `avg_accuracy` — average centroid accuracy

**Removed fields:** `has_start_endpoints`, `has_end_endpoints`, `sample_addresses` (trip-centric, no longer relevant)

**Filters:** `ignored_location_clusters` exclusion (unchanged)

### RPC 2: `get_cluster_occurrences` (replaced)

**Input:** centroid_lat, centroid_lng, radius_meters (default 150)

**Source:** `stationary_clusters WHERE matched_location_id IS NULL` within radius

**Returns per occurrence:**
- `cluster_id` (UUID)
- `employee_name`
- `centroid_latitude`, `centroid_longitude`, `centroid_accuracy`
- `started_at`, `ended_at`
- `duration_seconds`
- `gps_point_count`
- `shift_id`

### Dashboard changes

**Summary cards (each suggested location):**
- Google reverse-geocoded address (unchanged)
- Number of stops (e.g., "7 stops")
- Distinct employees
- Total cumulative duration
- Average centroid accuracy
- First/last seen dates

**Drill-down (selected location):**
- List: individual stationary clusters (Employee, Date, Duration, GPS Points, Accuracy)
- Map: marker per cluster with accuracy circle
- No more "Start/End" column (no trip endpoint concept)

**Actions (unchanged):**
- Create location: prefills form with group weighted centroid
- Ignore: uses existing `ignored_location_clusters`

### Migration

Single migration (063) replacing both RPCs. No schema changes, no new tables, no backfill needed.

| Function | Before | After |
|----------|--------|-------|
| `get_unmatched_trip_clusters` | DBSCAN on trips.start/end_latitude, naive AVG() | DBSCAN on stationary_clusters centroids, accuracy-weighted mean |
| `get_cluster_occurrences` | Trip endpoints within radius | Individual stationary_clusters within radius |
