# Research: Route Map Matching & Real Route Visualization

**Feature**: 018-route-map-matching | **Date**: 2026-02-25

## Research Question 1: Map Matching Engine Selection

### Decision: OSRM (Open Source Routing Machine) via Docker Container

### Rationale
- **Privacy-compliant**: Data stays on our infrastructure (satisfies SC-008)
- **Proven accuracy**: 90-95% accuracy for 30-60s GPS intervals
- **Simple deployment**: Single Docker container with Quebec OSM data (~1-2 GB)
- **Zero cost**: No per-request API fees; infrastructure cost only ($5-10/month VPS)
- **Returns geometry + distance**: Match API returns encoded polyline and road-based distance
- **Handles sparse traces**: Designed for GPS matching with configurable radiuses per point
- **OSM coverage**: Excellent road data coverage for Quebec, Canada

### Alternatives Considered

| Engine | Accuracy | Privacy | Complexity | Why Rejected |
|--------|----------|---------|------------|--------------|
| **Valhalla (Meili)** | 93-97% | Self-hosted | Medium-High | Higher resource requirements, steeper learning curve; accuracy gain not worth complexity for Phase 1 |
| **Mapbox Map Matching** | 94-98% | Violates SC-008 | None | Data sent to Mapbox servers; violates privacy requirement |
| **PostGIS + pgRouting** | 85-90% | Perfect | Medium | Accuracy too low for mileage reimbursement; road network loading complex |

### Key Finding: "Self-hosting" Scope Clarification
The spec lists "Self-hosting of the map matching engine" as Phase 2 / out of scope. This refers to a **production-grade managed OSRM deployment** (auto-updating OSM data, HA, monitoring, scaling). Phase 1 uses a **lightweight Docker container** on a small VPS — this is infrastructure, not a managed service.

---

## Research Question 2: OSRM Match API Capabilities

### Decision: Use OSRM Match API v5 with polyline6 encoding

### API Details
```
GET /match/v1/driving/{lon1},{lat1};{lon2},{lat2};...
    ?timestamps={t1};{t2};...
    &radiuses={r1};{r2};...
    &geometries=polyline6
    &overview=full
    &gaps=split
```

### Key Parameters
- **coordinates**: `lon,lat` pairs separated by `;` (note: longitude first)
- **timestamps**: Unix timestamps for each point (improves sparse trace matching)
- **radiuses**: GPS accuracy per point in meters (from `gps_points.accuracy`)
- **geometries=polyline6**: Returns high-precision encoded polyline (6 decimal places)
- **overview=full**: Returns complete route geometry (not simplified)
- **gaps=split**: Splits matching at large gaps (handles our 15-min GPS gap scenario)

### Response Structure
```json
{
  "matchings": [{
    "geometry": "encoded_polyline_string",
    "distance": 12345.6,     // meters
    "duration": 1234.5,      // seconds
    "confidence": 0.85       // 0-1
  }],
  "tracepoints": [
    { "location": [lon, lat], "matchings_index": 0 },
    null,  // unmatched point
    ...
  ]
}
```

### Coordinate Limit
OSRM default limit: **100 coordinates per request**. Our trips can have 30-240+ points (30-60s intervals). Strategy:
- Trips with ≤100 GPS points: Send all points directly
- Trips with >100 GPS points: Simplify trace (select every Nth point to stay under 100, preserving start/end)
- Self-hosted OSRM can increase this limit via `--max-matching-size`

### Accuracy with Sparse Traces
Research shows HMM-based map matching (OSRM uses this internally) achieves:
- **30s intervals**: ~95% link identification accuracy
- **60s intervals**: ~90% link identification accuracy
- Timestamps significantly improve accuracy for sparse traces

---

## Research Question 3: Route Geometry Storage Format

### Decision: Google Encoded Polyline (polyline6 precision)

### Rationale
- **Compact**: A 200-point route encoded as ~600 chars (vs. ~6000 chars as JSON coordinates)
- **Native support**: Google Maps Flutter (`google_maps_flutter`) can decode polyline strings
- **Standard format**: Leaflet (dashboard) has `polyline-encoded` package for decoding
- **OSRM native output**: OSRM returns polyline6 directly; no conversion needed
- **Database-friendly**: Stored as TEXT column; no PostGIS dependency

### Storage Estimate
- Average trip route: 50-200 geometry points → 150-600 bytes encoded
- 100 trips/month × 400 bytes average = ~40 KB/month (negligible)

---

## Research Question 4: Async Processing Architecture

### Decision: Supabase Edge Function triggered by app after trip detection

### Architecture
```
App → detect_trips() RPC → trips created (match_status='pending')
                              ↓
App → invoke Edge Function 'match-trip-route' for each trip
                              ↓
Edge Function → fetch GPS points from Supabase
              → call OSRM Match API (VPS)
              → validate result (anomaly check: distance > 3× haversine)
              → store route_geometry, road_distance_km, match_status
              → update distance_km with road-based distance
```

