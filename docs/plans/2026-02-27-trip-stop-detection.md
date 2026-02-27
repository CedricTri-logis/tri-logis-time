# Trip Stop Detection — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix `detect_trips` to use GPS sensor speed + spatial radius for stationary detection, include stationary points in trip_gps_points, and update dashboard stop visualization.

**Architecture:** Migration 053 replaces the stationary detection block in `detect_trips` with a sensor-speed + 50m-radius approach. Stationary points are included in `trip_gps_points` (without adding distance). Dashboard `detect-trip-stops.ts` is updated to use the same spatial-radius logic. Re-detection is run for all completed shifts.

**Tech Stack:** PostgreSQL/Supabase (detect_trips RPC), TypeScript/Next.js (dashboard), PostGIS (haversine_km)

---

## Task 1: Migration — Update `detect_trips` stationary detection

**Files:**
- Create: `supabase/migrations/053_sensor_speed_stop_detection.sql`

**Step 1: Write the migration**

The migration replaces `detect_trips` with an updated version. The key changes are in the DECLARE block (new variables) and the stationary detection block (lines ~398-515 of the current function in 051).

Changes to DECLARE:
- Add `v_stationary_center_lat DECIMAL := NULL` and `v_stationary_center_lng DECIMAL := NULL` — track the center of a stop cluster
- Add `v_sensor_stop_threshold CONSTANT DECIMAL := 0.28` — 1 km/h in m/s
- Add `v_spatial_radius_km CONSTANT DECIMAL := 0.05` — 50m in km
- Add `v_point_within_radius BOOLEAN` — temp flag per iteration

Changes to the stationary detection logic (the `ELSIF v_speed < v_stationary_speed AND v_in_trip` block):

Replace the existing block with this logic:
```
-- Determine if point is "stopped" using sensor speed + spatial radius
v_point_within_radius := FALSE;
IF v_stationary_center_lat IS NOT NULL THEN
    v_point_within_radius := haversine_km(
        v_stationary_center_lat, v_stationary_center_lng,
        v_point.latitude, v_point.longitude
    ) < v_spatial_radius_km;
END IF;

-- A point is stationary if:
-- (a) sensor speed < 1 km/h, OR
-- (b) sensor speed < 3 m/s AND within 50m of stop center (GPS noise suppression)
IF v_in_trip AND (
    (v_point.speed IS NOT NULL AND v_point.speed < v_sensor_stop_threshold) OR
    (v_point_within_radius AND v_point.speed IS NOT NULL AND v_point.speed < 3.0
     AND v_speed < v_movement_speed)
) THEN
    -- First stationary point: set center
    IF v_stationary_since IS NULL THEN
        v_stationary_since := v_point.captured_at;
        v_stationary_center_lat := v_point.latitude;
        v_stationary_center_lng := v_point.longitude;
    END IF;

    -- Include stationary point in trip (but don't add distance)
    v_trip_point_count := v_trip_point_count + 1;
    v_trip_points := v_trip_points || v_point.id;
    IF v_point.accuracy IS NOT NULL AND v_point.accuracy > 50 THEN
        v_trip_low_accuracy := v_trip_low_accuracy + 1;
    END IF;

    -- Check if stop duration exceeds cutoff → end trip
    IF EXTRACT(EPOCH FROM (v_point.captured_at - v_stationary_since)) / 60.0 >= v_stationary_gap_minutes THEN
        -- [existing trip-ending logic stays the same]
        ...
    END IF;
```

Also update the "moving" branches to clear the stationary center:
- Where `v_stationary_since := NULL` is set, also set `v_stationary_center_lat := NULL` and `v_stationary_center_lng := NULL`

**Important**: The existing condition structure is:
```
IF v_speed >= v_movement_speed THEN ...
ELSIF v_speed >= v_stationary_speed AND v_in_trip THEN ...
ELSIF v_speed < v_stationary_speed AND v_in_trip THEN ...
```

This must be restructured to:
```
IF v_speed >= v_movement_speed AND NOT <sensor_stopped> THEN ...
ELSIF v_in_trip AND <sensor_stopped_or_within_radius> THEN ...
ELSIF v_in_trip THEN ...  -- medium speed, continue trip
```

Where `<sensor_stopped_or_within_radius>` is the new composite check.

