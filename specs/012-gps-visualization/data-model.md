# Data Model: GPS Visualization

**Feature Branch**: `012-gps-visualization`
**Date**: 2026-01-15

## Overview

This document defines the data entities, TypeScript types, and state models for the GPS Visualization feature. This feature extends existing database tables without adding new tables.

---

## Existing Entities (No Modifications)

### shifts (PostgreSQL Table)

Already exists from Spec 003. Used as-is for historical shift queries.

```sql
-- Key columns for this feature:
id UUID PRIMARY KEY
employee_id UUID NOT NULL REFERENCES employee_profiles(id)
status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'completed'))
clocked_in_at TIMESTAMPTZ NOT NULL
clocked_out_at TIMESTAMPTZ
clock_in_location JSONB  -- {latitude: number, longitude: number}
clock_out_location JSONB
```

### gps_points (PostgreSQL Table)

Already exists from Spec 003. Used as-is for GPS trail retrieval.

```sql
-- Key columns for this feature:
id UUID PRIMARY KEY
shift_id UUID NOT NULL REFERENCES shifts(id)
employee_id UUID NOT NULL REFERENCES employee_profiles(id)
latitude DECIMAL(10, 8) NOT NULL
longitude DECIMAL(11, 8) NOT NULL
accuracy DECIMAL(8, 2)  -- GPS accuracy in meters
captured_at TIMESTAMPTZ NOT NULL
```

### employee_supervisors (PostgreSQL Table)

Already exists from Spec 010. Used for authorization checks.

```sql
-- Key columns for this feature:
manager_id UUID REFERENCES employee_profiles(id)
employee_id UUID REFERENCES employee_profiles(id)
effective_to TIMESTAMPTZ  -- NULL means currently active
```

---

## New TypeScript Types

### File: `dashboard/src/types/history.ts`

```typescript
/**
 * GPS Trail point for visualization
 * Matches RPC return structure from get_historical_shift_trail
 */
export interface HistoricalGpsPoint {
  id: string;
  latitude: number;
  longitude: number;
  accuracy: number | null;
  captured_at: string; // ISO timestamp
}

/**
 * Shift summary for history list view
 * Matches RPC return structure from get_employee_shift_history
 */
export interface ShiftHistorySummary {
  id: string;
  employee_id: string;
  employee_name: string;
  clocked_in_at: string;
  clocked_out_at: string;
  duration_minutes: number;
  gps_point_count: number;
  total_distance_km: number | null;
  clock_in_latitude: number | null;
  clock_in_longitude: number | null;
  clock_out_latitude: number | null;
  clock_out_longitude: number | null;
}

/**
 * Multi-shift GPS point with shift identification
 * Matches RPC return structure from get_multi_shift_trails
 */
export interface MultiShiftGpsPoint extends HistoricalGpsPoint {
  shift_id: string;
  shift_date: string; // Date only (YYYY-MM-DD)
}

/**
 * Playback control state
 */
export interface PlaybackState {
  isPlaying: boolean;
  currentIndex: number;
  speedMultiplier: PlaybackSpeed;
  elapsedMs: number;
  totalDurationMs: number;
}

export type PlaybackSpeed = 0.5 | 1 | 2 | 4;

export const PLAYBACK_SPEEDS: { value: PlaybackSpeed; label: string }[] = [
  { value: 0.5, label: '0.5x (Slow)' },
  { value: 1, label: '1x (Normal)' },
  { value: 2, label: '2x (Fast)' },
  { value: 4, label: '4x (Very Fast)' },
];

/**
 * Export configuration options
 */
export interface GpsExportOptions {
  format: 'csv' | 'geojson';
  includeMetadata: boolean;
  dateRange?: {
    start: string;
    end: string;
  };
}

/**
 * Export metadata included in files
 */
export interface GpsExportMetadata {
  employee_name: string;
  employee_id: string;
  date_range: string;
  total_distance_km: number;
  total_points: number;
  generated_at: string;
}

/**
 * Multi-shift view configuration
 */
export interface MultiShiftViewConfig {
  employeeId: string;
  startDate: string; // YYYY-MM-DD
  endDate: string;   // YYYY-MM-DD
  selectedShiftIds: string[];
}

/**
 * Trail rendering configuration
 */
export interface TrailRenderConfig {
  simplified: boolean;
  simplificationEpsilon: number;
  showAccuracyCircles: boolean;
  showTimestamps: boolean;
}

/**
 * Color assignment for multi-shift trails
 */
export interface ShiftColorMapping {
  shiftId: string;
  shiftDate: string;
  color: string; // HSL color string
}
```

