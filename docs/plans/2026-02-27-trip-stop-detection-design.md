# Trip Stop Detection — Design Document

**Date**: 2026-02-27
**Status**: Approved

## Problem

`detect_trips` uses calculated speed (haversine distance / time) to detect when a vehicle is stationary. GPS noise during real stops produces false calculated speeds of 2-5 km/h, preventing the stationary counter from reaching the 3-minute cutoff. This causes trips to not be split at real stops (e.g., Karo-Lyn's 4-minute stop that wasn't detected).

Additionally, stationary GPS points are not included in `trip_gps_points`, making it impossible for the dashboard to detect and visualize stops within trips.

## Research Findings

Industry best practices (Geotab, Traccar) confirm:

- **GPS Doppler speed** (sensor) is orders of magnitude more accurate than position-derived speed at low speeds (cm/s vs m/s accuracy)
- **Spatial radius check** (30-50m) combined with speed threshold prevents false positives from GPS noise
- **Industry thresholds**: Geotab uses < 1 km/h for 200s, Traccar uses ~0 km/h for 180-300s
- **Adaptive GPS frequency** (120s stationary intervals) makes position-derived speed unreliable during stops

## Design

### Part 1: Fix `detect_trips` (SQL migration)

**Replace stationary detection logic** with sensor-speed + spatial radius approach:

- **Speed threshold**: Use `gp.speed` (GPS Doppler) < 0.28 m/s (< 1 km/h) instead of calculated haversine speed
- **Spatial radius**: All points within 50m of first stationary point = confirmed stop, even if momentary GPS speed spikes occur (noise)
- **Cutoff duration**: 3 minutes (unchanged) — confirmed stop >= 3 min splits the trip
- **Include stationary points**: Add stationary points to `v_trip_points` array so they appear in `trip_gps_points`

**Specific changes to detect_trips**:

1. When in a trip and speed drops, use `gp.speed` (sensor) instead of `v_speed` (calculated) to determine if the vehicle is stationary
2. Add spatial radius check: track `v_stationary_center` (lat/lng of first stationary point) and verify all subsequent stationary points are within 50m via haversine
3. If a point has sensor speed >= 1 km/h but is within 50m of stationary center and the calculated speed is low, treat it as stationary (GPS noise suppression)
4. Add stationary points to `v_trip_points` and increment `v_trip_point_count` (but do NOT add their distance to `v_trip_distance`)

### Part 2: Dashboard Stop Visualization

**Update `detect-trip-stops.ts`**:

- Use `trip_gps_points` (now includes stationary points)
- Detection: consecutive points with `speed < 0.28 m/s` (< 1 km/h) OR within 50m radius of cluster centroid with speed < 1 m/s
- Minimum duration: >= 60 seconds (1 minute)
- Categories: moderate (1-3 min, orange #f97316), extended (> 3 min, red #ef4444)
- Display: circle marker at centroid, clickable InfoWindow with duration and time range

**Stop legend** in trip detail panel:
- "X arrêt(s) détecté(s)" with count per category

### Part 3: Re-detection

After migration:
1. Re-detect all trips for completed shifts
2. Trips with previously undetected >= 3 min stops will be correctly split
3. OSRM matching will need to be re-run for affected trips

## Thresholds Summary

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Sensor speed threshold | < 0.28 m/s (1 km/h) | Aligned with Geotab; filters GPS noise |
| Spatial radius | 50m | Captures GPS drift during stops |
| Trip split duration | >= 3 minutes | Existing threshold, unchanged |
| Visual stop minimum | >= 1 minute | Shows red lights, brief stops |
| Visual: moderate | 1-3 min | Orange marker |
| Visual: extended | > 3 min | Red marker |

## Files to Modify

1. `supabase/migrations/052_*.sql` — Updated `detect_trips` function
2. `dashboard/src/lib/utils/detect-trip-stops.ts` — Updated detection algorithm
3. `dashboard/src/components/trips/google-trip-route-map.tsx` — Already has StopsLayer (update colors/thresholds)
4. `dashboard/src/app/dashboard/mileage/page.tsx` — Already wired up (may need threshold updates)

## Verification

1. Re-detect Karo-Lyn's shift from Feb 26 — her trip should now be split into two at the 4-minute stop
2. Expand re-detected trips — stationary points should appear in trip_gps_points
3. Stop markers should appear at correct locations with correct durations
4. Trips without significant stops should remain unchanged
