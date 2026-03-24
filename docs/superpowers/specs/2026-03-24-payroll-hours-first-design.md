# Payroll Hours-First Redesign

## Problem

The payroll summary table has 14+ flat columns mixing hours and dollar amounts with no visual grouping. You see "1 253.88 $" but don't know the hourly rate or how the total was derived. Annual employees show opaque fixed amounts with no reference to the 40h/week base.

## Solution

Reorganize columns into labeled groups that read left-to-right: "Employee worked X hours (Y refused) at Z$/h + premiums = Total". Add a Taux/h column, a Refusées column, and make annual employee calculations explicit.

## Column Layout

### Current columns (14, flat)
▶ | Employé | Type | Heures | Rappel bonus | Pause | Sans pause | Déd. pause | % Sessions | Prime FDS | Base | Total | Jours | Paie

### New columns (16, grouped)

| Group | Columns | Notes |
|-------|---------|-------|
| ▶ | Expand chevron | unchanged |
| EMPLOYÉ | Employé, Type | unchanged |
| TEMPS | Heures, **Refusées**, Rappel, Pause, Sans pause, Déd. pause | Refusées is new; Déd. pause moves here from its current position |
| QUALITÉ | % Sessions | unchanged |
| CALCUL PAIE | **Taux/h**, Prime FDS, **Rappel $**, Total | Taux/h is new; Rappel $ replaces the old "Rappel bonus" dollar component; Base column removed |
| STATUT | Jours, Paie | unchanged |

### Visual treatment
- Group header row above column headers with colored labels: TEMPS (blue), CALCUL PAIE (amber), STATUT (gray)
- 2px vertical borders between groups
- Group colors on key column headers (Heures in blue, Taux/h in amber, Refusées in red)

## Column Details

### Added: "Refusées" (red)
- Shows hours rejected during day approval
- Source: `day_approvals.rejected_minutes` — exists in DB but not yet returned by `get_payroll_period_report`
- Display: `2h15` in red, or `—` if none
- Aggregated in sub-totals and grand total

### Added: "Taux/h" (amber)
- **Hourly employees**: exact rate from `employee_hourly_rates` (e.g., "19.33 $/h")
- **Annual employees**: equivalent rate = `annual_salary / 2080` with `~` prefix (e.g., "~25.00 $/h")
- Source: `hourly_rate` already returned by RPC; annual salary already returned, compute equivalent in hook

### Added: "Rappel $"
- Dollar amount of callback bonus (bonus hours × rate)
- Source: `callback_bonus_amount` already returned by RPC
- Replaces the dollar aspect that was conflated with "Rappel bonus" hours column

### Removed: "Base"
- Was: `heures × taux` for hourly, `period_salary` for annual
- Redundant — the reader can derive it from Heures × Taux/h
- For annual employees, the calculation is shown as sub-text under Total instead

### Kept: "Déd. pause"
- Already implemented (break deduction with waiver toggle)
- Moves into the TEMPS group where it logically belongs

## Annual Employee Display

- **Heures column**: shows actual hours worked (e.g., "75h20"). Warning icon + `<80h` if below 80h for the period
- **Taux/h column**: shows `~XX.XX $/h` (annual_salary / 2080)
- **Total column**: shows the fixed period amount (annual_salary / 26) + premiums. Below the amount, sub-text shows "80h × XX.XX" to make the calculation explicit
- The pay is always based on 80h (40h/week × 2 weeks), regardless of actual hours worked

## Database Changes

### Migration: Add `rejected_minutes` to payroll RPC
- Add `rejected_minutes` to the `RETURNS TABLE` of `get_payroll_period_report`
- Source from `day_approvals.rejected_minutes` (already exists, just not selected)
- Join is already in place via the `approvals` CTE — just need to include the column

## Frontend Changes

### `dashboard/src/types/payroll.ts`
- Add `rejected_minutes: number` to `PayrollReportRow`
- Add `total_rejected_minutes: number` to `PayrollEmployeeSummary`
- Add `hourly_rate_display: string` to `PayrollEmployeeSummary` (formatted rate for display)

### `dashboard/src/lib/hooks/use-payroll-report.ts`
- Aggregate `rejected_minutes` into `total_rejected_minutes`
- Compute `hourly_rate_display`: exact rate for hourly, `~` + (annual_salary/2080) for annual
- Include `rejected_minutes` in category and grand totals

### `dashboard/src/components/payroll/payroll-summary-table.tsx`
- Add group header row with colored labels and colSpan
- Reorder columns per new layout
- Add Refusées column
- Add Taux/h column
- Add Rappel $ column (from callback_bonus_amount)
- Remove Base column
- Add 2px vertical borders between groups
- Update sub-total and grand total rows to include new columns
- Annual employees: show sub-text "80h × rate" under Total

### `dashboard/src/lib/utils/export-payroll-excel.ts`
- Update Excel export to match new column order
- Add Refusées and Taux/h columns
- Remove Base column

## Out of Scope

- Changing the expanded employee detail view (daily breakdown)
- Changing the payroll approval flow
- Mileage columns in summary table (already in RPC, separate feature)
