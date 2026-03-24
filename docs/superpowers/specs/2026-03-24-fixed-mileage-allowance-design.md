# Fixed Mileage Allowance (Forfait kilométrage)

## Problem

Some employees have a negotiated agreement for a fixed mileage reimbursement per pay period instead of being paid per kilometer. Currently, the system only supports per-km CRA-tiered reimbursement. We need to support both models side by side.

## Current State

- All mileage reimbursement is calculated per-km using CRA tiered rates ($0.72/km first 5,000 km, $0.66/km after)
- `reimbursement_rates` table stores per-km rates
- `approve_mileage` RPC freezes calculated `reimbursable_km` and `reimbursement_amount`
- `get_mileage_approval_summary/detail` RPCs compute estimated amounts from km × rate
- `get_payroll_period_report` returns `reimbursement_amount` per employee
- Payroll export Excel uses the same column

## Design

### New Table: `employee_mileage_allowances`

Follows the same period-based pattern as `employee_vehicle_periods`.

```sql
CREATE TABLE employee_mileage_allowances (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES employee_profiles(id),
  amount_per_period DECIMAL(10,2) NOT NULL,
  started_at DATE NOT NULL,
  ended_at DATE,  -- NULL = ongoing
  notes TEXT,
  created_by UUID REFERENCES employee_profiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

**Constraints:**
- No overlapping active periods for the same employee (same pattern as vehicle periods)
- `amount_per_period > 0`

**Helper function:**
- `get_active_mileage_allowance(p_employee_id UUID, p_date DATE) RETURNS DECIMAL` — returns the fixed amount if an active allowance exists on that date, NULL otherwise.

### RPC Changes

#### `approve_mileage(employee_id, period_start, period_end)`

Current: calculates `reimbursement_amount` from km × tiered rate.

Change: before calculating, check if employee has an active mileage allowance for the period. If yes:
- `reimbursement_amount` = `amount_per_period` (the fixed forfait)
- `reimbursable_km` = still calculated normally (informational tracking)
- A flag or note indicates this is a forfait-based approval

Logic: use `get_active_mileage_allowance(employee_id, period_start)` to check. If the allowance is active at the start of the period, use the forfait.

#### `get_mileage_approval_summary(period_start, period_end)`

Change: for employees with active allowance, `estimated_amount` = forfait instead of km × rate. Add a `is_forfait BOOLEAN` field in the returned JSON so the dashboard can display a badge.

#### `get_mileage_approval_detail(employee_id, period_start, period_end)`

Change: include `is_forfait` and `forfait_amount` in the summary section of the response. Trip-level detail remains unchanged (km are still tracked).

#### `get_payroll_period_report`

Change: when building the mileage portion, if employee has active allowance → use forfait amount. Same `reimbursement_amount` column — no structural change to payroll output.

### Dashboard Changes

#### Mileage Allowance Management

Add a small management section (similar to vehicle periods) where admin can:
- View active mileage allowances
- Create a new allowance (employee, amount, start date)
- End an allowance (set `ended_at`)

Location: within the existing mileage configuration area or as a tab alongside vehicle periods.

#### Mileage Approval Grid

- For forfait employees, show a "Forfait" badge next to the estimated/approved amount
- The km column still shows actual tracked km (informational)
- Approval flow is identical — admin still clicks approve, but the frozen amount is the forfait

#### Payroll Report / Excel Export

- Same `reimbursement_amount` column, no distinction needed
- The value is simply the forfait instead of a calculated amount

### What Does NOT Change

- GPS tracking and trip recording — unchanged
- Trip classification (business/personal) — unchanged
- Vehicle type / role assignment — unchanged
- Carpool detection — unchanged
- `reimbursable_km` tracking — still calculated and stored (informational)
- Payroll column structure — same columns
- Per-km employees — completely unaffected

### Edge Cases

**Allowance starts mid-period:** Use the allowance active at `period_start`. If not active at period start, use per-km calculation for the whole period. No pro-rating — keep it simple.

**Allowance ends during period:** Same rule — check at `period_start`. If active, use forfait for the whole period.

**Employee has both vehicle periods and mileage allowance:** Independent concepts. An employee with a forfait could have a personal vehicle period. The forfait overrides the reimbursement calculation but doesn't affect vehicle/role tracking.

**Reopening an approved period:** Works the same — clears the frozen amount, recalculates on next approval using whatever method applies (forfait or per-km).

## Migration Plan

1. Create `employee_mileage_allowances` table with constraints and helper function
2. Update `approve_mileage` RPC to check for forfait
3. Update `get_mileage_approval_summary` to include `is_forfait` flag
4. Update `get_mileage_approval_detail` to include forfait info
5. Update `get_payroll_period_report` to use forfait when applicable
6. Dashboard: add allowance management UI
7. Dashboard: add forfait badge in approval grid
8. Seed Irène's allowance: $100/period, started_at = start of her agreement
