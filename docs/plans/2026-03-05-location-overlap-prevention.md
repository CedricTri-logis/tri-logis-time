# Location Overlap Prevention — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Prevent overlapping location geofences by showing nearby locations on the edit map and hard-blocking saves when overlap is detected.

**Architecture:** Extend `get_nearby_locations` RPC to return lat/lng so the map can render neighbor circles. Add a new `check_location_overlap` RPC for server-side validation. Wire both into the form (real-time visual feedback + save block) and into `bulk_insert_locations` (CSV import safety net).

**Tech Stack:** PostgreSQL/PostGIS (Supabase), TypeScript/Next.js, @vis.gl/react-google-maps, React Hook Form + Zod

---

### Task 1: DB Migration — Extend `get_nearby_locations` and add `check_location_overlap`

**Files:**
- Create: `supabase/migrations/133_location_overlap_prevention.sql`

**Step 1: Write the migration**

```sql
-- ============================================================
-- 133: Location overlap prevention
-- ============================================================

-- 1. Replace get_nearby_locations to also return lat/lng
--    (used by the edit map to render neighbor circles)
CREATE OR REPLACE FUNCTION get_nearby_locations(
    p_latitude NUMERIC,
    p_longitude NUMERIC,
    p_limit INTEGER DEFAULT 20,
    p_exclude_id UUID DEFAULT NULL
)
RETURNS TABLE(
    id UUID,
    name TEXT,
    location_type TEXT,
    distance_meters DOUBLE PRECISION,
    radius_meters NUMERIC,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION
)
LANGUAGE plpgsql SECURITY DEFINER AS $$
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
        l.radius_meters,
        l.latitude,
        l.longitude
    FROM locations l
    WHERE l.is_active = TRUE
      AND (p_exclude_id IS NULL OR l.id != p_exclude_id)
    ORDER BY distance_meters ASC
    LIMIT p_limit;
END;
$$;

-- 2. check_location_overlap: returns overlapping active locations
--    Overlap = distance between centers < sum of radii
CREATE OR REPLACE FUNCTION check_location_overlap(
    p_latitude NUMERIC,
    p_longitude NUMERIC,
    p_radius_meters NUMERIC,
    p_exclude_id UUID DEFAULT NULL
)
RETURNS TABLE(
    id UUID,
    name TEXT,
    location_type TEXT,
    distance_meters DOUBLE PRECISION,
    radius_meters NUMERIC,
    overlap_meters DOUBLE PRECISION
)
LANGUAGE plpgsql SECURITY DEFINER AS $$
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
        l.radius_meters,
        (l.radius_meters + p_radius_meters) - ST_Distance(
            l.location,
            ST_SetSRID(ST_MakePoint(p_longitude, p_latitude), 4326)::geography
        ) AS overlap_meters
    FROM locations l
    WHERE l.is_active = TRUE
      AND (p_exclude_id IS NULL OR l.id != p_exclude_id)
      AND ST_DWithin(
          l.location,
          ST_SetSRID(ST_MakePoint(p_longitude, p_latitude), 4326)::geography,
          l.radius_meters + p_radius_meters
      )
    ORDER BY distance_meters ASC;
END;
$$;

-- 3. Update bulk_insert_locations to check overlap before each insert
CREATE OR REPLACE FUNCTION bulk_insert_locations(p_locations JSONB)
RETURNS TABLE(id UUID, name TEXT, success BOOLEAN, error_message TEXT)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_location JSONB;
    v_id UUID;
    v_name TEXT;
    v_lat NUMERIC;
    v_lng NUMERIC;
    v_radius NUMERIC;
    v_overlap_name TEXT;
    v_overlap_distance NUMERIC;
BEGIN
    FOR v_location IN SELECT * FROM jsonb_array_elements(p_locations) LOOP
        v_name := v_location->>'name';
        v_id := NULL;

        v_lat := (v_location->>'latitude')::NUMERIC;
        v_lng := (v_location->>'longitude')::NUMERIC;
        v_radius := COALESCE((v_location->>'radius_meters')::NUMERIC, 100);

        -- Check for overlap with existing locations
        SELECT ol.name, ol.distance_meters
        INTO v_overlap_name, v_overlap_distance
        FROM check_location_overlap(v_lat, v_lng, v_radius) ol
        LIMIT 1;

        IF v_overlap_name IS NOT NULL THEN
            id := NULL;
            name := v_name;
            success := FALSE;
            error_message := format(
                'Chevauchement avec "%s" (distance: %sm, chevauchement: %sm)',
                v_overlap_name,
                round(v_overlap_distance::NUMERIC, 1),
                round((v_radius + (SELECT l.radius_meters FROM locations l WHERE l.name = v_overlap_name LIMIT 1) - v_overlap_distance)::NUMERIC, 1)
            );
            RETURN NEXT;
            CONTINUE;
        END IF;

        BEGIN
            INSERT INTO locations (name, location_type, location, radius_meters, address, notes, is_active)
            VALUES (
                v_name,
                (v_location->>'location_type')::location_type,
                ST_SetSRID(ST_MakePoint(v_lng, v_lat), 4326)::geography,
                v_radius,
                v_location->>'address',
                v_location->>'notes',
                COALESCE((v_location->>'is_active')::boolean, true)
            )
            RETURNING locations.id INTO v_id;

            id := v_id;
            name := v_name;
            success := TRUE;
            error_message := NULL;
            RETURN NEXT;
        EXCEPTION WHEN OTHERS THEN
            id := NULL;
            name := v_name;
            success := FALSE;
            error_message := SQLERRM;
            RETURN NEXT;
        END;
    END LOOP;
END;
$$;
```

