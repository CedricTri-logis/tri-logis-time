# Trip-to-Location Matching Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Match trip origins/destinations to known locations via PostGIS spatial queries, cluster unmatched endpoints for admin review, and provide inline location correction in the mileage dashboard.

**Architecture:** In-database matching via PostGIS `ST_DWithin` inside `detect_trips()`, with GPS accuracy tolerance. Unmatched endpoints clustered via `ST_ClusterDBSCAN`. Dashboard shows location names in route column with inline correction dropdown. New "Suggested" tab on locations page shows clustered unknown stops with Google Maps reverse geocoding suggestions.

**Tech Stack:** PostgreSQL/PostGIS (Supabase), Next.js 14+ dashboard, Google Maps Geocoding API (client-side), shadcn/ui

**Design doc:** `docs/plans/2026-02-26-trip-location-matching-design.md`

---

## Task 1: Migration — Add match method columns and helper function

**Files:**
- Create: `supabase/migrations/050_trip_location_matching.sql`

**Step 1: Write the migration SQL**

```sql
-- =============================================================================
-- 050: Trip-to-Location Matching
-- Feature: Match trip start/end to known locations using PostGIS spatial queries
-- =============================================================================

-- 1. Add location match method columns to trips
ALTER TABLE trips
  ADD COLUMN IF NOT EXISTS start_location_match_method TEXT DEFAULT 'auto'
    CHECK (start_location_match_method IN ('auto', 'manual')),
  ADD COLUMN IF NOT EXISTS end_location_match_method TEXT DEFAULT 'auto'
    CHECK (end_location_match_method IN ('auto', 'manual'));

-- 2. Update FK constraints to SET NULL on location delete
-- (current FKs have no ON DELETE action, default is RESTRICT)
ALTER TABLE trips DROP CONSTRAINT IF EXISTS trips_start_location_id_fkey;
ALTER TABLE trips DROP CONSTRAINT IF EXISTS trips_end_location_id_fkey;
ALTER TABLE trips
  ADD CONSTRAINT trips_start_location_id_fkey
    FOREIGN KEY (start_location_id) REFERENCES locations(id) ON DELETE SET NULL,
  ADD CONSTRAINT trips_end_location_id_fkey
    FOREIGN KEY (end_location_id) REFERENCES locations(id) ON DELETE SET NULL;

-- 3. Index for faster location matching queries
CREATE INDEX IF NOT EXISTS idx_trips_start_location_id ON trips(start_location_id);
CREATE INDEX IF NOT EXISTS idx_trips_end_location_id ON trips(end_location_id);
```

**Step 2: Write `match_trip_to_location()` helper function**

This is a reusable SECURITY DEFINER function that finds the closest matching location for a given GPS coordinate + accuracy.

```sql
-- 4. Helper: find closest matching location for a GPS point
CREATE OR REPLACE FUNCTION match_trip_to_location(
    p_latitude DECIMAL,
    p_longitude DECIMAL,
    p_accuracy_meters DECIMAL DEFAULT 0
)
RETURNS UUID AS $$
DECLARE
    v_location_id UUID;
BEGIN
    -- Find closest active location whose geofence (radius + GPS accuracy) contains this point
    -- Uses PostGIS ST_DWithin on geography type for meter-based distance
    SELECT l.id INTO v_location_id
    FROM locations l
    WHERE l.is_active = TRUE
      AND ST_DWithin(
          l.location,
          ST_SetSRID(ST_MakePoint(p_longitude, p_latitude), 4326)::geography,
          l.radius_meters + COALESCE(p_accuracy_meters, 0)
      )
    ORDER BY ST_Distance(
        l.location,
        ST_SetSRID(ST_MakePoint(p_longitude, p_latitude), 4326)::geography
    ) ASC
    LIMIT 1;

    RETURN v_location_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
```

**Step 3: Apply migration**

Run: `cd supabase && supabase db push` or apply via Supabase MCP tool.

**Step 4: Verify migration**

Run SQL to confirm columns exist and function is created:
```sql
SELECT column_name FROM information_schema.columns
WHERE table_name = 'trips' AND column_name LIKE '%match_method';
-- Expected: start_location_match_method, end_location_match_method

SELECT match_trip_to_location(45.5017, -73.5673, 10);
-- Expected: NULL (or a UUID if a location exists near Montreal)
```

**Step 5: Commit**

```bash
git add supabase/migrations/050_trip_location_matching.sql
git commit -m "feat: add trip location match method columns and helper function"
```

---

## Task 2: Migration — Update `detect_trips()` to populate location IDs

**Files:**
- Modify: `supabase/migrations/050_trip_location_matching.sql` (append to same migration)

**Context:** The current `detect_trips()` in migration 048 has 3 INSERT INTO trips statements (lines 286, 423, 509). Each one needs a post-INSERT step to call `match_trip_to_location()` and update the trip's location IDs. The GPS cursor (line 209-221) already includes `gp.accuracy`.

**Step 1: Write the updated `detect_trips()` function**

