# Research: Location Geofences & Shift Segmentation

**Feature Branch**: `015-location-geofences`
**Date**: 2026-01-16

This document consolidates research findings for implementing workplace location geofences with shift timeline segmentation.

---

## 1. PostGIS Spatial Queries

### Decision: Use `geography(POINT, 4326)` with GiST Index

**Rationale**:
- Geography type provides accurate distance calculations in meters on Earth's surface
- `ST_DWithin` is index-accelerated for filtering; `ST_Distance` for actual values
- GiST indexes reduce query complexity from O(n*m) to O(n*log(m))

**Alternatives Considered**:
- `geometry(POINT, 4326)` - Rejected: distance in degrees, inaccurate for GPS tracking
- Separate lat/lng columns - Rejected: no spatial index support, poor performance

### Recommended Schema

```sql
-- Enable PostGIS
CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA extensions;

-- Locations table with geofence
CREATE TABLE locations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    location_type location_type NOT NULL,
    location geography(POINT, 4326) NOT NULL,
    radius_meters NUMERIC(10,2) NOT NULL DEFAULT 100 CHECK (radius_meters BETWEEN 10 AND 1000),
    -- Computed columns for API convenience
    latitude DOUBLE PRECISION GENERATED ALWAYS AS (ST_Y(location::geometry)) STORED,
    longitude DOUBLE PRECISION GENERATED ALWAYS AS (ST_X(location::geometry)) STORED,
    address TEXT,
    notes TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Spatial index (critical for performance)
CREATE INDEX idx_locations_geo ON locations USING GIST (location);
```

### Closest Location Query Pattern

```sql
-- Find the closest location containing a GPS point
SELECT
    l.id,
    l.name,
    ST_Distance(l.location, ST_SetSRID(ST_MakePoint($lng, $lat), 4326)::geography) AS distance_meters
FROM locations l
WHERE l.is_active = TRUE
  AND ST_DWithin(
      l.location,
      ST_SetSRID(ST_MakePoint($lng, $lat), 4326)::geography,
      l.radius_meters
  )
ORDER BY ST_Distance(l.location, ST_SetSRID(ST_MakePoint($lng, $lat), 4326)::geography)
LIMIT 1;
```

### Batch Matching RPC Function

```sql
-- Match all GPS points of a shift to locations (batch operation)
CREATE OR REPLACE FUNCTION match_shift_gps_to_locations(p_shift_id UUID)
RETURNS TABLE (
    gps_point_id UUID,
    location_id UUID,
    distance_meters DOUBLE PRECISION,
    confidence_score DOUBLE PRECISION
) AS $$
    WITH gps AS (
        SELECT
            id,
            ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)::geography AS point
        FROM gps_points
        WHERE shift_id = p_shift_id
    )
    SELECT
        gps.id AS gps_point_id,
        closest.location_id,
        closest.distance_meters,
        -- Confidence: 1.0 at center, 0.0 at edge
        GREATEST(0, 1 - (closest.distance_meters / closest.radius)) AS confidence_score
    FROM gps
    CROSS JOIN LATERAL (
        SELECT
            l.id AS location_id,
            l.radius_meters AS radius,
            ST_Distance(l.location, gps.point) AS distance_meters
        FROM locations l
        WHERE l.is_active = TRUE
          AND ST_DWithin(l.location, gps.point, l.radius_meters)
        ORDER BY ST_Distance(l.location, gps.point)
        LIMIT 1
    ) AS closest;
$$ LANGUAGE sql STABLE;
```

**Performance Note**: With proper GiST indexes, matching 500 GPS points against 100 locations completes in <100ms.

---

## 2. Geocoding API Integration

### Decision: Server-side Google Maps Geocoding with Nominatim Fallback

**Rationale**:
- API key security (stays on server)
- Centralized rate limiting control
- Response caching to reduce API calls
- Google provides high accuracy; Nominatim as free fallback

**Alternatives Considered**:
- Client-side geocoding - Rejected: exposes API key in browser
- Nominatim only - Rejected: 1 req/sec limit, less accurate for some regions
- MapBox - Alternative option: 100K/month free tier

### Server-side API Route Pattern

