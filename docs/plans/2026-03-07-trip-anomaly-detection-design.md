# Trip Anomaly Detection Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Detect trips that don't make sense (excessive detour, unrealistic speed, abnormal distance/duration) and flag them for supervisor review in the approval tab.

**Architecture:** Two-tier anomaly detection. Tier 1 (known-to-known trips): OSRM computes the expected route between two known location coordinates; flag if actual exceeds 2x expected. Tier 2 (unknown endpoints): absolute thresholds on distance, duration, speed, and detour ratio. Both tiers feed into the existing `needs_review` classification in `get_day_approval_detail` and `get_weekly_approval_summary`.

**Tech Stack:** PostgreSQL (Supabase migrations), TypeScript/Deno (Supabase Edge Functions), OSRM routing API

---

## Context

**Key files:**
- `supabase/functions/_shared/osrm-matcher.ts` — OSRM shared utilities (`routeTripDirect`, `matchTripToRoad`, `storeMatchResult`)
- `supabase/functions/batch-match-trips/index.ts` — Batch OSRM matching edge function
- SQL function `get_day_approval_detail` — Trip/stop/clock classification for approval detail (latest: uses `to_business_date`, `business_day_start/end`)
- SQL function `get_weekly_approval_summary` — Summary grid classification (mirrors daily detail logic)
- SQL function `update_trip_match` — RPC to store match results on trips table

**Existing trips columns:** `distance_km`, `road_distance_km`, `duration_minutes`, `start_latitude/longitude`, `end_latitude/longitude`, `start_location_id`, `end_location_id`, `has_gps_gap`, `match_status`, `transport_mode`

**Existing locations columns:** `id`, `latitude`, `longitude`, `location_type`, `name`

**SQL function `haversine_km(lat1, lon1, lat2, lon2)`** already exists.

---

### Task 1: Schema Migration — Add expected route columns to trips

**Files:**
- Create: `supabase/migrations/128_trip_anomaly_detection.sql`

**Step 1: Write the migration**

```sql
-- Migration 128: Trip Anomaly Detection — Expected route columns
-- Stores OSRM-computed expected distance and duration for known-to-known trips.
-- Used by get_day_approval_detail to flag anomalous trips.

ALTER TABLE trips
    ADD COLUMN IF NOT EXISTS expected_distance_km DECIMAL(8, 3),
    ADD COLUMN IF NOT EXISTS expected_duration_seconds INTEGER;

COMMENT ON COLUMN trips.expected_distance_km IS 'OSRM optimal road distance between start and end locations (NULL if either endpoint unknown)';
COMMENT ON COLUMN trips.expected_duration_seconds IS 'OSRM estimated travel time in seconds between start and end locations (NULL if either endpoint unknown)';
```

**Step 2: Apply the migration**

Run via Supabase MCP `apply_migration` or `execute_sql`.

**Step 3: Verify columns exist**

```sql
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'trips'
  AND column_name IN ('expected_distance_km', 'expected_duration_seconds');
```

Expected: 2 rows, both nullable.

**Step 4: Commit**

```bash
git add supabase/migrations/128_trip_anomaly_detection.sql
git commit -m "feat: add expected_distance_km and expected_duration_seconds to trips table"
```

---

### Task 2: Update `routeTripDirect` to return duration

**Files:**
- Modify: `supabase/functions/_shared/osrm-matcher.ts`

**Step 1: Add `duration_seconds` to `MatchResult` interface**

In `osrm-matcher.ts`, update the `MatchResult` interface (line ~10-18):

```typescript
export interface MatchResult {
  success: boolean;
  match_status: "matched" | "failed" | "anomalous";
  route_geometry: string | null;
  road_distance_km: number | null;
  duration_seconds: number | null;       // NEW
  match_confidence: number | null;
  match_error: string | null;
  geometry_points: number;
}
```

**Step 2: Update `routeTripDirect` to capture duration**

In the `routeTripDirect` function (line ~152-200), after `const roadDistanceKm = route.distance / 1000;` add:

```typescript
  const durationSeconds = Math.round(route.duration);
```

And update both return statements to include `duration_seconds`:

Failure return (~line 163):
```typescript
      duration_seconds: null,
```

Success return (~line 191):
```typescript
      duration_seconds: durationSeconds,
```

**Step 3: Update `matchTripToRoad` to include `duration_seconds`**

In the `matchTripToRoad` function, update all return statements to include `duration_seconds: null` (the matched route duration is not the same as the expected optimal route duration — we compute expected separately).

All 4 return statements in `matchTripToRoad` get:
```typescript
      duration_seconds: null,
```