The key changes to `detect_trips()` are:
1. Add variable `v_prev_trip_end_location_id UUID` to track trip continuity
2. After each successful INSERT + transport mode validation, call `match_trip_to_location()` for start and end
3. For trip continuity: if start point is within 100m of previous trip's end, inherit the location

Add this to the migration file. The full function is a `CREATE OR REPLACE FUNCTION detect_trips(...)` that copies from migration 048 with modifications.

The modifications are applied after each successful `UPDATE trips SET transport_mode = ...` block (3 places):

```sql
-- After: UPDATE trips SET transport_mode = v_transport_mode WHERE id = v_trip_id;
-- Add location matching:
UPDATE trips SET
    start_location_id = CASE
        WHEN v_prev_trip_end_location_id IS NOT NULL
             AND haversine_km(
                 v_trip_start_point.latitude, v_trip_start_point.longitude,
                 v_prev_trip_end_lat, v_prev_trip_end_lng
             ) * 1000.0 < 100
        THEN v_prev_trip_end_location_id
        ELSE match_trip_to_location(
            v_trip_start_point.latitude,
            v_trip_start_point.longitude,
            COALESCE(v_trip_start_point.accuracy, 0)
        )
    END,
    end_location_id = match_trip_to_location(
        v_trip_end_point.latitude,
        v_trip_end_point.longitude,
        COALESCE(v_trip_end_point.accuracy, 0)
    )
WHERE id = v_trip_id;

-- Track for next trip's continuity
SELECT end_location_id INTO v_prev_trip_end_location_id FROM trips WHERE id = v_trip_id;
v_prev_trip_end_lat := v_trip_end_point.latitude;
v_prev_trip_end_lng := v_trip_end_point.longitude;
```

New variables to add to the function's DECLARE block:
```sql
v_prev_trip_end_location_id UUID := NULL;
v_prev_trip_end_lat DECIMAL;
v_prev_trip_end_lng DECIMAL;
```

**Important:** The implementer must copy the ENTIRE `detect_trips()` function from migration 048 and apply these changes at all 3 INSERT sites. Do NOT try to patch — CREATE OR REPLACE the full function.

**Step 2: Apply and verify**

Test with a known shift that has trips:
```sql
-- Find a shift with existing trips
SELECT id FROM shifts WHERE status = 'completed' LIMIT 1;
-- Run detect_trips on it (will re-detect)
SELECT * FROM detect_trips('<shift_id>');
-- Check if location IDs are populated
SELECT id, start_location_id, end_location_id FROM trips WHERE shift_id = '<shift_id>';
```

**Step 3: Commit**

```bash
git add supabase/migrations/050_trip_location_matching.sql
git commit -m "feat: populate start/end location IDs in detect_trips"
```

---

## Task 3: Migration — Admin override and rematch RPCs

**Files:**
- Modify: `supabase/migrations/050_trip_location_matching.sql` (append)

**Step 1: Write `update_trip_location()` RPC**

```sql
-- Admin: manually set a trip's start or end location
CREATE OR REPLACE FUNCTION update_trip_location(
    p_trip_id UUID,
    p_endpoint TEXT,  -- 'start' or 'end'
    p_location_id UUID  -- NULL to clear
)
RETURNS VOID AS $$
BEGIN
    IF p_endpoint NOT IN ('start', 'end') THEN
        RAISE EXCEPTION 'p_endpoint must be ''start'' or ''end''';
    END IF;

    IF p_endpoint = 'start' THEN
        UPDATE trips SET
            start_location_id = p_location_id,
            start_location_match_method = CASE WHEN p_location_id IS NULL THEN 'auto' ELSE 'manual' END,
            updated_at = NOW()
        WHERE id = p_trip_id;
    ELSE
        UPDATE trips SET
            end_location_id = p_location_id,
            end_location_match_method = CASE WHEN p_location_id IS NULL THEN 'auto' ELSE 'manual' END,
            updated_at = NOW()
        WHERE id = p_trip_id;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

**Step 2: Write `rematch_all_trip_locations()` RPC**

```sql
-- Batch re-match all trips to locations (skips manual overrides)
CREATE OR REPLACE FUNCTION rematch_all_trip_locations()
RETURNS TABLE (
    matched_count INTEGER,
    skipped_manual INTEGER,
    total_processed INTEGER
) AS $$
DECLARE
    v_matched INTEGER := 0;
    v_skipped INTEGER := 0;
    v_total INTEGER := 0;
    v_trip RECORD;
    v_start_loc UUID;
    v_end_loc UUID;
