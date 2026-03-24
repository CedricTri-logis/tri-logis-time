# Fixed Mileage Allowance (Forfait kilométrage)

## Problem

Some employees have a negotiated agreement for a fixed mileage reimbursement per pay period instead of being paid per kilometer. Currently, the system only supports per-km CRA-tiered reimbursement. We need to support both models side by side.

## Current State

- All mileage reimbursement is calculated per-km using CRA tiered rates ($0.72/km first 5,000 km, $0.66/km after)
- `reimbursement_rates` table stores per-km rates
- `approve_mileage` RPC freezes calculated `reimbursable_km` and `reimbursement_amount`
- `approve_mileage` delegates to `get_mileage_approval_detail` to get the `estimated_amount` before freezing
- `get_mileage_approval_summary/detail` RPCs compute estimated amounts from km × rate
- `get_payroll_period_report` returns `reimbursement_amount` per employee

## Design

### New Table: `employee_mileage_allowances`

Follows the same period-based pattern as `employee_vehicle_periods` (including ON DELETE CASCADE, indexes, overlap trigger, updated_at trigger, RLS policies, and COMMENT ON).

```sql
CREATE TABLE employee_mileage_allowances (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
  amount_per_period DECIMAL(10,2) NOT NULL CHECK (amount_per_period > 0),
  started_at DATE NOT NULL,
  ended_at DATE,  -- NULL = ongoing
  notes TEXT,
  created_by UUID REFERENCES employee_profiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes
CREATE INDEX idx_mileage_allowances_employee ON employee_mileage_allowances(employee_id);
CREATE INDEX idx_mileage_allowances_dates ON employee_mileage_allowances(started_at, ended_at);

-- updated_at trigger (reuse existing update_updated_at_column function)
CREATE TRIGGER trg_mileage_allowances_updated_at
  BEFORE UPDATE ON employee_mileage_allowances
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Overlap prevention trigger (per employee_id, no sub-type unlike vehicle_periods)
CREATE OR REPLACE FUNCTION check_mileage_allowance_overlap() ...
CREATE TRIGGER trg_mileage_allowance_no_overlap
  BEFORE INSERT OR UPDATE ON employee_mileage_allowances
  FOR EACH ROW EXECUTE FUNCTION check_mileage_allowance_overlap();

-- RLS: admin can manage, employee can view own
-- COMMENT ON TABLE and COMMENT ON COLUMN included in migration
```

**Helper function:**

```sql
get_active_mileage_allowance(p_employee_id UUID, p_date DATE)
  RETURNS DECIMAL
```

Returns the `amount_per_period` if an active allowance exists on that date (started_at <= date AND (ended_at IS NULL OR ended_at >= date)), NULL otherwise.

### Schema Change: `mileage_approvals` table

Add columns to freeze the forfait status at approval time (audit trail):

```sql
ALTER TABLE mileage_approvals
  ADD COLUMN is_forfait BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN forfait_amount DECIMAL(10,2);
```

When `approve_mileage` freezes values, it also sets `is_forfait = true` and `forfait_amount` for forfait employees. This ensures the dashboard can show the "Forfait" badge on already-approved periods without re-querying `employee_mileage_allowances` (which may have changed since approval).

### RPC Changes

**Important dependency:** `approve_mileage` delegates to `get_mileage_approval_detail` to get `estimated_amount`. Therefore `get_mileage_approval_detail` must have forfait logic FIRST — both RPCs must be updated in the same migration.

#### `get_mileage_approval_detail(employee_id, period_start, period_end)`

Change: check `get_active_mileage_allowance(employee_id, period_start)`. If non-null:
- Summary section includes `is_forfait: true`, `forfait_amount: <value>`, `estimated_amount: <forfait value>`
- Trip-level detail remains unchanged (km still tracked)
- `reimbursable_km` still calculated normally (informational)

This must come before `approve_mileage` changes since it depends on this output.

#### `approve_mileage(employee_id, period_start, period_end)`

