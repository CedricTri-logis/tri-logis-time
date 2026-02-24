# Data Model: Location Geofences & Shift Segmentation

**Feature Branch**: `015-location-geofences`
**Date**: 2026-01-16

---

## Entity Relationship Diagram

```
┌─────────────────┐       ┌──────────────────┐       ┌─────────────────┐
│   locations     │       │  location_matches │       │   gps_points    │
├─────────────────┤       ├──────────────────┤       ├─────────────────┤
│ id (PK)         │       │ id (PK)          │       │ id (PK)         │
│ name            │◄──────│ location_id (FK) │       │ shift_id (FK)   │
│ location_type   │       │ gps_point_id (FK)│──────►│ latitude        │
│ location (geo)  │       │ distance_meters  │       │ longitude       │
│ radius_meters   │       │ confidence_score │       │ accuracy        │
│ latitude        │       │ matched_at       │       │ captured_at     │
│ longitude       │       └──────────────────┘       │ ...             │
│ address         │                                  └────────┬────────┘
│ notes           │                                           │
│ is_active       │                                           │
│ created_at      │       ┌──────────────────┐                │
│ updated_at      │       │     shifts       │                │
└─────────────────┘       ├──────────────────┤                │
                          │ id (PK)          │◄───────────────┘
                          │ employee_id (FK) │
                          │ clocked_in_at    │
                          │ clocked_out_at   │
                          │ status           │
                          │ ...              │
                          └──────────────────┘
```

---

## Entity: Location

A geographic zone representing a workplace with a circular geofence boundary.

### Fields

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `id` | UUID | PK, default `gen_random_uuid()` | Unique identifier |
| `name` | TEXT | NOT NULL | Display name (e.g., "Head Office", "Building 42") |
| `location_type` | ENUM | NOT NULL | One of: `office`, `building`, `vendor`, `home`, `other` |
| `location` | GEOGRAPHY(POINT, 4326) | NOT NULL | Center point for spatial queries |
| `radius_meters` | NUMERIC(10,2) | NOT NULL, CHECK 10-1000 | Geofence radius in meters |
| `latitude` | DOUBLE PRECISION | GENERATED ALWAYS STORED | Computed from location for API convenience |
| `longitude` | DOUBLE PRECISION | GENERATED ALWAYS STORED | Computed from location for API convenience |
| `address` | TEXT | NULLABLE | Optional street address |
| `notes` | TEXT | NULLABLE | Optional notes/description |
| `is_active` | BOOLEAN | NOT NULL, DEFAULT TRUE | Active locations are used for GPS matching |
| `created_at` | TIMESTAMPTZ | NOT NULL, DEFAULT now() | Creation timestamp |
| `updated_at` | TIMESTAMPTZ | NOT NULL, DEFAULT now() | Last update timestamp |

### Indexes

| Index | Type | Columns | Purpose |
|-------|------|---------|---------|
| `idx_locations_geo` | GiST | `location` | Spatial query acceleration |
| `idx_locations_active` | B-tree | `is_active` | Active location filtering |
| `idx_locations_type` | B-tree | `location_type` | Type-based filtering |

### Validation Rules

- `name`: Required, non-empty string
- `location_type`: Must be one of the 5 defined types
- `latitude`: Must be between -90 and 90
- `longitude`: Must be between -180 and 180
- `radius_meters`: Must be between 10 and 1000

### Access Control

- **Read**: All authenticated users with `admin`, `super_admin`, `manager`, or `supervisor` role
- **Create/Update/Delete**: Same roles (company-wide resource)
- **Note**: No per-user ownership; locations are shared across all supervisors

---

## Entity: Location Match

An association between a GPS point and a matched location, created on-demand when viewing a shift timeline.

### Fields

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `id` | UUID | PK, default `gen_random_uuid()` | Unique identifier |
| `gps_point_id` | UUID | FK → gps_points(id), NOT NULL, ON DELETE CASCADE | Associated GPS point |
| `location_id` | UUID | FK → locations(id), NOT NULL, ON DELETE CASCADE | Matched location |
| `distance_meters` | DOUBLE PRECISION | NOT NULL | Distance from GPS point to location center |
| `confidence_score` | DOUBLE PRECISION | NOT NULL, CHECK 0-1 | Confidence: 1.0 at center, 0.0 at edge |
| `matched_at` | TIMESTAMPTZ | NOT NULL, DEFAULT now() | When the match was computed |

### Indexes

| Index | Type | Columns | Purpose |
|-------|------|---------|---------|
| `idx_location_matches_gps` | B-tree | `gps_point_id` | Fast lookup by GPS point |
| `idx_location_matches_location` | B-tree | `location_id` | Fast lookup by location |
| `idx_location_matches_unique` | Unique | `(gps_point_id, location_id)` | Prevent duplicates |

### Validation Rules

- `distance_meters`: Non-negative, represents actual distance
- `confidence_score`: Calculated as `MAX(0, 1 - (distance_meters / radius_meters))`

### State Transitions

Location matches are immutable once created. They persist even if:
- The location is later modified (historical accuracy preserved)
- The location is marked inactive
- The location is soft-deleted (if applicable)

### Access Control

- **Read**: Users who can view the associated shift (existing RLS on shifts)
- **Create**: System-generated via RPC function
- **Update/Delete**: Not allowed (immutable cache)

---

## Entity: Timeline Segment (Computed)

A computed grouping of consecutive GPS points sharing the same location match. Not stored in database; computed client-side or via RPC.

