# Stationary Clusters Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace single-point trip endpoints with accuracy-weighted centroids of stationary GPS clusters, and expose clusters as first-class entities for visualization in a new "Arrêts" dashboard tab.

**Architecture:** Stationary clusters are detected within `detect_trips` as contiguous sequences of stopped GPS points. Each cluster stores an accuracy-weighted centroid. Trip start/end coordinates use their linked cluster centroids. A new RPC + dashboard tab visualizes all clusters.

**Tech Stack:** PostgreSQL/PostGIS (Supabase), Next.js 14+ (App Router), Google Maps API (`@vis.gl/react-google-maps`), shadcn/ui

---

## Task 1: Database Migration — Schema

**Files:**
- Create: `supabase/migrations/060_stationary_clusters.sql`

**Step 1: Write the migration**

```sql
-- =============================================================================
-- 060: Stationary Clusters — schema (table, columns, indexes)
-- =============================================================================

-- 1. New table: stationary_clusters
CREATE TABLE stationary_clusters (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    shift_id UUID NOT NULL REFERENCES shifts(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
    centroid_latitude DECIMAL(10, 8) NOT NULL,
    centroid_longitude DECIMAL(11, 8) NOT NULL,
    centroid_accuracy DECIMAL(6, 2),
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ NOT NULL,
    duration_seconds INTEGER NOT NULL,
    gps_point_count INTEGER NOT NULL DEFAULT 0,
    matched_location_id UUID REFERENCES locations(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_stationary_clusters_shift ON stationary_clusters(shift_id);
CREATE INDEX idx_stationary_clusters_employee_time ON stationary_clusters(employee_id, started_at DESC);
CREATE INDEX idx_stationary_clusters_location ON stationary_clusters(matched_location_id)
    WHERE matched_location_id IS NOT NULL;

-- 2. New column on gps_points
ALTER TABLE gps_points ADD COLUMN stationary_cluster_id UUID
    REFERENCES stationary_clusters(id) ON DELETE SET NULL;
CREATE INDEX idx_gps_points_cluster ON gps_points(stationary_cluster_id)
    WHERE stationary_cluster_id IS NOT NULL;

-- 3. New columns on trips
ALTER TABLE trips ADD COLUMN start_cluster_id UUID
    REFERENCES stationary_clusters(id) ON DELETE SET NULL;
ALTER TABLE trips ADD COLUMN end_cluster_id UUID
    REFERENCES stationary_clusters(id) ON DELETE SET NULL;

-- 4. RLS: admin/super_admin SELECT on stationary_clusters
ALTER TABLE stationary_clusters ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can view stationary clusters"
    ON stationary_clusters FOR SELECT
    USING (is_admin_or_super_admin(auth.uid()));

CREATE POLICY "Employees can view own clusters"
    ON stationary_clusters FOR SELECT
    USING (employee_id = (
        SELECT id FROM employee_profiles WHERE user_id = auth.uid()
    ));

-- Full access for service role (detect_trips runs as SECURITY DEFINER)
CREATE POLICY "Service role full access"
    ON stationary_clusters FOR ALL
    USING (auth.role() = 'service_role');
```

**Step 2: Apply migration**

Run via Supabase MCP `apply_migration` with name `stationary_clusters` and the SQL above.

**Step 3: Verify**

```sql
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'stationary_clusters' ORDER BY ordinal_position;
```

Also verify `gps_points.stationary_cluster_id` and `trips.start_cluster_id`/`end_cluster_id` exist.

**Step 4: Commit**

```bash
git add supabase/migrations/060_stationary_clusters.sql
git commit -m "feat: add stationary_clusters table + FK columns on gps_points and trips"
```

---

## Task 2: Update `detect_trips` with Cluster Logic

**Files:**
- Modify: `supabase/migrations/057_fix_trip_endpoint_at_stop.sql` (canonical source — full replacement)
- Create: `supabase/migrations/061_detect_trips_with_clusters.sql` (migration to deploy)

This is the most complex task. The existing `detect_trips` function must be extended to:
1. Accumulate stationary GPS points into cluster arrays
2. Create `stationary_clusters` rows when a stop is confirmed (3-min threshold)
3. Continue accumulating points into the cluster while stationary
4. Compute accuracy-weighted centroid when cluster is finalized
5. Use centroid as trip start/end coordinates
6. Link trips to clusters via `start_cluster_id` / `end_cluster_id`

