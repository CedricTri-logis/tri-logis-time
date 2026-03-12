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
| created_at | TIMESTAMPTZ | default now() |
| updated_at | TIMESTAMPTZ | default now() |

**Constraints:**
- No overlapping periods for the same employee (exclusion constraint on daterange)
- `effective_to IS NULL OR effective_to > effective_from`
- At most one record with `effective_to IS NULL` per employee
- Unique: `(employee_id, effective_from)`

**RLS:**
- Admins/super_admins: full CRUD
- Managers: SELECT on supervised employees
- Employees: no access

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

**RLS:**
- Admins/super_admins: full CRUD
- Others: SELECT only

## Dashboard: Rémunération Page

### Route: `/dashboard/remuneration`

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
- Each period: rate, from → to, modified by

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
1. Fetch approved hours from `day_approvals` (only `status = 'approved'`)
2. For each day/employee, find the active `employee_hourly_rates` record at that date
3. For Saturdays/Sundays, calculate minutes from `work_sessions` where `activity_type = 'cleaning'` that fall on that day
4. Calculate:
   - `base_amount` = approved_minutes / 60 × hourly_rate
   - `weekend_cleaning_minutes` = cleaning work_session minutes on Sat/Sun
   - `premium_amount` = (weekend_cleaning_minutes / 60) × weekend_premium
   - `total_amount` = base_amount + premium_amount

### Return (per employee)
```
employee_id         UUID
full_name           TEXT
employee_id_code    TEXT
total_approved_minutes  INTEGER
hourly_rate         DECIMAL
base_amount         DECIMAL
weekend_cleaning_minutes INTEGER
weekend_premium_rate    DECIMAL
premium_amount      DECIMAL
total_amount        DECIMAL
```

### Edge Cases
- Employee without a defined rate → amounts = 0, flag "Taux non défini"
- Rate change mid-period → each day uses the rate active on that date
- Shift crossing midnight (Sat → Sun) → minutes attributed to the calendar day they fall on
- Work session spanning Fri evening into Sat → only the Saturday portion gets the premium

## Enriched Timesheet Export

The existing timesheet report (`/dashboard/reports/timesheet`) gains additional columns:

### CSV columns added
- Taux horaire ($/h)
- Montant de base ($)
- Heures ménage weekend
- Prime weekend ($)
- Montant total ($)

### PDF additions
- Same breakdown per employee
- Totals row at the bottom

## Out of Scope
- Display of $ amounts in the approval grid or day detail panel
- Individual weekend premiums per employee (global only)
- Holiday premiums (future feature)
- Tax calculations
- Flutter mobile app changes (dashboard only)