```typescript
// app/api/geocode/route.ts
import { NextRequest, NextResponse } from 'next/server';
import { z } from 'zod';

const geocodeSchema = z.object({
  address: z.string().min(1).max(500),
});

// In-memory cache (use Redis in production)
const cache = new Map<string, { data: LatLng; timestamp: number }>();
const CACHE_TTL = 24 * 60 * 60 * 1000; // 24 hours

export async function POST(request: NextRequest) {
  const body = await request.json();
  const { address } = geocodeSchema.parse(body);

  // Check cache
  const cacheKey = address.toLowerCase().trim();
  const cached = cache.get(cacheKey);
  if (cached && Date.now() - cached.timestamp < CACHE_TTL) {
    return NextResponse.json({ success: true, data: cached.data, cached: true });
  }

  // Call Google API
  const apiKey = process.env.GOOGLE_MAPS_API_KEY;
  const url = new URL('https://maps.googleapis.com/maps/api/geocode/json');
  url.searchParams.set('address', address);
  url.searchParams.set('key', apiKey!);

  const response = await fetch(url.toString());
  const data = await response.json();

  if (data.status !== 'OK') {
    // Error handling by status code
    const statusCode = data.status === 'ZERO_RESULTS' ? 404 :
                       data.status === 'OVER_QUERY_LIMIT' ? 429 : 400;
    return NextResponse.json(
      { success: false, error: data.status },
      { status: statusCode }
    );
  }

  const result = {
    lat: data.results[0].geometry.location.lat,
    lng: data.results[0].geometry.location.lng,
    formattedAddress: data.results[0].formatted_address,
  };

  cache.set(cacheKey, { data: result, timestamp: Date.now() });
  return NextResponse.json({ success: true, data: result });
}
```

### Environment Variables Required

```env
# Required for geocoding
GOOGLE_MAPS_API_KEY=your_google_api_key_here
```

### Fallback to Nominatim (Free)

```typescript
async function geocodeWithNominatim(address: string) {
  const url = new URL('https://nominatim.openstreetmap.org/search');
  url.searchParams.set('q', address);
  url.searchParams.set('format', 'json');
  url.searchParams.set('limit', '1');

  const response = await fetch(url.toString(), {
    headers: { 'User-Agent': 'GPS-Tracker-Dashboard/1.0' }, // Required by Nominatim
  });

  const results = await response.json();
  if (results.length === 0) return null;

  return {
    lat: parseFloat(results[0].lat),
    lng: parseFloat(results[0].lon),
    formattedAddress: results[0].display_name,
  };
}
```

---

## 3. Timeline Segment Computation Algorithm

### Decision: Two-phase O(n) Algorithm

**Rationale**:
- Phase 1: Group consecutive points by location_id (single pass)
- Phase 2: Classify segment types (matched/travel/unmatched)
- Clear separation of concerns, maintainable

**Alternatives Considered**:
- Single-pass algorithm - Acceptable for optimization later
- Server-side computation - Possible but adds latency; client-side allows instant updates

### Segment Types

| Type | Definition |
|------|------------|
| `matched` | GPS points within a location's geofence |
| `travel` | Unmatched points BETWEEN two different matched locations |
| `unmatched` | Unmatched points at shift start/end, or between same location |

### Algorithm Implementation

```typescript
interface MatchedGpsPoint {
  id: string;
  timestamp: Date;
  location_id: string | null;
  location_name: string | null;
  confidence_score: number | null;
}

type SegmentType = 'matched' | 'travel' | 'unmatched';

interface TimelineSegment {
  start_time: Date;
  end_time: Date;
  duration_seconds: number;
  point_count: number;
  location_id: string | null;
  location_name: string | null;
  segment_type: SegmentType;
}

function computeTimelineSegments(points: MatchedGpsPoint[]): TimelineSegment[] {
  if (points.length === 0) return [];

  // Phase 1: Group consecutive points by location_id
  const rawSegments = groupByConsecutiveLocation(points);

  // Phase 2: Classify segment types
  return classifySegments(rawSegments);
}

function classifySegments(rawSegments: RawSegment[]): TimelineSegment[] {
  const result: TimelineSegment[] = [];

  for (let i = 0; i < rawSegments.length; i++) {
    const segment = rawSegments[i];
    let segmentType: SegmentType;

    if (segment.location_id !== null) {
      segmentType = 'matched';
    } else {
      // Find previous and next matched segments
      const prevMatched = findPreviousMatched(rawSegments, i);
      const nextMatched = findNextMatched(rawSegments, i);

      if (prevMatched === null || nextMatched === null) {
        segmentType = 'unmatched'; // At boundary
      } else if (prevMatched.location_id !== nextMatched.location_id) {
        segmentType = 'travel'; // Between different locations
      } else {
        segmentType = 'unmatched'; // Between same location (GPS drift)
      }
    }

    result.push({
      start_time: segment.points[0].timestamp,
      end_time: segment.points[segment.points.length - 1].timestamp,
      duration_seconds: calculateDuration(segment.points),
      point_count: segment.points.length,
      location_id: segment.location_id,
      location_name: segment.location_name,
      segment_type: segmentType,
    });
  }

  return result;
}
```

### Edge Cases Handled

- All points unmatched → Single `unmatched` segment
- Single point segments → Valid segment with 0 duration
- Alternating matched/unmatched → Correct classification per segment
- GPS drift between same location → Classified as `unmatched` (not travel)

