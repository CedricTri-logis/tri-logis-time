# Employee Utilization Detail — Design Spec

**Date:** 2026-03-18
**Feature:** Drill-down page per employee showing timeline + cluster detail table to understand utilization and accuracy data.

---

## Problem

The cleaning utilization report shows aggregate metrics (utilization %, accuracy %) per employee, but supervisors need to understand *why* an employee has low accuracy or unusual utilization. They need to see:
- Where the employee physically was (clusters)
- What session was declared at that time
- Whether the location matches
- For admin employees: office vs home breakdown

## Approach

New dashboard page at `/dashboard/reports/cleaning-utilization/[employeeId]` with:
1. Header with employee name + summary stats
2. Timeline bars per day (color-coded by match/mismatch/trip/office/home)
3. Cluster detail table filtered by selected day

---

## Data Model

### New RPC: `get_employee_utilization_detail`

```sql
get_employee_utilization_detail(
  p_employee_id UUID,
  p_date_from DATE,
  p_date_to DATE
) RETURNS JSONB
```

### Return structure

```jsonc
{
  "employee_name": "Rostang Noumi",
  "summary": {
    "total_shift_minutes": 2733.5,
    "total_session_minutes": 2731.0,
    "total_trip_minutes": 359.0,
    "utilization_pct": 99.9,
    "accuracy_pct": 30.5,
    "total_shifts": 6,
    "total_sessions": 10
  },
  "days": [
    {
      "date": "2026-03-11",
      "shift_id": "uuid",
      "clocked_in_at": "2026-03-11T11:27:42Z",
      "clocked_out_at": "2026-03-11T19:55:38Z",
      "shift_minutes": 507.9,
      "session_minutes": 507.3,
      "trip_minutes": 61.0,
      "clusters": [
        {
          "started_at": "2026-03-11T11:28:09Z",
          "ended_at": "2026-03-11T12:05:00Z",
          "duration_minutes": 36.9,
          "physical_location": "151-159_Principale",
          "physical_location_id": "uuid",
          "session_building": "Maintenance @ 151-159_Principale",
          "session_location_id": "uuid",
          "session_activity_type": "maintenance",
          "match": true,
          "location_category": "office"  // "office" | "home" | "match" | "mismatch" | null
        },
        {
          "started_at": "2026-03-11T12:10:00Z",
          "ended_at": "2026-03-11T13:22:00Z",
          "duration_minutes": 72.0,
          "physical_location": "58-60_Perreault-E",
          "physical_location_id": "uuid",
          "session_building": "Maintenance @ 151-159_Principale",
          "session_location_id": "uuid",
          "session_activity_type": "maintenance",
          "match": false,
          "location_category": "mismatch"
        }
      ],
      "trips": [
        {
          "started_at": "2026-03-11T12:05:00Z",
          "ended_at": "2026-03-11T12:10:00Z",
          "duration_minutes": 5.0
        }
      ]
    }
  ]
}
```

### Calculation logic

#### Clusters

For each shift in the date range:
1. Get all `stationary_clusters` for that shift
2. For each cluster, find the overlapping `work_session` (if any)
3. Resolve the session's building location (via studios→buildings→locations or property_buildings→locations)
4. Compare `sc.matched_location_id` with the session's location → `match` boolean
5. Determine `location_category`:
   - If no session overlaps → `null`
   - If `session.activity_type = 'admin'`:
     - Cluster at `is_also_office` location → `"office"`
     - Cluster at `is_employee_home` location → `"home"`
     - Otherwise → `null` (admin elsewhere)
   - If session has a building:
     - Match → `"match"`
     - No match → `"mismatch"`

#### Trips

Simple: get all `trips` for the shift, return `started_at`, `ended_at`, `duration_minutes`.

#### Summary

Same formula as the main report RPC but for a single employee.

---

## Dashboard Page

### Route

`/dashboard/reports/cleaning-utilization/[employeeId]?from=YYYY-MM-DD&to=YYYY-MM-DD`

### Navigation

- From main report: click employee name → navigates with `from` and `to` query params
- Back button → returns to main report with same date range

### UI Components

#### Header
- Employee name (large)
- Summary line: shifts count, utilization %, accuracy %, date range
- Date range inputs (editable, pre-filled from query params)

#### Timeline section
- One horizontal bar per day/shift
- Color segments:
  - Green (`#10b981`) = cluster at correct building (match)
  - Red (`#ef4444`) = cluster at wrong building (mismatch)
  - Blue (`#3b82f6`) = office (admin session at office)
  - Purple (`#8b5cf6`) = home (admin session at home)
  - Amber (`#f59e0b`) = trip/driving
  - Gray (`#e2e8f0`) = no session active
- Click a day → filters the cluster table below
- Selected day has a highlight border

#### Cluster detail table
- Filtered by selected day (or shows all if none selected)
- Columns:
  - Heure (start - end)
  - Lieu physique (cluster's matched_location name)
  - Session déclarée (session building name + activity type)
  - Match (checkmark green / X red)
  - Durée (minutes)
- Mismatch rows have light red background (`#fef2f2`)
- Header shows: "N clusters · X match · Y mismatch"

---

## Modifications to main report page

### Employee name as link

In `cleaning-utilization/page.tsx`, change employee name cell from:
```tsx
<td className="py-3 pr-4 font-medium">{emp.employee_name}</td>
```
to a Link with query params:
```tsx
<td className="py-3 pr-4 font-medium">
  <Link href={`/dashboard/reports/cleaning-utilization/${emp.employee_id}?from=${toLocalDateString(dateFrom)}&to=${toLocalDateString(dateTo)}`}
    className="text-blue-600 hover:underline">
    {emp.employee_name}
  </Link>
</td>
```

---

## Files to create/modify

### New files
- `supabase/migrations/20260318300000_employee_utilization_detail.sql` — RPC
- `dashboard/src/lib/hooks/use-employee-utilization-detail.ts` — data hook
- `dashboard/src/app/dashboard/reports/cleaning-utilization/[employeeId]/page.tsx` — detail page

### Modified files
- `dashboard/src/app/dashboard/reports/cleaning-utilization/page.tsx` — employee name as Link

---

## Edge Cases

1. **Employee with only admin sessions** → accuracy = N/A, clusters show office/home/null categories
2. **Day with no clusters** (GPS gap, short shift) → empty timeline bar, no table rows
3. **Cluster without matched_location** (unmatched GPS) → physical_location = "Non identifié"
4. **Session spans midnight** → clamped to shift boundaries per existing logic
5. **Multiple sessions in one shift** → each cluster matched to the session covering its time range
