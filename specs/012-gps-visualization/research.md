# Research: GPS Visualization

**Feature Branch**: `012-gps-visualization`
**Date**: 2026-01-15

## Overview

This document captures research findings for implementing historical GPS visualization with playback, multi-shift aggregation, and export capabilities.

---

## Research Areas

### 1. Trail Simplification Algorithm

**Decision**: Douglas-Peucker algorithm for GPS trail simplification

**Rationale**:
- Douglas-Peucker is the standard algorithm for polyline simplification, preserving shape while reducing points
- Well-suited for GPS trails where we need to maintain path accuracy while reducing rendering overhead
- Configurable epsilon (tolerance) parameter allows tuning based on zoom level or point count
- O(n log n) average complexity, suitable for client-side processing

**Implementation Approach**:
- Implement pure TypeScript Douglas-Peucker function in `lib/utils/trail-simplify.ts`
- No external dependency needed (algorithm is ~30 lines of code)
- Apply simplification when point count exceeds 500 (per spec FR-014)
- Calculate epsilon dynamically based on map bounds/zoom level
- Preserve original points in state for "view full detail" toggle

**Alternatives Considered**:
- **Visvalingam-Whyatt**: Better for area preservation but less common for GPS trails
- **Ramer-Douglas-Peucker variants**: Overkill for our performance requirements
- **Server-side simplification**: Rejected - adds latency and complexity; client-side is sufficient for ~5,000 points

**Code Pattern**:
```typescript
interface GpsPoint {
  latitude: number;
  longitude: number;
  captured_at: string;
  accuracy?: number;
}

function simplifyTrail(points: GpsPoint[], epsilon: number): GpsPoint[] {
  if (points.length <= 2) return points;
  // Douglas-Peucker implementation
  // Returns subset of original points (preserves metadata)
}
```

---

### 2. Playback Animation with react-leaflet

**Decision**: Custom hook with `requestAnimationFrame` and Leaflet marker position updates

**Rationale**:
- react-leaflet doesn't have built-in animation support
- `requestAnimationFrame` provides smooth 60fps animations
- Direct Leaflet marker manipulation via refs avoids React re-render overhead
- Consistent with existing `gps-trail-map.tsx` patterns

**Implementation Approach**:
- Create `usePlaybackAnimation` hook managing playback state
- Store current position index, speed multiplier, and play/pause state
- Use `requestAnimationFrame` loop to advance through trail points
- Interpolate positions between GPS points for smooth movement
- Update Leaflet marker directly via `setLatLng()` method
- Sync timeline scrubber via React state (debounced for performance)

**Playback State Model**:
```typescript
interface PlaybackState {
  isPlaying: boolean;
  currentIndex: number;
  speedMultiplier: 0.5 | 1 | 2 | 4;
  elapsedMs: number;
  totalDurationMs: number;
}
```

**Animation Strategy**:
- Calculate time intervals between consecutive GPS points
- At 1x speed: animate in real-time proportional to actual GPS capture intervals
- At 4x speed: 4x faster than real-time
- Use linear interpolation (lerp) between points for smooth marker movement
- Skip large time gaps (>5 minutes) with visual indicator

**Alternatives Considered**:
- **Leaflet.AnimatedMarker plugin**: Abandoned/outdated, no TypeScript support
- **CSS animations**: Not suitable for geographic path following
- **Timer-based (setInterval)**: Less smooth than requestAnimationFrame

---

### 3. Client-Side Export (CSV/GeoJSON)

**Decision**: Client-side generation using Blob API and standard JSON/CSV formatting

**Rationale**:
- No server-side processing needed for standard datasets (<10,000 points)
- Immediate download without API round-trip
- User has control over when export happens
- Aligns with constitution principle VI (simplicity)

**CSV Export Format**:
```csv
shift_id,employee_name,timestamp,latitude,longitude,accuracy_meters
abc123,John Doe,2026-01-15T09:00:00Z,45.5017,-73.5673,10.5
abc123,John Doe,2026-01-15T09:05:00Z,45.5018,-73.5674,8.2
```

**GeoJSON Export Format**:
```json
{
  "type": "FeatureCollection",
  "metadata": {
    "employee_name": "John Doe",
    "date_range": "2026-01-15 to 2026-01-15",
    "total_distance_km": 5.2,
    "total_points": 150
  },
  "features": [
    {
      "type": "Feature",
      "geometry": {
        "type": "LineString",
        "coordinates": [[-73.5673, 45.5017], [-73.5674, 45.5018]]
      },
      "properties": {
        "shift_id": "abc123",
        "shift_date": "2026-01-15",
        "timestamps": ["2026-01-15T09:00:00Z", "2026-01-15T09:05:00Z"]
      }
    }
  ]
}
```

**Implementation Approach**:
- Create `lib/utils/export-gps.ts` with format-specific functions
- Use Blob API: `new Blob([content], { type: 'text/csv' })` or `application/geo+json`
- Trigger download via temporary anchor element with `download` attribute
- Include metadata header in CSV exports
- Multi-shift exports: separate features per shift in GeoJSON, grouped rows in CSV

**Large Export Handling**:
- For >10,000 points: show progress indicator during generation
- Use chunked processing with `setTimeout` to prevent UI blocking
- Consider web worker for very large exports (future enhancement)

**Alternatives Considered**:
- **Server-side generation**: Adds complexity, API endpoints, and latency
- **Third-party CSV library**: Unnecessary for simple tabular data
- **KML/GPX formats**: Out of scope per spec (CSV + GeoJSON sufficient)

---

### 4. Historical GPS Data Access Patterns

**Decision**: New RPC function `get_historical_shift_trail` that allows completed shifts (unlike current `get_shift_gps_trail`)

