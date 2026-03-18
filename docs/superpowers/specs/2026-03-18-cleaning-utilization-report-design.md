# Cleaning Utilization Report — Design Spec

**Date:** 2026-03-18
**Feature:** Dashboard report showing per-employee cleaning/work session utilization, GPS accuracy, and time breakdown by location category.

---

## Problem

Supervisors need visibility into how cleaning employees spend their shift time:
- What % of available (non-travel) time is spent in work sessions?
- Are employees physically at the building they scanned/selected?
- How is time distributed across short-term units, common areas, long-term buildings (cleaning vs maintenance), and office?

## Approach

Single Supabase RPC (`get_cleaning_utilization_report`) that computes all metrics server-side, consumed by a new dashboard page.

---

## Data Model

### Existing tables used (no schema changes required)

| Table | Role |
|---|---|
| `work_sessions` | Unified cleaning/maintenance/admin sessions with `studio_id` (short-term) or `building_id` (long-term) FK |
| `shifts` | Employee shift durations (clocked_in_at → clocked_out_at) |
| `trips` | Detected travel segments during shifts (from `detect_trips`) |
| `gps_points` | Continuous GPS capture during shifts |
| `studios` → `buildings` → `locations` | Short-term unit geofences (QR-based) |
| `property_buildings` → `locations` | Long-term building geofences |
| `locations` | Geofence definitions (lat/lng + radius_meters), `is_also_office` flag |

### Key relationships

```
work_session
  ├─ shift_id → shifts (duration, GPS points)
  ├─ studio_id → studios → buildings → locations (short-term geofence)
  └─ building_id → property_buildings → locations (long-term geofence)
```

### Short-term vs long-term distinction

- **Short-term:** `studio_id IS NOT NULL` — studios in cleaning buildings (QR-scanned or manually selected from studio list)
- **Long-term:** `building_id IS NOT NULL` — property_buildings (manually selected)
- This is implicit in the FK used; no `building_type` column needed.

---

## RPC: `get_cleaning_utilization_report`

### Signature

```sql
get_cleaning_utilization_report(
  p_date_from DATE,
  p_date_to DATE,
  p_employee_id UUID DEFAULT NULL
) RETURNS JSONB
```

### Return structure (per employee)

```jsonc
{
  "employees": [
    {
      "employee_id": "uuid",
      "employee_name": "string",

      // Time totals (minutes)
      "total_shift_minutes": 480,
      "total_trip_minutes": 60,
      "total_session_minutes": 350,
      "available_minutes": 420,       // shift - trips

      // Metrics
      "utilization_pct": 83.3,        // session / available × 100
      "accuracy_pct": 94.5,           // GPS points in geofence / total GPS points during sessions

      // Time breakdown (minutes)
      "short_term_unit_minutes": 180,
      "short_term_common_minutes": 40,
      "cleaning_long_term_minutes": 80,
      "maintenance_long_term_minutes": 30,
      "office_minutes": 20,

      // Counts
      "total_sessions": 12,
      "total_shifts": 2
    }
  ]
}
```

### Calculation logic

#### 1. Utilization %

```
utilization = total_session_minutes / (total_shift_minutes - total_trip_minutes) × 100
```

- `total_shift_minutes`: sum of `EXTRACT(EPOCH FROM (clocked_out_at - clocked_in_at)) / 60` for completed shifts in date range, **excluding lunch shifts** (`WHERE is_lunch IS NOT TRUE`). Lunch shift-splits (is_lunch=true) are break time, not work time.
- `total_trip_minutes`: sum of trip durations from `trips` table for those shifts (only completed shifts with `is_lunch IS NOT TRUE`)
- `total_session_minutes`: sum of `duration_minutes` from `work_sessions` (status IN completed, auto_closed, manually_closed)
- Only include completed shifts (`status = 'completed'`); active/in-progress shifts are excluded

#### 2. Accuracy %

