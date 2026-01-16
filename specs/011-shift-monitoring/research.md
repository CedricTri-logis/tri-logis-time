# Research: Shift Monitoring

**Feature Branch**: `011-shift-monitoring`
**Created**: 2026-01-15
**Status**: Complete

## Research Tasks

### 1. Map Library Selection for React/Next.js

**Decision**: react-leaflet with Leaflet.js

**Rationale**:
- Open-source and free (no API key required, unlike Google Maps or Mapbox)
- Excellent React integration via react-leaflet
- Supports custom markers, polylines (GPS trails), and clustering
- OpenStreetMap tiles available without billing
- Lightweight compared to Google Maps SDK
- Well-documented with active community
- Works with Next.js SSR when using dynamic imports (`next/dynamic`)

**Alternatives Considered**:
- **Google Maps (@react-google-maps/api)**: Requires API key and billing, more complex setup, overkill for internal tool
- **Mapbox (react-map-gl)**: Requires API key with free tier limits, Mapbox-specific styling
- **@vis.gl/react-google-maps**: Google's official library but requires billing setup

**Implementation Notes**:
- Use `next/dynamic` with `ssr: false` for map components
- Import Leaflet CSS in layout or component
- Consider react-leaflet-cluster for marker clustering if teams grow large

### 2. Supabase Realtime Integration Patterns

**Decision**: Channel-based subscriptions with PostgreSQL Changes

**Rationale**:
- Built into @supabase/supabase-js (already installed)
- PostgreSQL Changes provides row-level updates
- Supports filtering by table and specific conditions
- Automatic reconnection and error handling
- No additional infrastructure needed

**Alternatives Considered**:
- **Polling with setInterval**: Higher latency, more server load, not push-based
- **Server-Sent Events (custom)**: Requires additional backend setup
- **WebSocket (custom)**: Reinventing what Supabase provides

**Implementation Pattern**:
```typescript
// Subscribe to shifts table changes for supervised employees
const channel = supabase
  .channel('shifts-realtime')
  .on(
    'postgres_changes',
    {
      event: '*',
      schema: 'public',
      table: 'shifts',
      filter: `employee_id=in.(${employeeIds.join(',')})`
    },
    (payload) => handleShiftChange(payload)
  )
  .subscribe()
```

**Key Considerations**:
- Create custom React hooks (`useRealtimeShifts`, `useRealtimeGps`)
- Clean up subscriptions on component unmount
- Handle connection state (connecting, connected, disconnected)
- Combine with initial data fetch for complete state
- RLS policies automatically filter to authorized data

### 3. Real-Time Duration Counter Implementation

**Decision**: Client-side interval with React state

**Rationale**:
- Shift start time is fixed; duration is `now - clocked_in_at`
- No server roundtrip needed for display updates
- Standard React pattern with `useEffect` and `setInterval`
- Syncs with server on initial load and realtime updates

**Implementation Pattern**:
```typescript
function useLiveDuration(clockedInAt: Date | null) {
  const [duration, setDuration] = useState(() =>
    clockedInAt ? differenceInSeconds(new Date(), clockedInAt) : 0
  )

  useEffect(() => {
    if (!clockedInAt) return
    const interval = setInterval(() => {
      setDuration(differenceInSeconds(new Date(), clockedInAt))
    }, 1000) // Update every second
    return () => clearInterval(interval)
  }, [clockedInAt])

  return duration
}
```

**Formatting**: Use `date-fns` or simple math for HH:MM:SS display

### 4. GPS Data Staleness Detection

**Decision**: Client-side timestamp comparison with visual indicators

**Rationale**:
- Staleness threshold defined in spec (5 minutes)
- Simple comparison: `now - captured_at > 5 minutes`
- No server logic needed; pure UI concern
- Can show gradient indicators (fresh → stale → very stale)

**Implementation Pattern**:
```typescript
type StalenessLevel = 'fresh' | 'stale' | 'very-stale' | 'unknown'

function getStalenessLevel(capturedAt: Date | null): StalenessLevel {
  if (!capturedAt) return 'unknown'
  const ageMinutes = differenceInMinutes(new Date(), capturedAt)
  if (ageMinutes <= 5) return 'fresh'
  if (ageMinutes <= 15) return 'stale'
  return 'very-stale'
}
```