**Step 1: Add cluster tracking variables**

Add these variables after the existing declarations in `detect_trips`:

```sql
-- Cluster tracking
v_cluster_lats DECIMAL[] := '{}';
v_cluster_lngs DECIMAL[] := '{}';
v_cluster_accs DECIMAL[] := '{}';
v_cluster_point_ids UUID[] := '{}';
v_cluster_started_at TIMESTAMPTZ := NULL;
v_cluster_id UUID := NULL;
v_has_active_cluster BOOLEAN := FALSE;
v_centroid_lat DOUBLE PRECISION;
v_centroid_lng DOUBLE PRECISION;
v_centroid_acc DOUBLE PRECISION;
v_prev_cluster_id UUID := NULL;  -- cluster before current trip (for trip start)
```

**Step 2: Add cluster helper — centroid calculation**

Add a helper block or inline the calculation. The formula (accuracy-weighted centroid):

```sql
-- Calculate centroid from arrays
SELECT
    SUM(lat / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
    SUM(lng / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
    1.0 / SQRT(SUM(1.0 / GREATEST(acc * acc, 1)))
INTO v_centroid_lat, v_centroid_lng, v_centroid_acc
FROM unnest(v_cluster_lats, v_cluster_lngs, v_cluster_accs) AS t(lat, lng, acc);
```

**Step 3: Accumulate points when stopped**

In the existing stationary detection block (when `v_point_is_stopped` is TRUE), add point to cluster arrays:

```sql
-- Accumulate into cluster
v_cluster_lats := v_cluster_lats || v_point.latitude;
v_cluster_lngs := v_cluster_lngs || v_point.longitude;
v_cluster_accs := v_cluster_accs || COALESCE(v_point.accuracy, 20.0);
v_cluster_point_ids := v_cluster_point_ids || v_point.id;
IF v_cluster_started_at IS NULL THEN
    v_cluster_started_at := v_point.recorded_at;
END IF;
```

This goes in two places:
- **Pre-trip stationary** (when `NOT v_in_trip AND v_point_is_stopped`): lines ~161-169 area
- **In-trip stationary** (when `v_in_trip AND v_point_is_stopped`): lines ~319+ area

**Step 4: Create cluster when 3-min threshold reached**

When the stationary timeout is confirmed (existing line ~335 where `v_stationary_duration >= v_stationary_gap_minutes`), before creating the trip:

```sql
-- Create or finalize cluster
IF NOT v_has_active_cluster AND array_length(v_cluster_lats, 1) >= 1 THEN
    -- Compute centroid
    SELECT
        SUM(lat / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
        SUM(lng / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
        1.0 / SQRT(SUM(1.0 / GREATEST(acc * acc, 1)))
    INTO v_centroid_lat, v_centroid_lng, v_centroid_acc
    FROM unnest(v_cluster_lats, v_cluster_lngs, v_cluster_accs) AS t(lat, lng, acc);

    INSERT INTO stationary_clusters (
        shift_id, employee_id,
        centroid_latitude, centroid_longitude, centroid_accuracy,
        started_at, ended_at, duration_seconds, gps_point_count
    ) VALUES (
        p_shift_id, v_employee_id,
        v_centroid_lat, v_centroid_lng, v_centroid_acc,
        v_cluster_started_at, v_point.recorded_at,
        EXTRACT(EPOCH FROM (v_point.recorded_at - v_cluster_started_at))::INTEGER,
        array_length(v_cluster_point_ids, 1)
    )
    RETURNING id INTO v_cluster_id;

    v_has_active_cluster := TRUE;

    -- Tag GPS points with cluster ID
    UPDATE gps_points SET stationary_cluster_id = v_cluster_id
    WHERE id = ANY(v_cluster_point_ids);
END IF;
```

**Step 5: Update trip creation to use centroid and link cluster**

Where trips are INSERTed, use centroid coordinates and set cluster FKs:

For the trip end (current stop cluster):
```sql
-- Use cluster centroid for trip end if cluster exists
v_trip_end_lat := CASE WHEN v_has_active_cluster THEN v_centroid_lat
                       ELSE v_trip_end_point.latitude END;
v_trip_end_lng := CASE WHEN v_has_active_cluster THEN v_centroid_lng
                       ELSE v_trip_end_point.longitude END;
```