**Step 2: Apply the migration**

Run: `supabase migration apply` (via MCP tool `apply_migration`)

**Step 3: Verify with a test query**

```sql
-- Should return Toujours Mikes as overlapping 14-20_Perreault-E
SELECT * FROM check_location_overlap(48.2379933859967, -79.0194810362673, 20);
```

**Step 4: Commit**

```bash
git add supabase/migrations/133_location_overlap_prevention.sql
git commit -m "feat: add location overlap detection RPC and extend get_nearby_locations"
```

---

### Task 2: Frontend Hook — `useNearbyLocations`

**Files:**
- Modify: `dashboard/src/lib/hooks/use-locations.ts` (add hook at end of file, ~line 377)

**Step 1: Add the `NearbyLocation` type**

In `dashboard/src/types/location.ts`, add after the existing types:

```typescript
export interface NearbyLocation {
  id: string;
  name: string;
  locationType: string;
  distanceMeters: number;
  radiusMeters: number;
  latitude: number;
  longitude: number;
}
```

**Step 2: Add the `useNearbyLocations` hook**

Append to `dashboard/src/lib/hooks/use-locations.ts`:

```typescript
import type { NearbyLocation } from '@/types/location';

/**
 * Hook to fetch nearby locations for the edit map.
 * Returns neighbors within range, with overlap detection.
 */
export function useNearbyLocations(
  latitude: number | null,
  longitude: number | null,
  radiusMeters: number,
  excludeId?: string | null
) {
  const [nearbyLocations, setNearbyLocations] = useState<NearbyLocation[]>([]);
  const [isLoading, setIsLoading] = useState(false);

  const fetch = useCallback(async () => {
    if (latitude === null || longitude === null || (latitude === 0 && longitude === 0)) {
      setNearbyLocations([]);
      return;
    }

    setIsLoading(true);
    try {
      const params: Record<string, unknown> = {
        p_latitude: latitude,
        p_longitude: longitude,
        p_limit: 20,
      };
      if (excludeId) params.p_exclude_id = excludeId;

      const { data, error } = await supabaseClient.rpc('get_nearby_locations', params);
      if (error) throw error;

      const rows = (data ?? []) as Array<{
        id: string;
        name: string;
        location_type: string;
        distance_meters: number;
        radius_meters: number;
        latitude: number;
        longitude: number;
      }>;

      // Only keep locations within 500m
      setNearbyLocations(
        rows
          .filter((r) => r.distance_meters <= 500)
          .map((r) => ({
            id: r.id,
            name: r.name,
            locationType: r.location_type,
            distanceMeters: r.distance_meters,
            radiusMeters: r.radius_meters,
            latitude: r.latitude,
            longitude: r.longitude,
          }))
      );
    } catch {
      setNearbyLocations([]);
    } finally {
      setIsLoading(false);
    }
  }, [latitude, longitude, excludeId]);

  // Debounce: re-fetch when position changes (300ms)
  useEffect(() => {
    const timer = setTimeout(fetch, 300);
    return () => clearTimeout(timer);
  }, [fetch]);

  // Compute overlaps client-side
  const overlappingLocations = useMemo(
    () =>
      nearbyLocations.filter(
        (loc) => loc.distanceMeters < loc.radiusMeters + radiusMeters
      ),
    [nearbyLocations, radiusMeters]
  );

  return { nearbyLocations, overlappingLocations, isLoading };
}
```