BEGIN
    FOR v_trip IN
        SELECT t.id, t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude,
               t.start_location_match_method, t.end_location_match_method,
               gp_start.accuracy AS start_accuracy, gp_end.accuracy AS end_accuracy
        FROM trips t
        -- Get accuracy from the first and last GPS points of the trip
        LEFT JOIN LATERAL (
            SELECT gp.accuracy FROM trip_gps_points tgp
            JOIN gps_points gp ON gp.id = tgp.gps_point_id
            WHERE tgp.trip_id = t.id ORDER BY tgp.sequence_order ASC LIMIT 1
        ) gp_start ON TRUE
        LEFT JOIN LATERAL (
            SELECT gp.accuracy FROM trip_gps_points tgp
            JOIN gps_points gp ON gp.id = tgp.gps_point_id
            WHERE tgp.trip_id = t.id ORDER BY tgp.sequence_order DESC LIMIT 1
        ) gp_end ON TRUE
    LOOP
        v_total := v_total + 1;

        -- Match start (skip if manual)
        IF v_trip.start_location_match_method != 'manual' THEN
            v_start_loc := match_trip_to_location(
                v_trip.start_latitude, v_trip.start_longitude,
                COALESCE(v_trip.start_accuracy, 0)
            );
            UPDATE trips SET start_location_id = v_start_loc WHERE id = v_trip.id;
            IF v_start_loc IS NOT NULL THEN v_matched := v_matched + 1; END IF;
        ELSE
            v_skipped := v_skipped + 1;
        END IF;

        -- Match end (skip if manual)
        IF v_trip.end_location_match_method != 'manual' THEN
            v_end_loc := match_trip_to_location(
                v_trip.end_latitude, v_trip.end_longitude,
                COALESCE(v_trip.end_accuracy, 0)
            );
            UPDATE trips SET end_location_id = v_end_loc WHERE id = v_trip.id;
            IF v_end_loc IS NOT NULL THEN v_matched := v_matched + 1; END IF;
        ELSE
            v_skipped := v_skipped + 1;
        END IF;
    END LOOP;

    RETURN QUERY SELECT v_matched, v_skipped, v_total;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

**Step 3: Write `get_nearby_locations()` RPC (for inline dropdown)**

```sql
-- Get locations near a GPS point, sorted by distance (for inline dropdown)
CREATE OR REPLACE FUNCTION get_nearby_locations(
    p_latitude DECIMAL,
    p_longitude DECIMAL,
    p_limit INTEGER DEFAULT 10
)
RETURNS TABLE (
    id UUID,
    name TEXT,
    location_type TEXT,
    distance_meters DOUBLE PRECISION,
    radius_meters NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        l.id,
        l.name,
        l.location_type::TEXT,
        ST_Distance(
            l.location,
            ST_SetSRID(ST_MakePoint(p_longitude, p_latitude), 4326)::geography
        ) AS distance_meters,
        l.radius_meters
    FROM locations l
    WHERE l.is_active = TRUE
    ORDER BY distance_meters ASC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
```

**Step 4: Apply and verify**

```sql
-- Test update_trip_location
SELECT update_trip_location('<trip_id>', 'start', '<location_id>');
SELECT start_location_id, start_location_match_method FROM trips WHERE id = '<trip_id>';
-- Expected: location_id, 'manual'

-- Test get_nearby_locations
SELECT * FROM get_nearby_locations(45.5017, -73.5673, 5);
-- Expected: list of up to 5 locations with distances
```

**Step 5: Commit**

```bash
git add supabase/migrations/050_trip_location_matching.sql
git commit -m "feat: add update_trip_location, rematch, and get_nearby_locations RPCs"
```

---

## Task 4: Migration — Unmatched endpoint clustering RPC

**Files:**
- Modify: `supabase/migrations/050_trip_location_matching.sql` (append)

**Step 1: Write `get_unmatched_trip_clusters()` RPC**

```sql
-- Cluster unmatched trip endpoints for the "Suggested" tab
CREATE OR REPLACE FUNCTION get_unmatched_trip_clusters(
    p_min_occurrences INTEGER DEFAULT 1
)
RETURNS TABLE (
    cluster_id INTEGER,
    centroid_latitude DOUBLE PRECISION,
    centroid_longitude DOUBLE PRECISION,
    occurrence_count BIGINT,
    has_start_endpoints BOOLEAN,
    has_end_endpoints BOOLEAN,
    employee_names TEXT[],
    first_seen TIMESTAMPTZ,
    last_seen TIMESTAMPTZ,
    sample_addresses TEXT[]
) AS $$
BEGIN
    RETURN QUERY
    WITH unmatched_endpoints AS (
        -- Collect all unmatched start points
        SELECT
            t.start_latitude AS lat,
            t.start_longitude AS lng,
            'start'::TEXT AS endpoint_type,
            t.employee_id,
            t.started_at AS seen_at,
            t.start_address AS address
        FROM trips t
        WHERE t.start_location_id IS NULL

        UNION ALL

        -- Collect all unmatched end points
        SELECT
            t.end_latitude AS lat,
            t.end_longitude AS lng,
            'end'::TEXT AS endpoint_type,
            t.employee_id,
            t.ended_at AS seen_at,
            t.end_address AS address
        FROM trips t
        WHERE t.end_location_id IS NULL
    ),
    clustered AS (
        SELECT
            ue.*,
            ST_ClusterDBSCAN(
                ST_SetSRID(ST_MakePoint(ue.lng, ue.lat), 4326)::geometry,
                eps := 0.001,  -- ~100m in degrees at mid-latitudes
                minpoints := 1
            ) OVER () AS cid
        FROM unmatched_endpoints ue
    ),
    aggregated AS (
        SELECT
            c.cid,
            AVG(c.lat) AS centroid_lat,
            AVG(c.lng) AS centroid_lng,
            COUNT(*) AS cnt,
            BOOL_OR(c.endpoint_type = 'start') AS has_starts,
            BOOL_OR(c.endpoint_type = 'end') AS has_ends,
            ARRAY_AGG(DISTINCT ep.full_name) FILTER (WHERE ep.full_name IS NOT NULL) AS emp_names,
            MIN(c.seen_at) AS first_at,
            MAX(c.seen_at) AS last_at,
            ARRAY_AGG(DISTINCT c.address) FILTER (WHERE c.address IS NOT NULL) AS addrs
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
        a.has_starts,
        a.has_ends,
        a.emp_names,
        a.first_at,
        a.last_at,
        a.addrs
    FROM aggregated a
    ORDER BY a.cnt DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
```