Change: after getting detail from `get_mileage_approval_detail`, freeze:
- `reimbursement_amount` = forfait amount (from detail summary)
- `reimbursable_km` = still from km calculation (informational)
- `is_forfait = true`, `forfait_amount = <value>` on `mileage_approvals` row

**Vehicle/role assignment requirement:** forfait employees still need all trips assigned (vehicle_type + role) before approval. The tracking data is still valuable for reporting even though it doesn't affect the amount.

#### `get_mileage_approval_summary(period_start, period_end)`

Change: the CTE must check per-employee (not global) whether an allowance exists. For each employee:
- If approved: read `is_forfait` from `mileage_approvals` row
- If not approved: check `get_active_mileage_allowance(employee_id, period_start)`
- Add `is_forfait BOOLEAN` to returned JSON

The current CTE uses a single `v_rate_per_km` for all employees — this needs refactoring to per-employee logic via a CASE expression or lateral join.

#### `get_payroll_period_report`

Change: in the mileage data CTE, for unapproved forfait employees use the forfait amount instead of km × rate. For approved employees, use frozen values (which already include forfait if applicable).

### Dashboard Changes

#### Mileage Allowance Management

Add a management section (similar to vehicle periods tab) where admin can:
- View active mileage allowances
- Create a new allowance (employee, amount, start date)
- End an allowance (set `ended_at`)

Location: alongside vehicle periods in the mileage configuration area.

#### TypeScript Types

- `MileageApprovalSummaryRow` — add `is_forfait: boolean`
- `MileageApprovalDetailSummary` — add `is_forfait: boolean`, `forfait_amount: number | null`
- `MileageApproval` — add `is_forfait: boolean`, `forfait_amount: number | null`
- New `EmployeeMileageAllowance` type (mirrors `EmployeeVehiclePeriod`)

#### Mileage Approval Grid

- For forfait employees, show a "Forfait" badge next to the estimated/approved amount
- The km column still shows actual tracked km (informational)
- Approval flow is identical — admin still clicks approve, but the frozen amount is the forfait

#### Payroll Report / Excel Export

- Same `reimbursement_amount` column, no distinction needed
- Note: mileage columns are not yet in the Excel export (pre-existing gap, not in scope here)

### What Does NOT Change

- GPS tracking and trip recording
- Trip classification (business/personal)
- Vehicle type / role assignment (still required even for forfait employees)
- Carpool detection
- `reimbursable_km` tracking — still calculated and stored (informational)
- Payroll column structure
- Per-km employees — completely unaffected

### Edge Cases

**Allowance starts mid-period:** Use the allowance active at `period_start`. If not active at period start, use per-km calculation for the whole period. No pro-rating.

**Allowance ends during period:** Same rule — check at `period_start`. If active, use forfait for the whole period.

**Partial period (e.g. hired mid-period):** Forfait is always the full `amount_per_period`, regardless of how many days are in the period.

**Employee has both vehicle periods and mileage allowance:** Independent concepts. The forfait overrides the reimbursement calculation but doesn't affect vehicle/role tracking.

**Reopening an approved period:** Works the same — clears the frozen amount, recalculates on next approval using whatever method applies (forfait or per-km).

## Migration Plan

Single migration file (RPCs are interdependent):

1. Create `employee_mileage_allowances` table with all constraints, indexes, triggers, RLS, COMMENT ON
2. Create `get_active_mileage_allowance` helper function
3. ALTER `mileage_approvals` — add `is_forfait`, `forfait_amount` columns
4. Update `get_mileage_approval_detail` with forfait logic (must come before approve_mileage)
5. Update `approve_mileage` to freeze forfait fields
6. Update `get_mileage_approval_summary` with per-employee forfait check
7. Update `get_payroll_period_report` with forfait fallback
8. Seed Irène's allowance: $100/period (started_at to be confirmed with admin)

Dashboard work (separate from migration):

9. Add `EmployeeMileageAllowance` type and update existing mileage types
10. Add allowance management UI (tab alongside vehicle periods)
11. Add "Forfait" badge in mileage approval grid
