# Contract: match-trip-route Edge Function

**Type**: Supabase Edge Function (Deno)
**Method**: POST
**Auth**: Service role key (internal use) or authenticated user JWT

## Request

```typescript
interface MatchTripRouteRequest {
  trip_id: string;  // UUID of the trip to match
}
```

## Response

### Success (200)
```typescript
interface MatchTripRouteResponse {
  success: true;
  trip_id: string;
  match_status: 'matched' | 'failed' | 'anomalous';
  road_distance_km: number | null;    // km, 3 decimal places
  match_confidence: number | null;    // 0.0-1.0
  geometry_points: number;            // Number of points in matched route
  haversine_distance_km: number;      // Original Haversine distance (for comparison)
  distance_change_pct: number | null; // % change from Haversine to road distance
}
```

### Error (4xx/5xx)
```typescript
interface MatchTripRouteError {
  success: false;
  error: string;
  code: 'TRIP_NOT_FOUND' | 'NO_GPS_POINTS' | 'INSUFFICIENT_POINTS'
      | 'OSRM_UNAVAILABLE' | 'OSRM_ERROR' | 'MAX_ATTEMPTS_REACHED'
      | 'INTERNAL_ERROR';
}
```

## Processing Logic

### Step 1: Fetch Trip & GPS Points
```sql
-- Get trip details
SELECT id, distance_km, match_attempts FROM trips WHERE id = :trip_id;

-- Get GPS points for the trip (ordered by sequence)
SELECT gp.latitude, gp.longitude, gp.accuracy, gp.captured_at
FROM trip_gps_points tgp
JOIN gps_points gp ON gp.id = tgp.gps_point_id
WHERE tgp.trip_id = :trip_id
ORDER BY tgp.sequence_order ASC;
```

### Step 2: Validate & Prepare
- If `match_attempts >= 3`: Return error `MAX_ATTEMPTS_REACHED`
- If GPS points < 3: Return error `INSUFFICIENT_POINTS`, set `match_status = 'failed'`
- If GPS points > 100: Simplify trace (select every Nth point, preserve first/last)
- Set `match_status = 'processing'` on trip

### Step 3: Call OSRM Match API
```
GET {OSRM_BASE_URL}/match/v1/driving/{coordinates}
    ?timestamps={timestamps}
    &radiuses={radiuses}
    &geometries=polyline6
    &overview=full
    &gaps=split
```

Parameters:
- `coordinates`: `lon1,lat1;lon2,lat2;...` (longitude first!)
- `timestamps`: Unix timestamps in seconds, separated by `;`
- `radiuses`: GPS accuracy in meters per point (clamped to 5-100m range)
- Default radius: 30m when accuracy is null

### Step 4: Validate OSRM Response
1. Check response status (`Ok` = success)
2. Extract first matching (or combine if `gaps=split` produced multiple)
3. **Anomaly check**: If `road_distance > 3 × haversine_distance`:
   - Set `match_status = 'anomalous'`
   - Set `match_error = 'Road distance {X}km exceeds 3× haversine {Y}km'`
   - Do NOT update `distance_km`
4. **Low confidence check**: If `confidence < 0.3`:
   - Set `match_status = 'failed'`
   - Set `match_error = 'Match confidence too low: {confidence}'`
5. **Matched points check**: If <50% of tracepoints matched:
   - Set `match_status = 'failed'`
   - Set `match_error = 'Only {N}% of GPS points matched to roads'`

### Step 5: Store Results
```sql
SELECT update_trip_match(
    p_trip_id := :trip_id,
    p_match_status := :status,
    p_route_geometry := :geometry,        -- polyline6 string
    p_road_distance_km := :distance / 1000, -- OSRM returns meters
    p_match_confidence := :confidence,
    p_match_error := :error
);
```

## Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `OSRM_BASE_URL` | OSRM server URL | `http://osrm.example.com:5000` |
| `SUPABASE_URL` | Supabase project URL | `https://xdyzdclwvhkfwbkrdsiz.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | Service role key for RPC calls | `eyJ...` |

## Trace Simplification Algorithm

When GPS points > 100 (OSRM default limit):
```typescript
function simplifyTrace(points: GpsPoint[], maxPoints: number): GpsPoint[] {
  if (points.length <= maxPoints) return points;
  const step = (points.length - 2) / (maxPoints - 2);
  const result = [points[0]]; // Always keep first
  for (let i = 1; i < maxPoints - 1; i++) {
    result.push(points[Math.round(i * step)]);
  }
  result.push(points[points.length - 1]); // Always keep last
  return result;
}
```

## Multiple Matchings Handling

When `gaps=split` produces multiple matchings (due to GPS gaps):
```typescript
// Combine all matchings into one result
const totalDistance = matchings.reduce((sum, m) => sum + m.distance, 0);
const avgConfidence = matchings.reduce((sum, m) => sum + m.confidence, 0) / matchings.length;
const combinedGeometry = combinePolylines(matchings.map(m => m.geometry));
```
