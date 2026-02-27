# Suggested Locations Improvements Design

**Date:** 2026-02-27
**Features:** Existing locations on suggestions map, ignore clusters, re-match on create

## 1. Existing Locations Overlay on Suggestions Map

Display all active locations on the `SuggestedLocationsMap` so admins can see proximity between suggestions and existing geofences.

- Circles colored by location type (opacity ~0.3) showing geofence radius
- Markers with type icon at center
- Non-interactive (no click, no InfoWindow) — visual context only
- Data from `useActiveLocations()` hook (already available)

## 2. Ignore Suggestion Clusters

### Database

**Table `ignored_location_clusters`** (migration 053):
- `id` UUID PK DEFAULT gen_random_uuid()
- `centroid_latitude` DOUBLE PRECISION NOT NULL
- `centroid_longitude` DOUBLE PRECISION NOT NULL
- `occurrence_count_at_ignore` INTEGER NOT NULL
- `ignored_at` TIMESTAMPTZ DEFAULT now()
- `ignored_by` UUID REFERENCES auth.users(id)

RLS: admin/super_admin only (INSERT, SELECT, DELETE).

**RPC `ignore_location_cluster(p_lat, p_lng, p_occurrence_count)`:**
- Inserts into `ignored_location_clusters`
- Returns the new row id

### Filtering Logic

Modify `get_unmatched_trip_clusters` RPC:
- After aggregation, LEFT JOIN with `ignored_location_clusters` using `ST_DWithin(centroid, ignored_centroid, 150m)`
- Exclude clusters where a match exists AND `occurrence_count <= occurrence_count_at_ignore`
- Clusters with more occurrences than when ignored → re-surface with full history

### Re-appearance

When a new trip stop occurs in an ignored zone:
- The cluster's `occurrence_count` increases beyond `occurrence_count_at_ignore`
- The filter condition fails → cluster reappears in suggestions
- All historical occurrences are included (not just new ones)

### UI

- "Ignorer" button next to "Creer" on each suggestion card
- Calls `ignore_location_cluster` RPC
- Optimistic removal from the list

## 3. Re-match Trips After Location Creation

**New RPC `rematch_trips_near_location(p_location_id UUID)`:**
- Fetches the location's coordinates and radius
- Finds trips where `start_location_id IS NULL` and start point is within radius → updates `start_location_id`
- Finds trips where `end_location_id IS NULL` and end point is within radius → updates `end_location_id`
- Skips trips with `match_method = 'manual'`
- Returns count of matched endpoints

### Integration

- Called automatically after creating a location from the Suggested tab
- After re-match completes, refresh the suggestions list (clusters matched to the new location disappear)
- Only triggered from Suggested tab creation flow (not from regular location creation)

## Files to Modify

| File | Change |
|------|--------|
| `supabase/migrations/053_ignore_clusters_and_rematch.sql` | New table, ignore RPC, rematch RPC, modified get_unmatched_trip_clusters |
| `dashboard/src/components/locations/suggested-locations-map.tsx` | Add existing locations overlay (circles + markers) |
| `dashboard/src/components/locations/suggested-locations-tab.tsx` | Add ignore button, call rematch after create, pass locations data |
| `dashboard/src/app/dashboard/locations/page.tsx` | Pass active locations to SuggestedLocationsTab |
| `dashboard/src/lib/hooks/use-locations.ts` | Add `useIgnoreCluster()` and `useRematchForLocation()` hooks |
