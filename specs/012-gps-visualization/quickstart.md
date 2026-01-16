# Quickstart: GPS Visualization

**Feature Branch**: `012-gps-visualization`
**Date**: 2026-01-15

## Prerequisites

- Node.js 18.x LTS
- Existing dashboard running (from Spec 009-011)
- Supabase project with GPS data (shifts + gps_points)
- Supervisor role with assigned employees

## Quick Setup

### 1. Apply Database Migration

```bash
cd supabase

# Apply the GPS visualization migration
supabase db push

# Or manually if using local development:
psql -f migrations/013_gps_visualization.sql
```

### 2. Verify RPC Functions

Test the new functions are available:

```sql
-- In Supabase SQL Editor or psql
SELECT * FROM get_supervised_employees_list();
-- Should return list of employees you supervise

-- Test historical trail (replace with valid shift ID)
SELECT COUNT(*) FROM get_historical_shift_trail('your-shift-uuid');
```

### 3. Start Dashboard

```bash
cd dashboard
npm run dev
# Navigate to http://localhost:3000/dashboard/history
```

## Key Components

### Pages

| Route | Purpose |
|-------|---------|
| `/dashboard/history` | Shift history list with employee filter |
| `/dashboard/history/[shiftId]` | Individual shift GPS visualization |

### New Hooks

```typescript
// Fetch historical GPS trail
import { useHistoricalTrail } from '@/lib/hooks/use-historical-gps';

const { trail, isLoading, error } = useHistoricalTrail(shiftId);

// Fetch shift history for an employee
import { useShiftHistory } from '@/lib/hooks/use-historical-gps';

const { shifts, isLoading } = useShiftHistory({
  employeeId,
  startDate: '2026-01-08',
  endDate: '2026-01-15'
});
```

### Playback Animation

```typescript
import { usePlaybackAnimation } from '@/lib/hooks/use-playback-animation';

const {
  state,
  play,
  pause,
  seek,
  setSpeed,
  currentPoint
} = usePlaybackAnimation(trail);
```

### Export Utilities

```typescript
import { exportToCsv, exportToGeoJson } from '@/lib/utils/export-gps';

// Export single shift
exportToCsv(trail, { employeeName: 'John Doe', shiftDate: '2026-01-15' });

// Export to GeoJSON
exportToGeoJson(trail, { employeeName: 'John Doe', shiftDate: '2026-01-15' });
```

## Feature Flags / Configuration

No feature flags required. All functionality enabled by default.

## Development Workflow

### Adding GPS Test Data

```sql
-- Insert test GPS points for a completed shift
INSERT INTO gps_points (client_id, shift_id, employee_id, latitude, longitude, accuracy, captured_at)
SELECT
  gen_random_uuid(),
  'your-shift-id',
  'your-employee-id',
  45.5017 + (random() - 0.5) * 0.01,
  -73.5673 + (random() - 0.5) * 0.01,
  5 + random() * 20,
  '2026-01-15 09:00:00'::timestamptz + (n * interval '5 minutes')
FROM generate_series(1, 50) AS n;
```

### Testing Playback

1. Navigate to a shift with GPS data
2. Click "Play" button
3. Adjust speed with dropdown (0.5x, 1x, 2x, 4x)
4. Click on timeline to seek

### Testing Export

1. View a shift GPS trail
2. Click "Export" button
3. Select format (CSV or GeoJSON)
4. File downloads to browser

## Troubleshooting

### Empty GPS Trail

1. Check shift is within 90-day retention period
2. Verify supervisor relationship exists
3. Confirm shift has GPS points: `SELECT COUNT(*) FROM gps_points WHERE shift_id = 'xxx'`

### Map Not Loading

1. Check browser console for Leaflet errors
2. Verify OpenStreetMap tiles are accessible
3. Fallback table view should appear if map fails

### Slow Trail Rendering

1. Check point count - should auto-simplify above 500 points
2. Toggle "Show full detail" off for performance
3. Reduce date range for multi-shift views

## Key Files Reference

```
dashboard/src/
├── app/dashboard/history/
│   ├── page.tsx                    # History list page
│   └── [shiftId]/page.tsx          # Shift detail page
├── components/history/
│   ├── shift-history-table.tsx     # Filterable shift list
│   ├── gps-playback-controls.tsx   # Play/pause/seek UI
│   ├── multi-shift-map.tsx         # Multi-trail visualization
│   └── export-dialog.tsx           # Export format selection
├── lib/
│   ├── hooks/
│   │   ├── use-historical-gps.ts   # Data fetching hooks
│   │   └── use-playback-animation.ts
│   └── utils/
│       ├── export-gps.ts           # CSV/GeoJSON export
│       └── trail-simplify.ts       # Douglas-Peucker
└── types/
    └── history.ts                  # TypeScript types
```

## Related Specs

- [Spec 011: Shift Monitoring](../../specs/011-shift-monitoring/) - Real-time GPS visualization (active shifts)
- [Spec 010: Employee Management](../../specs/010-employee-management/) - Supervisor relationships
- [Spec 006: Employee History](../../specs/006-employee-history/) - Flutter app history (mobile)