---

## State Models

### Playback Animation State

```typescript
// Managed by usePlaybackAnimation hook
interface PlaybackAnimationState {
  // Core playback state
  state: PlaybackState;

  // Trail data
  trail: HistoricalGpsPoint[];

  // Derived values
  currentPoint: HistoricalGpsPoint | null;
  progress: number; // 0-1 percentage

  // Actions
  play: () => void;
  pause: () => void;
  seek: (index: number) => void;
  setSpeed: (speed: PlaybackSpeed) => void;
  reset: () => void;
}
```

### Multi-Shift Map State

```typescript
// Managed by useMultiShiftMap hook
interface MultiShiftMapState {
  // Configuration
  config: MultiShiftViewConfig;

  // Data
  trails: Map<string, MultiShiftGpsPoint[]>;
  colorMappings: ShiftColorMapping[];

  // UI state
  highlightedShiftId: string | null;
  isLoading: boolean;
  error: string | null;

  // Actions
  setDateRange: (start: string, end: string) => void;
  toggleShiftSelection: (shiftId: string) => void;
  highlightShift: (shiftId: string | null) => void;
  refreshData: () => void;
}
```

### Export State

```typescript
// Managed by useGpsExport hook
interface ExportState {
  isExporting: boolean;
  progress: number; // 0-100 for large exports
  error: string | null;

  // Actions
  exportCsv: (points: HistoricalGpsPoint[], metadata: GpsExportMetadata) => void;
  exportGeoJson: (points: HistoricalGpsPoint[], metadata: GpsExportMetadata) => void;
  exportMultiShift: (
    trails: Map<string, MultiShiftGpsPoint[]>,
    metadata: GpsExportMetadata
  ) => void;
}
```

---

## Validation Schemas (Zod)

### File: `dashboard/src/lib/validations/history.ts`

```typescript
import { z } from 'zod';

/**
 * Date range validation for shift history queries
 */
export const dateRangeSchema = z.object({
  startDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Invalid date format'),
  endDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Invalid date format'),
}).refine(
  (data) => new Date(data.startDate) <= new Date(data.endDate),
  { message: 'Start date must be before or equal to end date' }
).refine(
  (data) => {
    const start = new Date(data.startDate);
    const end = new Date(data.endDate);
    const diffDays = (end.getTime() - start.getTime()) / (1000 * 60 * 60 * 24);
    return diffDays <= 7;
  },
  { message: 'Date range cannot exceed 7 days' }
).refine(
  (data) => {
    const now = new Date();
    const start = new Date(data.startDate);
    const diffDays = (now.getTime() - start.getTime()) / (1000 * 60 * 60 * 24);
    return diffDays <= 90;
  },
  { message: 'Cannot query data older than 90 days' }
);

/**
 * Export options validation
 */
export const exportOptionsSchema = z.object({
  format: z.enum(['csv', 'geojson']),
  includeMetadata: z.boolean().default(true),
  dateRange: dateRangeSchema.optional(),
});

/**
 * Playback speed validation
 */
export const playbackSpeedSchema = z.union([
  z.literal(0.5),
  z.literal(1),
  z.literal(2),
  z.literal(4),
]);

/**
 * Shift ID array validation (for multi-shift queries)
 */
export const shiftIdsSchema = z.array(z.string().uuid()).min(1).max(10);
```

---

## RPC Function Contracts

### get_historical_shift_trail

**Purpose**: Retrieve GPS trail for a completed shift (within 90-day retention)

**Input**:
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| p_shift_id | UUID | Yes | Shift to retrieve GPS points for |

**Output**:
| Column | Type | Description |
|--------|------|-------------|
| id | UUID | GPS point ID |
| latitude | DECIMAL(10,8) | Latitude coordinate |
| longitude | DECIMAL(11,8) | Longitude coordinate |
| accuracy | DECIMAL(8,2) | GPS accuracy in meters |
| captured_at | TIMESTAMPTZ | Timestamp of GPS capture |

