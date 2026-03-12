# Employee Hourly Rates & Weekend Cleaning Premium

**Date:** 2026-03-12
**Status:** Approved
**Branch:** 008-employee-shift-dashboard

## Overview

Add per-employee hourly rates with period-based history, a global weekend cleaning premium, and enriched timesheet export with calculated pay amounts.

## Goals

1. Store individual hourly rates per employee with effective date periods (no end date = current)
2. Configure a global fixed premium ($/h) for weekend cleaning work sessions
3. New "Rémunération" dashboard page to manage rates and premium
4. Enrich timesheet CSV/PDF export with calculated pay amounts

## Data Model

### Table: `employee_hourly_rates`

| Column | Type | Constraints |
|--------|------|-------------|
| id | UUID | PK, default gen_random_uuid() |
| employee_id | UUID | FK → employee_profiles, NOT NULL |
| rate | DECIMAL(10,2) | NOT NULL, CHECK > 0 |
| effective_from | DATE | NOT NULL |
| effective_to | DATE | NULL (NULL = currently active) |
| created_by | UUID | FK → employee_profiles, NULL |
| created_at | TIMESTAMPTZ | default now() |
| updated_at | TIMESTAMPTZ | default now() |

**Constraints:**
- No overlapping periods: enforced via `BEFORE INSERT OR UPDATE` trigger (`check_hourly_rate_overlap`) — follows existing `check_vehicle_period_overlap` pattern from `employee_vehicle_periods`
- `effective_to IS NULL OR effective_to > effective_from` (CHECK constraint)
- At most one record with `effective_to IS NULL` per employee: enforced via partial unique index `CREATE UNIQUE INDEX idx_employee_hourly_rates_active ON employee_hourly_rates(employee_id) WHERE effective_to IS NULL`
- Unique: `(employee_id, effective_from)`
- Performance index: `(employee_id, effective_from DESC)` for per-day rate lookups

**Triggers:**
- `update_updated_at_column()` on UPDATE (standard project pattern)
- `check_hourly_rate_overlap()` on INSERT/UPDATE (overlap prevention)

**RLS:**
- Admins/super_admins: full CRUD (inline `role IN ('admin', 'super_admin')` check on `employee_profiles`)
- Employees: no access

**COMMENT ON TABLE/COLUMN:** Required in migration per project standards (ROLE/STATUTS/REGLES/RELATIONS/TRIGGERS format).

### Table: `pay_settings`

| Column | Type | Constraints |
|--------|------|-------------|
| id | UUID | PK, default gen_random_uuid() |
| key | TEXT | UNIQUE, NOT NULL |
| value | JSONB | NOT NULL |
| updated_at | TIMESTAMPTZ | default now() |
| updated_by | UUID | FK → employee_profiles |

**Initial row:**
- key: `weekend_cleaning_premium`
- value: `{ "amount": 0.00, "currency": "CAD" }`

**Triggers:**
- `update_updated_at_column()` on UPDATE

**RLS:**
- Admins/super_admins: full CRUD
- Others: SELECT only

**COMMENT ON TABLE/COLUMN:** Required in migration per project standards.

## Dashboard: Rémunération Page

### Route: `/dashboard/remuneration`

**Sidebar navigation:** Add "Rémunération" entry in `sidebar.tsx` navigation array, after "Approbation" and before "Rapports". Icon: DollarSign (from lucide-react).

### Main View — Employee Rates Table
- Columns: Nom, ID employé, Taux actuel ($/h), En vigueur depuis, Actions
- Employees without a rate show "Non défini" in grey
- Filters: search by name, filter with/without rate
- "Modifier" button opens edit dialog

### Edit/Add Rate Dialog
- Fields: hourly rate ($/h), effective date
- When employee already has a current rate, the system auto-closes the previous period (`effective_to` = day before new `effective_from`)
- Validation: rate > 0, date required, no future date beyond reasonable range

### Rate History (expandable per employee)
- Click on employee row to expand and show all past periods
- Each period: rate, from → to, created by (from `created_by` column joined to `employee_profiles.full_name`)

### Weekend Premium Section (top of page)
- Displays current premium: "+X.XX $/h pour le ménage le weekend"
- Edit button → simple dialog with amount field
- Explanatory note: "S'applique aux heures de sessions ménage (samedi/dimanche)"

## Pay Calculation: RPC `get_timesheet_with_pay`

### Parameters
- `p_start_date` DATE
- `p_end_date` DATE
- `p_employee_ids` UUID[] (optional, NULL = all)

### Logic
1. Fetch approved days from `day_approvals` where `status = 'approved'`
2. For each day/employee, find the active `employee_hourly_rates` record at that date (`effective_from <= date AND (effective_to IS NULL OR effective_to >= date)`)
3. Use `day_approvals.approved_minutes` (not `total_shift_minutes`) for pay calculation — this is the admin-validated amount after any rejections
4. For Saturdays/Sundays (determined using `AT TIME ZONE 'America/Toronto'`), calculate minutes from `work_sessions` where `activity_type = 'cleaning'` AND `status IN ('completed', 'auto_closed', 'manually_closed')` (exclude `in_progress`)
5. Calculate per day:
   - `day_base_amount` = approved_minutes / 60 × hourly_rate
   - `day_weekend_cleaning_minutes` = cleaning work_session minutes on Sat/Sun
   - `day_premium_amount` = (weekend_cleaning_minutes / 60) × weekend_premium
   - `day_total` = day_base_amount + day_premium_amount

### Return (per employee, per day)

Returns **per-day rows** (not aggregated per employee) to handle mid-period rate changes transparently. Client-side aggregation for totals.

```
employee_id             UUID
full_name               TEXT
employee_id_code        TEXT
date                    DATE
approved_minutes        INTEGER
hourly_rate             DECIMAL       -- rate active on that date, NULL if no rate defined
base_amount             DECIMAL
weekend_cleaning_minutes INTEGER      -- 0 if not a weekend day
weekend_premium_rate    DECIMAL       -- global premium amount
premium_amount          DECIMAL
total_amount            DECIMAL
has_rate                BOOLEAN       -- false if no rate defined for this date
```

### Permissions
- `GRANT EXECUTE ON FUNCTION get_timesheet_with_pay TO authenticated;`
- The RPC itself filters to employees the caller can access (admin: all, manager: supervised)

### Edge Cases
- Employee without a defined rate → `has_rate = false`, amounts = 0
- Rate change mid-period → each day row has its own `hourly_rate`, amounts reflect the rate active on that date
- Shift crossing midnight (Sat → Sun) → minutes attributed to the calendar day they fall on (using `America/Toronto` timezone)
- Work session spanning Fri evening into Sat → **Simplification v1:** entire session attributed to its start date (no cross-midnight splitting). If needed, splitting can be added in a future iteration
- Work sessions with `status = 'in_progress'` are excluded from premium calculation

## Enriched Timesheet Export

The existing timesheet report (`/dashboard/reports/timesheet`) calls `get_timesheet_with_pay` **as a new separate RPC** alongside the existing `get_timesheet_report_data`. The existing RPC continues to provide shift-level detail; the new RPC provides pay data per day.

### CSV columns added
- Taux horaire ($/h)
- Montant de base ($)
- Heures ménage weekend
- Prime weekend ($)
- Montant total ($)

### PDF additions
- Same breakdown per employee per day
- Totals row at the bottom per employee
- Grand total row at the very bottom

## Out of Scope
- Display of $ amounts in the approval grid or day detail panel
- Individual weekend premiums per employee (global only)
- Holiday premiums (future feature)
- Tax calculations
- Flutter mobile app changes (dashboard only)
