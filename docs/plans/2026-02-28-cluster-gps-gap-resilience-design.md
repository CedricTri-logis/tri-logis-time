# Cluster GPS Gap Resilience Design

**Date**: 2026-02-28
**Status**: Approved

## Problem

When GPS signal is lost during a shift (battery optimization, app killed, etc.), the `detect_trips` algorithm splits what should be a single stationary cluster into two separate clusters. For example, an employee at "45_Perreault-E" from 09:29 to 10:35 with a 50-min GPS gap in the middle appears as two 6-min and 9-min stops instead of one 66-min stop.

## Design Decisions

1. **Only a clock-out breaks a cluster.** GPS gaps never split a cluster. If GPS resumes and the next point is within the cluster radius, the cluster continues.
2. **Track GPS gap time per cluster.** New fields `gps_gap_seconds` and `gps_gap_count` on `stationary_clusters` accumulate the total missing GPS time and number of individual gaps.
3. **Gap threshold: 5 minutes.** Stationary mode sends GPS every ~2 min. A gap > 5 min between consecutive points is considered a GPS loss. The excess time (gap - 5 min) is accumulated.
4. **Trips across GPS gaps.** When GPS resumes at a different location, a trip is created with `has_gps_gap = TRUE` flag (no GPS trace available for the route).
5. **Warning badge in UI.** Clusters with `gps_gap_seconds > 0` show a yellow warning triangle with tooltip showing the missing GPS duration.
6. **Backfill historical data.** Re-run `detect_trips` on all existing shifts to merge previously split clusters.

## Schema Changes

### stationary_clusters
```sql
ALTER TABLE stationary_clusters
  ADD COLUMN gps_gap_seconds INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN gps_gap_count INTEGER NOT NULL DEFAULT 0;
```

- `gps_gap_seconds`: total accumulated time (seconds) of GPS gaps > 5 min within the cluster
- `gps_gap_count`: number of individual GPS gaps > 5 min within the cluster

### trips
```sql
ALTER TABLE trips
  ADD COLUMN has_gps_gap BOOLEAN NOT NULL DEFAULT FALSE;
```

- `has_gps_gap`: TRUE when the trip was created across a GPS gap with no/minimal GPS trace

## Algorithm Changes (detect_trips)

### Current behavior (GPS gap > 15 min)
1. Finalize current confirmed cluster
2. Discard tentative cluster
3. Reset all cluster state (lats, lngs, accs, point_ids, timestamps)
4. Next point starts fresh

### New behavior (no gap-based reset)
1. Remove the GPS gap handler that resets cluster state
2. Add gap tracking variables: `v_gap_accumulator INTEGER := 0`, `v_gap_count INTEGER := 0`
3. For each point, compute gap since previous point:
   - If gap > 300 seconds (5 min): `v_gap_accumulator += (gap_seconds - 300)`, `v_gap_count += 1`
4. Core algorithm unchanged: point evaluated against cluster centroid
   - Within radius (50m) -> cluster continues (gap time accumulated)
   - Outside radius -> cluster finalizes with `gps_gap_seconds` and `gps_gap_count` written
5. When creating a trip, if transit buffer is empty/minimal after a GPS gap, set `has_gps_gap = TRUE`

### Gap accumulator reset
- Reset when a new cluster is started (the gap belongs to the previous cluster or inter-cluster period)
- Gap time between clusters (during transit) is not attributed to either cluster

## Activity Timeline Changes

### get_employee_activity RPC
- Add `gps_gap_seconds` and `gps_gap_count` to stop records
- Add `has_gps_gap` to trip records

### Dashboard UI
- **Stops**: Yellow warning triangle icon next to duration when `gps_gap_seconds > 0`, tooltip: "X min sans signal GPS"
- **Trips**: Warning indicator when `has_gps_gap = TRUE`, indicating no GPS trace available

### Flutter App
- Same warning indicators in the employee's activity view (if applicable)

## Backfill Strategy

Re-run `detect_trips` for all completed shifts. The function already handles full re-detection (deletes existing clusters/trips and recreates). The backfill will:
1. Merge previously split clusters at the same location
2. Populate `gps_gap_seconds` and `gps_gap_count` on all clusters
3. Set `has_gps_gap` on trips created across GPS gaps
4. Be executed as part of the migration

## Edge Cases

- **GPS resumes far away**: Cluster finalizes when point is outside radius. Trip created with `has_gps_gap = TRUE`. New cluster starts at new location.
- **Multiple gaps in one cluster**: Each gap > 5 min adds to the accumulator independently. Example: two gaps of 20 min and 10 min = `gps_gap_seconds = (20-5)*60 + (10-5)*60 = 1200`, `gps_gap_count = 2`.
- **Gap during transit**: If GPS is lost while moving (between clusters), the gap time is not attributed to either cluster. The trip gets `has_gps_gap = TRUE`.
- **Very long gap (hours)**: Same treatment. Cluster continues if next point is in radius. The `gps_gap_seconds` will be large, making the warning prominent.
- **Clock-out during gap**: Clock-out finalizes the shift regardless. The cluster ends at the last GPS point before the gap.
