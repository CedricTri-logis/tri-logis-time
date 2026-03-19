# Geocode Cache — Reverse Geocoding for Unknown Locations

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a clock-in/clock-out or stop has no matching known location, display a reverse-geocoded address (from Google) instead of "Lieu inconnu", using a persistent Supabase cache to avoid duplicate API calls.

**Architecture:** A `geocode_cache` table stores reverse-geocoded addresses keyed by PostGIS point. A Next.js API route `/api/reverse-geocode` checks the cache first (spatial match within 55m — matching the DBSCAN eps used in cluster grouping), calls Google on miss, and persists the result. The suggested locations enrichment and the approval UI both use this route, so addresses are shared across views.

**Tech Stack:** PostgreSQL/PostGIS (Supabase), Next.js API routes, Google Maps Geocoding API + Places API (New), TypeScript/React

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `supabase/migrations/20260319000000_geocode_cache.sql` | Table + index + RLS + `find_geocode_cache` RPC |
| Create | `dashboard/src/app/api/reverse-geocode/route.ts` | Cache-through reverse geocoding endpoint |
| Create | `dashboard/src/lib/hooks/use-reverse-geocode.ts` | React hook for batch reverse geocoding |
| Modify | `dashboard/src/components/locations/suggested-locations-tab.tsx` | Use new API route instead of direct Google calls |
| Modify | `dashboard/src/components/approvals/day-approval-detail.tsx` | Add `useReverseGeocode` hook, pass results down |
| Modify | `dashboard/src/components/approvals/approval-rows.tsx` | Accept `geocodedAddresses` prop, resolve addresses |

---

### Task 1: Create `geocode_cache` table + RPC

**Files:**
- Create: `supabase/migrations/20260319000000_geocode_cache.sql`

- [ ] **Step 1: Write migration**

```sql
-- Geocode cache: stores reverse-geocoded addresses to avoid duplicate Google API calls.
-- Points within ~55m share the same address (matches DBSCAN eps=0.0005 used in cluster grouping).

CREATE TABLE IF NOT EXISTS geocode_cache (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    location GEOGRAPHY(POINT, 4326) NOT NULL,
    formatted_address TEXT NOT NULL,
    place_name TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_geocode_cache_location
    ON geocode_cache USING GIST (location);

ALTER TABLE geocode_cache ENABLE ROW LEVEL SECURITY;

CREATE POLICY geocode_cache_read ON geocode_cache
    FOR SELECT TO authenticated USING (true);

COMMENT ON TABLE geocode_cache IS 'Cache of reverse-geocoded addresses. Used by approval views and suggested locations to display addresses for GPS points that don''t match any known location. Points within 55m share a single cached entry.';
COMMENT ON COLUMN geocode_cache.location IS 'PostGIS point (SRID 4326) — the geocoded GPS coordinate';
COMMENT ON COLUMN geocode_cache.formatted_address IS 'Full address from Google reverse geocoding (fr locale)';
COMMENT ON COLUMN geocode_cache.place_name IS 'Business/POI name from Google Places Nearby (null if none found)';

-- RPC for the API route to check cache by proximity
CREATE OR REPLACE FUNCTION find_geocode_cache(
    p_lat DOUBLE PRECISION,
    p_lng DOUBLE PRECISION,
    p_radius DOUBLE PRECISION DEFAULT 55
)
RETURNS TABLE (
    formatted_address TEXT,
    place_name TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT gc.formatted_address, gc.place_name
    FROM geocode_cache gc
    WHERE ST_DWithin(
        gc.location,
        ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography,
        p_radius
    )
    ORDER BY ST_Distance(
        gc.location,
        ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography
    )
    LIMIT 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path TO public, extensions;
```

**Note:** The `SET search_path TO public, extensions` is required because PostGIS functions live in the `extensions` schema. Without it, the RPC will fail with "type geography does not exist". The `STABLE` marker allows PostgreSQL to optimize repeated calls in the same transaction.

- [ ] **Step 2: Apply migration**

Run via Supabase MCP `apply_migration` or `cd supabase && supabase db push`.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260319000000_geocode_cache.sql
git commit -m "feat: add geocode_cache table and find_geocode_cache RPC"
```

---

### Task 2: Create `/api/reverse-geocode` API route

**Files:**
- Create: `dashboard/src/app/api/reverse-geocode/route.ts`

**Reference:** Existing admin client at `dashboard/src/lib/supabase/admin.ts`, existing forward geocode route at `dashboard/src/app/api/geocode/route.ts`.

- [ ] **Step 1: Create the API route**

```typescript
import { NextRequest, NextResponse } from 'next/server';
import { z } from 'zod';
import { createAdminClient } from '@/lib/supabase/admin';