**Step 4: Verify `storeMatchResult` still works**

The `storeMatchResult` function calls `update_trip_match` RPC which doesn't use `duration_seconds` — it passes through `match_status`, `route_geometry`, `road_distance_km`, `match_confidence`, `match_error`. The new field is ignored by the RPC, so no changes needed there.

**Step 5: Commit**

```bash
git add supabase/functions/_shared/osrm-matcher.ts
git commit -m "feat: add duration_seconds to MatchResult interface and routeTripDirect"
```

---

### Task 3: Update `batch-match-trips` to compute expected route

**Files:**
- Modify: `supabase/functions/batch-match-trips/index.ts`

**Step 1: Fetch location IDs with trip details**

Update the trip select query (~line 150) to include location IDs:

```typescript
        const { data: trip, error: tripError } = await supabase
          .from("trips")
          .select("id, distance_km, match_attempts, match_status, transport_mode, gps_point_count, start_latitude, start_longitude, end_latitude, end_longitude, started_at, ended_at, start_location_id, end_location_id")
          .eq("id", tripId)
          .single();
```

**Step 2: Add expected route computation function**

Add this function before the `serve()` call (after the `delay` function, ~line 25):

```typescript
async function computeExpectedRoute(
  supabase: SupabaseClient,
  tripId: string,
  startLocationId: string,
  endLocationId: string
): Promise<void> {
  // Fetch location coordinates
  const { data: locations, error } = await supabase
    .from("locations")
    .select("id, latitude, longitude")
    .in("id", [startLocationId, endLocationId]);

  if (error || !locations || locations.length < 2) return;

  const startLoc = locations.find((l: { id: string }) => l.id === startLocationId);
  const endLoc = locations.find((l: { id: string }) => l.id === endLocationId);
  if (!startLoc || !endLoc) return;

  const osrmUrl = selectOsrmUrlForCoords(startLoc.latitude, startLoc.longitude);
  if (!osrmUrl) return;

  const result = await routeTripDirect(
    startLoc.latitude, startLoc.longitude,
    endLoc.latitude, endLoc.longitude,
    osrmUrl
  );

  if (result.success && result.road_distance_km != null && result.duration_seconds != null) {
    await supabase
      .from("trips")
      .update({
        expected_distance_km: result.road_distance_km,
        expected_duration_seconds: result.duration_seconds,
      })
      .eq("id", tripId);
  }
}
```

Add the import for `SupabaseClient`:

```typescript
import { type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
```

**Step 3: Call `computeExpectedRoute` after each successful match**

After each `storeMatchResult(supabase, tripId, ...)` call AND after each direct update that sets `match_status = 'matched'`, add:

```typescript
        // Compute expected route for known-to-known trips
        if (trip.start_location_id && trip.end_location_id) {
          try {
            await computeExpectedRoute(supabase, tripId, trip.start_location_id, trip.end_location_id);
          } catch (e) {
            console.error(`Expected route computation failed for trip ${tripId}:`, e);
          }
        }
```

Insert this in 3 places:
1. After the synthetic driving trip `routeTripDirect` + `storeMatchResult` (~line 273)
2. After the main `matchTripToRoad` + `storeMatchResult` (~line 334)
3. After the walking trip update (~line 252) — skip this one, walking trips don't need expected routes

**Step 4: Commit**

```bash
git add supabase/functions/batch-match-trips/index.ts
git commit -m "feat: compute OSRM expected route for known-to-known trips in batch-match"
```

---

### Task 4: Update `get_day_approval_detail` with anomaly detection