**Note on eps value:** `ST_ClusterDBSCAN` uses the geometry's coordinate units. For SRID 4326, 0.001 degrees ~ 111m at equator, ~80m at 45°N (Quebec). This is a reasonable approximation. For higher precision, the implementer could cast to geography and use meters, but this adds complexity. The 0.001 value is a good starting point for Quebec/Mexico latitudes.

**Step 2: Apply and verify**

```sql
SELECT * FROM get_unmatched_trip_clusters(1);
-- Expected: clusters of unmatched endpoints with counts
```

**Step 3: Commit**

```bash
git add supabase/migrations/050_trip_location_matching.sql
git commit -m "feat: add unmatched trip endpoint clustering RPC"
```

---

## Task 5: Dashboard — Update Trip type and fetch locations with trips

**Files:**
- Modify: `dashboard/src/types/mileage.ts`
- Modify: `dashboard/src/app/dashboard/mileage/page.tsx`

**Step 1: Update Trip type**

In `dashboard/src/types/mileage.ts`, add the new match method fields:

```typescript
// After line 35 (transport_mode field), add:
  // Location match methods
  start_location_match_method: 'auto' | 'manual';
  end_location_match_method: 'auto' | 'manual';
```

**Step 2: Fetch location data alongside trips**

In `dashboard/src/app/dashboard/mileage/page.tsx`, modify `fetchTrips()` (lines 110-160) to also fetch location names for trips that have `start_location_id` or `end_location_id`.

After the employee merge (line 148-152), add a locations fetch:

```typescript
// 3. Fetch location names for all referenced location IDs
const locationIds = [
  ...new Set([
    ...tripsData.map((t: any) => t.start_location_id).filter(Boolean),
    ...tripsData.map((t: any) => t.end_location_id).filter(Boolean),
  ]),
];
const locationMap: Record<string, { id: string; name: string }> = {};

if (locationIds.length > 0) {
  const { data: locations } = await supabaseClient
    .from('locations')
    .select('id, name')
    .in('id', locationIds);

  if (locations) {
    for (const loc of locations) {
      locationMap[loc.id] = loc;
    }
  }
}

// 4. Merge employee + location data into trips
const mergedTrips = tripsData.map((trip: any) => ({
  ...trip,
  employee: employeeMap[trip.employee_id] ?? null,
  start_location: trip.start_location_id ? locationMap[trip.start_location_id] ?? null : null,
  end_location: trip.end_location_id ? locationMap[trip.end_location_id] ?? null : null,
}));
```

**Step 3: Commit**

```bash
git add dashboard/src/types/mileage.ts dashboard/src/app/dashboard/mileage/page.tsx
git commit -m "feat: fetch location names with trips on mileage page"
```

---

## Task 6: Dashboard — Display location names in route column

**Files:**
- Modify: `dashboard/src/app/dashboard/mileage/page.tsx`

**Step 1: Update the route display in TripRow**

In `page.tsx`, modify the `TripRow` component. Currently at lines 699-700:

```typescript
const startLoc = formatLocation(trip.start_address, trip.start_latitude, trip.start_longitude);
const endLoc = formatLocation(trip.end_address, trip.end_latitude, trip.end_longitude);
```

Replace with:

```typescript
const startLocationName = trip.start_location?.name;
const endLocationName = trip.end_location?.name;
const startLoc = startLocationName || formatLocation(trip.start_address, trip.start_latitude, trip.start_longitude);
const endLoc = endLocationName || formatLocation(trip.end_address, trip.end_latitude, trip.end_longitude);
```

**Step 2: Update the route column rendering**

At lines 767-772, replace the route column cell with a version that shows location pins for matched endpoints and "?" for unmatched:

