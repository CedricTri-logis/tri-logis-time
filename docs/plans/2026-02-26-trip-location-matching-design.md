# Trip-to-Location Matching Design

**Date:** 2026-02-26
**Feature:** Match trip origins/destinations to known locations, surface unmatched endpoints for admin review
**Scope:** Supabase migration (RPC changes) + Next.js dashboard (mileage + locations pages)

## Goals

1. **Operational visibility** — see movement patterns between known locations (Bureau -> Chantier X -> Bureau)
2. **Mileage accuracy** — improve reimbursement accuracy by knowing exact origin/destination

## Architecture: In-Database Matching (Approach A)

PostGIS spatial matching inside `detect_trips()` at trip creation time. Clustering RPC for unmatched endpoints. Admin override via dashboard inline dropdown.

## 1. Location Matching Logic

### Spatial matching algorithm

For each trip endpoint (start and end):

1. Query all active locations where the GPS accuracy circle overlaps the location geofence:
   ```sql
   ST_DWithin(
     location.location,                            -- geofence center (geography)
     ST_Point(trip.longitude, trip.latitude)::geography,
     location.radius_meters + gps_accuracy_meters   -- combined tolerance
   )
   ```
2. If multiple locations match (close buildings), pick the **closest** one (shortest `ST_Distance`)
3. If no location matches, leave as NULL (unmatched)

### GPS accuracy integration

- Each trip stores start/end coordinates from the last stationary GPS point
- That GPS point has an `accuracy` field (meters) in `gps_points` table
- Matching radius = `location.radius_meters + gps_point.accuracy`
- A GPS point with 20m accuracy near a location with 50m radius matches within 70m

### Trip continuity

- If Trip N starts within 100m of where Trip N-1 ended (same shift), inherit Trip N-1's `end_location_id` as Trip N's `start_location_id`
- First trip of shift: start location matched from clock-in GPS point
- Prevents GPS drift from assigning different locations to the same physical stop

### Conflict resolution

- When multiple locations overlap, closest by `ST_Distance` wins
- Admin can override via inline dropdown in dashboard
- Manual overrides are preserved during re-matching (`location_match_method = 'manual'`)

## 2. Unmatched Endpoint Clustering

### Clustering approach

PostGIS `ST_ClusterDBSCAN` groups unmatched trip endpoints within **100m** of each other.

### RPC: `get_unmatched_trip_clusters(p_min_occurrences INT DEFAULT 1)`

Returns:
- `cluster_id` (integer)
- `centroid_latitude`, `centroid_longitude`
- `occurrence_count` (how many trip endpoints in cluster)
- `endpoint_type` ('start', 'end', or 'both')
- `employee_names` (text array of employees who visited)
- `first_seen`, `last_seen` (date range)
- `sample_addresses` (from existing trip start_address/end_address)

### Google Maps suggestions

- On-demand client-side: when admin views a cluster in the "Suggested" tab, the dashboard calls Google Maps Geocoding API to get a suggested address/place name
- Uses existing `NEXT_PUBLIC_GOOGLE_MAPS_API_KEY`
- Suggestion pre-fills the "Create Location" form
- No backend Google API calls (keeps costs low, on-demand only)

## 3. Dashboard UI Changes

### Mileage page route column

- **Matched**: `Bureau Tri-Logis -> Chantier Montcalm` (location names with pin icon)
- **Partially matched**: `Bureau Tri-Logis -> 456 Ave Destination` (one name, one address)
- **Unmatched**: `123 Rue Example -> 456 Ave Destination` (addresses with "?" indicator)

### Inline location correction dropdown

- Click location name or "?" to open dropdown
- Shows nearby locations sorted by distance (with distance in meters)
- Includes "None / Unknown" option
- Saving updates `start_location_id` or `end_location_id` via `update_trip_location()` RPC

### Locations page — "Suggested" tab

Three tabs: **Active** | **Inactive** | **Suggested**

Suggested tab contents:
- Map showing cluster markers (circle size proportional to occurrence count)
- List below with clusters sorted by frequency
- Each cluster card: occurrence count badge, Google Maps suggested address, employees who visited, date range
- Actions: "Create Location" (pre-filled form) | "Dismiss"

## 4. Database Changes (Migration 050)

### Modified: `detect_trips(p_shift_id UUID)`

After each trip INSERT, call `match_trip_to_location()` for start and end coordinates. Apply trip continuity logic for consecutive trips.

### New function: `match_trip_to_location(p_lat, p_lng, p_accuracy_meters)`

Reusable helper. Returns closest matching `location_id` (or NULL) using PostGIS `ST_DWithin` with combined tolerance.

### New RPC: `get_unmatched_trip_clusters(p_min_occurrences INT DEFAULT 1)`

Clusters unmatched trip endpoints using `ST_ClusterDBSCAN(eps := 100, minpoints := 1)`.

### New RPC: `update_trip_location(p_trip_id UUID, p_endpoint TEXT, p_location_id UUID)`

Admin override. Sets start or end location. Sets `location_match_method = 'manual'`.

### New RPC: `rematch_all_trip_locations()`

Batch re-match all trips against current locations. Skips trips where `location_match_method = 'manual'`.

### New columns on trips table

- `start_location_match_method TEXT DEFAULT 'auto'` — 'auto' or 'manual'
- `end_location_match_method TEXT DEFAULT 'auto'` — 'auto' or 'manual'

## 5. Edge Cases

| Case | Handling |
|------|----------|
| No locations exist yet | All trips unmatched, clusters accumulate in Suggested tab |
| Location deleted | Set location_id to NULL on affected trips (ON DELETE SET NULL) |
| Location radius changed | Admin triggers rematch to re-evaluate |
| GPS accuracy very poor (>200m) | Already filtered by detect_trips |
| Walking trips | Still matched to locations |
| Round trip (same start/end) | Both can point to the same location |
| Retroactive matching | "Re-match all trips" button triggers rematch_all_trip_locations() |

## 6. Out of Scope (YAGNI)

- No Flutter app changes (dashboard-only feature)
- No automatic Google Geocoding in backend
- No trip purpose inference from location types
- No notification system for new unmatched clusters
- No batch editing of trip locations
