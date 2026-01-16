# GPS Tracker Manager Dashboard - Desktop UI Roadmap

**Project**: Manager Dashboard for GPS Employee Tracking
**Framework**: Next.js 14+ (App Router) + TypeScript
**UI**: shadcn/ui + Tailwind CSS
**Data Layer**: Refine + Supabase
**Backend**: Supabase (shared with mobile app)
**Target Users**: Managers/Supervisors
**Distribution**: Web application (desktop-optimized)

---

## Executive Summary

This roadmap covers the **Manager Desktop UI** - a web application for supervisors to monitor employees, view shifts, and manage GPS tracking data. Built with the same tech stack as the ADMIN Data Room project for eventual integration.

### Tech Stack (ADMIN-Compatible)

| Layer | Technology | Rationale |
|-------|------------|-----------|
| Language | TypeScript (strict) | AI-optimized, compile-time safety |
| Framework | Next.js 14+ (App Router) | RSC support, Vercel deployment |
| UI Components | shadcn/ui | v0.dev AI generation, Radix primitives |
| Data Layer | Refine | Native Supabase provider, CRUD hooks |
| Styling | Tailwind CSS | Utility-first, no custom CSS |
| Database | Supabase PostgreSQL | Shared with mobile app |
| Validation | Zod | Runtime + compile-time safety |
| Testing | Playwright | E2E, accessibility verification |

### Spec Overview

| Spec # | Name | Priority | Dependencies |
|--------|------|----------|--------------|
| 009 | Dashboard Foundation | P0 | Mobile MVP (001-004) |
| 010 | Employee Management | P1 | 009 |
| 011 | Shift Monitoring | P1 | 010 |
| 012 | GPS Visualization | P2 | 011 |
| 013 | Reports & Export | P2 | 011 |

### Development Flow

```
+---------------------------------------------------------------------+
|                     MANAGER DASHBOARD PATH                          |
+---------------------------------------------------------------------+
|                                                                     |
|  Mobile MVP (001-004) ─────────────────────────────────────────────►|
|                                                                     |
|  009-Foundation --> 010-Employees --> 011-Shifts --> 012-GPS-Map   |
|       (Setup)        (List/View)      (Monitor)      (Visualize)   |
|                                                                     |
|                                           └──────> 013-Reports      |
|                                                    (Export)         |
|                                                                     |
+---------------------------------------------------------------------+
```

---

## Spec 009: Dashboard Foundation

**Branch**: `009-dashboard-foundation`
**Complexity**: Medium

### Purpose

Set up the Next.js project with Refine + Supabase integration, shadcn/ui components, and authentication for managers.

### Scope

#### In Scope
- Next.js 14+ project with App Router
- Refine configuration with Supabase data provider
- shadcn/ui component library setup
- Supabase Auth integration (manager role)
- Basic layout (sidebar, header, content area)
- TypeScript types generated from existing Supabase schema

#### Out of Scope
- Employee data display (Spec 010)
- Shift monitoring (Spec 011)
- Mobile responsiveness (desktop-first)

### Technical Setup

```bash
# Project initialization
npx create-next-app@latest gps-manager --typescript --tailwind --app

# Refine with Supabase
npm install @refinedev/core @refinedev/supabase @refinedev/nextjs-router

# shadcn/ui
npx shadcn@latest init
npx shadcn@latest add button card table sidebar avatar dropdown-menu

# Validation
npm install zod @hookform/resolvers
```

### Project Structure

```
gps-manager/
├── app/
│   ├── layout.tsx              # Root layout with Refine provider
│   ├── page.tsx                # Dashboard home
│   ├── login/
│   │   └── page.tsx            # Manager login
│   ├── employees/
│   │   ├── page.tsx            # Employee list
│   │   └── [id]/page.tsx       # Employee detail
│   └── shifts/
│       ├── page.tsx            # Shift list/monitor
│       └── [id]/page.tsx       # Shift detail
├── components/
│   ├── ui/                     # shadcn/ui components
│   ├── layout/
│   │   ├── Sidebar.tsx
│   │   ├── Header.tsx
│   │   └── AppShell.tsx
│   └── employees/
│       └── EmployeeCard.tsx
├── lib/
│   ├── supabase/
│   │   ├── client.ts           # Supabase client
│   │   └── types.ts            # Generated types
│   └── utils.ts
└── providers/
    └── RefineProvider.tsx
```

### Database Access

Uses existing tables from mobile app:
- `employee_profiles` - Employee data
- `shifts` - Shift records
- `gps_points` - GPS tracking data