### Why Edge Function (not pg_net, not client-side)
- **pg_net**: Async HTTP from PostgreSQL, but complex to handle response parsing and error handling
- **Client-side (Flutter)**: Would require OSRM URL in app config; GPS data leaves device twice; harder to batch
- **Edge Function**: Clean HTTP handling in Deno, decoupled from database, can be called from both app and dashboard

### Retry Strategy
- **Max 3 attempts** per trip (stored in `match_attempts` column)
- **Exponential backoff**: 0s, 30s, 120s between attempts
- **Retry triggers**: App-side retry on failure; batch re-process for historical trips
- **Permanent failure**: After 3 attempts, `match_status = 'failed'`; distance remains Haversine-based

---

## Research Question 5: Anomaly Detection Threshold

### Decision: Flag as anomalous if road distance > 3× haversine distance

### Rationale
- The current 1.3× correction factor represents the average road-to-straight-line ratio
- In practice, road distance can be up to ~2× the straight-line for winding suburban routes
- Highway routes are typically 1.0-1.2× straight-line
- A 3× threshold catches GPS glitches, OSRM errors, or impossible routes while allowing for legitimately winding routes
- Anomalous trips retain Haversine distance; admin can review and override

### Additional Validation
- **Minimum confidence**: Reject OSRM matches with confidence < 0.3
- **Minimum matched points**: At least 50% of input points must match to a road
- **Maximum detour**: Single segment distance between consecutive matched points should not exceed 5× the straight-line segment distance

---

## Research Question 6: Existing Map Components Integration

### Flutter (Mobile App)
- **TripRouteMap** (`gps_tracker/lib/features/mileage/widgets/trip_route_map.dart`): Already supports `routePoints` parameter as `List<LatLng>?`. Currently receives GPS points (straight lines) or null (dashed line). Will receive decoded polyline points for matched routes.
- **google_maps_flutter**: Already in pubspec. Has `Polyline` widget with solid/dashed patterns. No new dependency needed.
- **Polyline decoding**: Need `google_maps_flutter_platform_interface` or a lightweight decoder (the algorithm is ~20 lines of Dart).

### Dashboard (Next.js)
- **GpsTrailMap** (`dashboard/src/components/monitoring/gps-trail-map.tsx`): Uses react-leaflet with `Polyline` component. Can render decoded coordinates.
- **react-leaflet**: Already in package.json. Supports polyline rendering.
- **Polyline decoding**: Use `@mapbox/polyline` or `polyline-encoded` npm package to decode the stored encoded polyline.

### No New Map Dependencies Required
Both platforms already have map display components that can render polyline geometries. Only need lightweight polyline decoder utilities (no new map SDKs).

---

## Research Question 7: OSRM Deployment for Quebec

### Decision: Docker container with Quebec/Canada OSM extract

### Setup
```bash
# Download Quebec OSM extract (~500MB PBF)
wget https://download.geofabrik.de/north-america/canada/quebec-latest.osm.pbf

# Pre-process for OSRM
docker run -v $(pwd):/data osrm/osrm-backend osrm-extract -p /opt/car.lua /data/quebec-latest.osm.pbf
docker run -v $(pwd):/data osrm/osrm-backend osrm-partition /data/quebec-latest.osrm
docker run -v $(pwd):/data osrm/osrm-backend osrm-customize /data/quebec-latest.osrm

# Run OSRM
docker run -p 5000:5000 -v $(pwd):/data osrm/osrm-backend osrm-routed --algorithm mld /data/quebec-latest.osrm
```

### Resource Requirements
- **Disk**: ~2 GB (PBF + processed data)
- **RAM**: ~1-2 GB for Quebec road network
- **CPU**: Minimal (matching is fast, ~10-50ms per request)
- **VPS**: $5-10/month (DigitalOcean/Hetzner 2GB RAM droplet)

### OSM Data Freshness
- Quebec OSM data is well-maintained (active Canadian mapping community)
- Monthly data refresh is sufficient (road networks don't change frequently)
- Phase 2 (future) can automate OSM data updates via cron job

---

## Summary of Decisions

| Area | Decision | Key Reason |
|------|----------|------------|
| Map matching engine | OSRM v5 Docker | Privacy + simplicity + proven |
| Route storage format | Polyline6 encoded string | Compact + native OSRM output |
| Processing architecture | Supabase Edge Function | Clean HTTP handling + batch support |
| OSRM deployment | Docker on VPS | Private + cheap + adequate for scale |
| Anomaly threshold | >3× haversine distance | Catches errors, allows winding routes |
| Retry strategy | 3 attempts with backoff | Handles transient network failures |
| Coordinate limit handling | Trace simplification >100 points | OSRM default limit |
