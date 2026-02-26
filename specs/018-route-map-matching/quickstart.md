# Quickstart: Route Map Matching

## Prerequisites

- Docker installed locally
- Supabase CLI configured
- Flutter development environment
- ~3 GB free disk space (for OSRM data)

## 1. Set Up Local OSRM (Development)

```bash
# Create directory for OSRM data
mkdir -p ~/osrm-data && cd ~/osrm-data

# Download Quebec OSM extract (~500MB)
wget https://download.geofabrik.de/north-america/canada/quebec-latest.osm.pbf

# Pre-process for OSRM (takes ~5-10 minutes)
docker run -v $(pwd):/data osrm/osrm-backend osrm-extract -p /opt/car.lua /data/quebec-latest.osm.pbf
docker run -v $(pwd):/data osrm/osrm-backend osrm-partition /data/quebec-latest.osrm
docker run -v $(pwd):/data osrm/osrm-backend osrm-customize /data/quebec-latest.osrm

# Run OSRM server
docker run -d --name osrm -p 5000:5000 -v $(pwd):/data osrm/osrm-backend \
  osrm-routed --algorithm mld /data/quebec-latest.osrm

# Verify it works (Montreal coordinates)
curl "http://localhost:5000/match/v1/driving/-73.5673,45.5017;-73.5800,45.5100?geometries=polyline6&overview=full"
```

## 2. Apply Database Migration

```bash
cd supabase
# Apply migration 043
supabase db push
```

Verify new columns:
```sql
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_name = 'trips'
AND column_name IN ('route_geometry', 'road_distance_km', 'match_status', 'match_confidence', 'match_error', 'matched_at', 'match_attempts');
```

## 3. Deploy Edge Functions

```bash
# Set OSRM URL secret
supabase secrets set OSRM_BASE_URL=http://your-osrm-server:5000

# Deploy Edge Functions
supabase functions deploy match-trip-route
supabase functions deploy batch-match-trips
```

## 4. Test the Flow

```bash
# 1. Complete a shift with GPS data (or use existing test data)

# 2. Detect trips
curl -X POST "${SUPABASE_URL}/rest/v1/rpc/detect_trips" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"p_shift_id": "YOUR_SHIFT_ID"}'

# 3. Match a trip route
curl -X POST "${SUPABASE_URL}/functions/v1/match-trip-route" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"trip_id": "YOUR_TRIP_ID"}'

# 4. Verify result
curl "${SUPABASE_URL}/rest/v1/trips?id=eq.YOUR_TRIP_ID&select=distance_km,road_distance_km,match_status,match_confidence,route_geometry" \
  -H "Authorization: Bearer ${TOKEN}"
```

## 5. Batch Re-process Historical Trips

```bash
# Match all pending trips (up to 100)
curl -X POST "${SUPABASE_URL}/functions/v1/batch-match-trips" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"reprocess_failed": true, "limit": 100}'
```

## Key Files to Modify

### Database
- `supabase/migrations/043_route_map_matching.sql` — Schema changes

### Edge Functions
- `supabase/functions/match-trip-route/index.ts` — Single trip matching
- `supabase/functions/batch-match-trips/index.ts` — Batch processing

### Flutter (Mobile)
- `lib/features/mileage/models/trip.dart` — Add route matching fields
- `lib/features/mileage/models/local_trip.dart` — Local cache update
- `lib/features/mileage/services/trip_service.dart` — Trigger matching after detection
- `lib/features/mileage/widgets/trip_route_map.dart` — Render matched polyline
- `lib/features/mileage/widgets/trip_card.dart` — Match status badge
- `lib/features/mileage/screens/trip_detail_screen.dart` — Route verified indicator
- `lib/shared/utils/polyline_decoder.dart` — NEW: Polyline6 decoder utility

### Dashboard (Next.js)
- `src/types/trip.ts` — Add route matching fields to Trip type
- `src/components/trips/trip-route-map.tsx` — NEW: Render matched route on Leaflet map
- `src/components/trips/match-status-badge.tsx` — NEW: Visual match status indicator
- `src/components/monitoring/gps-trail-map.tsx` — Support matched route overlay

## Development Workflow

1. Start OSRM locally: `docker start osrm`
2. Start Supabase locally: `cd supabase && supabase start`
3. Run Flutter app: `cd gps_tracker && flutter run`
4. Complete a shift → trips auto-detected → route matching triggered
5. View trip detail → matched route displayed on map
