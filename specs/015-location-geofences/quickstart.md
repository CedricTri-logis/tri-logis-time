# Quickstart: Location Geofences & Shift Segmentation

**Feature Branch**: `015-location-geofences`
**Date**: 2026-01-16

This document provides setup instructions for developers working on the Location Geofences feature.

---

## Prerequisites

- Node.js 18.x LTS
- npm or pnpm
- Supabase CLI installed (`npm install -g supabase`)
- Local Supabase instance running (`supabase start`)
- Dashboard development environment from Spec 009-013

---

## New Dependencies

### Dashboard (npm)

```bash
cd dashboard
npm install papaparse
npm install -D @types/papaparse
```

**Package Versions:**
- `papaparse`: ^5.4.0 (CSV parsing)
- `@types/papaparse`: ^5.3.0 (TypeScript types)

All other dependencies (react-leaflet, shadcn/ui, Zod, date-fns) are already installed.

---

## Database Setup

### 1. Enable PostGIS Extension

PostGIS should already be enabled from previous specs. Verify:

```sql
SELECT extname, extversion FROM pg_extension WHERE extname = 'postgis';
```

If not enabled:

```sql
CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA extensions;
```

### 2. Apply Migration

```bash
cd supabase
supabase db push
```

The migration `015_location_geofences.sql` will:
- Create `location_type` enum
- Create `locations` table with PostGIS geography column
- Create `location_matches` table
- Create GiST spatial index
- Create RPC functions
- Set up RLS policies

### 3. Seed Data (Optional)

To import the 77 sample locations from the seed file:

```bash
# From project root
cd supabase
psql "postgresql://postgres:postgres@localhost:54322/postgres" -c "
  SELECT bulk_insert_locations(
    (SELECT content::jsonb FROM pg_read_file('/path/to/specs/014-seed-locations.json'))
  );
"
```

Or use the CSV import UI once implemented.

---

## Environment Variables

### Dashboard (.env.local)

```env
# Required for geocoding (address → coordinates)
GOOGLE_MAPS_API_KEY=your_google_api_key_here

# Existing variables (should already be set)
NEXT_PUBLIC_SUPABASE_URL=http://localhost:54321
NEXT_PUBLIC_SUPABASE_ANON_KEY=your_anon_key
```

### Getting a Google Maps API Key

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project or select existing
3. Enable "Geocoding API" under APIs & Services
4. Create credentials (API Key)
5. Restrict key to:
   - HTTP referrers: `localhost:*`, `your-domain.com/*`
   - API restrictions: Geocoding API only

**Note**: Geocoding is optional. If not configured, users can manually place markers on the map.

---

## Running the Dashboard

```bash
cd dashboard
npm run dev
```

Access at: http://localhost:3000

New routes:
- `/dashboard/locations` - Location list and map
- `/dashboard/locations/[id]` - Location detail/edit
- `/dashboard/locations/import` - CSV bulk import

---

## Verifying PostGIS Functions

Run these queries to verify spatial functions work:

```sql
-- Test point creation
SELECT ST_AsText(ST_SetSRID(ST_MakePoint(-73.5673, 45.5017), 4326)::geography);
-- Expected: POINT(-73.5673 45.5017)

-- Test distance calculation (should be ~0 for same point)
SELECT ST_Distance(
  ST_SetSRID(ST_MakePoint(-73.5673, 45.5017), 4326)::geography,
  ST_SetSRID(ST_MakePoint(-73.5673, 45.5017), 4326)::geography
);
-- Expected: 0

-- Test ST_DWithin (point within 100m of itself)
SELECT ST_DWithin(
  ST_SetSRID(ST_MakePoint(-73.5673, 45.5017), 4326)::geography,
  ST_SetSRID(ST_MakePoint(-73.5673, 45.5017), 4326)::geography,
  100
);
-- Expected: true
```

---

## Testing the RPC Functions

### Test `get_locations_paginated`

