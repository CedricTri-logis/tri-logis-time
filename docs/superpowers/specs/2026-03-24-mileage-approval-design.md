# Mileage Approval Design Spec

**Date:** 2026-03-24
**Status:** Approved
**Feature:** Dedicated mileage approval workflow for supervisors

## Overview

A dedicated mileage approval page in the admin dashboard, accessible after day-level approvals are complete. Supervisors assign vehicle type (personal/company) and role (driver/passenger) per trip, resolve carpooling groups, and approve reimbursement amounts per employee per pay period.

## Business Rules

### Trip Reimbursement Eligibility

A trip is reimbursable when ALL of the following are true:
1. The departure stop AND arrival stop have a **final status of 'approved'** — either auto-classified from a professional location type (office, building, vendor, gaz) or explicitly overridden to 'approved' via `activity_overrides`
2. The trip role is **driver** (not passenger)
3. The vehicle type is **personal** (not company)
4. The `transport_mode` is **driving** (existing column on `trips`, already populated)

### Reimbursement Calculation

- Distance: `road_distance_km` if available, else `distance_km`
- CRA 2026 rates: $0.73/km (first 5,000 km YTD) → $0.67/km thereafter (DB currently has 2025 rates $0.72/$0.66 — migration will UPDATE existing row)
- YTD calculated from January 1 to the last day of the period

### Carpooling Rules

- Auto-detected by `detect_carpools` (same route ±200m, temporal overlap >80%)
- Only the driver with a personal vehicle is reimbursed; passengers get $0
- When supervisor assigns driver role on one carpool member, other members in the group are automatically set to passenger
- Supervisor can override any auto-assignment

### Vehicle Default Assignment

| Employee vehicle periods | Default vehicle_type | Default role | Review needed? |
|---|---|---|---|
| Only personal active | personal | driver | No |
| Only company active | company | driver | No |
| Both active | NULL | NULL | Yes |
| Carpool detected — auto-assigned driver | (from vehicle period) | driver | Depends on group |
| Carpool detected — other members | (from vehicle period) | passenger | Depends on group |

### Employee Vehicle Configuration (Reference)

| Employee | Vehicles | Notes |
|---|---|---|
| Mario | personal + company | Both active |
| Moussalifou | personal + company | Both active |
| Rostang | personal + company | Both active |
| Céline | personal | — |
| Jessy | personal | — |
| Ozaka | personal | — |
| Anthony | personal | May ride with Irène or Maeva |
| Maeva | personal | May ride with Irène or Anthony |
| Irène | personal | — |
| Yvan | personal | — |
| Vincent | personal + company | Both active |
| Fabrice | personal | — |
| Gérald | personal | — |

## Approval Workflow

### Two-Phase Flow

1. **Day-level approval** (existing) — supervisor approves stops/hours. Trips are visible but vehicle/role assignment is informational only.
2. **Mileage approval** (new) — dedicated page per pay period, after all worked days are approved. This is where vehicle type, carpooling, and reimbursement are finalized.

### Pre-condition

The mileage approval page requires ALL worked days in the period to have `day_approvals.status = 'approved'`. If any day is not approved, a blocking message is shown.

### Supervisor Flow

1. Select pay period (biweekly dropdown)
2. System auto-calls `prefill_mileage_defaults` to assign defaults on trips without vehicle_type/role
3. Left panel: employee list sorted by review-needed first, with summary stats
4. Click employee → right panel shows trips grouped by day
5. For each trip: assign vehicle type + role via dropdowns (or use batch shortcuts)
6. Carpool groups highlighted with member names; changing driver cascades passenger roles
7. When all trips are assigned → "Approve mileage" button becomes active
8. Approval freezes `reimbursable_km` and `reimbursement_amount` on `mileage_approvals`
9. Supervisor can "Reopen" to unlock and make changes

## Data Model

### Modified Table: `trips`

New nullable columns (using `TEXT CHECK(...)` pattern, consistent with existing codebase):
- `vehicle_type TEXT CHECK (vehicle_type IN ('personal', 'company'))` — NULL until assigned
- `role TEXT CHECK (role IN ('driver', 'passenger'))` — NULL until assigned

When `update_trip_vehicle` or `batch_update_trip_vehicles` modifies `trips.role` for a trip that belongs to a carpool group, the corresponding `carpool_members.role` is also updated to stay in sync. `carpool_members.role` remains the source of truth for the existing Flutter `get_mileage_summary` RPC; `trips.role` is the source of truth for the mileage approval system.

### New Table: `mileage_approvals`

```sql
CREATE TABLE mileage_approvals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES employee_profiles(id),
  period_start DATE NOT NULL,
  period_end DATE NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved')),
  reimbursable_km DECIMAL(10,2),       -- frozen at approval
  reimbursement_amount DECIMAL(10,2),  -- frozen at approval
  approved_by UUID REFERENCES employee_profiles(id),
  approved_at TIMESTAMPTZ,
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  unlocked_by UUID REFERENCES employee_profiles(id),
  unlocked_at TIMESTAMPTZ,
  UNIQUE (employee_id, period_start, period_end)
);
```

### Locking Trigger

On `trips`: block UPDATE of `vehicle_type`/`role` if an approved `mileage_approvals` covers the trip's period. Also block `detect_trips` and `detect_carpools` from deleting/recreating trips and carpool data for dates covered by an approved mileage period. If trip or carpool re-detection is needed, the mileage approval must be reopened first.

### CRA Rate Update

