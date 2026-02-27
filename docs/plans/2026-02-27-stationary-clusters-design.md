# Stationary Clusters + Centroid Trip Endpoints

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace single-point trip endpoints with accuracy-weighted centroids of stationary GPS clusters, and expose stationary clusters as first-class entities for visualization and analytics.

**Architecture:** Stationary clusters are detected within `detect_trips` as contiguous sequences of low-speed GPS points in the same spatial radius. Each cluster stores an accuracy-weighted centroid. Trip start/end coordinates use their linked cluster centroids instead of individual GPS points. A new dashboard tab visualizes all clusters.

**Tech Stack:** PostgreSQL/PostGIS (Supabase), Next.js 14+ (App Router), Google Maps API, shadcn/ui

---

## Problem

GPS points have 10-20m accuracy in urban areas. Using a single point (first stationary) as a trip endpoint causes:
- Endpoint drift ~18m from actual stop location
- Missed geofence matches (point falls outside 10m radius)
- False suggested locations

**Validated on real data:** Kouma Baraka trip (Feb 27, 2026)
- First stationary point: 18.7m from location "254-258_Cardinal-Begin-E"
- Centroid of 12 stationary points: 7.4m from location (11.3m improvement)
- With centroid: match. Without: miss.

## Database Schema

### New table: `stationary_clusters`

```sql
CREATE TABLE stationary_clusters (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    shift_id UUID NOT NULL REFERENCES shifts(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
    centroid_latitude DECIMAL(10, 8) NOT NULL,
    centroid_longitude DECIMAL(11, 8) NOT NULL,
    centroid_accuracy DECIMAL(6, 2),          -- estimated accuracy of centroid
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ NOT NULL,
    duration_seconds INTEGER NOT NULL,
    gps_point_count INTEGER NOT NULL DEFAULT 0,
    matched_location_id UUID REFERENCES locations(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_stationary_clusters_shift ON stationary_clusters(shift_id);
CREATE INDEX idx_stationary_clusters_employee_time ON stationary_clusters(employee_id, started_at DESC);
CREATE INDEX idx_stationary_clusters_location ON stationary_clusters(matched_location_id) WHERE matched_location_id IS NOT NULL;
```

### New column on `gps_points`

```sql
ALTER TABLE gps_points ADD COLUMN stationary_cluster_id UUID REFERENCES stationary_clusters(id) ON DELETE SET NULL;
CREATE INDEX idx_gps_points_cluster ON gps_points(stationary_cluster_id) WHERE stationary_cluster_id IS NOT NULL;
```

### New columns on `trips`

```sql
ALTER TABLE trips ADD COLUMN start_cluster_id UUID REFERENCES stationary_clusters(id) ON DELETE SET NULL;
ALTER TABLE trips ADD COLUMN end_cluster_id UUID REFERENCES stationary_clusters(id) ON DELETE SET NULL;
```

## Centroid Calculation

Accuracy-weighted centroid (inverse-accuracy weighting):

```sql
centroid_lat = SUM(lat_i / GREATEST(accuracy_i, 1)) / SUM(1 / GREATEST(accuracy_i, 1))
centroid_lng = SUM(lng_i / GREATEST(accuracy_i, 1)) / SUM(1 / GREATEST(accuracy_i, 1))
centroid_accuracy = 1 / SQRT(SUM(1 / GREATEST(accuracy_i^2, 1)))
```

Points with lower accuracy (better GPS) contribute more to the centroid. GREATEST(accuracy, 1) prevents division by zero.

## detect_trips Modifications

### Cluster lifecycle within the existing state machine:

1. **Stationary detected (speed < threshold):** Accumulate point into current cluster arrays (lat[], lng[], accuracy[], timestamps)
2. **3-min threshold reached:** Create `stationary_clusters` row, set `gps_points.stationary_cluster_id` for accumulated points, create trip with cluster centroid as endpoint
3. **Still stationary after trip created:** Continue adding points to cluster, update centroid/ended_at
4. **Movement resumes or shift ends:** Finalize cluster (UPDATE centroid, ended_at, duration, point_count). The next trip start uses this cluster's centroid.

### Key: Two-pass approach

- **Pass 1 (existing):** detect_trips creates trips and clusters, using the centroid of points accumulated so far
- **Pass 2 (new, at end of function):** For each cluster, recalculate final centroid with ALL its points and UPDATE trip endpoints. This handles the case where points arrive after the trip was created.

Actually, simpler: since detect_trips already processes ALL points in one pass, by the time a cluster is finalized (movement resumes), all its points are known. The centroid can be calculated at finalization time and the trip endpoint updated in the same pass.

### Variable tracking:

```
v_cluster_lats DECIMAL[] := '{}';
v_cluster_lngs DECIMAL[] := '{}';
v_cluster_accs DECIMAL[] := '{}';
v_cluster_point_ids UUID[] := '{}';
v_cluster_started_at TIMESTAMPTZ := NULL;
v_cluster_id UUID := NULL;
```

### Centroid replaces endpoint:

When trip is created:
- `start_latitude/longitude` = centroid of the pre-trip stationary cluster
- `end_latitude/longitude` = centroid of the post-trip stationary cluster (updated when movement resumes)
- `start_cluster_id` / `end_cluster_id` = FK to the cluster

## Dashboard: "Arrets" Tab in /dashboard/mileage

### RPC: `get_stationary_clusters`

```sql
get_stationary_clusters(
    p_employee_id UUID DEFAULT NULL,
    p_date_from DATE DEFAULT NULL,
    p_date_to DATE DEFAULT NULL,
    p_min_duration_seconds INTEGER DEFAULT 180
)
```

Returns: clusters with employee name, matched location name, duration, point count.

### UI Components:

1. **Filter bar:** Employee picker, date range, min duration slider
2. **Map view:** Google Maps showing all clusters as circle markers (radius = centroid_accuracy). Color-coded by match status (green = matched, amber = unmatched). Click to see details.
3. **List view:** Table with employee, location, duration, point count, centroid accuracy. Sortable.
4. **Detail popup:** Shows individual GPS points in the cluster, the centroid, nearby locations with their geofences.

## Impact on Existing Functions

| Function | Change |
|----------|--------|
| `detect_trips` | Create clusters, compute centroids, link to trips |
| `match_trip_to_location` | No change (already uses trip lat/lng + accuracy) |
| `rematch_trips_near_location` | No change (uses trip start/end_latitude/longitude) |
| `rematch_trips_for_updated_location` | No change (same) |
| `get_unmatched_trip_clusters` | No change (clusters from this RPC are trip-endpoint clusters, different concept) |
| `rematch_all_trip_locations` | No change |

## Files Modified

| File | Change |
|------|--------|
| `supabase/migrations/059_stationary_clusters.sql` | New table, columns, indexes |
| `supabase/migrations/060_detect_trips_with_clusters.sql` | Updated detect_trips with cluster logic |
| `supabase/migrations/061_get_stationary_clusters_rpc.sql` | New RPC for dashboard |
| `dashboard/src/app/dashboard/mileage/page.tsx` | Add "Arrets" tab |
| `dashboard/src/components/mileage/stationary-clusters-tab.tsx` | New tab component |
| `dashboard/src/components/mileage/stationary-clusters-map.tsx` | New map component |
