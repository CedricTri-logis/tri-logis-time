# GPS Point Clustering on Trip Map — Design

## Goal

When multiple GPS points are co-located on the trip route map (vehicle stopped), visually cluster them into a single enlarged marker showing the point count and stop duration, instead of overlapping individual dots.

## Current State

- Each GPS point renders as a small circle (radius 4) colored by speed
- Stop markers (orange/red) appear for stops >= 60 seconds via `detectTripStops`
- When 5+ points overlap at the same location, they stack invisibly — user can't tell how long the vehicle was there

## Design

### Clustering Algorithm

Reuse the same spatial logic as `detectTripStops` but with a lower duration threshold:

- **Sensor speed threshold**: < 0.28 m/s (same as stop detection)
- **Spatial radius**: 50m (same as stop detection)
- **GPS noise suppression**: speed < 3 m/s within radius (same)
- **Minimum duration**: 10 seconds (vs 60s for stop markers) — captures red lights
- **Minimum points**: 2

Output: array of `GpsCluster` objects with centroid position, time range, duration, point count.

### Visual Rendering

- **Circle**: radius ~18 (larger than individual points at 4)
- **Color by duration**: yellow (< 30s), orange (30s–3min), red (> 3min)
- **Label**: white text showing point count (e.g., "5")
- **zIndex**: 15 (above individual GPS points at 10, below stop markers at 20)
- **Click**: opens InfoWindow with duration, time range (HH:mm:ss – HH:mm:ss), point count

### Relationship with Stop Markers

- Stop markers (>= 60s) remain at zIndex 20, unchanged
- Clusters < 60s render as cluster markers at zIndex 15
- **No duplicates**: clusters >= 60s are suppressed (stop marker takes precedence)

### Files to Modify

1. `dashboard/src/lib/utils/detect-trip-stops.ts` — add `detectGpsClusters()` function (same algo, 10s threshold, no category)
2. `dashboard/src/components/trips/google-trip-route-map.tsx` — add `GpsClustersLayer` component
3. `dashboard/src/app/dashboard/mileage/page.tsx` — compute clusters, pass to map

### No Database Changes

Pure client-side visualization using existing GPS point data already fetched on trip row expand.