**Authorization**: Caller must supervise the shift's employee OR be admin/super_admin
**Constraint**: Shift must have clocked_in_at within last 90 days

---

### get_employee_shift_history

**Purpose**: List completed shifts for an employee with summary statistics

**Input**:
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| p_employee_id | UUID | Yes | Employee to query shifts for |
| p_start_date | DATE | Yes | Start of date range |
| p_end_date | DATE | Yes | End of date range |

**Output**:
| Column | Type | Description |
|--------|------|-------------|
| id | UUID | Shift ID |
| employee_id | UUID | Employee ID |
| employee_name | TEXT | Employee full name |
| clocked_in_at | TIMESTAMPTZ | Shift start time |
| clocked_out_at | TIMESTAMPTZ | Shift end time |
| duration_minutes | INTEGER | Shift duration in minutes |
| gps_point_count | BIGINT | Number of GPS points recorded |
| total_distance_km | DECIMAL | Total distance traveled (calculated) |
| clock_in_latitude | DECIMAL | Start location latitude |
| clock_in_longitude | DECIMAL | Start location longitude |
| clock_out_latitude | DECIMAL | End location latitude |
| clock_out_longitude | DECIMAL | End location longitude |

**Authorization**: Caller must supervise the employee OR be admin/super_admin
**Constraint**: Date range must be within last 90 days

---

### get_multi_shift_trails

**Purpose**: Retrieve GPS trails for multiple shifts at once

**Input**:
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| p_shift_ids | UUID[] | Yes | Array of shift IDs (max 10) |

**Output**:
| Column | Type | Description |
|--------|------|-------------|
| id | UUID | GPS point ID |
| shift_id | UUID | Associated shift ID |
| shift_date | DATE | Date of the shift |
| latitude | DECIMAL(10,8) | Latitude coordinate |
| longitude | DECIMAL(11,8) | Longitude coordinate |
| accuracy | DECIMAL(8,2) | GPS accuracy in meters |
| captured_at | TIMESTAMPTZ | Timestamp of GPS capture |

**Authorization**: All shifts must belong to supervised employees
**Constraint**: All shifts must be within 90-day retention period

---

## Entity Relationships

```
┌─────────────────────┐      ┌─────────────────────┐
│  employee_profiles  │      │  employee_supervisors│
│  (existing)         │◄─────│  (existing)          │
│                     │      │  manager_id ────────►│
│  id ◄───────────────┼──────┤  employee_id        │
│  full_name          │      │  effective_to       │
│  employee_id        │      └─────────────────────┘
└─────────┬───────────┘
          │
          │ 1:N
          ▼
┌─────────────────────┐
│  shifts (existing)  │
│                     │
│  id ◄───────────────┼──────┐
│  employee_id        │      │
│  status             │      │
│  clocked_in_at      │      │ 1:N
│  clocked_out_at     │      │
│  clock_in_location  │      │
│  clock_out_location │      │
└─────────────────────┘      │
                             │
                             ▼
                    ┌─────────────────────┐
                    │  gps_points (existing)│
                    │                     │
                    │  id                 │
                    │  shift_id           │
                    │  employee_id        │
                    │  latitude           │
                    │  longitude          │
                    │  accuracy           │
                    │  captured_at        │
                    └─────────────────────┘
```

---

## Data Retention

| Entity | Retention Period | Enforcement |
|--------|-----------------|-------------|
| shifts | 90 days | RPC WHERE clause |
| gps_points | 90 days | Cascades from shifts |

**Note**: The 90-day retention is enforced at the query level in RPC functions. A future cleanup job should delete data beyond retention period.

---

## Performance Considerations

### Trail Simplification Thresholds

| Point Count | Action |
|-------------|--------|
| ≤500 | Display all points |
| 501-2000 | Apply Douglas-Peucker with epsilon=0.00001 |
| 2001-5000 | Apply Douglas-Peucker with epsilon=0.00005 |
| >5000 | Apply Douglas-Peucker with epsilon=0.0001 |

### Query Optimization

- `get_employee_shift_history`: Index on `shifts(employee_id, clocked_in_at DESC)` already exists
- `get_historical_shift_trail`: Index on `gps_points(shift_id, captured_at)` already exists
- Multi-shift queries: Batch shifts into single RPC call to reduce round-trips