**RLS Policy Addition:**
```sql
-- Allow managers to view all employees
CREATE POLICY "Managers can view all employees"
  ON employee_profiles FOR SELECT
  USING (
    auth.uid() IN (
      SELECT id FROM employee_profiles WHERE role = 'manager'
    )
  );

-- Allow managers to view all shifts
CREATE POLICY "Managers can view all shifts"
  ON shifts FOR SELECT
  USING (
    auth.uid() IN (
      SELECT id FROM employee_profiles WHERE role = 'manager'
    )
  );
```

### Success Criteria

- [x] Next.js project builds and runs
- [x] Refine connects to Supabase
- [x] Manager can log in
- [x] Basic layout renders (sidebar, header)
- [x] TypeScript types match database schema

### Checkpoint

**After this spec**: Empty dashboard shell with authentication. Manager can log in but sees no data yet.

---

## Spec 010: Employee Management

**Branch**: `010-employee-management`
**Complexity**: Medium

### Purpose

Display employee list with real-time status indicators showing who is currently clocked in.

### Scope

#### In Scope
- Employee list with Refine `useTable`
- Real-time clock-in status via Supabase Realtime
- Employee detail view
- Search and filter employees
- Active/inactive employee status

#### Out of Scope
- Employee CRUD (admin function)
- Shift history (Spec 011)

### User Stories

#### US1: View Employee List (P1)
**As a** manager
**I want** to see all my employees in a list
**So that** I can quickly identify who is working

**Acceptance Criteria**:
- Given I am on the dashboard, then I see a table of employees
- Given an employee is clocked in, then I see a green "Active" badge
- Given I search for a name, then the list filters accordingly

#### US2: View Employee Detail (P1)
**As a** manager
**I want** to see detailed info about an employee
**So that** I can review their profile

**Acceptance Criteria**:
- Given I click an employee row, then I navigate to their detail page
- Given I am on detail page, then I see profile info and current status

### Screens

```
+--------------------------------------------------+
|  [Logo]  GPS Manager           [Avatar] Manager  |
+--------------------------------------------------+
|           |                                      |
| Dashboard |  Employees                           |
| Employees |  ┌────────────────────────────────┐  |
| Shifts    |  │ Search: [____________] [Filter]│  |
| Reports   |  └────────────────────────────────┘  |
|           |                                      |
|           |  ┌──────────────────────────────────┐|
|           |  │ Name         │ Status │ Since    │|
|           |  ├──────────────┼────────┼──────────┤|
|           |  │ John Doe     │ [ON]   │ 9:00 AM  │|
|           |  │ Jane Smith   │ [OFF]  │ -        │|
|           |  │ Bob Wilson   │ [ON]   │ 8:30 AM  │|
|           |  └──────────────────────────────────┘|
+--------------------------------------------------+
```

### Technical Implementation

```tsx
// Using Refine's useTable with Supabase
const { tableProps } = useTable<Employee>({
  resource: "employee_profiles",
  filters: {
    initial: [{ field: "is_active", operator: "eq", value: true }]
  },
  sorters: {
    initial: [{ field: "full_name", order: "asc" }]
  },
  liveMode: "auto", // Real-time updates
});

// shadcn/ui Table
<Table>
  <TableHeader>
    <TableRow>
      <TableHead>Name</TableHead>
      <TableHead>Status</TableHead>
      <TableHead>Since</TableHead>
    </TableRow>
  </TableHeader>
  <TableBody>
    {tableProps.data?.map(employee => (
      <TableRow key={employee.id}>
        <TableCell>{employee.full_name}</TableCell>
        <TableCell>
          <Badge variant={employee.active_shift ? "success" : "secondary"}>
            {employee.active_shift ? "ON" : "OFF"}
          </Badge>
        </TableCell>
        <TableCell>
          {employee.active_shift?.clock_in_at
            ? format(employee.active_shift.clock_in_at, 'h:mm a')
            : '-'}
        </TableCell>
      </TableRow>
    ))}
  </TableBody>
</Table>
```

### Success Criteria

- [x] Employee list displays with Refine useTable
- [x] Real-time status updates when employee clocks in/out
- [x] Search filters employees by name
- [x] Employee detail page shows profile info
- [x] Accessibility: keyboard navigation works

### Checkpoint

**After this spec**: Manager can view all employees and see who is currently working in real-time.

---

## Spec 011: Shift Monitoring

**Branch**: `011-shift-monitoring`
**Complexity**: Medium-High

### Purpose

Enable managers to monitor active shifts in real-time and view shift history with GPS point counts.

### Scope

#### In Scope
- Active shifts dashboard (who is clocked in now)
- Shift history list with filters
- Shift detail view with GPS point count
- Date range filtering
- Employee filtering

#### Out of Scope
- GPS map visualization (Spec 012)
- Shift editing/correction
- Export functionality (Spec 013)

### User Stories

#### US1: Monitor Active Shifts (P1)
**As a** manager
**I want** to see all currently active shifts
**So that** I can monitor who is working right now