```tsx
<td className="px-4 py-3 max-w-[250px]">
  <div className="flex items-center gap-1 text-xs text-muted-foreground truncate">
    {startLocationName ? (
      <span className="flex items-center gap-0.5 text-emerald-700 font-medium truncate" title={startLocationName}>
        <MapPin className="h-3 w-3 flex-shrink-0 text-emerald-500" />
        {startLocationName}
      </span>
    ) : (
      <span className="truncate opacity-70" title={startLoc}>{startLoc}</span>
    )}
    <ArrowRight className="h-3 w-3 flex-shrink-0" />
    {endLocationName ? (
      <span className="flex items-center gap-0.5 text-emerald-700 font-medium truncate" title={endLocationName}>
        <MapPin className="h-3 w-3 flex-shrink-0 text-emerald-500" />
        {endLocationName}
      </span>
    ) : (
      <span className="truncate opacity-70" title={endLoc}>{endLoc}</span>
    )}
  </div>
</td>
```

**Step 3: Verify visually**

Open `https://time.trilogis.ca/dashboard/mileage` and confirm:
- Trips with matched locations show green pin icon + location name
- Trips without matched locations show faded address/coordinates

**Step 4: Commit**

```bash
git add dashboard/src/app/dashboard/mileage/page.tsx
git commit -m "feat: display location names in mileage route column"
```

---

## Task 7: Dashboard — Inline location correction dropdown

**Files:**
- Create: `dashboard/src/components/trips/location-picker-dropdown.tsx`
- Modify: `dashboard/src/app/dashboard/mileage/page.tsx`

**Step 1: Create the LocationPickerDropdown component**

```typescript
// dashboard/src/components/trips/location-picker-dropdown.tsx
'use client';

import { useState, useEffect, useCallback } from 'react';
import { MapPin, Check, X, Loader2 } from 'lucide-react';
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from '@/components/ui/popover';
import { Button } from '@/components/ui/button';
import { supabaseClient } from '@/lib/supabase/client';
import { toast } from 'sonner';

interface NearbyLocation {
  id: string;
  name: string;
  location_type: string;
  distance_meters: number;
  radius_meters: number;
}

interface LocationPickerDropdownProps {
  tripId: string;
  endpoint: 'start' | 'end';
  latitude: number;
  longitude: number;
  currentLocationId: string | null;
  currentLocationName: string | null;
  displayText: string;
  onLocationChanged: () => void;
}

export function LocationPickerDropdown({
  tripId,
  endpoint,
  latitude,
  longitude,
  currentLocationId,
  currentLocationName,
  displayText,
  onLocationChanged,
}: LocationPickerDropdownProps) {
  const [open, setOpen] = useState(false);
  const [nearbyLocations, setNearbyLocations] = useState<NearbyLocation[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [isSaving, setIsSaving] = useState(false);

  const fetchNearby = useCallback(async () => {
    setIsLoading(true);
    const { data, error } = await supabaseClient.rpc('get_nearby_locations', {
      p_latitude: latitude,
      p_longitude: longitude,
      p_limit: 10,
    });
    if (error) {
      toast.error('Erreur lors du chargement des emplacements');
    } else {
      setNearbyLocations(data || []);
    }
    setIsLoading(false);
  }, [latitude, longitude]);

  useEffect(() => {
    if (open) fetchNearby();
  }, [open, fetchNearby]);

  const handleSelect = async (locationId: string | null) => {
    setIsSaving(true);
    const { error } = await supabaseClient.rpc('update_trip_location', {
      p_trip_id: tripId,
      p_endpoint: endpoint,
      p_location_id: locationId,
    });
    if (error) {
      toast.error('Erreur lors de la mise à jour');
    } else {
      toast.success('Emplacement mis à jour');
      onLocationChanged();
    }
    setIsSaving(false);
    setOpen(false);
  };

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <button
          className="flex items-center gap-0.5 text-xs cursor-pointer hover:underline truncate"
          title={`Cliquer pour modifier (${endpoint === 'start' ? 'départ' : 'arrivée'})`}
        >
          {currentLocationName ? (
            <span className="flex items-center gap-0.5 text-emerald-700 font-medium truncate">
              <MapPin className="h-3 w-3 flex-shrink-0 text-emerald-500" />
              {currentLocationName}
            </span>
          ) : (
            <span className="truncate opacity-70">{displayText}</span>
          )}
        </button>
      </PopoverTrigger>
      <PopoverContent className="w-72 p-2" align="start">
        <div className="text-xs font-medium text-muted-foreground mb-2">
          {endpoint === 'start' ? 'Emplacement de départ' : "Emplacement d'arrivée"}
        </div>
        {isLoading ? (
          <div className="flex items-center justify-center py-4">
            <Loader2 className="h-4 w-4 animate-spin" />
          </div>
        ) : (
          <div className="space-y-1 max-h-60 overflow-y-auto">
            {/* None / Unknown option */}
            <button
              onClick={() => handleSelect(null)}
              disabled={isSaving}
              className={`w-full text-left px-2 py-1.5 rounded text-xs hover:bg-muted flex items-center justify-between ${
                currentLocationId === null ? 'bg-muted' : ''
              }`}
            >
              <span className="text-muted-foreground italic">Aucun / Inconnu</span>
              {currentLocationId === null && <Check className="h-3 w-3 text-emerald-500" />}
            </button>
            {nearbyLocations.map((loc) => (
              <button
                key={loc.id}
                onClick={() => handleSelect(loc.id)}
                disabled={isSaving}
                className={`w-full text-left px-2 py-1.5 rounded text-xs hover:bg-muted flex items-center justify-between ${
                  currentLocationId === loc.id ? 'bg-muted' : ''
                }`}
              >
                <div className="truncate">
                  <span className="font-medium">{loc.name}</span>
                  <span className="text-muted-foreground ml-1">
                    ({Math.round(loc.distance_meters)}m)
                  </span>
                </div>
                {currentLocationId === loc.id && <Check className="h-3 w-3 text-emerald-500" />}
              </button>
            ))}
            {nearbyLocations.length === 0 && (
              <div className="text-xs text-muted-foreground text-center py-2">
                Aucun emplacement trouvé
              </div>
            )}
          </div>
        )}
      </PopoverContent>
    </Popover>
  );
}
```

