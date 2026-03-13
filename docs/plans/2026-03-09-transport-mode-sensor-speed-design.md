# Transport Mode Classification — Sensor Speed

**Date:** 2026-03-09
**Status:** Approved

## Problem

`classify_trip_transport_mode` uses calculated speed (distance/time) instead of GPS sensor speed. This misclassifies ~83 driving trips (13%) that are actually walking (max GPS speed < 6 km/h).

## Solution

### 1. New `classify_trip_transport_mode` logic (SQL migration)

Use `gps_points.speed` (m/s) from trip GPS points:
- Max speed > 4.2 m/s (15 km/h) → `driving`
- Max speed < 1.7 m/s (6 km/h) → `walking`
- Gray zone (6–15 km/h): >70% of moving points < 1.7 m/s → `walking`, else `driving`
- Fallback to current calculated logic if no sensor speed data (pre-Feb 2026 data)

### 2. One-shot reclassification (same migration)

UPDATE trips SET transport_mode = classify_trip_transport_mode(id) for all driving trips where max sensor speed < 6 km/h.

### 3. Dashboard icon fix

`day-approval-detail.tsx` line 1152: show neutral icon for `unknown` transport mode instead of defaulting to car.