**Rationale**:
- Current `get_shift_gps_trail` (Spec 011) explicitly returns empty for completed shifts (FR-007: active shifts only)
- Historical visualization requires access to completed shift GPS data
- Must maintain same supervisor authorization checks
- Need to enforce 90-day retention at query level

**New RPC Functions Required**:

1. **`get_historical_shift_trail`**: Returns GPS points for any authorized shift within retention period
   - Parameters: `p_shift_id UUID`
   - Returns: Same structure as `get_shift_gps_trail`
   - Authorization: Supervisor relationship OR admin/super_admin role
   - Constraint: Shift must be within 90 days of current date

2. **`get_employee_shift_history`**: Returns completed shifts for an employee with GPS point counts
   - Parameters: `p_employee_id UUID`, `p_start_date DATE`, `p_end_date DATE`
   - Returns: Shift list with summary stats (duration, point count, distance)
   - Authorization: Same as above
   - Constraint: Date range within 90-day retention period

3. **`get_multi_shift_trails`**: Returns GPS trails for multiple shifts at once
   - Parameters: `p_shift_ids UUID[]`
   - Returns: GPS points with shift_id included for differentiation
   - Authorization: All shifts must belong to supervised employees
   - Constraint: All shifts within 90-day retention

**Existing Pattern Reference** (from `012_shift_monitoring.sql`):
```sql
-- Authorization pattern to reuse
IF v_user_role NOT IN ('admin', 'super_admin') THEN
  IF NOT EXISTS (
    SELECT 1 FROM employee_supervisors
    WHERE manager_id = v_user_id
      AND employee_supervisors.employee_id = v_shift_employee_id
      AND effective_to IS NULL
  ) THEN
    RETURN;
  END IF;
END IF;
```

**Alternatives Considered**:
- **Modifying existing RPC**: Would break Spec 011 contract (active-only requirement)
- **Direct table queries**: RLS alone is insufficient (need retention enforcement)
- **Single RPC for all use cases**: Too complex; separate functions are clearer

---

### 5. Distance Calculation

**Decision**: Haversine formula for total distance calculation

**Rationale**:
- Haversine is the standard formula for great-circle distance between two GPS coordinates
- Sufficient accuracy for shift-level distance tracking (not surveying-grade)
- Fast client-side calculation
- Already well-known pattern in GPS applications

**Implementation**:
```typescript
function haversineDistance(
  lat1: number, lon1: number,
  lat2: number, lon2: number
): number {
  const R = 6371; // Earth's radius in km
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a = Math.sin(dLat/2) * Math.sin(dLat/2) +
            Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) *
            Math.sin(dLon/2) * Math.sin(dLon/2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));
  return R * c;
}

function calculateTotalDistance(points: GpsPoint[]): number {
  let total = 0;
  for (let i = 1; i < points.length; i++) {
    total += haversineDistance(
      points[i-1].latitude, points[i-1].longitude,
      points[i].latitude, points[i].longitude
    );
  }
  return total;
}
```

---

### 6. Multi-Shift Trail Differentiation

**Decision**: Color-coded trails with shift date legend

**Rationale**:
- Visual differentiation is essential when viewing overlapping trails
- Color coding is intuitive and widely understood
- Legend provides context for date correlation
- Consistent with mapping application conventions

**Implementation Approach**:
- Generate distinct colors programmatically based on shift index
- Use HSL color space for perceptually distinct colors: `hsl(${index * 137.5 % 360}, 70%, 50%)`
- Golden angle (137.5°) ensures good color distribution
- Add legend overlay showing shift date → color mapping
- On hover/click: highlight specific shift trail, dim others
- Show shift date in popup when clicking trail segment

**Color Palette**:
- Maximum 7 shifts recommended (per spec: 7-day date range)
- Fallback to pattern differentiation if colors insufficient (dashed vs solid)

---

### 7. Map Service Fallback

**Decision**: Table view fallback when Leaflet fails to load

**Rationale**:
- Map tile servers may occasionally be unavailable
- Users should still access GPS data without map visualization
- Table format provides all raw data for analysis
- Meets FR-016 requirement

**Implementation**:
- Wrap map component in error boundary
- On map error: render `<GpsTrailTable>` component instead
- Table shows: timestamp, latitude, longitude, accuracy
- Include "Map unavailable" message with retry button
- Table supports sorting and filtering

---

## Summary of Decisions

| Area | Decision | Key Rationale |
|------|----------|---------------|
| Trail Simplification | Douglas-Peucker (client-side) | Standard algorithm, no dependencies |
| Playback Animation | requestAnimationFrame + Leaflet refs | Smooth 60fps, no re-renders |
| Export Format | CSV + GeoJSON (client-side) | No server dependency, immediate download |
| Historical Data | New RPC functions | Preserve Spec 011 contract, enforce retention |
| Distance Calculation | Haversine formula | Standard GPS distance calculation |
| Trail Differentiation | HSL color coding with legend | Intuitive, programmatic generation |
| Map Fallback | Table view on error | Data access guaranteed |

---

## Dependencies to Add

```json
{
  "dependencies": {
    // No new npm dependencies required
    // All implementations use native APIs:
    // - Blob API (export)
    // - requestAnimationFrame (animation)
    // - Built-in math functions (haversine, Douglas-Peucker)
  }
}
```

---

## Open Questions (Resolved)

All NEEDS CLARIFICATION items from Technical Context have been resolved:

1. ✅ Trail simplification threshold: 500 points (from spec FR-014)
2. ✅ Playback speeds: 0.5x, 1x, 2x, 4x (from spec clarifications)
3. ✅ Export formats: CSV, GeoJSON (from spec clarifications)
4. ✅ Map provider: Leaflet + OpenStreetMap (from spec assumptions)
5. ✅ Retention period: 90 days (from spec clarifications)
