# Suggested Locations from Stationary Clusters — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace suggested locations RPCs to source from `stationary_clusters` instead of raw trip endpoints, using accuracy-weighted centroids.

**Architecture:** New migration (063) replaces `get_unmatched_trip_clusters` and `get_cluster_occurrences` RPCs to query `stationary_clusters WHERE matched_location_id IS NULL`. Dashboard components adapt to new fields. Group-level ignore via existing `ignored_location_clusters` table; per-occurrence ignore removed (no longer applicable since occurrences are clusters, not trip endpoints).

**Tech Stack:** PostgreSQL/PostGIS (Supabase), TypeScript/Next.js, @vis.gl/react-google-maps

---

### Task 1: Migration 063 — Replace `get_unmatched_trip_clusters` RPC

**Files:**
- Create: `supabase/migrations/063_suggested_locations_from_clusters.sql`

**Reference:** Current version at `supabase/migrations/056_ignore_individual_endpoints.sql:51-152`

**Step 1: Write the migration**

```sql
-- =============================================================================
-- 063: Rewrite suggested locations RPCs to source from stationary_clusters
-- =============================================================================
-- Replaces get_unmatched_trip_clusters() and get_cluster_occurrences() to use
-- stationary_clusters table instead of raw trip endpoints. Centroids are now
-- accuracy-weighted means of already-weighted cluster centroids.
-- =============================================================================

-- 1. Replace get_unmatched_trip_clusters
CREATE OR REPLACE FUNCTION get_unmatched_trip_clusters(
    p_min_occurrences INTEGER DEFAULT 1
)
RETURNS TABLE (
    cluster_id INTEGER,
    centroid_latitude DOUBLE PRECISION,
    centroid_longitude DOUBLE PRECISION,
    occurrence_count BIGINT,
    employee_names TEXT[],
    first_seen TIMESTAMPTZ,
    last_seen TIMESTAMPTZ,
    total_duration_seconds BIGINT,
    avg_accuracy DOUBLE PRECISION
) AS $$
BEGIN
    RETURN QUERY
    WITH unmatched AS (
        SELECT
            sc.id,
            sc.centroid_latitude AS lat,
            sc.centroid_longitude AS lng,
            sc.centroid_accuracy AS acc,
            sc.employee_id,
            sc.started_at,
            sc.duration_seconds
        FROM stationary_clusters sc
        WHERE sc.matched_location_id IS NULL
    ),
    clustered AS (
        SELECT
            u.*,
            ST_ClusterDBSCAN(
                ST_SetSRID(ST_MakePoint(u.lng, u.lat), 4326)::geometry,
                eps := 0.001,
                minpoints := 1
            ) OVER () AS cid
        FROM unmatched u
    ),
    aggregated AS (
        SELECT
            c.cid,
            -- Accuracy-weighted centroid of centroids
            (SUM(c.lat::DOUBLE PRECISION / GREATEST(c.acc::DOUBLE PRECISION, 0.1))
             / SUM(1.0 / GREATEST(c.acc::DOUBLE PRECISION, 0.1))) AS centroid_lat,
            (SUM(c.lng::DOUBLE PRECISION / GREATEST(c.acc::DOUBLE PRECISION, 0.1))
             / SUM(1.0 / GREATEST(c.acc::DOUBLE PRECISION, 0.1))) AS centroid_lng,
            COUNT(*) AS cnt,
            ARRAY_AGG(DISTINCT ep.full_name) FILTER (WHERE ep.full_name IS NOT NULL) AS emp_names,
            MIN(c.started_at) AS first_at,
            MAX(c.started_at) AS last_at,
            SUM(c.duration_seconds)::BIGINT AS total_dur,
            AVG(c.acc::DOUBLE PRECISION) AS avg_acc
        FROM clustered c
        LEFT JOIN employee_profiles ep ON ep.id = c.employee_id
        WHERE c.cid IS NOT NULL
        GROUP BY c.cid
        HAVING COUNT(*) >= p_min_occurrences
    )
    SELECT
        a.cid::INTEGER,
        a.centroid_lat,
        a.centroid_lng,
        a.cnt,
        a.emp_names,
        a.first_at,
        a.last_at,
        a.total_dur,
        a.avg_acc
    FROM aggregated a
    WHERE NOT EXISTS (
        SELECT 1
        FROM ignored_location_clusters ic
        WHERE ST_DWithin(
            ST_SetSRID(ST_MakePoint(a.centroid_lng, a.centroid_lat), 4326)::geography,
            ST_SetSRID(ST_MakePoint(ic.centroid_longitude, ic.centroid_latitude), 4326)::geography,
            150
        )
        AND a.cnt <= ic.occurrence_count_at_ignore
    )
    ORDER BY a.cnt DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. Replace get_cluster_occurrences
CREATE OR REPLACE FUNCTION get_cluster_occurrences(
    p_centroid_lat DOUBLE PRECISION,
    p_centroid_lng DOUBLE PRECISION,
    p_radius_meters DOUBLE PRECISION DEFAULT 150
)
RETURNS TABLE (
    cluster_id UUID,
    employee_name TEXT,
    centroid_latitude DOUBLE PRECISION,
    centroid_longitude DOUBLE PRECISION,
    centroid_accuracy DOUBLE PRECISION,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    duration_seconds INTEGER,
    gps_point_count INTEGER,
    shift_id UUID
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        sc.id AS cluster_id,
        ep.full_name::TEXT AS employee_name,
        sc.centroid_latitude::DOUBLE PRECISION,
        sc.centroid_longitude::DOUBLE PRECISION,
        sc.centroid_accuracy::DOUBLE PRECISION,
        sc.started_at,
        sc.ended_at,
        sc.duration_seconds,
        sc.gps_point_count,
        sc.shift_id
    FROM stationary_clusters sc
    JOIN employee_profiles ep ON ep.id = sc.employee_id
    WHERE sc.matched_location_id IS NULL
      AND ST_DWithin(
          ST_SetSRID(ST_MakePoint(sc.centroid_longitude, sc.centroid_latitude), 4326)::geography,
          ST_SetSRID(ST_MakePoint(p_centroid_lng, p_centroid_lat), 4326)::geography,
          p_radius_meters
      )
    ORDER BY sc.started_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

**Step 2: Apply migration to Supabase**

Apply via Supabase MCP `apply_migration` or `execute_sql`. Verify with:

```sql
SELECT * FROM get_unmatched_trip_clusters(1) LIMIT 5;
SELECT * FROM get_cluster_occurrences(48.241, -79.028) LIMIT 5;
```

**Step 3: Commit**

```bash
git add supabase/migrations/063_suggested_locations_from_clusters.sql
git commit -m "feat: rewrite suggested locations RPCs to source from stationary_clusters"
```

---

### Task 2: Update `MapCluster` and `ClusterOccurrence` TypeScript interfaces

**Files:**
- Modify: `dashboard/src/components/locations/suggested-locations-map.tsx:21-45`

**Step 1: Replace interfaces**

Replace the `MapCluster` interface (lines 21-33) with:

```typescript
export interface MapCluster {
  cluster_id: number;
  centroid_latitude: number;
  centroid_longitude: number;
  occurrence_count: number;
  employee_names: string[];
  first_seen: string;
  last_seen: string;
  total_duration_seconds: number;
  avg_accuracy: number;
  google_address?: string | null;
  place_name?: string | null;
}
```

Changes: removed `has_start_endpoints`, `has_end_endpoints`. Added `total_duration_seconds`, `avg_accuracy`.

Replace the `ClusterOccurrence` interface (lines 35-45) with:

```typescript
export interface ClusterOccurrence {
  cluster_id: string;
  employee_name: string;
  centroid_latitude: number;
  centroid_longitude: number;
  centroid_accuracy: number | null;
  started_at: string;
  ended_at: string;
  duration_seconds: number;
  gps_point_count: number;
  shift_id: string;
}
```

Changes: replaced trip-centric fields (trip_id, endpoint_type, latitude/longitude, seen_at, address, gps_accuracy, stop_duration_minutes) with cluster fields.

**Step 2: Update `UnmatchedCluster` in tab**

Modify `dashboard/src/components/locations/suggested-locations-tab.tsx:26-28`.

Replace:
```typescript
interface UnmatchedCluster extends MapCluster {
  sample_addresses: string[];
}
```
With:
```typescript
type UnmatchedCluster = MapCluster;
```

The `sample_addresses` field is removed since we no longer source from trips.

**Step 3: Verify TypeScript compiles**

```bash
cd dashboard && npx tsc --noEmit 2>&1 | head -50
```

Expected: errors in components referencing old fields (we'll fix those in next tasks). Note the errors for Task 3 and 4.

**Step 4: Commit**

```bash
git add dashboard/src/components/locations/suggested-locations-map.tsx dashboard/src/components/locations/suggested-locations-tab.tsx
git commit -m "refactor: update TypeScript interfaces for cluster-based suggested locations"
```

---

### Task 3: Update `suggested-locations-tab.tsx` — data fetching, display, and ignore

**Files:**
- Modify: `dashboard/src/components/locations/suggested-locations-tab.tsx`

**Key changes:**

1. **Remove `enrichClusters` dependency on `sample_addresses`** (lines 41-102): The Google reverse geocode still works — it uses `centroid_latitude/longitude` which remain the same. Remove any reference to `sample_addresses` in the address fallback logic.

2. **Update cluster card display** (lines 233-315):
   - Remove "Départ"/"Arrivée" badges (referenced `has_start_endpoints`/`has_end_endpoints`)
   - Add total duration display: format `total_duration_seconds` as "Xh Ymin"
   - Add average accuracy display: `avg_accuracy` formatted as "~Xm"
   - Update address fallback: remove `sample_addresses[0]` fallback, keep `google_address` or coords

3. **Update ignore handler** (lines 152-171):
   - Change from `ignore_trip_endpoint(trip_id, endpoint_type)` to `ignore_location_cluster(centroid_lat, centroid_lng, occurrence_count)` (existing RPC from migration 053)
   - The ignore now applies to the whole suggested location group, not individual occurrences
   - Remove per-occurrence ignore; keep group-level "Ignorer" button on the cluster card
   - After ignore: remove the cluster from the list (no decrement logic needed)

4. **Remove `onIgnoreOccurrence` callback** passed to map — the map no longer has per-occurrence ignore buttons

5. **Helper function**: Add `formatDuration(seconds: number): string` if not already present (same as in stationary-clusters-tab.tsx)

**Step 1: Implement all changes described above**

**Step 2: Verify TypeScript compiles**

```bash
cd dashboard && npx tsc --noEmit 2>&1 | head -50
```

**Step 3: Commit**

```bash
git add dashboard/src/components/locations/suggested-locations-tab.tsx
git commit -m "feat: update suggested locations tab for cluster-based data source"
```

---

### Task 4: Update `suggested-locations-map.tsx` — markers, InfoWindow, occurrences

**Files:**
- Modify: `dashboard/src/components/locations/suggested-locations-map.tsx`

**Key changes:**

1. **Occurrence fetch** (lines 74-108): The RPC call `get_cluster_occurrences` already matches the new signature (same param names). The returned data shape changed — update the state variable type.

2. **InfoWindow display** (lines 227-375):
   - Remove "Départ"/"Arrivée" badges from occurrence display
   - Show: employee name, date range (`started_at` — `ended_at`), duration (`duration_seconds`), GPS point count, centroid accuracy
   - Update coordinates display: use `centroid_latitude`/`centroid_longitude` instead of `latitude`/`longitude`

3. **Accuracy circle** (lines 199-202, 439-455):
   - Use `centroid_accuracy` instead of `gps_accuracy`
   - Position at `centroid_latitude`/`centroid_longitude`

4. **Remove per-occurrence ignore button** from InfoWindow (lines 351-371). The ignore is now group-level only (handled in tab).

5. **Remove `onIgnoreOccurrence` prop** from component interface.

6. **Occurrence navigation** (lines 306-326): Still works — just cycling through stationary clusters instead of trip endpoints.

**Step 1: Implement all changes described above**

**Step 2: Verify TypeScript compiles with zero errors**

```bash
cd dashboard && npx tsc --noEmit 2>&1 | head -50
```

Expected: 0 errors.

**Step 3: Commit**

```bash
git add dashboard/src/components/locations/suggested-locations-map.tsx
git commit -m "feat: update suggested locations map for cluster-based occurrences"
```

---

### Task 5: Push and deploy

Use the `/push` skill to:
1. Apply migration 063 to Supabase (register via `supabase migration repair --status applied 063`)
2. Commit any remaining changes
3. Push to origin
4. Deploy to Vercel

**Verification:**
1. Open dashboard → Emplacements → Suggérés tab
2. Verify suggested locations appear with occurrence counts
3. Click a suggested location → verify drill-down shows individual stationary clusters (duration, GPS points, accuracy)
4. Verify map markers display correctly with accuracy circles
5. Verify "Créer" button works (prefills location form with centroid)
6. Verify "Ignorer" button works (removes group from list)
