# Data Model: Route Map Matching & Real Route Visualization

**Feature**: 018-route-map-matching | **Date**: 2026-02-25

## Entity Changes

### trips (EXTENDED — migration 043)

Existing table gains new columns for route matching data.

```sql
-- New columns added to existing trips table
ALTER TABLE trips ADD COLUMN route_geometry TEXT;
ALTER TABLE trips ADD COLUMN road_distance_km DECIMAL(8, 3);
ALTER TABLE trips ADD COLUMN match_status TEXT NOT NULL DEFAULT 'pending'
    CHECK (match_status IN ('pending', 'processing', 'matched', 'failed', 'anomalous'));
ALTER TABLE trips ADD COLUMN match_confidence DECIMAL(3, 2)
    CHECK (match_confidence IS NULL OR (match_confidence >= 0 AND match_confidence <= 1));
ALTER TABLE trips ADD COLUMN match_error TEXT;
ALTER TABLE trips ADD COLUMN matched_at TIMESTAMPTZ;
ALTER TABLE trips ADD COLUMN match_attempts INTEGER NOT NULL DEFAULT 0;
```

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| `route_geometry` | TEXT | Yes | NULL | Encoded polyline (polyline6 format) of the matched road route |
| `road_distance_km` | DECIMAL(8,3) | Yes | NULL | OSRM-calculated road distance in km |
| `match_status` | TEXT | No | 'pending' | Current matching state: pending, processing, matched, failed, anomalous |
| `match_confidence` | DECIMAL(3,2) | Yes | NULL | OSRM matching confidence (0.00-1.00) |
| `match_error` | TEXT | Yes | NULL | Error message when match_status = 'failed' or 'anomalous' |
| `matched_at` | TIMESTAMPTZ | Yes | NULL | Timestamp when matching completed (success or failure) |
| `match_attempts` | INTEGER | No | 0 | Number of matching attempts made |

### State Transitions for match_status

```
                    ┌──────────────────────────────────────┐
                    │                                      │
   detect_trips()   │    match_trip_route()                │  match_trip_route()
   ──────────────►  │  ──────────────────────►             │  (retry, attempt ≤ 3)
     'pending' ─────┼──► 'processing' ───┬──► 'matched'   │
                    │                    ├──► 'failed' ────┘
                    │                    └──► 'anomalous'
                    │
                    │  Note: 'anomalous' = road_distance > 3× haversine;
                    │  trip keeps haversine distance, admin can review
```

### Indexes (new)

```sql
CREATE INDEX idx_trips_match_status ON trips(match_status);
```

### Existing Columns Behavior Change

| Column | Before | After |
|--------|--------|-------|
| `distance_km` | Always Haversine × 1.3 | Updated to `road_distance_km` when `match_status = 'matched'`; retains Haversine × 1.3 when `match_status` is 'pending', 'failed', or 'anomalous' |

### No New Tables

The spec's "Matching Job" entity is implemented as state columns on `trips` rather than a separate table. This follows YAGNI — the matching lifecycle is simple enough to track inline:
- `match_status`: Job state (pending → processing → matched/failed/anomalous)
- `match_attempts`: Retry counter
- `match_error`: Failure reason
- `matched_at`: Completion timestamp

---

## Migration: 043_route_map_matching.sql

```sql
-- =============================================================================
-- 043: Route Map Matching - Add route geometry and matching status to trips
-- Feature: 018-route-map-matching
-- =============================================================================

-- Route geometry: encoded polyline (polyline6 format) from OSRM
ALTER TABLE trips ADD COLUMN route_geometry TEXT;

-- Road-based distance from OSRM (replaces Haversine estimate when available)
ALTER TABLE trips ADD COLUMN road_distance_km DECIMAL(8, 3);

-- Matching status lifecycle
ALTER TABLE trips ADD COLUMN match_status TEXT NOT NULL DEFAULT 'pending'
    CHECK (match_status IN ('pending', 'processing', 'matched', 'failed', 'anomalous'));

-- OSRM matching confidence (0.00 to 1.00)
ALTER TABLE trips ADD COLUMN match_confidence DECIMAL(3, 2)
    CHECK (match_confidence IS NULL OR (match_confidence >= 0 AND match_confidence <= 1));

-- Error details for failed/anomalous matches
ALTER TABLE trips ADD COLUMN match_error TEXT;

-- Timestamp when matching completed
ALTER TABLE trips ADD COLUMN matched_at TIMESTAMPTZ;

-- Retry counter (max 3 attempts)
ALTER TABLE trips ADD COLUMN match_attempts INTEGER NOT NULL DEFAULT 0;

-- Index for querying unmatched trips (batch processing, monitoring)
CREATE INDEX idx_trips_match_status ON trips(match_status);

-- Set existing trips to 'pending' so they can be batch-processed
-- (They already have Haversine distances, so no data loss)
-- Note: match_status defaults to 'pending' via column default

COMMENT ON COLUMN trips.route_geometry IS 'Encoded polyline6 of road-matched route from OSRM';
COMMENT ON COLUMN trips.road_distance_km IS 'Road-based distance in km from OSRM (replaces Haversine when matched)';
COMMENT ON COLUMN trips.match_status IS 'Map matching lifecycle: pending→processing→matched/failed/anomalous';
```

