# RPC Function Contracts: Location Geofences

**Feature Branch**: `015-location-geofences`
**Date**: 2026-01-16

This document defines the PostgreSQL RPC function signatures for the Location Geofences feature. All functions follow the existing Supabase patterns established in previous specs.

---

## 1. get_locations_paginated

Retrieve locations with pagination, filtering, and search capabilities.

### Signature

```sql
CREATE OR REPLACE FUNCTION get_locations_paginated(
    p_limit INTEGER DEFAULT 20,
    p_offset INTEGER DEFAULT 0,
    p_search TEXT DEFAULT NULL,
    p_location_type location_type DEFAULT NULL,
    p_is_active BOOLEAN DEFAULT NULL,
    p_sort_by TEXT DEFAULT 'name',
    p_sort_order TEXT DEFAULT 'asc'
)
RETURNS TABLE (
    id UUID,
    name TEXT,
    location_type location_type,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    radius_meters NUMERIC(10,2),
    address TEXT,
    notes TEXT,
    is_active BOOLEAN,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    total_count BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
```

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `p_limit` | INTEGER | 20 | Maximum rows to return (max 100) |
| `p_offset` | INTEGER | 0 | Number of rows to skip |
| `p_search` | TEXT | NULL | Search term for name/address (ILIKE) |
| `p_location_type` | location_type | NULL | Filter by type (NULL = all types) |
| `p_is_active` | BOOLEAN | NULL | Filter by active status (NULL = all) |
| `p_sort_by` | TEXT | 'name' | Sort column: name, created_at, updated_at, location_type |
| `p_sort_order` | TEXT | 'asc' | Sort direction: asc, desc |

### Return Type

Each row contains:
- All location fields
- `total_count`: Total matching records (for pagination UI)

### Authorization

Requires one of: `admin`, `super_admin`, `manager`, `supervisor` role.

### Example Usage (TypeScript)

```typescript
const { data, error } = await supabase.rpc('get_locations_paginated', {
  p_limit: 20,
  p_offset: 0,
  p_search: 'office',
  p_location_type: null,
  p_is_active: true,
  p_sort_by: 'name',
  p_sort_order: 'asc',
});

const locations = data;
const totalCount = data?.[0]?.total_count ?? 0;
```

---

## 2. match_shift_gps_to_locations

Match all GPS points of a shift to their closest containing geofence and cache results.

### Signature

```sql
CREATE OR REPLACE FUNCTION match_shift_gps_to_locations(
    p_shift_id UUID
)
RETURNS TABLE (
    gps_point_id UUID,
    gps_latitude DOUBLE PRECISION,
    gps_longitude DOUBLE PRECISION,
    captured_at TIMESTAMPTZ,
    location_id UUID,
    location_name TEXT,
    location_type location_type,
    distance_meters DOUBLE PRECISION,
    confidence_score DOUBLE PRECISION
)
LANGUAGE plpgsql
SECURITY DEFINER
```

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `p_shift_id` | UUID | The shift to process |

### Return Type

For each GPS point in the shift:
- GPS point details (id, lat/lng, timestamp)
- Matched location details (id, name, type) - NULL if unmatched
- Distance from location center (NULL if unmatched)
- Confidence score (NULL if unmatched)

### Behavior

1. **Check existing matches**: If `location_matches` already exist for this shift, return cached results
2. **Compute matches**: For each GPS point without a cached match:
   - Find all active locations where the point falls within the radius
   - Select the closest location (smallest distance to center)
   - Calculate confidence score: `MAX(0, 1 - (distance / radius))`
3. **Cache results**: Insert new matches into `location_matches` table
4. **Return**: All GPS points with their matches (or NULL if unmatched)

### Authorization

User must be authorized to view the shift (existing RLS check via `employee_supervisors`).

### Example Usage (TypeScript)

```typescript
const { data, error } = await supabase.rpc('match_shift_gps_to_locations', {
  p_shift_id: '123e4567-e89b-12d3-a456-426614174000',
});

// data contains all GPS points with location matches
const matchedPoints = data?.filter(p => p.location_id !== null);
const unmatchedPoints = data?.filter(p => p.location_id === null);
```

---

## 3. get_shift_timeline

Get timeline segments for a shift, computing matches if needed.

### Signature

```sql
CREATE OR REPLACE FUNCTION get_shift_timeline(
    p_shift_id UUID
)
RETURNS TABLE (
    segment_index INTEGER,
    segment_type TEXT,
    start_time TIMESTAMPTZ,
    end_time TIMESTAMPTZ,
    duration_seconds INTEGER,
    point_count INTEGER,
    location_id UUID,
    location_name TEXT,
    location_type location_type,
    avg_confidence DOUBLE PRECISION
)
LANGUAGE plpgsql
SECURITY DEFINER
```

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `p_shift_id` | UUID | The shift to generate timeline for |

### Return Type

Ordered list of timeline segments with:
- Segment metadata (index, type, timestamps, duration)
- Location reference (if matched)
- Statistics (point count, average confidence)

### Segment Types

| Type | Description |
|------|-------------|
| `matched` | Points within a location's geofence |
| `travel` | Unmatched points between two different matched locations |
| `unmatched` | Unmatched points at shift boundaries or between same location |