**Files:**
- Create: `supabase/migrations/128_trip_anomaly_detection.sql` (append to Task 1's migration)

**Step 1: Write the updated function**

Replace the trip classification CASE statements in `get_day_approval_detail`. The key change is in the TRIPS section of the `activity_data` CTE.

Current auto_status CASE for trips:
```sql
CASE
    WHEN t.has_gps_gap = TRUE THEN 'needs_review'
    WHEN t.duration_minutes > 60 THEN 'needs_review'
    WHEN ... IN ('office', 'building') AND ... IN ('office', 'building') THEN 'approved'
    WHEN ... IN ('home', ...) OR ... IN ('home', ...) THEN 'rejected'
    WHEN ... IS NULL OR ... IS NULL THEN 'needs_review'
    ELSE 'needs_review'
END
```

New auto_status CASE (with anomaly detection):
```sql
CASE
    -- GPS gap always needs review
    WHEN t.has_gps_gap = TRUE THEN 'needs_review'

    -- TIER 1: Both endpoints are known approved locations
    WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('office', 'building', 'vendor', 'gaz')
     AND COALESCE(el.location_type, arr_loc.location_type) IN ('office', 'building', 'vendor', 'gaz') THEN
        CASE
            -- Anomaly: distance > 2x expected (if expected is known)
            WHEN t.expected_distance_km IS NOT NULL
             AND t.distance_km > 2.0 * t.expected_distance_km THEN 'needs_review'
            -- Anomaly: duration > 2x expected (if expected is known)
            WHEN t.expected_duration_seconds IS NOT NULL
             AND t.duration_minutes > 2.0 * (t.expected_duration_seconds / 60.0) THEN 'needs_review'
            ELSE 'approved'
        END

    -- Either endpoint at rejected location
    WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('home', 'cafe_restaurant', 'other')
      OR COALESCE(el.location_type, arr_loc.location_type) IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'

    -- TIER 2: At least one endpoint unknown — apply absolute thresholds
    WHEN t.duration_minutes > 30 THEN 'needs_review'
    WHEN t.distance_km > 10 THEN 'needs_review'
    WHEN haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) > 0.1
     AND t.distance_km / GREATEST(haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude), 0.01) > 2.0
        THEN 'needs_review'
    WHEN haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) > 2.0
     AND haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude)
         / GREATEST(t.duration_minutes / 60.0, 0.01) > 130
        THEN 'needs_review'
    WHEN haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) > 2.0
     AND haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude)
         / GREATEST(t.duration_minutes / 60.0, 0.01) < 5
        THEN 'needs_review'

    -- Fallback for unknown endpoints
    WHEN COALESCE(sl.location_type, dep_loc.location_type) IS NULL
      OR COALESCE(el.location_type, arr_loc.location_type) IS NULL THEN 'needs_review'

    ELSE 'needs_review'
END
```

New auto_reason CASE (with descriptive messages):
```sql
CASE
    WHEN t.has_gps_gap = TRUE THEN 'Donnees GPS incompletes'

    -- TIER 1 reasons
    WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('office', 'building', 'vendor', 'gaz')
     AND COALESCE(el.location_type, arr_loc.location_type) IN ('office', 'building', 'vendor', 'gaz') THEN
        CASE
            WHEN t.expected_distance_km IS NOT NULL
             AND t.distance_km > 2.0 * t.expected_distance_km
                THEN 'Detour excessif : ' || ROUND(t.distance_km, 1) || ' km parcourus vs ' || ROUND(t.expected_distance_km, 1) || ' km attendus'
            WHEN t.expected_duration_seconds IS NOT NULL
             AND t.duration_minutes > 2.0 * (t.expected_duration_seconds / 60.0)
                THEN 'Trajet trop long : ' || t.duration_minutes || ' min vs ' || ROUND(t.expected_duration_seconds / 60.0) || ' min attendues'
            ELSE 'Deplacement professionnel'
        END

    WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('home', 'cafe_restaurant', 'other')
      OR COALESCE(el.location_type, arr_loc.location_type) IN ('home', 'cafe_restaurant', 'other') THEN 'Trajet personnel'

    -- TIER 2 reasons
    WHEN t.duration_minutes > 30 THEN 'Trajet de plus de 30 min (' || t.duration_minutes || ' min)'
    WHEN t.distance_km > 10 THEN 'Trajet de plus de 10 km (' || ROUND(t.distance_km, 1) || ' km)'
    WHEN haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) > 0.1
     AND t.distance_km / GREATEST(haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude), 0.01) > 2.0
        THEN 'Detour excessif (ratio ' || ROUND(t.distance_km / GREATEST(haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude), 0.01), 1) || 'x)'
    WHEN haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) > 2.0
     AND haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude)
         / GREATEST(t.duration_minutes / 60.0, 0.01) > 130
        THEN 'Vitesse irrealiste (' || ROUND(haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) / GREATEST(t.duration_minutes / 60.0, 0.01)) || ' km/h)'
    WHEN haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) > 2.0
     AND haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude)
         / GREATEST(t.duration_minutes / 60.0, 0.01) < 5
        THEN 'Trajet anormalement lent (' || ROUND(haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) / GREATEST(t.duration_minutes / 60.0, 0.01)) || ' km/h)'

    WHEN COALESCE(sl.location_type, dep_loc.location_type) IS NULL
      OR COALESCE(el.location_type, arr_loc.location_type) IS NULL THEN 'Destination inconnue'

    ELSE 'A verifier'
END
```

The full `CREATE OR REPLACE FUNCTION get_day_approval_detail(...)` must be written in the migration, preserving the existing structure (stops, clock-in, clock-out sections unchanged) and only modifying the TRIPS section's auto_status and auto_reason CASE statements.

**Step 2: Apply the migration**

Run via Supabase MCP.

**Step 3: Test with a known trip**

```sql
SELECT get_day_approval_detail(
    '<employee_id_with_trips>'::UUID,
    '2026-03-06'::DATE
);
```

Verify that trips between known locations show 'approved' or 'needs_review' with anomaly reasons, and trips with unknown endpoints show absolute threshold reasons.

**Step 4: Commit**

```bash
git add supabase/migrations/128_trip_anomaly_detection.sql
git commit -m "feat: add anomaly detection to get_day_approval_detail"
```

---

### Task 5: Update `get_weekly_approval_summary` with matching logic

**Files:**
- Modify: `supabase/migrations/128_trip_anomaly_detection.sql` (append)

**Step 1: Update the trip classification in the weekly summary**

The `live_activity_classification` CTE in `get_weekly_approval_summary` has a simpler trip classification. Update it to mirror the daily detail anomaly logic.

Current:
```sql
CASE
    WHEN t.has_gps_gap = TRUE THEN 'needs_review'
    WHEN t.duration_minutes > 60 THEN 'needs_review'
    WHEN ... IN ('office', 'building') AND ... IN ('office', 'building') THEN 'approved'
    WHEN ... IN ('home', ...) OR ... IN ('home', ...) THEN 'rejected'
    ELSE 'needs_review'
END
```

New (same anomaly logic, no reason strings needed since summary only uses status):
```sql
CASE
    WHEN t.has_gps_gap = TRUE THEN 'needs_review'
    WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('office', 'building', 'vendor', 'gaz')
     AND COALESCE(el.location_type, arr_loc.location_type) IN ('office', 'building', 'vendor', 'gaz') THEN
        CASE
            WHEN t.expected_distance_km IS NOT NULL AND t.distance_km > 2.0 * t.expected_distance_km THEN 'needs_review'
            WHEN t.expected_duration_seconds IS NOT NULL AND t.duration_minutes > 2.0 * (t.expected_duration_seconds / 60.0) THEN 'needs_review'
            ELSE 'approved'
        END
    WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('home', 'cafe_restaurant', 'other')
      OR COALESCE(el.location_type, arr_loc.location_type) IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
    WHEN t.duration_minutes > 30 THEN 'needs_review'
    WHEN t.distance_km > 10 THEN 'needs_review'
    WHEN haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) > 0.1
     AND t.distance_km / GREATEST(haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude), 0.01) > 2.0
        THEN 'needs_review'
    WHEN haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) > 2.0
     AND haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude)
         / GREATEST(t.duration_minutes / 60.0, 0.01) > 130 THEN 'needs_review'
    WHEN haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) > 2.0
     AND haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude)
         / GREATEST(t.duration_minutes / 60.0, 0.01) < 5 THEN 'needs_review'
    ELSE 'needs_review'
END
```

**Step 2: Apply and verify**

Same as Task 4.

**Step 3: Commit**

```bash
git add supabase/migrations/128_trip_anomaly_detection.sql
git commit -m "feat: add anomaly detection to get_weekly_approval_summary"
```

---

### Task 6: Deploy edge functions

**Step 1: Deploy updated edge functions**

```bash
cd supabase
supabase functions deploy batch-match-trips
supabase functions deploy route-between-points
```

**Step 2: Backfill expected routes for existing known-to-known trips**

Call the batch-match-trips edge function with `reprocess_all: true` to recompute expected routes for all existing trips:

```bash
curl -X POST 'https://xdyzdclwvhkfwbkrdsiz.supabase.co/functions/v1/batch-match-trips' \
  -H 'Authorization: Bearer <service_role_key>' \
  -H 'Content-Type: application/json' \
  -d '{"reprocess_all": true, "limit": 500}'
```

**Step 3: Verify end-to-end**

Check a day approval detail for an employee with trips between known locations:
```sql
SELECT get_day_approval_detail('<employee_id>'::UUID, '<date>'::DATE);
```

Verify:
- Trips between known locations with `expected_distance_km` set: `approved` if normal, `needs_review` with descriptive reason if anomalous
- Trips with unknown endpoints: `needs_review` if > 10 km, > 30 min, detour > 2x, or speed anomaly
- Existing behavior preserved for stops, clock events

**Step 4: Commit and push**

```bash
git add -A
git commit -m "feat: deploy trip anomaly detection (edge functions + migration 128)"
git push
```