---

## Flutter Model Changes

### Trip Model (extended)

```dart
// New fields added to Trip model
class Trip {
  // ... existing fields ...

  // Route matching fields (new)
  final String? routeGeometry;     // Encoded polyline6 string
  final double? roadDistanceKm;    // OSRM road distance
  final String matchStatus;        // 'pending', 'processing', 'matched', 'failed', 'anomalous'
  final double? matchConfidence;   // 0.0-1.0
  final String? matchError;
  final DateTime? matchedAt;
  final int matchAttempts;

  // Computed properties
  bool get isRouteMatched => matchStatus == 'matched';
  bool get isRouteEstimated => matchStatus != 'matched';
  bool get isMatchPending => matchStatus == 'pending' || matchStatus == 'processing';
  bool get isMatchFailed => matchStatus == 'failed';
  bool get isMatchAnomalous => matchStatus == 'anomalous';
  bool get canRetryMatch => matchAttempts < 3 && (matchStatus == 'failed');

  /// Effective distance: road distance if matched, haversine otherwise
  double get effectiveDistanceKm => roadDistanceKm ?? distanceKm;
}
```

### LocalTrip Model (SQLCipher — extended)

```dart
// New fields for local cache
class LocalTrip {
  // ... existing fields ...
  final String? routeGeometry;
  final double? roadDistanceKm;
  final String matchStatus;        // Default: 'pending'
  final double? matchConfidence;
}
```

---

## Dashboard Type Changes

```typescript
// Extended Trip type
interface Trip {
  // ... existing fields ...

  // Route matching (new)
  route_geometry: string | null;    // Encoded polyline6
  road_distance_km: number | null;  // Road distance
  match_status: 'pending' | 'processing' | 'matched' | 'failed' | 'anomalous';
  match_confidence: number | null;
  match_error: string | null;
  matched_at: string | null;
  match_attempts: number;
}
```

---

## RPC Changes

### detect_trips (MODIFIED)

No changes to the detection logic itself. The only change is that newly created trips now include `match_status = 'pending'` (via column default). The 1.3× correction factor remains as the initial `distance_km` value; it gets replaced when route matching succeeds.

### get_mileage_summary (NO CHANGES)

Continues to use `trips.distance_km` for reimbursement calculation. When route matching updates `distance_km` with the road-based distance, the summary automatically reflects the improved accuracy.

### New: update_trip_match (RPC)

Called by the Edge Function to store matching results. Requires SECURITY DEFINER to bypass RLS (Edge Function uses service role key).

```sql
CREATE OR REPLACE FUNCTION update_trip_match(
    p_trip_id UUID,
    p_match_status TEXT,
    p_route_geometry TEXT DEFAULT NULL,
    p_road_distance_km DECIMAL DEFAULT NULL,
    p_match_confidence DECIMAL DEFAULT NULL,
    p_match_error TEXT DEFAULT NULL
) RETURNS VOID AS $$
BEGIN
    UPDATE trips SET
        match_status = p_match_status,
        route_geometry = COALESCE(p_route_geometry, route_geometry),
        road_distance_km = COALESCE(p_road_distance_km, road_distance_km),
        match_confidence = COALESCE(p_match_confidence, match_confidence),
        match_error = p_match_error,
        matched_at = NOW(),
        match_attempts = match_attempts + 1,
        -- Update distance_km with road distance when matched
        distance_km = CASE
            WHEN p_match_status = 'matched' AND p_road_distance_km IS NOT NULL
            THEN p_road_distance_km
            ELSE distance_km
        END
    WHERE id = p_trip_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```