**Step 3: Commit**

```bash
git add dashboard/src/types/location.ts dashboard/src/lib/hooks/use-locations.ts
git commit -m "feat: add useNearbyLocations hook with overlap detection"
```

---

### Task 3: Map Component — Show nearby locations on edit map

**Files:**
- Modify: `dashboard/src/components/locations/google-location-map.tsx`

**Step 1: Extend `LocationMapProps` to accept nearby locations**

Add to the existing interface at line 15:

```typescript
interface NearbyLocationCircle {
  id: string;
  name: string;
  latitude: number;
  longitude: number;
  radiusMeters: number;
  isOverlapping: boolean;
}

interface LocationMapProps {
  position: [number, number] | null;
  radius: number;
  locationType: LocationType;
  onPositionChange: (lat: number, lng: number) => void;
  className?: string;
  readOnly?: boolean;
  apiKey?: string;
  nearbyLocations?: NearbyLocationCircle[];  // NEW
}
```

**Step 2: Render nearby location circles inside the `<Map>`**

After the existing `<GeofenceCircle>` (line 72), add rendering of nearby locations:

```tsx
{/* Nearby location circles */}
{nearbyLocations?.map((loc) => (
  <NearbyCircle
    key={loc.id}
    center={{ lat: loc.latitude, lng: loc.longitude }}
    radius={loc.radiusMeters}
    name={loc.name}
    isOverlapping={loc.isOverlapping}
  />
))}
```

**Step 3: Add the `NearbyCircle` component**

After the existing `AutoFitCircle` component (after line 118):

```typescript
function NearbyCircle({
  center,
  radius,
  name,
  isOverlapping,
}: {
  center: google.maps.LatLngLiteral;
  radius: number;
  name: string;
  isOverlapping: boolean;
}) {
  const map = useMap();

  useEffect(() => {
    if (!map) return;

    const color = isOverlapping ? '#ef4444' : '#6b7280';

    const circle = new google.maps.Circle({
      map,
      center,
      radius,
      fillColor: color,
      fillOpacity: isOverlapping ? 0.25 : 0.08,
      strokeColor: color,
      strokeOpacity: isOverlapping ? 0.9 : 0.4,
      strokeWeight: isOverlapping ? 2 : 1,
    });

    // Label
    const label = new google.maps.Marker({
      map,
      position: center,
      icon: {
        path: google.maps.SymbolPath.CIRCLE,
        scale: 0,
      },
      label: {
        text: name,
        fontSize: '10px',
        fontWeight: isOverlapping ? '700' : '500',
        color: isOverlapping ? '#dc2626' : '#6b7280',
        className: 'nearby-location-label',
      },
    });

    return () => {
      circle.setMap(null);
      label.setMap(null);
    };
  }, [map, center, radius, name, isOverlapping]);

  return null;
}
```

**Step 4: Commit**

```bash
git add dashboard/src/components/locations/google-location-map.tsx
git commit -m "feat: render nearby location circles with overlap highlighting on edit map"
```

---

### Task 4: Form — Integrate overlap validation into LocationForm

**Files:**
- Modify: `dashboard/src/components/locations/location-form.tsx`

**Step 1: Import and wire the `useNearbyLocations` hook**

At line 47, add import:

```typescript
import { useNearbyLocations } from '@/lib/hooks/use-locations';
```

Inside the `LocationForm` component (after line 111), add:

```typescript
// Fetch nearby locations and compute overlaps
const { nearbyLocations, overlappingLocations } = useNearbyLocations(
  latitude !== 0 || longitude !== 0 ? latitude : null,
  latitude !== 0 || longitude !== 0 ? longitude : null,
  radius,
  location?.id ?? null  // exclude self when editing
);

const hasOverlap = overlappingLocations.length > 0;

// Build nearby circles for the map
const nearbyCircles = nearbyLocations.map((loc) => ({
  id: loc.id,
  name: loc.name,
  latitude: loc.latitude,
  longitude: loc.longitude,
  radiusMeters: loc.radiusMeters,
  isOverlapping: overlappingLocations.some((o) => o.id === loc.id),
}));
```