**Acceptance Criteria**:
- Given I open the shifts page, then I see active shifts prominently
- Given a shift includes GPS points, then I see the count
- Given real-time updates occur, then the UI updates automatically

#### US2: View Shift History (P1)
**As a** manager
**I want** to see past shifts for any employee
**So that** I can verify work hours

**Acceptance Criteria**:
- Given I select a date range, then I see shifts in that period
- Given I select an employee filter, then I see only their shifts
- Given a shift, then I see duration and GPS point count

#### US3: View Shift Detail (P2)
**As a** manager
**I want** to see full details of a shift
**So that** I can verify clock times and GPS data

**Acceptance Criteria**:
- Given I click a shift, then I see clock in/out times with locations
- Given the shift has GPS points, then I see the list of timestamps

### Screens

```
+--------------------------------------------------+
| Active Shifts (3)                      [Refresh] |
+--------------------------------------------------+
| ┌────────────────────────────────────────────┐   |
| │ John Doe      │ Since 9:00 AM │ 45 GPS pts │   |
| │ Bob Wilson    │ Since 8:30 AM │ 52 GPS pts │   |
| │ Alice Brown   │ Since 9:15 AM │ 38 GPS pts │   |
| └────────────────────────────────────────────┘   |
|                                                  |
| Shift History                                    |
| ┌────────────────────────────────────────────┐   |
| │ Date Range: [Jan 1] to [Jan 10]  [Apply]   │   |
| │ Employee: [All ▼]                          │   |
| └────────────────────────────────────────────┘   |
|                                                  |
| ┌────────────────────────────────────────────────┐
| │ Date    │ Employee  │ Duration │ GPS │ Status │
| ├─────────┼───────────┼──────────┼─────┼────────┤
| │ Jan 10  │ John Doe  │ 8h 30m   │ 102 │ Done   │
| │ Jan 10  │ Jane Smith│ 7h 45m   │ 93  │ Done   │
| │ Jan 9   │ John Doe  │ 8h 15m   │ 99  │ Done   │
| └────────────────────────────────────────────────┘
```

### Technical Implementation

```tsx
// Active shifts query
const { data: activeShifts } = useList<Shift>({
  resource: "shifts",
  filters: [{ field: "status", operator: "eq", value: "active" }],
  liveMode: "auto",
  meta: {
    select: "*, employee:employee_profiles(full_name), gps_count:gps_points(count)"
  }
});

// Shift history with filters
const { tableProps, filters, setFilters } = useTable<Shift>({
  resource: "shifts",
  filters: {
    initial: [
      { field: "clock_in_at", operator: "gte", value: startDate },
      { field: "clock_in_at", operator: "lte", value: endDate },
    ]
  },
  sorters: {
    initial: [{ field: "clock_in_at", order: "desc" }]
  }
});
```

### Success Criteria

- [x] Active shifts display with real-time updates
- [x] Shift history loads with pagination
- [x] Date range filter works correctly
- [x] Employee filter works correctly
- [x] GPS point count shows for each shift
- [x] Shift detail page shows full info

### Checkpoint

**After this spec**: Manager has full visibility into active and historical shifts with filtering capabilities.

---

## Spec 012: GPS Visualization

**Branch**: `012-gps-visualization`
**Complexity**: High

### Purpose

Display GPS points on an interactive map for visual verification of employee locations during shifts.

### Scope

#### In Scope
- Map component using Mapbox GL or Google Maps
- GPS trail visualization for a shift
- Point-by-point timeline
- Zoom to shift area

#### Out of Scope
- Real-time live tracking (would require WebSocket)
- Geofencing
- Heat maps

### User Stories

#### US1: View GPS Trail on Map (P1)
**As a** manager
**I want** to see GPS points plotted on a map
**So that** I can verify where an employee worked

**Acceptance Criteria**:
- Given I view a shift detail, then I see a map with GPS points
- Given points are plotted, then they connect as a trail
- Given I click a point, then I see the timestamp

#### US2: Timeline Playback (P2)
**As a** manager
**I want** to step through GPS points chronologically
**So that** I can trace the employee's path

**Acceptance Criteria**:
- Given I am on the map view, then I see a timeline slider
- Given I move the slider, then the map highlights that point
- Given I click play, then points animate in sequence

### Technical Implementation