**Step 2: Integrate into the mileage page TripRow**

Replace the route column in `page.tsx` (the code from Task 6 Step 2) with the interactive dropdown version:

```tsx
<td className="px-4 py-3 max-w-[250px]">
  <div className="flex items-center gap-1 text-xs text-muted-foreground truncate">
    <LocationPickerDropdown
      tripId={trip.id}
      endpoint="start"
      latitude={trip.start_latitude}
      longitude={trip.start_longitude}
      currentLocationId={trip.start_location_id}
      currentLocationName={trip.start_location?.name ?? null}
      displayText={startLoc}
      onLocationChanged={fetchTrips}
    />
    <ArrowRight className="h-3 w-3 flex-shrink-0" />
    <LocationPickerDropdown
      tripId={trip.id}
      endpoint="end"
      latitude={trip.end_latitude}
      longitude={trip.end_longitude}
      currentLocationId={trip.end_location_id}
      currentLocationName={trip.end_location?.name ?? null}
      displayText={endLoc}
      onLocationChanged={fetchTrips}
    />
  </div>
</td>
```

Add the import at the top of `page.tsx`:
```typescript
import { LocationPickerDropdown } from '@/components/trips/location-picker-dropdown';
```

**Step 3: Verify**

Click a location name or address in the route column. Dropdown should show nearby locations with distances. Select one and confirm it updates.

**Step 4: Commit**

```bash
git add dashboard/src/components/trips/location-picker-dropdown.tsx dashboard/src/app/dashboard/mileage/page.tsx
git commit -m "feat: add inline location correction dropdown on mileage page"
```

---

## Task 8: Dashboard — "Re-match all trips" button

**Files:**
- Modify: `dashboard/src/app/dashboard/mileage/page.tsx`

**Step 1: Add a "Re-match Locations" button**

In the route matching card section (around line 405-430 where the other batch buttons are), add:

```tsx
<Button
  variant="outline"
  size="sm"
  onClick={handleRematchLocations}
  disabled={isRematching}
>
  {isRematching ? (
    <Loader2 className="h-4 w-4 mr-1 animate-spin" />
  ) : (
    <MapPin className="h-4 w-4 mr-1" />
  )}
  Re-match emplacements
</Button>
```

**Step 2: Add the handler**

```typescript
const [isRematching, setIsRematching] = useState(false);

const handleRematchLocations = async () => {
  setIsRematching(true);
  try {
    const { data, error } = await supabaseClient.rpc('rematch_all_trip_locations');
    if (error) throw error;
    const result = data?.[0] || data;
    toast.success(
      `Re-match terminé: ${result.matched_count} associés, ${result.skipped_manual} manuels ignorés`
    );
    fetchTrips();
  } catch (err) {
    toast.error('Erreur lors du re-match des emplacements');
  } finally {
    setIsRematching(false);
  }
};
```

**Step 3: Commit**

```bash
git add dashboard/src/app/dashboard/mileage/page.tsx
git commit -m "feat: add re-match locations button on mileage page"
```

---

## Task 9: Dashboard — "Suggested" tab on locations page

**Files:**
- Create: `dashboard/src/components/locations/suggested-locations-tab.tsx`
- Modify: `dashboard/src/app/dashboard/locations/page.tsx`

**Step 1: Create the SuggestedLocationsTab component**

This component:
- Calls `get_unmatched_trip_clusters()` RPC
- Shows clusters on a map and in a list sorted by frequency
- For each cluster, calls Google Maps Geocoding API client-side to get a suggested address
- Has "Create Location" button that pre-fills the LocationForm