### Fields (TypeScript Interface)

```typescript
interface TimelineSegment {
  // Time boundaries
  start_time: Date;
  end_time: Date;
  duration_seconds: number;

  // Segment identification
  segment_type: 'matched' | 'travel' | 'unmatched';

  // Location reference (nullable for travel/unmatched)
  location_id: string | null;
  location_name: string | null;
  location_type: LocationType | null;

  // Statistics
  point_count: number;
  avg_confidence: number | null;

  // Optional: raw GPS points for detailed view
  gps_points?: Array<{
    id: string;
    latitude: number;
    longitude: number;
    captured_at: Date;
  }>;
}
```

### Segment Type Definitions

| Type | Description | Color |
|------|-------------|-------|
| `matched` | GPS points within a location's geofence | Location type color |
| `travel` | Unmatched points between two DIFFERENT matched locations | Yellow (#eab308) |
| `unmatched` | Unmatched points at shift start/end, or between same location | Red (#ef4444) |

### Computation Rules

1. GPS points are processed in chronological order
2. Consecutive points with the same `location_id` (including null) are grouped
3. Null-location segments are classified based on surrounding segments:
   - Has matched segment on BOTH sides with DIFFERENT locations → `travel`
   - Otherwise → `unmatched`

---

## Entity: Timeline Summary (Computed)

Aggregated statistics for a shift showing time breakdown by segment type.

### Fields (TypeScript Interface)

```typescript
interface TimelineSummary {
  shift_id: string;
  total_duration_seconds: number;
  total_gps_points: number;

  // Breakdown by segment type
  matched_duration_seconds: number;
  matched_percentage: number;
  travel_duration_seconds: number;
  travel_percentage: number;
  unmatched_duration_seconds: number;
  unmatched_percentage: number;

  // Breakdown by location type (matched segments only)
  by_location_type: Array<{
    location_type: LocationType;
    duration_seconds: number;
    percentage: number;
    locations: Array<{
      location_id: string;
      location_name: string;
      duration_seconds: number;
    }>;
  }>;
}
```

---

## Enum: Location Type

```sql
CREATE TYPE location_type AS ENUM (
  'office',    -- Corporate office, administrative building
  'building',  -- Construction site, job site
  'vendor',    -- Supplier, external partner location
  'home',      -- Employee home (work from home)
  'other'      -- Miscellaneous locations
);
```

### Type Display Properties

| Value | Display Name | Color | Icon Suggestion |
|-------|--------------|-------|-----------------|
| `office` | Office | Blue (#3b82f6) | Building |
| `building` | Construction Site | Amber (#f59e0b) | HardHat |
| `vendor` | Vendor | Violet (#8b5cf6) | Truck |
| `home` | Home | Green (#22c55e) | Home |
| `other` | Other | Gray (#6b7280) | MapPin |

---

## Database Migration Summary

### New Objects

| Object | Type | Purpose |
|--------|------|---------|
| `location_type` | ENUM | Location classification |
| `locations` | TABLE | Geofence definitions |
| `location_matches` | TABLE | GPS-to-location match cache |
| `idx_locations_geo` | INDEX (GiST) | Spatial query optimization |
| `match_shift_gps_to_locations` | FUNCTION | Batch GPS matching |
| `get_locations_paginated` | FUNCTION | Location list with pagination |
| `get_shift_timeline` | FUNCTION | Return cached matches or compute new |

### RLS Policies

| Table | Policy | Roles | Action |
|-------|--------|-------|--------|
| `locations` | `locations_select_policy` | supervisor+ | SELECT |
| `locations` | `locations_insert_policy` | supervisor+ | INSERT |
| `locations` | `locations_update_policy` | supervisor+ | UPDATE |
| `locations` | `locations_delete_policy` | admin, super_admin | DELETE |
| `location_matches` | `location_matches_select_policy` | Based on shift access | SELECT |

---

## Relationships to Existing Entities

### gps_points (Existing)

No schema changes required. Location matches reference `gps_points.id` via foreign key.

### shifts (Existing)

No schema changes required. Timeline is computed for a shift by:
1. Fetching all `gps_points` for the shift
2. Matching each point to locations (or retrieving cached matches)
3. Computing segments and summary

### employee_profiles (Existing)

No direct relationship. Location access is based on user role, not employee ID.

---

## Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    SHIFT TIMELINE VIEW                          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
               ┌──────────────────────────────┐
               │ Check: Are location_matches  │
               │ cached for this shift?       │
               └──────────────────────────────┘
                      │              │
                   No │              │ Yes
                      ▼              ▼
        ┌─────────────────────┐  ┌─────────────────────┐
        │ Call RPC:           │  │ Fetch cached        │
        │ match_shift_gps_    │  │ location_matches    │
        │ to_locations()      │  │ from database       │
        └─────────────────────┘  └─────────────────────┘
                      │              │
                      ▼              │
        ┌─────────────────────┐      │
        │ Store matches in    │      │
        │ location_matches    │      │
        └─────────────────────┘      │
                      │              │
                      └──────┬───────┘
                             │
                             ▼
               ┌──────────────────────────────┐
               │ Compute timeline segments    │
               │ (client-side or RPC)         │
               └──────────────────────────────┘
                             │
                             ▼
               ┌──────────────────────────────┐
               │ Render: Timeline bar,        │
               │ summary stats, segmented map │
               └──────────────────────────────┘
```
