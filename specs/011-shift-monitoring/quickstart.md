# Quickstart: Shift Monitoring

**Feature Branch**: `011-shift-monitoring`
**Created**: 2026-01-15

## Prerequisites

- Existing dashboard running (`dashboard/` directory)
- Supabase project with migrations applied (specs 001-010)
- Node.js 18.x LTS installed
- Manager or admin account for testing

## Quick Setup

### 1. Install New Dependencies

```bash
cd dashboard
npm install react-leaflet leaflet date-fns
npm install -D @types/leaflet
```

### 2. Apply Database Migration

```bash
cd supabase
supabase db push
```

This applies the new RPC functions:
- `get_monitored_team`
- `get_shift_detail`
- `get_shift_gps_trail`
- `get_employee_current_shift`

### 3. Start Development Server

```bash
cd dashboard
npm run dev
```

### 4. Access Monitoring Dashboard

Navigate to: `http://localhost:3000/dashboard/monitoring`

Login as:
- **Admin/Super Admin**: Sees all employees
- **Manager**: Sees only supervised employees

## Feature Verification

### Test Real-Time Updates

1. Open monitoring dashboard in browser
2. In a separate window, trigger a clock-in via mobile app or direct API:

```bash
# Example: Clock in an employee (replace with valid credentials)
curl -X POST 'https://your-project.supabase.co/rest/v1/rpc/clock_in' \
  -H "Authorization: Bearer <employee-jwt>" \
  -H "Content-Type: application/json" \
  -d '{"p_latitude": 37.7749, "p_longitude": -122.4194, "p_accuracy": 10}'
```

3. Observe status update within 60 seconds (no page refresh)

### Test Map Display

1. Navigate to monitoring page
2. Employees with active shifts show as markers on map
3. Click a marker to see employee name and last update time
4. Stale locations (>5 min) show warning indicator

### Test Shift Detail

1. Click an employee row in the team list
2. Detail page shows:
   - Shift start time
   - Live duration counter
   - GPS trail on map (for active shifts)
3. New GPS points appear on trail within 60 seconds

### Test Filtering

1. Use search box to filter by employee name
2. Toggle between "All", "On-shift", "Off-shift" filter
3. Verify team list updates immediately

## Key Files Created

```
dashboard/src/
├── app/dashboard/monitoring/
│   ├── page.tsx                    # Team overview page
│   └── [employeeId]/page.tsx       # Shift detail page
├── components/monitoring/
│   ├── team-list.tsx               # Employee status list
│   ├── team-filters.tsx            # Search and status filter
│   ├── team-map.tsx                # Interactive map
│   ├── location-marker.tsx         # Map marker component
│   ├── shift-detail-card.tsx       # Shift info display
│   ├── gps-trail-map.tsx           # Trail visualization
│   ├── duration-counter.tsx        # Live HH:MM:SS
│   ├── staleness-indicator.tsx     # Freshness badge
│   └── empty-states.tsx            # No data states
├── lib/hooks/
│   ├── use-realtime-shifts.ts      # Shift subscriptions
│   ├── use-realtime-gps.ts         # GPS subscriptions
│   └── use-supervised-team.ts      # Combined team data
├── lib/validations/
│   └── monitoring.ts               # Zod schemas
└── types/
    └── monitoring.ts               # TypeScript types

supabase/migrations/
└── XXX_add_monitoring_functions.sql # New RPC functions
```

## Common Issues

### Map Not Rendering

Ensure Leaflet CSS is imported:

```typescript
// In layout.tsx or monitoring page
import 'leaflet/dist/leaflet.css'
```

Use dynamic import for SSR:

```typescript
const TeamMap = dynamic(() => import('@/components/monitoring/team-map'), {
  ssr: false,
  loading: () => <Skeleton className="h-[400px]" />
})
```

### Realtime Updates Not Working

1. Verify Supabase Realtime is enabled in dashboard
2. Check browser console for WebSocket errors
3. Ensure RLS policies allow SELECT for authenticated user
4. Verify employee is in supervisor's team

### Empty Team List

1. Verify logged-in user has supervisor relationships:

```sql
SELECT * FROM employee_supervisors
WHERE manager_id = 'your-user-id'
  AND effective_to IS NULL;
```

2. Or login as admin/super_admin to see all employees

### GPS Trail Not Showing

- Per spec, GPS trail only displays for **active** shifts
- Completed shifts show times/duration but no location data
- Verify shift status is 'active' in database

## Environment Variables

No new environment variables required. Uses existing:

```
NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=your-anon-key
```

## Testing Checklist

- [ ] Team list shows supervised employees
- [ ] On-shift/off-shift status accurate
- [ ] Duration counter updates every second
- [ ] Map displays employee markers
- [ ] Stale indicator shows for old locations
- [ ] Real-time clock-in updates list
- [ ] Real-time clock-out updates list
- [ ] Real-time GPS updates marker position
- [ ] Shift detail shows GPS trail
- [ ] Trail updates with new points
- [ ] Search filters employee list
- [ ] Status filter works correctly
- [ ] Empty states display appropriately
- [ ] Network offline shows warning
