# Cluster-Trip Continuity - Design Document

**Date:** 2026-03-07
**Status:** Approved

## Problem

The activity timeline has gaps: consecutive clusters (stops) without any trip between them (169 out of 655 pairs). Also, movements between clock-in/out and the first/last cluster are invisible. Trip location names sometimes mismatch the surrounding stops (e.g., "Parking 29 Perreault-E" vs "151-159 Principale").

## Design Decisions

### 1. Synthetic trips for all missing cluster pairs

- `detect_trips` post-processing inserts a trip with `has_gps_gap=true`, `gps_point_count=0` for every consecutive cluster pair without a trip
- **No minimum distance filter** -- if two clusters exist, the movement happened (even 50m)
- Coordinates come from cluster centroids
- `match_status='pending'` so OSRM route estimation runs automatically

### 2. detect_trips only on completed shifts

- Remove the active-shift trip detection logic entirely
- No feature needs trips during an active shift (monitoring uses raw GPS points)
- Eliminates wasted computation, race conditions, and code complexity (`v_create_clusters` branching)

### 3. OSRM route estimation for trips without GPS

Three scenarios for route matching:

| Scenario | GPS points | OSRM call | Result |
|----------|-----------|-----------|--------|
| Normal trip | Full trace | `/match` | Snapped route |
| Trip with GPS gap | Partial trace | `/match` + `/route` for gaps | Composite: real + estimated |
| Synthetic trip | 0 points | `/route` (A to B shortest) | Estimated route |

- Composite geometry stores which segments are real vs estimated
- Distance shown as: `"18.3 km (dont 4.2 km estimes)"`
- Edge Function detects trip type and calls appropriate OSRM endpoint

### 4. Clock-in/out gap entries

- `get_employee_activity` emits `activity_type='gap'` rows when:
  - Clock-in > 60 sec before first cluster AND locations differ
  - Clock-out > 60 sec after last cluster AND locations differ
- Same treatment in `get_day_approval_detail` with `auto_status='needs_review'`
- Displayed with clock-in/clock-out icons
- These are query-time virtual rows (not stored in trips table) -- avoids polluting mileage data with commutes

### 5. Remove from/to location names on trip rows

- **Dashboard timeline (activity tab + approvals):** trip rows show only duration, distance, transport mode, GPS gap warning
- The stops above/below already provide location context
- **PDF/CSV reports:** keep from/to names (no visual timeline context)
- Eliminates the mismatch problem entirely (Parking vs Bureau)

### 6. Two visual styles for trips

- **Solid line:** trip with full GPS trace (normal)
- **Amber/dashed:** trip without GPS or partial GPS (synthetic, with gap, clock gap)
- On the map: real GPS trace = solid blue line, estimated OSRM route = dashed line

### 7. Approval workflow

- Synthetic trips and clock gaps get `auto_status='needs_review'`
- Supervisor validates before they count in mileage
- Once approved, included in reports normally with "(estime)" mention

## Out of Scope

- Splitting clusters that have GPS gaps at different matched locations (edge case; the current cluster detection already handles this for gaps > 15 min)
- Mobile app changes (Flutter) -- this is dashboard + backend only
- Changes to the monitoring real-time view

## Migration Plan

| Migration | Purpose |
|-----------|---------|
| 129 | `detect_trips`: remove active-shift detection + add synthetic trip post-processing |
| 130 | `get_employee_activity`: clock-in/out gap entries |
| 131 | `get_day_approval_detail`: clock-in/out gap entries |
| 132 | Edge Function: OSRM `/route` for synthetic trips + composite for gap trips |
| 133 | Backfill: re-run detect_trips on all completed shifts |

| Dashboard File | Change |
|----------------|--------|
| `activity-tab.tsx` | Render `'gap'` type, remove from/to on trips, amber/dashed style |
| `day-approval-detail.tsx` | Same gap rendering + approval integration |