For the trip start (previous cluster before movement):
```sql
-- Use previous cluster centroid for trip start if it exists
-- v_prev_cluster_id is set when movement resumes after a cluster
```

After trip INSERT, UPDATE to set cluster IDs:
```sql
UPDATE trips SET
    start_cluster_id = v_prev_cluster_id,
    end_cluster_id = CASE WHEN v_has_active_cluster THEN v_cluster_id ELSE NULL END
WHERE id = v_trip_id;
```

**Step 6: Finalize cluster when movement resumes**

When movement is detected and `v_has_active_cluster` is TRUE:

```sql
-- Finalize current cluster: recompute centroid with ALL points
IF v_has_active_cluster THEN
    SELECT
        SUM(lat / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
        SUM(lng / GREATEST(acc, 1)) / SUM(1 / GREATEST(acc, 1)),
        1.0 / SQRT(SUM(1.0 / GREATEST(acc * acc, 1)))
    INTO v_centroid_lat, v_centroid_lng, v_centroid_acc
    FROM unnest(v_cluster_lats, v_cluster_lngs, v_cluster_accs) AS t(lat, lng, acc);

    UPDATE stationary_clusters SET
        centroid_latitude = v_centroid_lat,
        centroid_longitude = v_centroid_lng,
        centroid_accuracy = v_centroid_acc,
        ended_at = v_cluster_lats_ended,  -- last point timestamp
        duration_seconds = EXTRACT(EPOCH FROM (v_last_cluster_time - v_cluster_started_at))::INTEGER,
        gps_point_count = array_length(v_cluster_point_ids, 1)
    WHERE id = v_cluster_id;

    -- Also update the trip endpoint that used this cluster
    UPDATE trips SET
        end_latitude = v_centroid_lat,
        end_longitude = v_centroid_lng
    WHERE end_cluster_id = v_cluster_id;

    -- Match cluster to location
    SELECT ml.id INTO v_cluster_id  -- reuse variable
    FROM locations ml
    WHERE ml.is_active = TRUE
      AND ST_DWithin(
          ST_SetSRID(ST_MakePoint(v_centroid_lng, v_centroid_lat), 4326)::geography,
          ml.location::geography,
          ml.radius_meters + COALESCE(v_centroid_acc, 0)
      )
    ORDER BY ST_Distance(
        ST_SetSRID(ST_MakePoint(v_centroid_lng, v_centroid_lat), 4326)::geography,
        ml.location::geography
    )
    LIMIT 1;

    -- Save for next trip start
    v_prev_cluster_id := v_cluster_id;
END IF;

-- Reset cluster state
v_cluster_lats := '{}';
v_cluster_lngs := '{}';
v_cluster_accs := '{}';
v_cluster_point_ids := '{}';
v_cluster_started_at := NULL;
v_cluster_id := NULL;
v_has_active_cluster := FALSE;
```

**Step 7: Handle pre-trip cluster (before first trip starts)**

Points accumulated while `NOT v_in_trip` need to be clustered too. When movement starts:
1. If `array_length(v_cluster_lats, 1) >= 1` and 3+ min of stopped time, create cluster
2. Set `v_prev_cluster_id` to this cluster
3. Use its centroid as trip start coordinates
4. Reset cluster arrays

**Step 8: Delete old data before re-detection**

At the top of `detect_trips`, add cleanup:

```sql
-- Delete existing clusters for this shift (they'll be recreated)
DELETE FROM stationary_clusters WHERE shift_id = p_shift_id;
```

This goes alongside the existing `DELETE FROM trip_gps_points` and `DELETE FROM trips` blocks.

**Step 9: Apply migration**

Create migration 061 with `CREATE OR REPLACE FUNCTION detect_trips(...)` containing all changes. Apply via Supabase MCP.

**Step 10: Commit**

```bash
git add supabase/migrations/061_detect_trips_with_clusters.sql
git commit -m "feat: detect_trips creates stationary clusters with accuracy-weighted centroids"
```

---

## Task 3: RPC — `get_stationary_clusters`

**Files:**
- Create: `supabase/migrations/062_get_stationary_clusters_rpc.sql`