---

## 4. CSV Bulk Import Patterns

### Decision: PapaParse + Zod Validation + Batch Insert

**Rationale**:
- PapaParse: Fast, no dependencies, streaming support
- Zod: Consistent with existing codebase validation
- Batch insert (500 rows/batch): Optimal for Supabase performance

**Alternatives Considered**:
- Native File API parsing - Rejected: more code, less robust
- Single insert per row - Rejected: N queries instead of ceil(N/500)

### Dependencies

```bash
npm install papaparse
npm install -D @types/papaparse
```

### Validation Schema

```typescript
import { z } from 'zod';

export const locationCsvRowSchema = z.object({
  name: z.string().min(1, 'Name is required'),
  location_type: z.enum(['office', 'building', 'vendor', 'home', 'other']),
  latitude: z.coerce.number().min(-90).max(90),
  longitude: z.coerce.number().min(-180).max(180),
  radius_meters: z.coerce.number().min(10).max(1000).optional().default(100),
  address: z.string().optional(),
  notes: z.string().optional(),
  is_active: z.coerce.boolean().optional().default(true),
});
```

### Import Flow

1. **Parse CSV**: `Papa.parse(file, { header: true, dynamicTyping: true })`
2. **Validate rows**: `zod.safeParse()` per row, collect all errors
3. **Preview**: Show table with row-level validation status
4. **Batch insert**: Chunk into 500-row batches, sequential processing
5. **Report results**: Imported count, skipped (validation), failed (database)

### Partial Success Pattern

```typescript
interface ImportResult {
  status: 'success' | 'partial' | 'failed';
  summary: {
    totalRows: number;
    importedCount: number;
    skippedCount: number;  // Validation errors
    failedCount: number;   // Database errors
  };
  skippedRows: Array<{ rowIndex: number; errors: string[] }>;
  failedRows: Array<{ rowIndex: number; error: string }>;
}
```

---

## 5. React-Leaflet Geofence Visualization

### Decision: Circle + Marker Composition with Location Type Colors

**Rationale**:
- `Circle` component scales with map zoom (represents actual geographic area)
- Combine with `Marker` for clickable center point
- Color by location type for visual distinction
- Follows existing patterns in `location-marker.tsx`

**Alternatives Considered**:
- `CircleMarker` - Rejected: fixed pixel size, doesn't represent real radius
- Polygon - Rejected: overkill for circular geofences

### Location Type Color Scheme

```typescript
export const LOCATION_TYPE_COLORS = {
  office: { color: '#3b82f6', name: 'Office' },           // blue-500
  building: { color: '#f59e0b', name: 'Construction' },   // amber-500
  vendor: { color: '#8b5cf6', name: 'Vendor' },           // violet-500
  home: { color: '#22c55e', name: 'Home' },               // green-500
  other: { color: '#6b7280', name: 'Other' },             // gray-500
  travel: { color: '#eab308', name: 'Travel' },           // yellow-500
  unmatched: { color: '#ef4444', name: 'Unmatched' },     // red-500
} as const;
```

### Click-to-Place Pattern

```typescript
function ClickToPlaceMarker({ position, onPositionChange }) {
  useMapEvents({
    click(e) {
      onPositionChange(e.latlng);
    },
  });
  return position ? <Marker position={position} /> : null;
}
```

### Real-time Radius Update

```typescript
// Circle automatically updates when radius state changes
<Circle
  center={center}
  radius={radius}  // Reactive to state changes
  pathOptions={{ color: typeColor, fillOpacity: 0.2 }}
/>
```

### Bounds Fitting for Circles

```typescript
function FitBoundsToCircles({ locations }) {
  const map = useMap();

  useEffect(() => {
    if (locations.length === 0) return;

    let bounds = null;
    locations.forEach((loc) => {
      const circle = L.circle([loc.latitude, loc.longitude], { radius: loc.radius_meters });
      const circleBounds = circle.getBounds();
      bounds = bounds ? bounds.extend(circleBounds) : circleBounds;
    });

    if (bounds) {
      map.fitBounds(bounds, { padding: [50, 50], maxZoom: 15 });
    }
  }, [map, locations]);

  return null;
}
```

---

## Summary of Key Decisions

| Topic | Decision | Key Benefit |
|-------|----------|-------------|
| Spatial Storage | `geography(POINT, 4326)` + GiST index | Accurate meters, fast queries |
| Geocoding | Server-side Google Maps API | Security, caching, rate control |
| Timeline Algorithm | Two-phase O(n) with travel detection | Efficient, maintainable |
| CSV Import | PapaParse + Zod + 500-row batches | Validated, performant |
| Map Visualization | react-leaflet Circle + type colors | Real radius, visual distinction |
