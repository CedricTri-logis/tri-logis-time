# Trip Detection Algorithm

## Overview

The `detect_trips(p_shift_id)` PostgreSQL function analyzes GPS points collected during a shift to automatically detect vehicle trips (and walking trips). It processes points chronologically and identifies movement segments separated by stationary periods.

## How It Works

### State Machine

The algorithm is a simple state machine with two states:

```
    ┌─────────────┐    speed >= movement_threshold    ┌───────────┐
    │  NOT IN TRIP │ ──────────────────────────────►  │  IN TRIP  │
    │  (idle)      │                                   │  (moving)  │
    └─────────────┘  ◄──────────────────────────────  └───────────┘
                       stationary for >= 3 minutes
                       OR GPS gap > 15 minutes
```

### Processing Steps

1. **For each GPS point** (ordered by `captured_at`):
   - Calculate haversine distance to previous point
   - Calculate effective speed (distance / time), with GPS accuracy filtering
   - Apply state machine logic

2. **Trip starts** when:
   - Speed exceeds `movement_threshold` (currently 8 km/h)
   - The previous point becomes the trip start

3. **Trip continues** when:
   - Speed >= `stationary_threshold` (currently 3 km/h)
   - Distance and point count accumulate

4. **Trip ends** when:
   - Speed < `stationary_threshold` for >= `stationary_gap` (3 minutes), OR
   - GPS gap > 15 minutes between consecutive points

5. **After trip ends**:
   - Apply 1.3x distance correction factor (roads aren't straight lines)
   - Classify transport mode (driving vs walking) via `classify_trip_transport_mode()`
   - Validate: walking trips need >= 100m displacement, driving trips need >= 500m

### Active vs Completed Shifts

- **Completed shifts**: Full re-detection (delete all trips, re-process all points)
- **Active shifts**: Incremental detection (preserve matched trips, process only new GPS points, don't close the last in-progress trip)

## Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `movement_threshold` | 8 km/h | Speed to start a new trip |
| `stationary_threshold` | 3 km/h | Speed below which a person might be stopped |
| `stationary_gap` | 3 min | How long someone must be stationary to end a trip |
| `gps_gap` | 15 min | Gap between GPS points that forces trip end |
| `min_distance_km` | 0.2 km | Minimum trip distance (all modes) |
| `min_distance_driving` | 0.5 km | Minimum distance for driving trips |
| `min_displacement_walking` | 0.1 km | Minimum straight-line displacement for walking |
| `max_speed` | 200 km/h | Speeds above this are GPS glitches (ignored) |
| `max_accuracy` | 200 m | Points with worse accuracy are skipped |
| `correction_factor` | 1.3 | Multiplier to estimate road distance from haversine |

## GPS Accuracy Filtering

### The Problem

GPS accuracy of 20-80m creates **phantom movement**. A stationary person's GPS coordinates can drift 10-80m between readings, generating calculated speeds of 2-10 km/h that look like slow movement.

### The Solution

**Displacement noise floor**: If the distance between two consecutive points is less than the GPS accuracy of either point, the displacement is treated as noise (effective speed = 0).

```
effective_speed = 0  IF  displacement < MAX(accuracy_A, accuracy_B)
```

**GPS sensor speed cross-check**: When available, the device's GPS sensor speed provides ground truth. If both the current and previous point report sensor speed < 0.5 m/s (1.8 km/h), the algorithm overrides haversine speed to 0, regardless of calculated displacement.

```
effective_speed = 0  IF  gps_speed_A < 0.5 AND gps_speed_B < 0.5
```

These two filters work together: the accuracy filter catches noise from poor GPS, and the sensor speed filter catches cases where accuracy looks good but the person isn't moving.

## Transport Mode Classification

After a trip is detected, `classify_trip_transport_mode()` determines if it's driving or walking:

1. **Trip average speed** (distance / duration):
   - > 10 km/h → driving
   - < 4 km/h → walking

2. **Grey zone** (4-10 km/h): Calculate inter-point speeds via haversine
   - If > 80% of segments < 5 km/h AND distance < 1 km → walking
   - Otherwise → driving (city driving with frequent stops)

## Distance Calculation

- **Haversine distance**: Straight-line distance between consecutive GPS points, summed
- **Correction factor**: × 1.3 to approximate road distance
- **Road distance** (post-matching): OSRM map-matching provides the actual road distance

## Known Limitations

1. **Indoor GPS drift**: Inside buildings, GPS can drift significantly. The accuracy filter mitigates this but doesn't eliminate it entirely.
2. **Very slow driving**: Driving < 8 km/h (parking lots, heavy traffic) won't start a trip until speed picks up.
3. **Short stops**: Stops under 3 minutes are absorbed into the trip as slow segments.
4. **GPS gaps**: If the phone stops reporting GPS for > 15 minutes, the trip is force-ended at the gap boundary.