**Step 2: Pass nearby circles to the map**

Change the `<LocationMap>` call at line 331:

```tsx
<LocationMap
  position={mapPosition}
  radius={radius}
  locationType={locationType}
  onPositionChange={handlePositionChange}
  className="h-[350px] w-full rounded-lg border"
  nearbyLocations={nearbyCircles}
/>
```

**Step 3: Add overlap error banner**

After the map (after the `<LocationMap>` closing tag, before the lat/lng grid), add:

```tsx
{hasOverlap && (
  <div className="flex items-start gap-2 rounded-lg border border-red-200 bg-red-50 p-3">
    <AlertTriangle className="h-4 w-4 text-red-600 mt-0.5 shrink-0" />
    <div>
      <p className="text-sm font-medium text-red-800">
        Chevauchement detecte
      </p>
      <ul className="mt-1 text-xs text-red-700 space-y-0.5">
        {overlappingLocations.map((loc) => (
          <li key={loc.id}>
            {loc.name} — {Math.round(loc.distanceMeters)}m de distance,
            chevauchement de {Math.round(loc.radiusMeters + radius - loc.distanceMeters)}m
          </li>
        ))}
      </ul>
      <p className="mt-1.5 text-xs text-red-600">
        Deplacez le marqueur ou reduisez le rayon pour eliminer le chevauchement.
      </p>
    </div>
  </div>
)}
```

Add `AlertTriangle` to the lucide-react import at line 46:

```typescript
import { Monitor, Building, ShoppingCart, Home, Coffee, Fuel, MapPin, Search, Loader2, AlertTriangle } from 'lucide-react';
```

**Step 4: Block save when overlap exists**

Change the submit button at line 528:

```tsx
<Button type="submit" disabled={isSubmitting || hasOverlap}>
```

Also add overlap check in `handleSubmit` at line 180:

```typescript
const handleSubmit = form.handleSubmit(async (data) => {
  if (data.latitude === 0 && data.longitude === 0) {
    form.setError('latitude', { message: 'Veuillez selectionner un emplacement sur la carte' });
    return;
  }
  if (hasOverlap) return;  // safety net
  await onSubmit(data);
});
```

**Step 5: Commit**

```bash
git add dashboard/src/components/locations/location-form.tsx
git commit -m "feat: block location save on geofence overlap with visual feedback"
```

---

### Task 5: CSV Import — Add overlap errors in preview

**Files:**
- Modify: `dashboard/src/components/locations/csv-import-dialog.tsx`

The `bulk_insert_locations` DB function now checks overlaps server-side (Task 1). Rows that overlap will come back with `success: false` and an error message. The CSV import dialog already handles this via the `CompleteStep` which shows failed rows with their error messages.

**Step 1: Verify existing error display handles overlap messages**

Read the `CompleteStep` component in `csv-import-dialog.tsx` and confirm it displays `errorMessage` from failed rows. If it already does (it should based on the existing code), no changes needed.

**Step 2: Test by importing a CSV with a location that overlaps an existing one**

Create a test CSV with a location at coordinates that overlap "Toujours Mikes" and verify the error message appears.

**Step 3: Commit (if changes were needed)**

```bash
git add dashboard/src/components/locations/csv-import-dialog.tsx
git commit -m "feat: show overlap errors in CSV import results"
```

---

### Task 6: Verification

**Step 1: Test create flow**

1. Go to `/dashboard/locations` and click "Create"
2. Click on the map near an existing location (e.g., near 14-20_Perreault-E)
3. Verify nearby locations appear as gray circles on the map
4. Adjust radius until overlap occurs — verify circles turn red and error banner appears
5. Verify save button is disabled
6. Move marker away — verify overlap clears and save is enabled

**Step 2: Test edit flow**

1. Go to an existing location's edit page
2. Verify the current location's circle is shown normally
3. Verify nearby locations are shown (excluding self)
4. Drag the marker toward another location — verify overlap detection

**Step 3: Test CSV import**

1. Create a CSV with one valid and one overlapping location
2. Import it
3. Verify the valid one succeeds and the overlapping one shows the overlap error

**Step 4: Final commit**

```bash
git add -A
git commit -m "feat: location geofence overlap prevention (visual + hard block)"
```