const SEARCH_RADIUS_METERS = 55; // matches DBSCAN eps=0.0005 (~55m)

const pointSchema = z.object({
  latitude: z.number().min(-90).max(90),
  longitude: z.number().min(-180).max(180),
});

const batchSchema = z.object({
  points: z.array(pointSchema).min(1).max(100),
});

interface ReverseGeocodeResult {
  formatted_address: string | null;
  place_name: string | null;
}

async function reverseGeocodeGoogle(
  lat: number,
  lng: number,
  apiKey: string
): Promise<{ address: string | null; placeName: string | null }> {
  let address: string | null = null;
  let placeName: string | null = null;

  // 1. Reverse geocode for address
  try {
    const geoRes = await fetch(
      `https://maps.googleapis.com/maps/api/geocode/json?latlng=${lat},${lng}&key=${apiKey}&language=fr`
    );
    const geoData = await geoRes.json();
    address = geoData.results?.[0]?.formatted_address || null;
  } catch {
    /* keep null */
  }

  // 2. Places Nearby Search for business name
  try {
    const placesRes = await fetch(
      'https://places.googleapis.com/v1/places:searchNearby',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': apiKey,
          'X-Goog-FieldMask':
            'places.displayName,places.formattedAddress,places.types',
        },
        body: JSON.stringify({
          locationRestriction: {
            circle: {
              center: { latitude: lat, longitude: lng },
              radius: 50.0,
            },
          },
          maxResultCount: 1,
          languageCode: 'fr',
        }),
      }
    );
    const placesData = await placesRes.json();
    placeName = placesData.places?.[0]?.displayName?.text || null;
    if (!address && placesData.places?.[0]?.formattedAddress) {
      address = placesData.places[0].formattedAddress;
    }
  } catch {
    /* no business name found */
  }

  return { address, placeName };
}

/**
 * POST /api/reverse-geocode
 *
 * Accepts { points: [{ latitude, longitude }, ...] } (max 100)
 * Returns { results: [{ formatted_address, place_name }, ...] }
 *
 * For each point: checks geocode_cache (spatial match within 55m).
 * On cache miss: calls Google reverse geocode + Places Nearby, stores result in cache.
 */