For each completed work session:
1. Get GPS points from `gps_points` where `shift_id = session.shift_id` AND `captured_at BETWEEN session.started_at AND session.completed_at` AND `accuracy <= 50` (filter out noisy GPS, consistent with location matching in migration 080)
2. Resolve the session's building geofence via JOIN:
   - If `studio_id` is set: `work_sessions.studio_id → studios.building_id → buildings.location_id → locations` (get location's geography + radius)
   - If `building_id` is set: `work_sessions.building_id → property_buildings.location_id → locations` (get location's geography + radius)
   - If location_id is NULL (building not linked to a location) → accuracy = NULL for this session, skip it in the aggregate
3. Count GPS points within geofence: `ST_DWithin(location.location, ST_SetSRID(ST_MakePoint(gps.longitude, gps.latitude), 4326)::geography, location.radius_meters)`
4. `accuracy = points_in_geofence / total_points × 100`

Aggregate across all sessions for the employee (excluding sessions with NULL accuracy due to unlinked buildings).

#### 3. Time breakdown

| Category | Filter |
|---|---|
| `short_term_unit_minutes` | `ws.studio_id IS NOT NULL` AND `s.studio_type = 'unit'` (JOIN: `work_sessions ws JOIN studios s ON s.id = ws.studio_id`) |
| `short_term_common_minutes` | `ws.studio_id IS NOT NULL` AND `s.studio_type IN ('common_area', 'conciergerie')` (same JOIN) |
| `cleaning_long_term_minutes` | `building_id IS NOT NULL` AND `activity_type = 'cleaning'` |
| `maintenance_long_term_minutes` | `building_id IS NOT NULL` AND `activity_type = 'maintenance'` |
| `office_minutes` | GPS time at 151-159_Principale (location with `is_also_office = true`) NOT covered by any work session |

#### 4. Office time calculation

1. Find location where `is_also_office = true` (151-159_Principale)
2. Get GPS points for employee's shifts in date range that fall within office geofence AND `accuracy <= 50`
3. Filter OUT any GPS points that fall during an active work session (`NOT EXISTS work_session covering that timestamp`)
4. Estimate time: sum of intervals between consecutive remaining GPS points at office
5. This avoids double-counting — if an employee does a cleaning session at Le Chic-urbain (which IS the office building), that time is counted under short_term, not office

---

## Dashboard Page

### Route

`/dashboard/reports/cleaning-utilization`

### UI Components

**Filters:**
- Date range picker (date_from / date_to)
- Optional employee filter (dropdown)

**Table columns:**

| Column | Source |
|---|---|
| Employé | `employee_name` |
| Shifts (h) | `total_shift_minutes` → formatted |
| Déplacements (h) | `total_trip_minutes` → formatted |
| Sessions (h) | `total_session_minutes` → formatted |
| **Utilisation %** | `utilization_pct` — progress bar |
| **Accuracy %** | `accuracy_pct` — progress bar |
| Unités CT | `short_term_unit_minutes` → formatted |
| Aires communes CT | `short_term_common_minutes` → formatted |
| Ménage LT | `cleaning_long_term_minutes` → formatted |
| Entretien LT | `maintenance_long_term_minutes` → formatted |
| Bureau | `office_minutes` → formatted |

**Visual thresholds (progress bar colors):**

| Metric | Green | Yellow | Red |
|---|---|---|---|
| Utilisation | ≥80% | 60–80% | <60% |
| Accuracy | ≥90% | 70–90% | <70% |

**Footer row:** Averages/totals across all employees.

### Navigation

Add link in sidebar under "Rapports" section, labeled "Utilisation ménage".

---

## Edge Cases

1. **No GPS points during a session** → accuracy = NULL (not 0%), shown as "N/A"
2. **No trips detected for a shift** → trip_minutes = 0, available = shift total
3. **Session without completed_at** (in_progress) → excluded from calculations
4. **Building/studio not linked to a location** → accuracy = NULL for those sessions
5. **Employee with 0 work sessions** → utilization = 0%, still shown in report if they had shifts
6. **Lunch shifts** (`is_lunch = true`) → excluded from shift duration calculation
7. **Office time**: GPS points during work sessions are excluded BEFORE computing office time, so negative values cannot occur
8. **Property building not linked to a location** (`location_id IS NULL`) → accuracy = NULL for sessions at that building; time breakdown still counts the minutes
9. **GPS accuracy filter**: only points with `accuracy <= 50m` are used for accuracy % and office time (consistent with location matching elsewhere in the app)

---

## Files to create/modify

### New files
- `supabase/migrations/XXX_cleaning_utilization_report.sql` — RPC
- `dashboard/src/app/dashboard/reports/cleaning-utilization/page.tsx` — page
- `dashboard/src/components/reports/cleaning-utilization-table.tsx` — table component
- `dashboard/src/lib/hooks/use-cleaning-utilization.ts` — data hook

### Modified files
- `dashboard/src/components/layout/sidebar.tsx` — add nav link