**Visual Indicators**:
- Fresh (green): Data updated within 5 minutes
- Stale (yellow/orange): Data 5-15 minutes old
- Very Stale (red): Data >15 minutes old
- Unknown (gray): No GPS data received

### 5. GPS Trail Rendering for Performance

**Decision**: Polyline with point reduction for large trails

**Rationale**:
- react-leaflet Polyline component handles connected paths
- For 500+ points, apply Douglas-Peucker simplification
- Start/end markers with direction indicators
- Click handlers on trail points for timestamp display

**Implementation Pattern**:
```typescript
// Use react-leaflet Polyline
<Polyline
  positions={gpsPoints.map(p => [p.latitude, p.longitude])}
  pathOptions={{ color: 'blue', weight: 3 }}
/>

// For large trails, reduce points client-side
import simplify from 'simplify-js' // Or implement Douglas-Peucker
const simplified = simplify(points, tolerance)
```

**Performance Considerations**:
- Limit initial fetch to active shift's GPS points
- Paginate historical data if needed
- Use `useMemo` for expensive point transformations
- Consider canvas renderer for very large datasets

### 6. Access Control and Authorization

**Decision**: Leverage existing RLS + middleware + role checks

**Rationale**:
- Existing middleware already protects `/dashboard` routes
- RLS policies on shifts/gps_points filter by supervisor relationship
- Role check in middleware allows admin/super_admin access
- Managers see only their supervised employees via RPC functions

**Existing Infrastructure**:
- `middleware.ts`: Auth + role check (admin, super_admin allowed)
- RLS on `shifts`: Employees see own, supervisors see supervised
- RLS on `gps_points`: Same pattern as shifts
- `employee_supervisors` table: Defines supervision relationships

**Additional Consideration**:
- For managers (not admin/super_admin), restrict monitoring to their team
- Use existing `get_supervised_employees` RPC or similar
- Verify role in page component and show appropriate empty state

### 7. Graceful Degradation for Map Service

**Decision**: Conditional rendering with fallback UI

**Rationale**:
- Spec requires graceful degradation when map unavailable
- Team list remains functional regardless of map status
- Show last known positions with warning banner
- Cache considerations for tile layer

**Implementation Pattern**:
```typescript
function TeamMap({ employees }) {
  const [mapError, setMapError] = useState(false)

  if (mapError) {
    return (
      <Card>
        <Alert variant="warning">
          Map service unavailable. Showing last known positions.
        </Alert>
        <LocationList employees={employees} />
      </Card>
    )
  }

  return (
    <MapContainer onError={() => setMapError(true)}>
      {/* Map content */}
    </MapContainer>
  )
}
```

### 8. Empty States and Edge Cases

**Decision**: Dedicated components with informative messages

**Rationale**:
- Spec explicitly defines empty state requirements
- Multiple scenarios: no team, no active shifts, no GPS data, offline
- Consistent UI pattern with existing dashboard

**Empty State Scenarios**:
1. No supervised employees → "No team members assigned"
2. No active shifts → "All team members are off-shift"
3. Active shift, no GPS → "Location pending" on marker
4. Poor GPS accuracy → Accuracy circle radius + warning badge
5. Network offline → "Connection lost" banner with last update time

## Dependencies to Add

```json
{
  "dependencies": {
    "react-leaflet": "^4.2.1",
    "leaflet": "^1.9.4",
    "date-fns": "^3.0.0"
  },
  "devDependencies": {
    "@types/leaflet": "^1.9.8"
  }
}
```

**Note**: Check if `date-fns` is already installed; it's commonly used in dashboards.

## New Database Functions Required

Based on existing RPC patterns, the following new functions are needed:

1. **`get_monitored_team`**: Returns supervised employees with current shift status and latest GPS
2. **`get_shift_gps_trail`**: Returns GPS points for a specific shift (active only per spec)

These build on existing patterns in `get_supervised_employees` and `get_shift_gps_points`.

## Summary

All technical decisions align with the existing dashboard architecture and constitution requirements. Key additions are:
- react-leaflet for map rendering
- Supabase Realtime for push updates
- Client-side duration/staleness calculations
- New RPC functions for monitoring-specific data shapes
