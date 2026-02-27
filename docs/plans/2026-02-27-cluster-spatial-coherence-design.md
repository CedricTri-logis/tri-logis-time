# Cluster Spatial Coherence — Design

## Problem

`detect_trips` accumulates stopped GPS points into a pre-trip stationary cluster without checking spatial coherence. When an employee walks slowly (~1 m/s, ~3.6 km/h) between two locations:

1. Walking speed never reaches the trip-start threshold (8 km/h) → no trip is created
2. Walking points fall through the state machine (NOT stopped, NOT in trip, speed < 8 km/h) → invisible
3. Stopped points at the new location are appended to the **same** cluster as the old location
4. The accuracy-weighted centroid lands **between** the two locations — where nobody ever was

**Real example**: Ginette walks 285m from 110 Mgr-Tessier to 151 Principale in 6 minutes. `detect_trips` creates a single cluster whose centroid falls on IRIS Optométristes (130m from both actual locations). All 145 GPS points are 100-200m from the centroid.

## Solution: Spatial coherence check in cluster accumulation

### Formula

When a stopped point is about to be added to an existing pre-trip cluster, check:

```
GREATEST(haversine(cluster_centroid, point) - point.accuracy, 0) > 50
```

- `haversine(cluster_centroid, point)`: raw distance from the running centroid to the new point
- `- point.accuracy`: subtract the GPS accuracy radius (the point could be this much closer than reported)
- `GREATEST(..., 0)`: clamp negative values to 0 (high accuracy = uncertain, can't conclude drift)
- `> 50m`: threshold for split

This formula ensures that even accounting for worst-case GPS error toward the centroid, the point is genuinely beyond 50m.

### Validated against real data

Ginette's shift (2026-02-27, cluster `574b6060-8287-4370-88f8-e901c3e4b20f`):

| Phase | Time | Location | Behavior |
|-------|------|----------|----------|
| Cluster 1 | 17:19 → 18:03 | 110 Mgr-Tessier | ~30 stopped points, all within 15m of centroid |
| Walking (unclaimed) | 18:05 → 18:09 | Transit | 16 points, speed ~1 m/s, fall through state machine |
| SPLIT TRIGGER | 18:09:57 | Brief stop | speed=0.08 m/s, 286m from cluster 1, adjusted 278m >> 50m |
| Cluster 2 | 18:09 → 19:10 | 151 Principale | Stopped points, 15-58m from new centroid |

Edge cases validated:
- GPS jitter during stationary (speed=1.26, 15m from centroid, acc=13m): `15 - 13 = 2m` → no split ✓
- High-accuracy point far away (286m, acc=8m): `286 - 8 = 278m` → split ✓
- Low-accuracy point far away (315m, acc=377m): `GREATEST(315 - 377, 0) = 0` → no split ✓

### When split triggers

1. **Finalize current cluster** — same code as existing "finalize pre-trip cluster" (lines 366-421 of migration 061)
2. **Create a trip** from `v_unclaimed_point_ids` (points that fell through the state machine between the two clusters)
   - Start: last point of cluster 1
   - End: the point that triggered the split (first point of cluster 2)
   - Transport mode: classified by existing `classify_trip_transport_mode`
   - Existing filters apply: displacement min 100m for walking, 500m for driving, ghost trip filters
3. **Start a new cluster** with the split-triggering point

### New state variable

`v_unclaimed_point_ids UUID[]` — collects points that fall through the state machine (NOT stopped, NOT in_trip, speed < movement_speed). Reset to `'{}'` whenever a stopped point is successfully added to the cluster (within distance threshold).

### What does NOT change

- Speed thresholds: `v_movement_speed = 8.0`, `v_sensor_stop_threshold = 0.28`
- In-trip logic (PATH 2, PATH 3)
- Accuracy-weighted centroid formula for clusters
- Ghost trip filters
- Transport mode classification
- GPS fields used (no new sensor fields needed — `activity_type`, `heading` etc. not required)

### Migration

Single migration (064) replacing `detect_trips` with the spatial coherence check added to the pre-trip cluster accumulation block.

### Re-detection

After deploying, run `detect_trips` on affected shifts to re-detect with the fix. The function already handles re-runs (deletes previous trips/clusters for the shift).
