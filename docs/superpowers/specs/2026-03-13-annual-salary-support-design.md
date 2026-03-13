# Annual Salary Support in Remuneration

**Date:** 2026-03-13
**Status:** Approved
**Feature:** Add annual contract (salaried) employee support alongside existing hourly rate system

## Context

The remuneration page currently supports hourly-rate employees only. Some employees have annual contracts with a fixed salary regardless of hours worked. These employees still use the app to track their time (for operational visibility), but their pay is not calculated from hours.

Pay frequency: biweekly (26 periods/year).

## Database Changes

### 1. New column on `employee_profiles`

```sql
pay_type TEXT NOT NULL DEFAULT 'hourly' CHECK (pay_type IN ('hourly', 'annual'))
```

- Default `'hourly'` ensures backwards compatibility — all existing employees remain hourly.

### 2. New table: `employee_annual_salaries`

| Column | Type | Constraints |
|--------|------|-------------|
| id | UUID PK | gen_random_uuid() |
| employee_id | UUID NOT NULL | FK → employee_profiles(id) ON DELETE CASCADE |
| salary | DECIMAL(12,2) NOT NULL | CHECK (salary > 0) |
| effective_from | DATE NOT NULL | |
| effective_to | DATE NULL | NULL = currently active |
| created_by | UUID | FK → employee_profiles(id) |
| created_at | TIMESTAMPTZ | DEFAULT now() |
| updated_at | TIMESTAMPTZ | DEFAULT now() |

**Constraints (mirroring `employee_hourly_rates`):**
- `CHECK (effective_to IS NULL OR effective_to > effective_from)`
- `UNIQUE (employee_id, effective_from)`
- Unique partial index: one active salary per employee (`WHERE effective_to IS NULL`)
- Overlap prevention trigger (reuse parameterized logic from `check_hourly_rate_overlap`)
- `update_updated_at_column()` trigger on UPDATE

**Indexes:**
- `idx_employee_annual_salaries_lookup` on `(employee_id, effective_from DESC)` — for efficient per-day salary lookups in the RPC

**RLS:**
- Admins/super_admins: full CRUD (FOR ALL policy with `is_admin_or_super_admin()` check)
- `GRANT ALL ON employee_annual_salaries TO authenticated` (matches `employee_hourly_rates` pattern)

**Comments (per project convention):**
- `COMMENT ON TABLE employee_annual_salaries` — with ROLE/STATUTS/REGLES/RELATIONS/TRIGGERS format
- `COMMENT ON COLUMN` for salary, effective_from, effective_to

### 3. Modify `get_timesheet_with_pay()` RPC

**New return fields:**
- `pay_type TEXT` — 'hourly' or 'annual'
- `annual_salary DECIMAL(12,2)` — raw annual salary (NULL for hourly)
- `period_amount DECIMAL(10,2)` — salary / 26 (NULL for hourly)
- Keep `has_rate BOOLEAN` as-is for backwards compatibility
- Add `has_compensation BOOLEAN` — true if hourly rate OR annual salary exists for the date

**Calculation for annual employees:**

The RPC distributes the biweekly amount (`salary / 26`) across actual working days (days with approved time) in the queried period:

- `period_amount = salary / 26` (fixed, always shown)
- `base_amount = 0` on each daily row (hours are informational only)
- The UI sums the period total as `period_amount` (not from daily `base_amount`)
- `hourly_rate` field returns NULL

**Key difference from hourly:** For annual employees, the RPC must generate rows even when no approved days exist. The approach:
1. For hourly employees: existing logic (rows only for approved days)
2. For annual employees: generate a date series for the queried range using `generate_series(p_start_date, p_end_date, '1 day')`, LEFT JOIN to `day_approvals` for informational hours. The `period_amount` is returned on every row but the UI aggregates it once per period.

**Simpler alternative chosen:** Return one summary row per annual employee per queried period with `period_amount = salary / 26`. Daily detail rows (if approved days exist) show hours for information with `base_amount = 0`. This avoids complex date series generation while ensuring annual employees always appear in the report.

**Weekend cleaning premium:** Applies to both types using the same minutes-based calculation: `cleaning_minutes / 60 × premium_rate`. This is an additional amount on top of the base pay regardless of pay type.

**Mid-period type change:** If an employee switches type mid-period, each day uses whichever type is active. For annual days, the prorated amount = `(salary / 26) × (annual_days_in_period / total_days_in_period)`.

