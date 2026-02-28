# Activity Timeline — Design Document

**Date**: 2026-02-28
**Feature**: Replace Trajets + Arrêts tabs with unified "Activité" tab in Kilométrage

## Problem

The dashboard's Kilométrage page has separate Trajets and Arrêts tabs. To see an employee's full day (where they went, where they worked), you need to switch between tabs and mentally reconstruct the chronological sequence. There's also no employee or date filter on the Trajets tab.

## Solution

A single **"Activité"** tab that merges trips and stationary clusters into a chronological timeline for one employee at a time.

## Tab Structure

**Before**: Trajets | Arrêts | Véhicules | Covoiturages
**After**: **Activité** | Véhicules | Covoiturages

Batch actions (Process Pending, Reprocess Failed, Reprocess All, Rematch Locations) move to a global "Actions" dropdown button at the top-right of the page, accessible from any tab.

## Filters

| Filter | Type | Default | Notes |
|--------|------|---------|-------|
| Employé | Dropdown (required) | — | No "Tous" option; must select one employee |
| Date | Date picker + < > arrows | Today | Toggle to switch to date range (from/to) |
| Type | Chips: Tout / Trajets / Arrêts | Tout | "Trajets" filter recreates the mileage-review workflow |
| Durée min (arrêts) | Dropdown: 3/5/10/15/30 min | 5 min | Only visible when Type = Tout or Arrêts |
| Vue | Toggle: Tableau / Timeline | Tableau | |

## Data Model

Trips already reference `start_cluster_id` and `end_cluster_id` (migration 060), creating a natural sequence:

```
Cluster A (stop) → Trip (A→B) → Cluster B (stop) → Trip (B→C) → Cluster C (stop)
```

Edge cases:
- Clock-in while moving → first trip has no start cluster
- Clock-out while moving → last trip has no end cluster

## Backend

### New RPC: `get_employee_activity`

**Parameters**:
- `p_employee_id UUID` (required)
- `p_date_from DATE` (required)
- `p_date_to DATE` (required)
- `p_type TEXT DEFAULT 'all'` — 'all', 'trips', 'stops'
- `p_min_duration_seconds INT DEFAULT 300`

**Returns**: Array of records sorted by `started_at`, each containing:

For trips (`type = 'trip'`):
- id, started_at, ended_at
- start/end latitude, longitude, address
- start/end location_id, location_name (JOIN locations)
- start/end cluster_id
- distance_km, road_distance_km, duration_minutes
- transport_mode, match_status, match_confidence
- route_geometry (polyline6)

For stops (`type = 'stop'`):
- id, started_at, ended_at
- centroid_latitude, centroid_longitude, centroid_accuracy
- duration_seconds, gps_point_count
- matched_location_id, matched_location_name (JOIN locations)

**Implementation**: `UNION ALL` of trips query + stationary_clusters query, `ORDER BY started_at`.

### Existing RPCs (kept for drill-down)
- `get_cluster_gps_points(p_cluster_id)` — GPS points for a stop
- Trip GPS points — direct query on `gps_points` table filtered by trip time range

## Vue Tableau

**Columns**:

| Column | Description |
|--------|-------------|
| Type | Icon: car (driving trip), walk (walking trip), pin (stop) |
| Début | Start time (HH:mm) |
| Fin | End time (HH:mm) |
| Durée | Formatted duration ("25 min", "2h 15min") |
| Détails | Trip: "Bureau A → Client B" / Stop: "Bureau A" or "Non associé" |
| Distance | Trip: GPS + route distance / Stop: — |
| Statut | Trip: match status badge / Stop: matched/unmatched badge |

**Stats bar** (top):
- Total events count, trips count, stops count
- Total distance (GPS km + route km)
- Total travel time vs total stop time

**Row expand**:
- Trip → Google Maps with GPS trace, route geometry, full trip details (speed, confidence, etc.), location picker for manual assignment
- Stop → Google Maps with cluster centroid, individual GPS points, accuracy circles

## Vue Timeline

Vertical timeline with stacked cards:

- **Card structure**: colored left border + time + type icon + details
- **Colors**: Blue = trip, Green = stop with matched location, Orange = stop unmatched
- **Line**: vertical connector between cards
- **Expand**: clicking a card opens the same detail view as table expand (GPS map + details)
- **Date range mode**: day separators ("Mardi 25 février", "Mercredi 26 février")

## Migration

- New migration (077): `get_employee_activity` RPC
- No new tables needed

## Component Structure

```
MileagePage
├─ Global Actions dropdown (Process Pending, Reprocess, Rematch)
├─ Tab: "Activité"
│  └─ ActivityTab
│     ├─ FilterBar (employee, date, type chips, min duration, view toggle)
│     ├─ StatsBar (counts, distances, times)
│     ├─ ActivityTable (when view = tableau)
│     │  └─ ActivityRow (expandable)
│     │     ├─ TripDetail (map + details) — reuses existing TripRow expand logic
│     │     └─ StopDetail (map + GPS points) — reuses existing cluster detail logic
│     └─ ActivityTimeline (when view = timeline)
│        └─ TimelineCard (expandable, same detail components)
├─ Tab: "Véhicules" (unchanged)
└─ Tab: "Covoiturages" (unchanged)
```