export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const parseResult = batchSchema.safeParse(body);

    if (!parseResult.success) {
      return NextResponse.json(
        { success: false, error: 'Invalid input' },
        { status: 400 }
      );
    }

    const { points } = parseResult.data;
    const supabase = createAdminClient();
    const apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY;
    const results: ReverseGeocodeResult[] = [];

    for (const point of points) {
      // 1. Check cache (spatial match within 55m)
      const { data: cached } = await supabase
        .rpc('find_geocode_cache', {
          p_lat: point.latitude,
          p_lng: point.longitude,
          p_radius: SEARCH_RADIUS_METERS,
        });

      if (cached && cached.length > 0) {
        results.push({
          formatted_address: cached[0].formatted_address,
          place_name: cached[0].place_name,
        });
        continue;
      }

      // 2. Cache miss — call Google (skip if no API key)
      if (!apiKey) {
        results.push({ formatted_address: null, place_name: null });
        continue;
      }

      const { address, placeName } = await reverseGeocodeGoogle(
        point.latitude,
        point.longitude,
        apiKey
      );

      // 3. Store in cache if we got an address
      if (address) {
        await supabase
          .from('geocode_cache')
          .insert({
            location: `SRID=4326;POINT(${point.longitude} ${point.latitude})`,
            formatted_address: address,
            place_name: placeName,
          });
      }

      results.push({
        formatted_address: address,
        place_name: placeName,
      });
    }

    return NextResponse.json({ success: true, results });
  } catch (error) {
    console.error('Reverse geocode error:', error);
    return NextResponse.json(
      { success: false, error: 'Reverse geocoding failed' },
      { status: 500 }
    );
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/app/api/reverse-geocode/route.ts
git commit -m "feat: add /api/reverse-geocode route with geocode_cache lookup"
```

---

### Task 3: Create `useReverseGeocode` hook

**Files:**
- Create: `dashboard/src/lib/hooks/use-reverse-geocode.ts`

- [ ] **Step 1: Write the hook**

The hook must use a serialized stable key as the `useEffect` dependency (not the `points` array reference, which changes every render and would cause infinite loops).

```typescript
'use client';

import { useState, useEffect, useRef, useMemo } from 'react';

interface GeoPoint {
  latitude: number;
  longitude: number;
}

export interface GeocodeResult {
  formatted_address: string | null;
  place_name: string | null;
}

// Module-level in-memory cache — survives re-renders and component remounts
const sessionCache = new Map<string, GeocodeResult>();

function cacheKey(lat: number, lng: number): string {
  return `${lat.toFixed(5)},${lng.toFixed(5)}`;
}

/**
 * Batch reverse-geocode a list of points.
 * Returns a Map keyed by "lat,lng" (5 decimal places) → GeocodeResult.
 * Uses: session memory cache → server geocode_cache → Google API (stored back to cache).
 */
export function useReverseGeocode(points: GeoPoint[]) {
  const [results, setResults] = useState<Map<string, GeocodeResult>>(new Map());
  const [isLoading, setIsLoading] = useState(false);

  // Serialize points into a stable string for useEffect dependency
  const stableKey = useMemo(() => {
    const keys: string[] = [];
    for (const p of points) {
      if (p.latitude != null && p.longitude != null) {
        keys.push(cacheKey(p.latitude, p.longitude));
      }
    }
    // Deduplicate and sort for stability
    return [...new Set(keys)].sort().join('|');
  }, [points]);

  useEffect(() => {
    if (!stableKey) return;

    const keys = stableKey.split('|');

    // Separate cached vs. uncached
    const fromCache = new Map<string, GeocodeResult>();
    const toFetch: GeoPoint[] = [];

    for (const key of keys) {
      const hit = sessionCache.get(key);
      if (hit) {
        fromCache.set(key, hit);
      } else {
        const [lat, lng] = key.split(',').map(Number);
        toFetch.push({ latitude: lat, longitude: lng });
      }
    }

    // Apply cached results immediately
    if (fromCache.size > 0) {
      setResults((prev) => {
        const next = new Map(prev);
        fromCache.forEach((v, k) => next.set(k, v));
        return next;
      });
    }

    if (toFetch.length === 0) return;

    let cancelled = false;
    setIsLoading(true);

    fetch('/api/reverse-geocode', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ points: toFetch }),
    })
      .then((res) => res.json())
      .then((data) => {
        if (cancelled || !data.success || !data.results) return;
        const fetched = new Map<string, GeocodeResult>();
        toFetch.forEach((p, i) => {
          const key = cacheKey(p.latitude, p.longitude);
          const result = data.results[i];
          sessionCache.set(key, result);
          fetched.set(key, result);
        });
        setResults((prev) => {
          const next = new Map(prev);
          fetched.forEach((v, k) => next.set(k, v));
          return next;
        });
      })
      .catch(console.error)
      .finally(() => {
        if (!cancelled) setIsLoading(false);
      });

    return () => { cancelled = true; };
  }, [stableKey]);

  return { results, isLoading };
}

/**
 * Helper to resolve a geocoded display name for an activity.
 * Returns place_name > formatted_address > fallback.
 */
export function resolveGeocodedName(
  lat: number | null,
  lng: number | null,
  geocodedAddresses: Map<string, GeocodeResult> | undefined,
  fallback: string
): string {
  if (lat == null || lng == null || !geocodedAddresses) return fallback;
  const key = cacheKey(lat, lng);
  const geo = geocodedAddresses.get(key);
  if (geo?.place_name) return geo.place_name;
  if (geo?.formatted_address) return geo.formatted_address;
  return fallback;
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/lib/hooks/use-reverse-geocode.ts
git commit -m "feat: add useReverseGeocode hook with session + DB cache"
```

---

### Task 4: Update suggested locations to use the cache route

**Files:**
- Modify: `dashboard/src/components/locations/suggested-locations-tab.tsx`

- [ ] **Step 1: Replace `enrichClusters()` with API route call**

Replace the entire `enrichClusters` function (lines 39-100) with:

```typescript
async function enrichClusters(rawClusters: UnmatchedCluster[]): Promise<UnmatchedCluster[]> {
  if (rawClusters.length === 0) return rawClusters;

  const points = rawClusters.map((c) => ({
    latitude: c.centroid_latitude,
    longitude: c.centroid_longitude,
  }));

  try {
    const res = await fetch('/api/reverse-geocode', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ points }),
    });
    const data = await res.json();

    if (data.success && data.results) {
      return rawClusters.map((cluster, i) => ({
        ...cluster,
        google_address: data.results[i].formatted_address,
        place_name: data.results[i].place_name,
      }));
    }
  } catch {
    /* fallback to raw clusters */
  }

  return rawClusters;
}
```

This moves Google API calls from the browser to the server-side API route. The `NEXT_PUBLIC_GOOGLE_MAPS_API_KEY` is no longer exposed client-side for this feature. All results are persisted to `geocode_cache` automatically.

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/components/locations/suggested-locations-tab.tsx
git commit -m "refactor: route suggested locations enrichment through /api/reverse-geocode"
```