```tsx
// Map component with GPS trail
import Map, { Marker, Source, Layer } from 'react-map-gl';

const ShiftMap = ({ gpsPoints }: { gpsPoints: GpsPoint[] }) => {
  const geojson = {
    type: 'Feature',
    geometry: {
      type: 'LineString',
      coordinates: gpsPoints.map(p => [p.longitude, p.latitude])
    }
  };

  return (
    <Map
      initialViewState={{
        longitude: gpsPoints[0]?.longitude,
        latitude: gpsPoints[0]?.latitude,
        zoom: 14
      }}
      style={{ width: '100%', height: 400 }}
      mapStyle="mapbox://styles/mapbox/streets-v12"
    >
      <Source type="geojson" data={geojson}>
        <Layer
          type="line"
          paint={{ 'line-color': '#3b82f6', 'line-width': 3 }}
        />
      </Source>
      {gpsPoints.map((point, i) => (
        <Marker key={i} longitude={point.longitude} latitude={point.latitude}>
          <div className="w-3 h-3 bg-blue-500 rounded-full" />
        </Marker>
      ))}
    </Map>
  );
};
```

### Success Criteria

- [x] Map displays GPS points for a shift
- [x] Trail line connects points chronologically
- [x] Clicking a point shows timestamp
- [x] Map auto-zooms to fit all points
- [x] Timeline slider highlights points

### Checkpoint

**After this spec**: Managers can visually verify employee locations on a map.

---

## Spec 013: Reports & Export

**Branch**: `013-reports-export`
**Complexity**: Medium

### Purpose

Generate reports and export shift data for payroll and compliance purposes.

### Scope

#### In Scope
- Weekly/monthly shift summary
- Employee hours report
- CSV export
- PDF export (optional)

#### Out of Scope
- Payroll integration
- Custom report builder
- Scheduled reports

### User Stories

#### US1: Generate Hours Report (P1)
**As a** manager
**I want** to generate a report of employee hours
**So that** I can submit for payroll

**Acceptance Criteria**:
- Given I select a date range, then I see total hours per employee
- Given the report generates, then I can export to CSV
- Given I export, then the file downloads immediately

#### US2: Export Shift Data (P1)
**As a** manager
**I want** to export shift data as CSV
**So that** I can import into other systems

**Acceptance Criteria**:
- Given I am on the shifts page, then I see an export button
- Given I click export, then a CSV downloads with filtered data
- Given the CSV, then it includes: employee, date, clock in/out, duration, GPS count

### Technical Implementation

```tsx
// CSV Export using native browser API
const exportToCSV = (shifts: Shift[]) => {
  const headers = ['Employee', 'Date', 'Clock In', 'Clock Out', 'Duration', 'GPS Points'];
  const rows = shifts.map(s => [
    s.employee.full_name,
    format(s.clock_in_at, 'yyyy-MM-dd'),
    format(s.clock_in_at, 'HH:mm'),
    s.clock_out_at ? format(s.clock_out_at, 'HH:mm') : '-',
    formatDuration(s.duration),
    s.gps_count
  ]);

  const csv = [headers, ...rows].map(row => row.join(',')).join('\n');
  const blob = new Blob([csv], { type: 'text/csv' });
  const url = URL.createObjectURL(blob);

  const a = document.createElement('a');
  a.href = url;
  a.download = `shifts-${format(new Date(), 'yyyy-MM-dd')}.csv`;
  a.click();
};
```

### Success Criteria

- [ ] Hours report generates for date range
- [ ] Report shows total hours per employee
- [ ] CSV export downloads correctly
- [ ] Exported data matches displayed data
- [ ] Export includes all filtered shifts

### Checkpoint

**After this spec**: Full manager dashboard with reporting and export capabilities.

---

## Implementation Order

```
Phase 1: Spec 009 (Foundation)
         +-- Next.js + Refine + shadcn/ui setup

Phase 2: Spec 010 (Employees)
         +-- Employee list with real-time status

Phase 3: Spec 011 (Shifts)
         +-- Shift monitoring and history

Phase 4: Spec 012 (GPS Map)
         +-- Visual GPS trail on map

Phase 5: Spec 013 (Reports)
         +-- Export and reporting features
```

---

## Dependencies Graph

```
Mobile MVP (001-004)
        |
        v
009-Dashboard-Foundation
        |
        v
010-Employee-Management
        |
        v
011-Shift-Monitoring
        |
        +-------+-------+
        |               |
        v               v
012-GPS-Map      013-Reports
```

---

## Integration Notes

### Merging with ADMIN Project

This dashboard is designed to eventually merge into the ADMIN Data Room project:

1. **Shared Supabase Instance**: Same database, different schemas if needed
2. **Same Tech Stack**: Next.js, Refine, shadcn/ui - identical patterns
3. **Constitution Compliance**: Follows ADMIN constitution principles
4. **Module Extraction**: Can be extracted as `features/gps-tracking/` in ADMIN

### Migration Path

```
Current:
  GPS_Tracker/           (Mobile Flutter app)
  gps-manager/           (Desktop Next.js dashboard)

Future:
  ADMIN/
  ├── app/
  │   ├── gps/           (GPS tracking dashboard pages)
  │   └── ...
  └── features/
      └── gps-tracking/  (Components, hooks, types)
```