**Step 1: Write the RPC**

```sql
-- =============================================================================
-- 062: get_stationary_clusters RPC for dashboard visualization
-- =============================================================================

CREATE OR REPLACE FUNCTION get_stationary_clusters(
    p_employee_id UUID DEFAULT NULL,
    p_date_from DATE DEFAULT NULL,
    p_date_to DATE DEFAULT NULL,
    p_min_duration_seconds INTEGER DEFAULT 180
)
RETURNS TABLE (
    id UUID,
    shift_id UUID,
    employee_id UUID,
    employee_name TEXT,
    centroid_latitude DECIMAL(10, 8),
    centroid_longitude DECIMAL(11, 8),
    centroid_accuracy DECIMAL(6, 2),
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    duration_seconds INTEGER,
    gps_point_count INTEGER,
    matched_location_id UUID,
    matched_location_name TEXT,
    created_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        sc.id,
        sc.shift_id,
        sc.employee_id,
        (ep.first_name || ' ' || ep.last_name)::TEXT AS employee_name,
        sc.centroid_latitude,
        sc.centroid_longitude,
        sc.centroid_accuracy,
        sc.started_at,
        sc.ended_at,
        sc.duration_seconds,
        sc.gps_point_count,
        sc.matched_location_id,
        l.name::TEXT AS matched_location_name,
        sc.created_at
    FROM stationary_clusters sc
    JOIN employee_profiles ep ON ep.id = sc.employee_id
    LEFT JOIN locations l ON l.id = sc.matched_location_id
    WHERE (p_employee_id IS NULL OR sc.employee_id = p_employee_id)
      AND (p_date_from IS NULL OR sc.started_at >= p_date_from::TIMESTAMPTZ)
      AND (p_date_to IS NULL OR sc.started_at < (p_date_to + INTERVAL '1 day')::TIMESTAMPTZ)
      AND sc.duration_seconds >= p_min_duration_seconds
    ORDER BY sc.started_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

**Step 2: Apply migration**

**Step 3: Verify**

```sql
SELECT * FROM get_stationary_clusters() LIMIT 5;
```

**Step 4: Commit**

```bash
git add supabase/migrations/062_get_stationary_clusters_rpc.sql
git commit -m "feat: add get_stationary_clusters RPC for dashboard"
```

---

## Task 4: Dashboard — Add "Arrêts" Tab to Mileage Page

**Files:**
- Modify: `dashboard/src/app/dashboard/mileage/page.tsx` — wrap existing content in Tabs, add "Arrêts" tab
- Create: `dashboard/src/components/mileage/stationary-clusters-tab.tsx` — new tab component
- Create: `dashboard/src/components/mileage/stationary-clusters-map.tsx` — Google Maps cluster visualization

### Sub-step 4a: Add Tabs to mileage page

The current mileage page has NO tabs. Wrap its content in a `<Tabs>` component (same pattern as `/dashboard/locations/page.tsx`):

```tsx
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs';
import { StationaryClustersTab } from '@/components/mileage/stationary-clusters-tab';

// Inside the component, add state:
const [activeTab, setActiveTab] = useState('trips');

// Wrap existing content:
<Tabs value={activeTab} onValueChange={setActiveTab}>
  <TabsList>
    <TabsTrigger value="trips">Trajets</TabsTrigger>
    <TabsTrigger value="clusters">
      <MapPin className="h-3.5 w-3.5 mr-1" />
      Arrêts
    </TabsTrigger>
  </TabsList>

  <TabsContent value="trips" className="space-y-6 mt-4">
    {/* ALL existing mileage page content goes here */}
  </TabsContent>

  <TabsContent value="clusters" className="mt-4">
    <StationaryClustersTab />
  </TabsContent>