UPDATE existing `reimbursement_rates` row (seeded in migration 033 with 2025 rates $0.72/$0.66):
- `rate_per_km = 0.73`, `rate_after_threshold = 0.67`
- `effective_from = '2026-01-01'`

## RPCs

### `prefill_mileage_defaults(p_employee_id, p_period_start, p_period_end)`

- First calls `detect_carpools(p_date)` for each day in the period that has trips (ensures carpool data is up-to-date)
- Sets `vehicle_type` and `role` on trips where they are NULL
- Uses `employee_vehicle_periods` for vehicle type defaults
- Uses `carpool_members` for role defaults
- Returns: `{ prefilled_count, needs_review_count }`

### `update_trip_vehicle(p_trip_id, p_vehicle_type, p_role)`

- Updates `vehicle_type` and `role` on a single trip
- If trip is in a carpool group and set as driver → other members' `trips.role` AND `carpool_members.role` become passenger
- Blocks if period's mileage approval is already approved
- All RPCs use `SECURITY DEFINER` (consistent with existing approval RPCs)
- Returns: updated trip data

### `batch_update_trip_vehicles(p_trip_ids UUID[], p_vehicle_type, p_role)`

- Same logic as `update_trip_vehicle`, applied in batch
- Returns: `{ updated_count }`

### `get_mileage_approval_detail(p_employee_id, p_period_start, p_period_end)`

Returns JSONB:
- Trips grouped by day, each with:
  - Trip info (departure, arrival, distance, vehicle_type, role)
  - Adjacent stop approval status from `day_approvals`
  - Carpool info (group members, roles)
  - `eligible` flag (between 2 approved stops + driving)
- Summary: reimbursable km, company km, passenger km, estimated amount, needs_review_count
- Mileage approval status

### `get_mileage_approval_summary(p_period_start, p_period_end)`

Returns JSONB array — one entry per employee with trips in the period:
- employee_id, full_name
- trip_count, reimbursable_km, company_km, estimated_amount
- needs_review_count, carpool_group_count
- mileage_approval status

### `approve_mileage(p_employee_id, p_period_start, p_period_end, p_notes)`

- Validates: no eligible trip with NULL vehicle_type/role
- Validates: all worked days are day-approved
- Creates/updates `mileage_approvals` with frozen totals (km + amount calculated at CRA rates with YTD tiers)
- Returns: mileage approval record

### `reopen_mileage_approval(p_employee_id, p_period_start, p_period_end)`

- Sets `status = 'pending'`, records `unlocked_by`/`unlocked_at`, clears `approved_at`/`approved_by`
- Unlocks trip modifications
- Returns: updated mileage approval record

### Modified: `get_payroll_period_report`

Add columns from `mileage_approvals`:
- `reimbursable_km`
- `reimbursement_amount`

Uses frozen values from `mileage_approvals` when status = 'approved'; shows live-calculated estimate when status = 'pending' or no mileage approval exists yet.

## Relationship with Payroll Approval

Mileage approval and payroll approval are **independent** — payroll can be approved before mileage is finalized. The payroll report shows mileage data (frozen if approved, estimated if not) but does not gate on mileage approval status. This allows flexibility: hours/salary can be processed while mileage is still being reviewed.

## Trip-to-Period Mapping

A trip belongs to a period based on `to_business_date(started_at)` — the Montreal-timezone business date of the trip start time. This is consistent with the existing payroll report's day mapping via `to_business_date()`.

## Dashboard Components

### New Page: `/mileage-approval`

Added to dashboard navigation.

### Components

1. **`MileageApprovalPage`** — main page
   - Pay period selector (biweekly, same logic as payroll)
   - Blocking message if days not yet approved
   - Split layout: left panel (40%) + right panel (60%)

2. **`MileageEmployeeList`** — left panel
   - Employee list with summary stats (trips, km, amount, review count)
   - Sort: ⚠ needs review first → ✓ ready → ✓✓ approved
   - Team total at bottom
   - Click to select → loads detail in right panel

3. **`MileageEmployeeDetail`** — right panel
   - Header: employee name, batch action buttons
   - Trips grouped by day with `MileageTripRow` per trip
   - Financial summary + approve/reopen button at bottom

4. **`MileageTripRow`** — trip line item
   - Departure → Arrival, distance
   - Carpool badge with co-rider names if applicable
   - Vehicle type dropdown (personal/company) + role dropdown (driver/passenger)
   - Greyed out if non-eligible (stops not approved) with tooltip
   - Left border color: green = resolved, orange = needs review

5. **`MileageApprovalSummary`** — footer of right panel
   - Breakdown: reimbursable km / company km / passenger km
   - Amount at CRA rate with tier detail
   - Approve button (disabled if NULL trips remain)
   - Reopen button (if already approved)

### Batch Shortcuts

- "All = Personal" / "All = Company" per day
- "All = Personal + Driver" for entire employee
- "Reset to defaults" — re-runs `prefill_mileage_defaults` for the employee (useful if supervisor made mistakes)
- Apply via `batch_update_trip_vehicles`

## Migration Strategy

- New columns on `trips` are nullable — no backfill needed
- Existing trips get defaults via `prefill_mileage_defaults` on first page load
- `get_mileage_summary` (Flutter) continues working with existing logic; can later prioritize `vehicle_type`/`role` when populated
- UPDATE existing CRA rates to 2026 values: $0.73/$0.67 with `effective_from = '2026-01-01'`

## Out of Scope

- Employee self-service vehicle assignment in mobile app (future feature)
- Retroactive backfill of vehicle_type/role on historical trips
- Modification of existing `get_mileage_summary` RPC (Flutter keeps current behavior)