### 4. Pay type switch validation

`updateEmployeePayType` is implemented as an RPC (not a direct table update) that:
1. Validates the target compensation record exists (active hourly rate or active annual salary)
2. If no active record exists, returns an error — the UI must prompt the admin to set the rate/salary first
3. Updates `employee_profiles.pay_type` only after validation passes

This prevents broken states where `pay_type = 'annual'` but no salary is configured.

## Dashboard UI Changes

### Rates Table (`rates-table.tsx`)

- Add "Type" column showing "Horaire" or "Annuel" badge
- Filter dropdown: rename "Avec taux" / "Sans taux" → "Avec compensation" / "Sans compensation"
- Add filter option for pay type: "Tous" / "Horaire" / "Annuel"
- Add ability to change an employee's `pay_type` (with confirmation dialog, calls the validation RPC)
- When switching type, the previous rate/salary history is preserved (just becomes inactive context)

### Rate Dialog (`rate-dialog.tsx`)

- If `pay_type = 'hourly'`: current dialog (rate $/h + effective_from)
- If `pay_type = 'annual'`: new dialog (salary $/year + effective_from), shows biweekly equivalent (`salary / 26`) as helper text
- Display shows current active rate or salary accordingly

### Rate History (`rate-history.tsx`)

- For annual employees: shows salary history instead of hourly rate history
- Column header: "Salaire ($/an)" instead of "Taux ($/h)"
- Same expandable row UX

### Timesheet / Pay Report

- For annual employees: "Montant" column shows `salary ÷ 26` with "(annuel)" label
- Hours column still populated (informational)
- `has_compensation` column used for flagging employees without any rate/salary configured

### CSV Export (`report-export.ts`)

- For annual employees: column header "Salaire annuel ($/an)" instead of "Taux horaire ($/h)"
- Include `pay_type` column in export
- Period amount column shows `salary / 26` for annuals

## API Functions (`remuneration.ts`)

```typescript
// Modified — now also queries employee_annual_salaries + pay_type
getEmployeeRatesList(): Promise<EmployeeRateListItem[]>

// New
getEmployeeSalaryHistory(employeeId: string): Promise<EmployeeAnnualSalary[]>
upsertEmployeeSalary(employeeId: string, salary: number, effectiveFrom: string): Promise<void>

// New — RPC call with server-side validation
updateEmployeePayType(employeeId: string, payType: 'hourly' | 'annual'): Promise<void>
```

## Types (TypeScript)

```typescript
// New type
interface EmployeeAnnualSalary {
  id: string;
  employee_id: string;
  salary: number;
  effective_from: string;
  effective_to: string | null;
  created_by: string | null;
  created_at: string;
  updated_at: string;
}

// Modified
interface EmployeeRateListItem {
  employee_id: string;
  full_name: string | null;
  employee_id_code: string | null;
  pay_type: 'hourly' | 'annual';
  current_rate: number | null;       // hourly rate (if hourly)
  current_salary: number | null;     // annual salary (if annual)
  effective_from: string | null;
}

// Modified
interface TimesheetWithPayRow {
  // ... existing fields ...
  pay_type: 'hourly' | 'annual';
  annual_salary: number | null;       // raw annual salary (if annual)
  period_amount: number | null;       // salary / 26 (if annual)
  has_compensation: boolean;          // true if rate OR salary exists
}
```

## Edge Cases

1. **Switching from hourly to annual:** Previous hourly rates stay in history. Admin must set an active salary before the switch is allowed (enforced by RPC).
2. **Switching from annual to hourly:** Previous salaries stay in history. Admin must set an active hourly rate before the switch is allowed (enforced by RPC).
3. **No compensation set:** `has_compensation = false`, flagged in UI with warning badge.
4. **Mid-period type change:** Each day uses the active type. Annual portion is prorated: `(salary / 26) × (annual_days / total_period_days)`.
5. **Weekend cleaning premium:** Applies to both types — minutes-based calculation (`cleaning_minutes / 60 × premium_rate`), added on top of base pay.
6. **Annual employee with no approved days:** Still appears in pay report with `period_amount = salary / 26`. Hours show as 0.

## Out of Scope

- **Flutter mobile app:** No changes needed. The mobile app does not display pay information — it only tracks time.
- **Pay period calendar/boundaries:** The system uses the query date range as the period. No separate `pay_periods` table is needed since the biweekly schedule is fixed at 26 periods/year.