```sql
SELECT * FROM get_locations_paginated(
  p_limit := 10,
  p_offset := 0,
  p_search := NULL,
  p_location_type := NULL,
  p_is_active := TRUE
);
```

### Test `match_shift_gps_to_locations`

```sql
-- Replace with a real shift_id from your database
SELECT * FROM match_shift_gps_to_locations(
  p_shift_id := '123e4567-e89b-12d3-a456-426614174000'
);
```

### Test `get_shift_timeline`

```sql
SELECT * FROM get_shift_timeline(
  p_shift_id := '123e4567-e89b-12d3-a456-426614174000'
);
```

---

## Component Development

### New Components to Create

```
dashboard/src/components/
├── locations/
│   ├── location-form.tsx       # Create/edit form with map picker
│   ├── location-map.tsx        # Map showing all locations with circles
│   ├── geofence-circle.tsx     # Single geofence circle component
│   └── csv-import-dialog.tsx   # CSV upload and preview dialog
├── timeline/
│   ├── timeline-bar.tsx        # Horizontal segment visualization
│   ├── timeline-segment.tsx    # Individual segment with tooltip
│   ├── timeline-summary.tsx    # Duration breakdown panel
│   └── segmented-trail-map.tsx # GPS trail colored by segment
```

### New Hooks to Create

```
dashboard/src/lib/hooks/
├── use-locations.ts            # Location CRUD with Refine
├── use-location-matches.ts     # GPS matching via RPC
└── use-timeline-segments.ts    # Timeline computation
```

### New Validation Schemas

```
dashboard/src/lib/validations/
└── location.ts                 # Zod schemas for location form and CSV
```

---

## Existing Patterns to Follow

### Map Component Pattern

Reference: `dashboard/src/components/monitoring/team-map.tsx`

```tsx
'use client';

import { MapContainer, TileLayer } from 'react-leaflet';
import 'leaflet/dist/leaflet.css';

export function LocationMap() {
  return (
    <MapContainer
      center={[45.5017, -73.5673]}
      zoom={12}
      className="h-[400px] w-full rounded-lg"
    >
      <TileLayer
        attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
        url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
      />
      {/* Add geofence circles here */}
    </MapContainer>
  );
}
```

### Refine Data Hook Pattern

Reference: `dashboard/src/lib/hooks/use-historical-gps.ts`

```tsx
export function useLocations(filters: LocationFilters) {
  return useCustom<LocationRow[]>({
    url: '',
    method: 'get',
    meta: {
      rpc: 'get_locations_paginated',
    },
    config: {
      payload: {
        p_limit: filters.limit,
        p_offset: filters.offset,
        p_search: filters.search || null,
        p_location_type: filters.type || null,
        p_is_active: filters.activeOnly ? true : null,
      },
    },
  });
}
```

### Color Constants

Reference: `dashboard/src/lib/utils/trail-colors.ts`

```tsx
export const LOCATION_TYPE_COLORS = {
  office: '#3b82f6',    // blue-500
  building: '#f59e0b',  // amber-500
  vendor: '#8b5cf6',    // violet-500
  home: '#22c55e',      // green-500
  other: '#6b7280',     // gray-500
  travel: '#eab308',    // yellow-500
  unmatched: '#ef4444', // red-500
} as const;
```

---

## Troubleshooting

### "PostGIS extension not found"

```sql
CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA extensions;
```

### "Permission denied on locations table"

Verify RLS policies are in place and user has supervisor+ role:

```sql
SELECT * FROM pg_policies WHERE tablename = 'locations';
```

### "Geocoding returns 403"

Check API key restrictions in Google Cloud Console. Ensure:
- Geocoding API is enabled
- API key has correct HTTP referrer restrictions
- Billing is enabled on the project

### "Map doesn't render"

Ensure Leaflet CSS is imported:

```tsx
import 'leaflet/dist/leaflet.css';
```

---

## Next Steps

After completing setup:

1. Run `/speckit.tasks` to generate the implementation task list
2. Implement database migration first
3. Build location CRUD pages
4. Add timeline visualization to shift detail view
5. Test with seed data