The full migration must include the COMPLETE `detect_trips` function (CREATE OR REPLACE). Copy the entire function from `051_trip_location_matching.sql` and apply the modifications.

**Step 2: Apply migration to remote**

Run: `cd /Users/cedric/Desktop/PROJECT/TEST/GPS_Tracker && supabase db push --linked`

Expected: Migration 053 applied successfully.

**Step 3: Verify with Karo-Lyn's data**

Test the new function on Karo-Lyn's shift:
```sql
-- Find her shift from Feb 26
SELECT id FROM shifts
WHERE employee_id = (SELECT id FROM employee_profiles WHERE full_name ILIKE '%fauchon%')
  AND started_at::date = '2026-02-26';

-- Run detect_trips on it
SELECT * FROM detect_trips('<shift_id>');
```

Expected: The trip that was previously 1 trip (21:13-21:35) should now be split into 2 trips at the ~4-minute stop around 21:21-21:25.

**Step 4: Commit**

```bash
git add supabase/migrations/053_sensor_speed_stop_detection.sql
git commit -m "feat: use sensor speed + spatial radius for stop detection in detect_trips

Replace calculated-speed-based stationary detection with GPS Doppler
sensor speed (< 1 km/h) and 50m spatial radius check. Include
stationary points in trip_gps_points. Fixes false negatives caused
by GPS noise producing phantom calculated speeds during real stops."
```

---

## Task 2: Update dashboard `detect-trip-stops.ts`

**Files:**
- Modify: `dashboard/src/lib/utils/detect-trip-stops.ts`

**Step 1: Rewrite the detection algorithm**

Replace the entire file with the updated algorithm that uses spatial radius clustering:

```typescript
import type { TripGpsPoint } from '@/types/mileage';

export interface TripStop {
  latitude: number;
  longitude: number;
  startTime: string;
  endTime: string;
  durationSeconds: number;
  pointCount: number;
  category: 'moderate' | 'extended';
}

// Thresholds aligned with detect_trips server-side
const SENSOR_STOP_SPEED = 0.28;    // m/s (< 1 km/h)
const NOISE_SPEED_LIMIT = 3.0;     // m/s — GPS noise ceiling within radius
const SPATIAL_RADIUS_M = 50;       // meters
const MIN_STOP_DURATION = 60;      // seconds (1 minute)

function haversineM(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const R = 6371000;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLng = (lng2 - lng1) * Math.PI / 180;
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
    Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function categorize(durationSeconds: number): TripStop['category'] {
  if (durationSeconds <= 180) return 'moderate';
  return 'extended';
}

export function detectTripStops(points: TripGpsPoint[]): TripStop[] {
  if (points.length < 2) return [];

  const sorted = [...points].sort(
    (a, b) => new Date(a.captured_at).getTime() - new Date(b.captured_at).getTime(),
  );

  const stops: TripStop[] = [];
  let cluster: TripGpsPoint[] = [];
  let centerLat = 0;
  let centerLng = 0;

  function flushCluster() {
    if (cluster.length < 2) {
      cluster = [];
      return;
    }

    const first = cluster[0];
    const last = cluster[cluster.length - 1];
    const duration =
      (new Date(last.captured_at).getTime() - new Date(first.captured_at).getTime()) / 1000;

    if (duration < MIN_STOP_DURATION) {
      cluster = [];
      return;
    }

    const latSum = cluster.reduce((s, p) => s + p.latitude, 0);
    const lngSum = cluster.reduce((s, p) => s + p.longitude, 0);

    stops.push({
      latitude: latSum / cluster.length,
      longitude: lngSum / cluster.length,
      startTime: first.captured_at,
      endTime: last.captured_at,
      durationSeconds: duration,
      pointCount: cluster.length,
      category: categorize(duration),
    });

    cluster = [];
  }

  for (const pt of sorted) {
    const sensorStopped = pt.speed === null || pt.speed < SENSOR_STOP_SPEED;
    const withinRadius =
      cluster.length > 0 &&
      haversineM(centerLat, centerLng, pt.latitude, pt.longitude) < SPATIAL_RADIUS_M;
    const noiseSuppressed =
      withinRadius && pt.speed !== null && pt.speed < NOISE_SPEED_LIMIT;

    if (sensorStopped || noiseSuppressed) {
      if (cluster.length === 0) {
        centerLat = pt.latitude;
        centerLng = pt.longitude;
      }
      cluster.push(pt);
    } else {
      flushCluster();
    }
  }

  flushCluster();
  return stops;
}
```