```typescript
// dashboard/src/components/locations/suggested-locations-tab.tsx
'use client';

import { useState, useEffect, useCallback } from 'react';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Loader2, MapPin, Plus, Eye } from 'lucide-react';
import { toast } from 'sonner';
import { supabaseClient } from '@/lib/supabase/client';

interface UnmatchedCluster {
  cluster_id: number;
  centroid_latitude: number;
  centroid_longitude: number;
  occurrence_count: number;
  has_start_endpoints: boolean;
  has_end_endpoints: boolean;
  employee_names: string[];
  first_seen: string;
  last_seen: string;
  sample_addresses: string[];
  // Client-side enrichment
  google_address?: string;
  google_loading?: boolean;
}

interface SuggestedLocationsTabProps {
  onCreateLocation: (prefill: {
    latitude: number;
    longitude: number;
    name: string;
    address: string;
  }) => void;
}

export function SuggestedLocationsTab({ onCreateLocation }: SuggestedLocationsTabProps) {
  const [clusters, setClusters] = useState<UnmatchedCluster[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  const fetchClusters = useCallback(async () => {
    setIsLoading(true);
    const { data, error } = await supabaseClient.rpc('get_unmatched_trip_clusters', {
      p_min_occurrences: 1,
    });
    if (error) {
      toast.error('Erreur lors du chargement des suggestions');
    } else {
      setClusters(data || []);
    }
    setIsLoading(false);
  }, []);

  useEffect(() => {
    fetchClusters();
  }, [fetchClusters]);

  const reverseGeocode = async (cluster: UnmatchedCluster) => {
    const apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY;
    if (!apiKey) {
      toast.error('Clé Google Maps non configurée');
      return;
    }

    setClusters((prev) =>
      prev.map((c) =>
        c.cluster_id === cluster.cluster_id ? { ...c, google_loading: true } : c
      )
    );

    try {
      const response = await fetch(
        `https://maps.googleapis.com/maps/api/geocode/json?latlng=${cluster.centroid_latitude},${cluster.centroid_longitude}&key=${apiKey}&language=fr`
      );
      const data = await response.json();
      const address = data.results?.[0]?.formatted_address || 'Adresse non trouvée';

      setClusters((prev) =>
        prev.map((c) =>
          c.cluster_id === cluster.cluster_id
            ? { ...c, google_address: address, google_loading: false }
            : c
        )
      );
    } catch {
      setClusters((prev) =>
        prev.map((c) =>
          c.cluster_id === cluster.cluster_id ? { ...c, google_loading: false } : c
        )
      );
      toast.error('Erreur de géocodage');
    }
  };

  const handleCreate = (cluster: UnmatchedCluster) => {
    const name = cluster.google_address?.split(',')[0] || `Emplacement ${cluster.cluster_id}`;
    const address = cluster.google_address || cluster.sample_addresses?.[0] || '';
    onCreateLocation({
      latitude: cluster.centroid_latitude,
      longitude: cluster.centroid_longitude,
      name,
      address,
    });
  };

  if (isLoading) {
    return (
      <div className="flex items-center justify-center py-12">
        <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
      </div>
    );
  }

  if (clusters.length === 0) {
    return (
      <div className="text-center py-12 text-muted-foreground">
        <MapPin className="h-8 w-8 mx-auto mb-2 opacity-50" />
        <p>Aucun emplacement non vérifié</p>
        <p className="text-xs mt-1">
          Tous les départs et arrivées de trajets correspondent à des emplacements connus.
        </p>
      </div>
    );
  }

  return (
    <div className="space-y-3">
      <p className="text-sm text-muted-foreground">
        {clusters.length} groupe{clusters.length > 1 ? 's' : ''} d&apos;emplacements non vérifiés.
        Cliquez sur &quot;Voir adresse&quot; pour obtenir une suggestion Google Maps.
      </p>
      {clusters.map((cluster) => (
        <Card key={cluster.cluster_id}>
          <CardContent className="p-4">
            <div className="flex items-start justify-between gap-4">
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2 mb-1">
                  <Badge variant="secondary" className="text-xs">
                    {cluster.occurrence_count} occurrence{cluster.occurrence_count > 1 ? 's' : ''}
                  </Badge>
                  {cluster.has_start_endpoints && (
                    <Badge variant="outline" className="text-xs">Départ</Badge>
                  )}
                  {cluster.has_end_endpoints && (
                    <Badge variant="outline" className="text-xs">Arrivée</Badge>
                  )}
                </div>

                {cluster.google_address ? (
                  <p className="text-sm font-medium">{cluster.google_address}</p>
                ) : cluster.sample_addresses?.length > 0 ? (
                  <p className="text-sm text-muted-foreground">{cluster.sample_addresses[0]}</p>
                ) : (
                  <p className="text-sm text-muted-foreground">
                    {cluster.centroid_latitude.toFixed(5)}, {cluster.centroid_longitude.toFixed(5)}
                  </p>
                )}

                <div className="text-xs text-muted-foreground mt-1 space-y-0.5">
                  {cluster.employee_names?.length > 0 && (
                    <p>Employés: {cluster.employee_names.join(', ')}</p>
                  )}
                  <p>
                    Période: {new Date(cluster.first_seen).toLocaleDateString('fr-CA')} —{' '}
                    {new Date(cluster.last_seen).toLocaleDateString('fr-CA')}
                  </p>
                </div>
              </div>

              <div className="flex flex-col gap-1">
                {!cluster.google_address && (
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => reverseGeocode(cluster)}
                    disabled={cluster.google_loading}
                  >
                    {cluster.google_loading ? (
                      <Loader2 className="h-3 w-3 animate-spin mr-1" />
                    ) : (
                      <Eye className="h-3 w-3 mr-1" />
                    )}
                    Voir adresse
                  </Button>
                )}
                <Button
                  variant="default"
                  size="sm"
                  onClick={() => handleCreate(cluster)}
                >
                  <Plus className="h-3 w-3 mr-1" />
                  Créer
                </Button>
              </div>
            </div>
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
```

**Step 2: Add tabs to the locations page**

In `dashboard/src/app/dashboard/locations/page.tsx`, add a tab state and import `Tabs` from shadcn/ui. The implementer should:

1. Add `import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs';`
2. Add `import { SuggestedLocationsTab } from '@/components/locations/suggested-locations-tab';`
3. Wrap the existing content in `<TabsContent value="active">` and add a new `<TabsContent value="suggested">`
4. Add tab state: `const [activeTab, setActiveTab] = useState<'active' | 'inactive' | 'suggested'>('active')`
5. Add tab triggers at the top of the page (after the title, before filters)

The tab bar should look like:
```tsx
<Tabs value={activeTab} onValueChange={(v) => setActiveTab(v as any)}>
  <TabsList>
    <TabsTrigger value="active">Actifs</TabsTrigger>
    <TabsTrigger value="inactive">Inactifs</TabsTrigger>
    <TabsTrigger value="suggested">Suggérés</TabsTrigger>
  </TabsList>

  <TabsContent value="active">
    {/* existing filters + list/map view */}
  </TabsContent>

  <TabsContent value="inactive">
    {/* same as active but with is_active=false filter */}
  </TabsContent>

  <TabsContent value="suggested">
    <SuggestedLocationsTab
      onCreateLocation={(prefill) => {
        // Open create dialog with pre-filled values
        setCreatePrefill(prefill);
        setIsCreateDialogOpen(true);
      }}
    />
  </TabsContent>
</Tabs>
```

6. Add state for pre-fill: `const [createPrefill, setCreatePrefill] = useState<{latitude: number; longitude: number; name: string; address: string} | null>(null);`
7. Pass `createPrefill` to `LocationForm` as `defaultValues` when the dialog opens

**Step 3: Verify**

Navigate to `/dashboard/locations`, check the "Suggérés" tab appears and shows clusters if any unmatched trip endpoints exist.

**Step 4: Commit**

```bash
git add dashboard/src/components/locations/suggested-locations-tab.tsx dashboard/src/app/dashboard/locations/page.tsx
git commit -m "feat: add Suggested tab with unmatched trip endpoint clusters"
```

---

## Task 10: Apply migration to production and backfill existing trips

**Step 1: Apply migration to production Supabase**

Use the Supabase MCP tool or `supabase db push` to apply migration 050.

**Step 2: Run `rematch_all_trip_locations()` to backfill**

```sql
SELECT * FROM rematch_all_trip_locations();
```

This will match all existing trips to known locations. Report the result (matched/skipped/total).

**Step 3: Verify on dashboard**

Open `https://time.trilogis.ca/dashboard/mileage` and confirm:
- Trips near known locations now show location names
- The inline dropdown works
- The "Re-match emplacements" button works

Open `https://time.trilogis.ca/dashboard/locations` and confirm:
- "Suggérés" tab shows unmatched endpoint clusters
- "Voir adresse" fetches Google Maps suggestion
- "Créer" opens pre-filled location form

**Step 4: Commit any final adjustments**

```bash
git add -A
git commit -m "feat: trip-to-location matching complete"
```

---

## Summary

| Task | What | Files |
|------|------|-------|
| 1 | Migration: match method columns + helper function | `050_trip_location_matching.sql` |
| 2 | Migration: update `detect_trips()` with location matching | `050_trip_location_matching.sql` |
| 3 | Migration: admin override + rematch + nearby RPCs | `050_trip_location_matching.sql` |
| 4 | Migration: unmatched endpoint clustering RPC | `050_trip_location_matching.sql` |
| 5 | Dashboard: update Trip type + fetch locations | `types/mileage.ts`, `mileage/page.tsx` |
| 6 | Dashboard: display location names in route column | `mileage/page.tsx` |
| 7 | Dashboard: inline location correction dropdown | `location-picker-dropdown.tsx`, `mileage/page.tsx` |
| 8 | Dashboard: re-match all trips button | `mileage/page.tsx` |
| 9 | Dashboard: Suggested tab on locations page | `suggested-locations-tab.tsx`, `locations/page.tsx` |
| 10 | Production deploy + backfill | N/A |

**Dependencies:** Tasks 1-4 are sequential (same migration file). Tasks 5-9 depend on Tasks 1-4 being applied. Task 10 depends on all others.