---

### Task 5: Display geocoded addresses in approval view

**Files:**
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx` — add the hook
- Modify: `dashboard/src/components/approvals/approval-rows.tsx` — accept and use geocoded addresses

This is the most complex task. Read both files fully before making changes.

- [ ] **Step 1: Read both files**

Read `day-approval-detail.tsx` and `approval-rows.tsx` in full to understand:
1. Which component owns the activities list
2. How activities are passed to row components
3. All the row component interfaces that need the new prop

- [ ] **Step 2: Add the hook in `day-approval-detail.tsx`**

In the component that owns `detail.activities`:

```typescript
import { useReverseGeocode, type GeocodeResult } from '@/lib/hooks/use-reverse-geocode';

// Inside the component, after detail is loaded:
const unknownLocationPoints = useMemo(() =>
  (detail?.activities || [])
    .filter((a: ApprovalActivity) =>
      !a.location_name && a.latitude != null && a.longitude != null
    )
    .map((a: ApprovalActivity) => ({
      latitude: a.latitude!,
      longitude: a.longitude!,
    })),
  [detail?.activities]
);

const { results: geocodedAddresses } = useReverseGeocode(unknownLocationPoints);
```

Thread `geocodedAddresses` as a prop to all row components that render location fallback text. This includes finding every place where activity row components are rendered and adding the prop.

- [ ] **Step 3: Add `geocodedAddresses` prop to row component interfaces**

In `approval-rows.tsx`, add to each row component's props interface:

```typescript
geocodedAddresses?: Map<string, GeocodeResult>;
```

Components that need this prop (check the actual interfaces when implementing):
- `ActivityRow`
- `MergedLocationRow`
- `TripConnectorRow`
- `GapSubRow`
- `LunchGroupRow` (if it renders child rows)

- [ ] **Step 4: Replace fallback text in row components**

Import the helper:

```typescript
import { resolveGeocodedName, type GeocodeResult } from '@/lib/hooks/use-reverse-geocode';
```

Replace all location fallback patterns. Search for these exact strings in the file:

1. `'Lieu inconnu'` (clock events) → `resolveGeocodedName(activity.latitude, activity.longitude, geocodedAddresses, 'Lieu inconnu')`
2. `'Arrêt non associé'` / `'Arret non associe'` (stops) → `resolveGeocodedName(activity.latitude, activity.longitude, geocodedAddresses, 'Arrêt non associé')`
3. `'Inconnu'` (trip start/end in gap rows) → use `start_latitude`/`start_longitude` or `end_latitude`/`end_longitude` with the helper

Also update the expand-detail components if they show fallback text:
- `trip-expand-detail.tsx`: `'Inconnu'` at lines 77-78
- `gap-expand-detail.tsx`: `'Inconnu'` at lines 99, 103

- [ ] **Step 5: Commit**

```bash
git add dashboard/src/components/approvals/day-approval-detail.tsx dashboard/src/components/approvals/approval-rows.tsx dashboard/src/components/approvals/trip-expand-detail.tsx dashboard/src/components/approvals/gap-expand-detail.tsx dashboard/src/lib/hooks/use-reverse-geocode.ts
git commit -m "feat: show reverse-geocoded address instead of 'Lieu inconnu' in approval view"
```

---

### Task 6: Build and verify

- [ ] **Step 1: Build the dashboard**

Run: `cd dashboard && npm run build`
Expected: Build succeeds with no TypeScript errors.

- [ ] **Step 2: Manual test**

1. Open the locations page → Suggested tab → verify addresses load and come from cache on reload
2. Open approval for a day with a clock-in at an unknown location → verify the address appears instead of "Lieu inconnu"
3. Reload the approval page → verify the address loads instantly (from cache, no Google API call)

- [ ] **Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: address review findings from geocode cache integration"
```