### Behavior

1. Calls `match_shift_gps_to_locations` to ensure matches are computed
2. Groups consecutive GPS points by location_id
3. Classifies null-location segments as `travel` or `unmatched`
4. Returns ordered segments with aggregated statistics

### Authorization

User must be authorized to view the shift.

### Example Usage (TypeScript)

```typescript
const { data, error } = await supabase.rpc('get_shift_timeline', {
  p_shift_id: '123e4567-e89b-12d3-a456-426614174000',
});

// Render timeline bar
const segments = data?.map(seg => ({
  type: seg.segment_type,
  durationPercent: (seg.duration_seconds / totalDuration) * 100,
  color: SEGMENT_COLORS[seg.segment_type],
  label: seg.location_name ?? seg.segment_type,
}));
```

---

## 4. bulk_insert_locations

Insert multiple locations in a single transaction (for CSV import).

### Signature

```sql
CREATE OR REPLACE FUNCTION bulk_insert_locations(
    p_locations JSONB
)
RETURNS TABLE (
    id UUID,
    name TEXT,
    success BOOLEAN,
    error_message TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
```

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `p_locations` | JSONB | Array of location objects |

### Input Format

```json
[
  {
    "name": "Office HQ",
    "location_type": "office",
    "latitude": 45.5017,
    "longitude": -73.5673,
    "radius_meters": 100,
    "address": "123 Main St",
    "notes": null,
    "is_active": true
  },
  ...
]
```

### Return Type

For each input location:
- Generated `id` (if successful)
- `name` (for identification)
- `success` boolean
- `error_message` (if failed)

### Behavior

1. Validates each location object
2. Inserts valid locations
3. Returns results for all inputs (success or failure)
4. Transaction continues even if some rows fail (partial success)

### Authorization

Requires one of: `admin`, `super_admin`, `manager`, `supervisor` role.

### Example Usage (TypeScript)

```typescript
const { data, error } = await supabase.rpc('bulk_insert_locations', {
  p_locations: JSON.stringify(validatedRows),
});

const imported = data?.filter(r => r.success);
const failed = data?.filter(r => !r.success);
```

---

## 5. check_shift_matches_exist

Check if a shift has cached location matches (used before fetching timeline).

### Signature

```sql
CREATE OR REPLACE FUNCTION check_shift_matches_exist(
    p_shift_id UUID
)
RETURNS TABLE (
    has_matches BOOLEAN,
    match_count BIGINT,
    matched_at TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
```

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `p_shift_id` | UUID | The shift to check |

### Return Type

- `has_matches`: TRUE if any location_matches exist for this shift
- `match_count`: Number of cached matches
- `matched_at`: Timestamp of most recent match computation

### Use Case

Allows UI to show a "Compute Timeline" button if matches don't exist, or directly display cached timeline if they do.

### Example Usage (TypeScript)

```typescript
const { data } = await supabase.rpc('check_shift_matches_exist', {
  p_shift_id: shiftId,
});

if (!data?.[0]?.has_matches) {
  // Show loading spinner while computing
  await supabase.rpc('match_shift_gps_to_locations', { p_shift_id: shiftId });
}
```

---

## TypeScript Type Definitions

```typescript
// For use with Refine data provider

export interface LocationRow {
  id: string;
  name: string;
  location_type: 'office' | 'building' | 'vendor' | 'home' | 'other';
  latitude: number;
  longitude: number;
  radius_meters: number;
  address: string | null;
  notes: string | null;
  is_active: boolean;
  created_at: string;
  updated_at: string;
  total_count?: number;
}

export interface LocationMatchRow {
  gps_point_id: string;
  gps_latitude: number;
  gps_longitude: number;
  captured_at: string;
  location_id: string | null;
  location_name: string | null;
  location_type: LocationType | null;
  distance_meters: number | null;
  confidence_score: number | null;
}

export interface TimelineSegmentRow {
  segment_index: number;
  segment_type: 'matched' | 'travel' | 'unmatched';
  start_time: string;
  end_time: string;
  duration_seconds: number;
  point_count: number;
  location_id: string | null;
  location_name: string | null;
  location_type: LocationType | null;
  avg_confidence: number | null;
}

export interface BulkInsertResultRow {
  id: string | null;
  name: string;
  success: boolean;
  error_message: string | null;
}
```

---

## Error Handling

All RPC functions follow this error pattern:

| Error Code | Description | HTTP Status |
|------------|-------------|-------------|
| `PGRST116` | No rows returned (not found) | 404 |
| `42501` | Insufficient privilege | 403 |
| `23505` | Unique violation (duplicate) | 409 |
| `23503` | Foreign key violation | 400 |
| `22P02` | Invalid input syntax | 400 |

### Example Error Handling (TypeScript)

```typescript
const { data, error } = await supabase.rpc('get_shift_timeline', {
  p_shift_id: shiftId,
});

if (error) {
  if (error.code === 'PGRST116') {
    // Shift not found or no GPS points
    showEmptyState('No GPS data available for this shift');
  } else if (error.code === '42501') {
    // Not authorized to view this shift
    showError('You do not have permission to view this shift');
  } else {
    showError('An error occurred while loading the timeline');
  }
}
```