Key changes from the old version:
- Speed threshold from 0.83 m/s → 0.28 m/s (sensor-aligned)
- Added `haversineM` for spatial radius check (50m)
- GPS noise suppression: points within 50m with speed < 3 m/s stay in cluster
- Removed `brief` category (< 1 min filtered out now)
- Min stop duration from 15s → 60s

**Step 2: Update stop colors in `google-trip-route-map.tsx`**

Modify `dashboard/src/components/trips/google-trip-route-map.tsx:41-44`:

Remove `brief` from `STOP_COLORS`:
```typescript
const STOP_COLORS: Record<TripStop['category'], string> = {
  moderate: '#f97316',
  extended: '#ef4444',
};
```

**Step 3: Update legend in `mileage/page.tsx`**

Modify `dashboard/src/app/dashboard/mileage/page.tsx:948-981`:

Remove the `brief` legend entry (the block checking `s.category === 'brief'`).

**Step 4: Run lint**

Run: `cd /Users/cedric/Desktop/PROJECT/TEST/GPS_Tracker/dashboard && npx eslint src/lib/utils/detect-trip-stops.ts src/components/trips/google-trip-route-map.tsx`

Expected: No new errors (existing warnings about `any` types in other files are OK).

**Step 5: Commit**

```bash
git add dashboard/src/lib/utils/detect-trip-stops.ts \
       dashboard/src/components/trips/google-trip-route-map.tsx \
       dashboard/src/app/dashboard/mileage/page.tsx
git commit -m "feat: update dashboard stop detection with sensor speed + spatial radius

Align client-side detection with updated server-side detect_trips:
sensor speed < 1 km/h threshold, 50m spatial radius for GPS noise
suppression, 1-minute minimum stop duration. Remove brief category."
```

---

## Task 3: Re-detect all trips

**Step 1: Run re-detection for all completed shifts**

```sql
-- Re-detect trips for all completed shifts
SELECT detect_trips(id)
FROM shifts
WHERE status = 'completed'
ORDER BY started_at DESC;
```

This will delete and re-create all trips for completed shifts with the new algorithm.

**Step 2: Verify Karo-Lyn's trip was split**

```sql
SELECT t.id, t.started_at, t.ended_at, t.distance_km, t.gps_point_count
FROM trips t
JOIN employee_profiles e ON e.id = t.employee_id
WHERE e.full_name ILIKE '%fauchon%'
  AND t.started_at::date = '2026-02-26'
ORDER BY t.started_at;
```

Expected: The single 21:13-21:35 trip should now be 2 trips split at the ~4-minute stop.

**Step 3: Verify stationary points are included**

```sql
SELECT tgp.sequence_order, gp.speed, gp.captured_at
FROM trip_gps_points tgp
JOIN gps_points gp ON gp.id = tgp.gps_point_id
WHERE tgp.trip_id = '<first_trip_id>'
ORDER BY tgp.sequence_order;
```

Expected: Trip should include points with speed ~0 near the end (the stationary points before the trip was cut).

**Step 4: Re-trigger OSRM matching for affected trips**

```sql
-- Reset match status for re-detected trips so OSRM picks them up
UPDATE trips SET match_status = 'pending', match_attempts = 0
WHERE match_status != 'pending';
```

Note: This will require running the OSRM edge function or waiting for the next scheduled match cycle.

---

## Task 4: Deploy dashboard

**Step 1: Push to git**

```bash
git push
```

**Step 2: Deploy to Vercel**

```bash
cd /Users/cedric/Desktop/PROJECT/TEST/GPS_Tracker/dashboard && npx vercel --prod --yes
```

**Step 3: Verify on live dashboard**

1. Open mileage page
2. Find Karo-Lyn Fauchon, Feb 26 — should see 2 trips instead of 1
3. Expand a trip with stops — should see orange/red stop markers
4. Click a stop marker — should show duration and time range
5. Legend should show "X arrêt(s) détecté(s)" with category breakdown