</Tabs>
```

### Sub-step 4b: Create `StationaryClustersTab` component

**File:** `dashboard/src/components/mileage/stationary-clusters-tab.tsx`

Features:
- **Filter bar:** Employee picker (reuse existing employee list from supabase), date range inputs, min duration slider
- **Map view:** `StationaryClustersMap` showing all clusters
- **List view:** Table with employee, location name, duration, point count, centroid accuracy

Data fetching:
```tsx
const { data: clusters } = await supabaseClient.rpc('get_stationary_clusters', {
  p_employee_id: selectedEmployee || undefined,
  p_date_from: dateFrom || undefined,
  p_date_to: dateTo || undefined,
  p_min_duration_seconds: minDuration,
});
```

Table columns:
- Employé (employee_name)
- Emplacement (matched_location_name or "Non associé")
- Début (started_at formatted)
- Durée (duration_seconds formatted as Xh Xm)
- Points GPS (gps_point_count)
- Précision centroïde (centroid_accuracy + "m")

Color-code rows: green if `matched_location_id` is set, amber if null.

### Sub-step 4c: Create `StationaryClustersMap` component

**File:** `dashboard/src/components/mileage/stationary-clusters-map.tsx`

Use the same `@vis.gl/react-google-maps` pattern as `google-trip-route-map.tsx`:

```tsx
import { APIProvider, Map, AdvancedMarker, InfoWindow } from '@vis.gl/react-google-maps';
```

Each cluster renders as:
- A circle marker at (centroid_latitude, centroid_longitude)
- Circle radius = centroid_accuracy (in meters) — use `google.maps.Circle`
- Color: green (#22c55e) if matched, amber (#f59e0b) if unmatched
- Click opens InfoWindow with: employee name, location name, duration, point count, start/end time

Map auto-fits bounds to show all visible clusters.

### Sub-step 4d: Commit

```bash
git add dashboard/src/app/dashboard/mileage/page.tsx
git add dashboard/src/components/mileage/stationary-clusters-tab.tsx
git add dashboard/src/components/mileage/stationary-clusters-map.tsx
git commit -m "feat: add Arrêts tab to mileage page with cluster map visualization"
```

---

## Task 5: Backfill — Re-run `detect_trips` on All Completed Shifts

After deploying all migrations, re-run trip detection to populate clusters for historical data.

**Step 1: Re-run detect_trips**

```sql
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT id FROM shifts
        WHERE status = 'completed'
        ORDER BY clocked_in_at DESC
    LOOP
        PERFORM detect_trips(r.id);
    END LOOP;
END $$;
```

**Step 2: Re-run location matching**

```sql
SELECT * FROM rematch_all_trip_locations();
```

**Step 3: Verify cluster data**

```sql
SELECT COUNT(*) as total_clusters,
       COUNT(matched_location_id) as matched,
       AVG(gps_point_count) as avg_points,
       AVG(centroid_accuracy) as avg_accuracy
FROM stationary_clusters;
```

**Step 4: Verify the Kouma Baraka case**

Check the trip that originally motivated this feature — should now match "254-258_Cardinal-Begin-E":

```sql
SELECT t.id, t.end_latitude, t.end_longitude,
       sc.centroid_latitude, sc.centroid_longitude, sc.centroid_accuracy,
       sc.gps_point_count,
       l.name as end_location
FROM trips t
LEFT JOIN stationary_clusters sc ON sc.id = t.end_cluster_id
LEFT JOIN locations l ON l.id = t.end_location_id
WHERE t.shift_id IN (
    SELECT s.id FROM shifts s
    JOIN employee_profiles ep ON ep.id = s.employee_id
    WHERE ep.first_name = 'Kouma' AND ep.last_name = 'Baraka'
      AND s.clocked_in_at::date = '2026-02-27'
)
AND t.started_at::time BETWEEN '12:15' AND '12:20';
```

---

## Task 6: Push & Deploy

Use the `/push` skill to:
1. Apply pending migrations (060, 061, 062) via `supabase db push --linked`
2. Commit all changes
3. Push to remote
4. Deploy to Vercel

---

## Summary of Files

| File | Action |
|------|--------|
| `supabase/migrations/060_stationary_clusters.sql` | New: table + columns + indexes + RLS |
| `supabase/migrations/061_detect_trips_with_clusters.sql` | New: updated detect_trips with cluster logic |
| `supabase/migrations/062_get_stationary_clusters_rpc.sql` | New: RPC for dashboard |
| `dashboard/src/app/dashboard/mileage/page.tsx` | Modify: wrap in Tabs, add "Arrêts" tab |
| `dashboard/src/components/mileage/stationary-clusters-tab.tsx` | New: tab with filters + table |
| `dashboard/src/components/mileage/stationary-clusters-map.tsx` | New: Google Maps cluster visualization |
