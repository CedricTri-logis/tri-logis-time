# Annual Salary Support Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add annual contract (salaried) employee support to the remuneration system, alongside the existing hourly rate system.

**Architecture:** Add `pay_type` column to `employee_profiles`, create `employee_annual_salaries` table (mirroring `employee_hourly_rates`), update `get_timesheet_with_pay()` RPC to handle both types, and adapt the dashboard UI to manage both pay types.

**Tech Stack:** PostgreSQL (Supabase), TypeScript, Next.js 14+, shadcn/ui, @tanstack/react-table, Zod

**Spec:** `docs/superpowers/specs/2026-03-13-annual-salary-support-design.md`

---

## Chunk 1: Database Migrations

### Task 1: Add `pay_type` column and `employee_annual_salaries` table

**Files:**
- Create: `supabase/migrations/20260313000000_annual_salary_support.sql`

- [ ] **Step 1: Write the migration file**

Create `supabase/migrations/20260313000000_annual_salary_support.sql`:

```sql
-- ============================================================
-- Migration: Annual Salary Support
-- Feature: Add pay_type to employee_profiles + employee_annual_salaries table
-- Spec: docs/superpowers/specs/2026-03-13-annual-salary-support-design.md
-- ============================================================

-- ===================
-- 1. Add pay_type to employee_profiles
-- ===================
ALTER TABLE employee_profiles
  ADD COLUMN pay_type TEXT NOT NULL DEFAULT 'hourly'
  CHECK (pay_type IN ('hourly', 'annual'));

COMMENT ON COLUMN employee_profiles.pay_type IS 'Pay type: hourly (default) or annual (fixed salary contract). Determines how compensation is calculated in get_timesheet_with_pay.';

-- ===================
-- 2. employee_annual_salaries table
-- ===================
CREATE TABLE IF NOT EXISTS employee_annual_salaries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
  salary DECIMAL(12,2) NOT NULL CHECK (salary > 0),
  effective_from DATE NOT NULL,
  effective_to DATE NULL,
  created_by UUID REFERENCES employee_profiles(id),
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT annual_salary_dates_valid CHECK (effective_to IS NULL OR effective_to > effective_from),
  CONSTRAINT annual_salary_unique_period UNIQUE (employee_id, effective_from)
);

-- Partial unique index: only one active (no end date) salary per employee
CREATE UNIQUE INDEX idx_employee_annual_salaries_active
  ON employee_annual_salaries(employee_id) WHERE effective_to IS NULL;

-- Performance index for per-day salary lookups
CREATE INDEX idx_employee_annual_salaries_lookup
  ON employee_annual_salaries(employee_id, effective_from DESC);

-- Trigger: auto-update updated_at
CREATE TRIGGER update_employee_annual_salaries_updated_at
  BEFORE UPDATE ON employee_annual_salaries
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- ===================
-- 3. Overlap prevention trigger
-- ===================
CREATE OR REPLACE FUNCTION check_annual_salary_overlap()
RETURNS TRIGGER AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM employee_annual_salaries
    WHERE employee_id = NEW.employee_id
      AND id != COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid)
      AND effective_from < COALESCE(NEW.effective_to, '9999-12-31'::date)
      AND COALESCE(effective_to, '9999-12-31'::date) > NEW.effective_from
  ) THEN
    RAISE EXCEPTION 'Overlapping annual salary period for employee %', NEW.employee_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_annual_salary_overlap
  BEFORE INSERT OR UPDATE ON employee_annual_salaries
  FOR EACH ROW
  EXECUTE FUNCTION check_annual_salary_overlap();

-- ===================
-- 4. RLS
-- ===================
ALTER TABLE employee_annual_salaries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage annual salaries"
  ON employee_annual_salaries FOR ALL
  USING (is_admin_or_super_admin(auth.uid()))
  WITH CHECK (is_admin_or_super_admin(auth.uid()));

-- Grant
GRANT ALL ON employee_annual_salaries TO authenticated;

-- ===================
-- 5. Comments
-- ===================
COMMENT ON TABLE employee_annual_salaries IS
  'ROLE: Stores per-employee annual salary amounts with period-based history.
   STATUTS: effective_to IS NULL means currently active salary.
   REGLES: No overlapping periods per employee (trigger). At most one active salary per employee (partial unique index). Salary must be > 0.
   RELATIONS: employee_id → employee_profiles (CASCADE), created_by → employee_profiles.
   TRIGGERS: check_annual_salary_overlap (BEFORE INSERT/UPDATE), update_updated_at_column (BEFORE UPDATE).';

COMMENT ON COLUMN employee_annual_salaries.salary IS 'Annual salary in CAD ($/year). Biweekly amount = salary / 26.';
COMMENT ON COLUMN employee_annual_salaries.effective_from IS 'Start date of this salary period (inclusive)';
COMMENT ON COLUMN employee_annual_salaries.effective_to IS 'End date of this salary period (inclusive). NULL = currently active.';
COMMENT ON COLUMN employee_annual_salaries.created_by IS 'Admin who created/modified this salary entry';

-- ===================
-- 6. RPC: update_employee_pay_type (with validation)
-- ===================
CREATE OR REPLACE FUNCTION update_employee_pay_type(
  p_employee_id UUID,
  p_pay_type TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_has_compensation BOOLEAN;
BEGIN
  -- Validate pay_type value
  IF p_pay_type NOT IN ('hourly', 'annual') THEN
    RAISE EXCEPTION 'Invalid pay_type: %. Must be hourly or annual.', p_pay_type;
  END IF;

  -- Check that the target compensation type has an active record
  IF p_pay_type = 'hourly' THEN
    SELECT EXISTS(
      SELECT 1 FROM employee_hourly_rates
      WHERE employee_id = p_employee_id AND effective_to IS NULL
    ) INTO v_has_compensation;
  ELSE
    SELECT EXISTS(
      SELECT 1 FROM employee_annual_salaries
      WHERE employee_id = p_employee_id AND effective_to IS NULL
    ) INTO v_has_compensation;
  END IF;

  IF NOT v_has_compensation THEN
    RAISE EXCEPTION 'Cannot switch to %: no active % found for employee %. Set the % first.',
      p_pay_type,
      CASE WHEN p_pay_type = 'hourly' THEN 'hourly rate' ELSE 'annual salary' END,
      p_employee_id,
      CASE WHEN p_pay_type = 'hourly' THEN 'rate' ELSE 'salary' END;
  END IF;

  -- Update pay_type
  UPDATE employee_profiles SET pay_type = p_pay_type WHERE id = p_employee_id;
END;
$$;

GRANT EXECUTE ON FUNCTION update_employee_pay_type TO authenticated;
```

- [ ] **Step 2: Apply migration via MCP**

Run this migration against the live Supabase database using the `apply_migration` MCP tool. Verify no errors.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260313000000_annual_salary_support.sql
git commit -m "feat(db): add pay_type column and employee_annual_salaries table

Adds annual salary support:
- pay_type column on employee_profiles (hourly/annual)
- employee_annual_salaries table with overlap prevention
- update_employee_pay_type RPC with validation"
```

---

### Task 2: Update `get_timesheet_with_pay()` RPC

**Files:**
- Create: `supabase/migrations/20260313000001_update_timesheet_with_pay_annual.sql`

- [ ] **Step 1: Write the updated RPC migration**

Create `supabase/migrations/20260313000001_update_timesheet_with_pay_annual.sql`:

```sql
-- ============================================================
-- Migration: Update get_timesheet_with_pay for annual salary support
-- Adds pay_type, annual_salary, period_amount, has_compensation fields
-- Annual employees appear even without approved days
-- ============================================================

CREATE OR REPLACE FUNCTION get_timesheet_with_pay(
  p_start_date DATE,
  p_end_date DATE,
  p_employee_ids UUID[] DEFAULT NULL
)
RETURNS TABLE (
  employee_id UUID,
  full_name TEXT,
  employee_id_code TEXT,
  date DATE,
  approved_minutes INTEGER,
  hourly_rate DECIMAL(10,2),
  base_amount DECIMAL(10,2),
  weekend_cleaning_minutes INTEGER,
  weekend_premium_rate DECIMAL(10,2),
  premium_amount DECIMAL(10,2),
  total_amount DECIMAL(10,2),
  has_rate BOOLEAN,
  pay_type TEXT,
  annual_salary DECIMAL(12,2),
  period_amount DECIMAL(10,2),
  has_compensation BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_caller_role TEXT;
  v_caller_id UUID := auth.uid();
  v_premium DECIMAL(10,2);
  v_supervised_ids UUID[];
BEGIN
  -- 1. Auth check
  SELECT role INTO v_caller_role
  FROM employee_profiles WHERE id = v_caller_id;

  IF v_caller_role IS NULL OR v_caller_role NOT IN ('admin', 'super_admin', 'manager') THEN
    RAISE EXCEPTION 'Unauthorized: requires admin, super_admin, or manager role';
  END IF;

  -- 2. For managers, restrict to supervised employees
  IF v_caller_role = 'manager' THEN
    SELECT array_agg(es.employee_id) INTO v_supervised_ids
    FROM employee_supervisors es
    WHERE es.manager_id = v_caller_id
      AND es.effective_to IS NULL;

    IF p_employee_ids IS NOT NULL THEN
      p_employee_ids := ARRAY(
        SELECT unnest(p_employee_ids)
        INTERSECT
        SELECT unnest(v_supervised_ids)
      );
    ELSE
      p_employee_ids := v_supervised_ids;
    END IF;
  END IF;

  -- 3. Get weekend cleaning premium
  SELECT COALESCE((value->>'amount')::DECIMAL(10,2), 0.00) INTO v_premium
  FROM pay_settings WHERE key = 'weekend_cleaning_premium';

  IF v_premium IS NULL THEN
    v_premium := 0.00;
  END IF;

  -- 4. Return rows for HOURLY employees (existing logic)
  RETURN QUERY
  WITH approved_days AS (
    SELECT
      da.employee_id,
      da.date,
      da.approved_minutes AS mins
    FROM day_approvals da
    WHERE da.status = 'approved'
      AND da.date BETWEEN p_start_date AND p_end_date
      AND (p_employee_ids IS NULL OR da.employee_id = ANY(p_employee_ids))
  ),
  rates AS (
    SELECT
      ehr.employee_id,
      ehr.rate,
      ehr.effective_from,
      ehr.effective_to
    FROM employee_hourly_rates ehr
    WHERE (p_employee_ids IS NULL OR ehr.employee_id = ANY(p_employee_ids))
  ),
  weekend_cleaning AS (
    SELECT
      ws.employee_id,
      (ws.started_at AT TIME ZONE 'America/Toronto')::DATE AS ws_date,
      SUM(
        EXTRACT(EPOCH FROM (
          COALESCE(ws.completed_at, now()) - ws.started_at
        )) / 60
      )::INTEGER AS cleaning_mins
    FROM work_sessions ws
    WHERE ws.activity_type = 'cleaning'
      AND ws.status IN ('completed', 'auto_closed', 'manually_closed')
      AND (ws.started_at AT TIME ZONE 'America/Toronto')::DATE BETWEEN p_start_date AND p_end_date
      AND EXTRACT(DOW FROM (ws.started_at AT TIME ZONE 'America/Toronto')) IN (0, 6)
      AND (p_employee_ids IS NULL OR ws.employee_id = ANY(p_employee_ids))
    GROUP BY ws.employee_id, (ws.started_at AT TIME ZONE 'America/Toronto')::DATE
  )
  SELECT
    ad.employee_id,
    ep.full_name,
    ep.employee_id AS employee_id_code,
    ad.date,
    ad.mins AS approved_minutes,
    r.rate AS hourly_rate,
    COALESCE(ROUND((ad.mins / 60.0) * r.rate, 2), 0.00) AS base_amount,
    COALESCE(wc.cleaning_mins, 0) AS weekend_cleaning_minutes,
    v_premium AS weekend_premium_rate,
    COALESCE(ROUND((COALESCE(wc.cleaning_mins, 0) / 60.0) * v_premium, 2), 0.00) AS premium_amount,
    COALESCE(ROUND((ad.mins / 60.0) * r.rate, 2), 0.00)
      + COALESCE(ROUND((COALESCE(wc.cleaning_mins, 0) / 60.0) * v_premium, 2), 0.00) AS total_amount,
    r.rate IS NOT NULL AS has_rate,
    'hourly'::TEXT AS pay_type,
    NULL::DECIMAL(12,2) AS annual_salary,
    NULL::DECIMAL(10,2) AS period_amount,
    r.rate IS NOT NULL AS has_compensation
  FROM approved_days ad
  JOIN employee_profiles ep ON ep.id = ad.employee_id AND ep.pay_type = 'hourly'
  LEFT JOIN rates r ON r.employee_id = ad.employee_id
    AND r.effective_from <= ad.date
    AND (r.effective_to IS NULL OR r.effective_to >= ad.date)
  LEFT JOIN weekend_cleaning wc ON wc.employee_id = ad.employee_id AND wc.ws_date = ad.date;

  -- 5. Return rows for ANNUAL employees
  -- Annual employees get one summary row per employee for the period
  -- plus daily detail rows if they have approved days
  RETURN QUERY
  WITH annual_employees AS (
    SELECT ep.id AS emp_id, ep.full_name AS emp_name, ep.employee_id AS emp_code
    FROM employee_profiles ep
    WHERE ep.pay_type = 'annual'
      AND ep.status = 'active'
      AND (p_employee_ids IS NULL OR ep.id = ANY(p_employee_ids))
  ),
  annual_salaries AS (
    SELECT
      eas.employee_id,
      eas.salary
    FROM employee_annual_salaries eas
    WHERE (p_employee_ids IS NULL OR eas.employee_id = ANY(p_employee_ids))
      AND eas.effective_from <= p_end_date
      AND (eas.effective_to IS NULL OR eas.effective_to >= p_start_date)
    -- Pick the salary active at end of period (or most recent)
  ),
  annual_approved AS (
    SELECT
      da.employee_id,
      da.date,
      da.approved_minutes AS mins
    FROM day_approvals da
    JOIN annual_employees ae ON ae.emp_id = da.employee_id
    WHERE da.status = 'approved'
      AND da.date BETWEEN p_start_date AND p_end_date
  ),
  annual_weekend_cleaning AS (
    SELECT
      ws.employee_id,
      (ws.started_at AT TIME ZONE 'America/Toronto')::DATE AS ws_date,
      SUM(
        EXTRACT(EPOCH FROM (
          COALESCE(ws.completed_at, now()) - ws.started_at
        )) / 60
      )::INTEGER AS cleaning_mins
    FROM work_sessions ws
    JOIN annual_employees ae ON ae.emp_id = ws.employee_id
    WHERE ws.activity_type = 'cleaning'
      AND ws.status IN ('completed', 'auto_closed', 'manually_closed')
      AND (ws.started_at AT TIME ZONE 'America/Toronto')::DATE BETWEEN p_start_date AND p_end_date
      AND EXTRACT(DOW FROM (ws.started_at AT TIME ZONE 'America/Toronto')) IN (0, 6)
    GROUP BY ws.employee_id, (ws.started_at AT TIME ZONE 'America/Toronto')::DATE
  )
  -- Summary row per annual employee (date = p_start_date as anchor)
  SELECT
    ae.emp_id AS employee_id,
    ae.emp_name AS full_name,
    ae.emp_code AS employee_id_code,
    p_start_date AS date,
    COALESCE((SELECT SUM(aa.mins) FROM annual_approved aa WHERE aa.employee_id = ae.emp_id), 0)::INTEGER AS approved_minutes,
    NULL::DECIMAL(10,2) AS hourly_rate,
    0.00::DECIMAL(10,2) AS base_amount,
    COALESCE((SELECT SUM(awc.cleaning_mins) FROM annual_weekend_cleaning awc WHERE awc.employee_id = ae.emp_id), 0)::INTEGER AS weekend_cleaning_minutes,
    v_premium AS weekend_premium_rate,
    COALESCE(ROUND((COALESCE((SELECT SUM(awc.cleaning_mins) FROM annual_weekend_cleaning awc WHERE awc.employee_id = ae.emp_id), 0) / 60.0) * v_premium, 2), 0.00) AS premium_amount,
    COALESCE(ROUND(sal.salary / 26.0, 2), 0.00)
      + COALESCE(ROUND((COALESCE((SELECT SUM(awc.cleaning_mins) FROM annual_weekend_cleaning awc WHERE awc.employee_id = ae.emp_id), 0) / 60.0) * v_premium, 2), 0.00) AS total_amount,
    FALSE AS has_rate,
    'annual'::TEXT AS pay_type,
    sal.salary AS annual_salary,
    COALESCE(ROUND(sal.salary / 26.0, 2), 0.00) AS period_amount,
    sal.salary IS NOT NULL AS has_compensation
  FROM annual_employees ae
  LEFT JOIN LATERAL (
    SELECT eas.salary FROM employee_annual_salaries eas
    WHERE eas.employee_id = ae.emp_id
      AND eas.effective_from <= p_end_date
      AND (eas.effective_to IS NULL OR eas.effective_to >= p_start_date)
    ORDER BY eas.effective_from DESC
    LIMIT 1
  ) sal ON TRUE
  ORDER BY ae.emp_name;
END;
$$;

COMMENT ON FUNCTION get_timesheet_with_pay IS
  'Returns per-employee pay data for a date range.
   Hourly employees: per-day rows (approved_minutes x hourly_rate + weekend premium).
   Annual employees: one summary row per period (salary / 26 + weekend premium).
   New fields: pay_type, annual_salary, period_amount, has_compensation.
   Timezone: America/Toronto for weekend determination.';
```

- [ ] **Step 2: Apply migration via MCP**

Run this migration against the live Supabase database. Verify no errors.

- [ ] **Step 3: Test the RPC**

Run a quick test query via MCP `execute_sql`:
```sql
SELECT * FROM get_timesheet_with_pay('2026-03-01', '2026-03-13') LIMIT 5;
```
Verify: existing hourly employees still return correct data, new columns (`pay_type`, `annual_salary`, `period_amount`, `has_compensation`) are present.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260313000001_update_timesheet_with_pay_annual.sql
git commit -m "feat(db): update get_timesheet_with_pay for annual salary support

Annual employees get one summary row per period with salary/26.
Hourly employees unchanged. New return fields: pay_type,
annual_salary, period_amount, has_compensation."
```

---

## Chunk 2: TypeScript Types, API Functions, and Validations

### Task 3: Update TypeScript types

**Files:**
- Modify: `dashboard/src/types/remuneration.ts`

- [ ] **Step 1: Add new types and update existing ones**

Add `EmployeeAnnualSalary` and `EmployeeAnnualSalaryWithCreator` interfaces. Add `pay_type`, `current_salary` to `EmployeeRateListItem`. Add `pay_type`, `annual_salary`, `period_amount`, `has_compensation` to `TimesheetWithPayRow`.

```typescript
// Add after EmployeeHourlyRateWithCreator (line 16):

export interface EmployeeAnnualSalary {
  id: string;
  employee_id: string;
  salary: number;
  effective_from: string; // DATE as ISO string
  effective_to: string | null;
  created_by: string | null;
  created_at: string;
  updated_at: string;
}

export interface EmployeeAnnualSalaryWithCreator extends EmployeeAnnualSalary {
  creator_name: string | null;
}
```

Update `EmployeeRateListItem` (lines 18-24) to:
```typescript
export interface EmployeeRateListItem {
  employee_id: string;
  full_name: string | null;
  employee_id_code: string | null;
  pay_type: 'hourly' | 'annual';
  current_rate: number | null;
  current_salary: number | null;
  effective_from: string | null;
}
```

Update `TimesheetWithPayRow` (lines 39-52) to add new fields at the end:
```typescript
export interface TimesheetWithPayRow {
  employee_id: string;
  full_name: string;
  employee_id_code: string;
  date: string;
  approved_minutes: number;
  hourly_rate: number | null;
  base_amount: number;
  weekend_cleaning_minutes: number;
  weekend_premium_rate: number;
  premium_amount: number;
  total_amount: number;
  has_rate: boolean;
  pay_type: 'hourly' | 'annual';
  annual_salary: number | null;
  period_amount: number | null;
  has_compensation: boolean;
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/types/remuneration.ts
git commit -m "feat(types): add annual salary types and update existing remuneration types"
```

---

### Task 4: Update API functions

**Files:**
- Modify: `dashboard/src/lib/api/remuneration.ts`

- [ ] **Step 1: Update `getEmployeeRatesList` to include pay_type and salary**

Replace the function (lines 11-43) with:

```typescript
export async function getEmployeeRatesList(): Promise<EmployeeRateListItem[]> {
  // Get all active employees with pay_type
  const { data, error } = await supabaseClient
    .from('employee_profiles')
    .select('id, full_name, employee_id, pay_type')
    .eq('status', 'active')
    .order('full_name');

  if (error) throw error;

  // Get all active hourly rates
  const { data: rates, error: ratesError } = await supabaseClient
    .from('employee_hourly_rates')
    .select('employee_id, rate, effective_from')
    .is('effective_to', null);

  if (ratesError) throw ratesError;

  // Get all active annual salaries
  const { data: salaries, error: salariesError } = await supabaseClient
    .from('employee_annual_salaries')
    .select('employee_id, salary, effective_from')
    .is('effective_to', null);

  if (salariesError) throw salariesError;

  const rateMap = new Map(
    (rates || []).map((r) => [r.employee_id, r])
  );
  const salaryMap = new Map(
    (salaries || []).map((s) => [s.employee_id, s])
  );

  return (data || []).map((emp) => {
    const rate = rateMap.get(emp.id);
    const salary = salaryMap.get(emp.id);
    const payType = (emp.pay_type as 'hourly' | 'annual') || 'hourly';
    return {
      employee_id: emp.id,
      full_name: emp.full_name,
      employee_id_code: emp.employee_id,
      pay_type: payType,
      current_rate: rate?.rate ?? null,
      current_salary: salary?.salary ?? null,
      effective_from: payType === 'annual'
        ? (salary?.effective_from ?? null)
        : (rate?.effective_from ?? null),
    };
  });
}
```

- [ ] **Step 2: Add salary history and upsert functions**

Add the following after `upsertEmployeeRate` (after line 107), and add the import for `EmployeeAnnualSalaryWithCreator`:

```typescript
// ── Employee Annual Salaries ──

export async function getEmployeeSalaryHistory(
  employeeId: string
): Promise<EmployeeAnnualSalaryWithCreator[]> {
  const { data, error } = await supabaseClient
    .from('employee_annual_salaries')
    .select(`
      *,
      creator:created_by(full_name)
    `)
    .eq('employee_id', employeeId)
    .order('effective_from', { ascending: false });

  if (error) throw error;

  return (data || []).map((row) => ({
    ...row,
    creator_name: (row.creator as any)?.full_name ?? null,
  }));
}

export async function upsertEmployeeSalary(
  employeeId: string,
  salary: number,
  effectiveFrom: string
): Promise<void> {
  const { data: { user } } = await supabaseClient.auth.getUser();

  // 1. Close current active salary (if any)
  const { data: activeSalary } = await supabaseClient
    .from('employee_annual_salaries')
    .select('id')
    .eq('employee_id', employeeId)
    .is('effective_to', null)
    .single();

  if (activeSalary) {
    const closingDate = new Date(effectiveFrom);
    closingDate.setDate(closingDate.getDate() - 1);
    const closingDateStr = closingDate.toISOString().split('T')[0];

    const { error: updateError } = await supabaseClient
      .from('employee_annual_salaries')
      .update({ effective_to: closingDateStr })
      .eq('id', activeSalary.id);

    if (updateError) throw updateError;
  }

  // 2. Insert new salary
  const { error: insertError } = await supabaseClient
    .from('employee_annual_salaries')
    .insert({
      employee_id: employeeId,
      salary,
      effective_from: effectiveFrom,
      effective_to: null,
      created_by: user?.id ?? null,
    });

  if (insertError) throw insertError;
}

// ── Pay Type ──

export async function updateEmployeePayType(
  employeeId: string,
  payType: 'hourly' | 'annual'
): Promise<void> {
  const { error } = await supabaseClient.rpc('update_employee_pay_type', {
    p_employee_id: employeeId,
    p_pay_type: payType,
  });

  if (error) throw error;
}
```

Update the imports at the top (line 2-7) to include the new types:
```typescript
import type {
  EmployeeHourlyRateWithCreator,
  EmployeeAnnualSalaryWithCreator,
  EmployeeRateListItem,
  WeekendCleaningPremium,
  TimesheetWithPayRow,
} from '@/types/remuneration';
```

- [ ] **Step 3: Commit**

```bash
git add dashboard/src/lib/api/remuneration.ts
git commit -m "feat(api): add annual salary API functions and update rates list"
```

---

### Task 5: Add validation schema for annual salary

**Files:**
- Modify: `dashboard/src/lib/validations/remuneration.ts`

- [ ] **Step 1: Add annual salary form schema**

Add after line 13 (after `HourlyRateFormValues`):

```typescript
export const annualSalaryFormSchema = z.object({
  salary: z
    .number({ message: 'Le salaire annuel est requis' })
    .positive('Le salaire doit être supérieur à 0')
    .multipleOf(0.01, 'Maximum 2 décimales'),
  effective_from: z
    .string({ message: 'La date est requise' })
    .regex(/^\d{4}-\d{2}-\d{2}$/, 'Format de date invalide (AAAA-MM-JJ)'),
});

export type AnnualSalaryFormValues = z.infer<typeof annualSalaryFormSchema>;
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/lib/validations/remuneration.ts
git commit -m "feat(validations): add annual salary form schema"
```

---

## Chunk 3: Dashboard UI Components

### Task 6: Create `SalaryDialog` component

**Files:**
- Create: `dashboard/src/components/remuneration/salary-dialog.tsx`

- [ ] **Step 1: Create the salary dialog**

Create `dashboard/src/components/remuneration/salary-dialog.tsx`:

```typescript
'use client';

import { useState, useEffect } from 'react';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { upsertEmployeeSalary } from '@/lib/api/remuneration';
import type { EmployeeRateListItem } from '@/types/remuneration';

interface SalaryDialogProps {
  employee: EmployeeRateListItem | null;
  onClose: () => void;
  onSaved: () => void;
}

export function SalaryDialog({ employee, onClose, onSaved }: SalaryDialogProps) {
  const [salary, setSalary] = useState('');
  const [effectiveFrom, setEffectiveFrom] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (employee) {
      setSalary(employee.current_salary?.toString() ?? '');
      setEffectiveFrom(new Date().toISOString().split('T')[0]);
      setError(null);
    }
  }, [employee]);

  const handleSave = async () => {
    setError(null);
    const parsedSalary = parseFloat(salary);
    if (isNaN(parsedSalary) || parsedSalary <= 0) {
      setError('Le salaire doit être supérieur à 0');
      return;
    }
    if (!effectiveFrom) {
      setError('La date est requise');
      return;
    }

    setSaving(true);
    try {
      await upsertEmployeeSalary(employee!.employee_id, parsedSalary, effectiveFrom);
      onSaved();
    } catch (e: any) {
      setError(e.message || 'Erreur lors de la sauvegarde');
    } finally {
      setSaving(false);
    }
  };

  const biweeklyAmount = salary ? (parseFloat(salary) / 26).toFixed(2) : null;

  return (
    <Dialog open={employee !== null} onOpenChange={() => onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>
            {employee?.current_salary !== null
              ? `Modifier le salaire — ${employee?.full_name}`
              : `Définir le salaire — ${employee?.full_name}`}
          </DialogTitle>
        </DialogHeader>
        <div className="space-y-4 py-4">
          {employee?.current_salary !== null && (
            <p className="text-sm text-muted-foreground">
              Salaire actuel : {employee?.current_salary?.toLocaleString('fr-CA')} $/an
              (depuis {employee?.effective_from})
            </p>
          )}
          <div className="space-y-2">
            <Label htmlFor="salary">Salaire annuel ($/an)</Label>
            <Input
              id="salary"
              type="number"
              step="0.01"
              min="0.01"
              value={salary}
              onChange={(e) => setSalary(e.target.value)}
              placeholder="ex: 52000.00"
            />
            {biweeklyAmount && (
              <p className="text-xs text-muted-foreground">
                Équivalent aux 2 semaines : {parseFloat(biweeklyAmount).toLocaleString('fr-CA')} $
              </p>
            )}
          </div>
          <div className="space-y-2">
            <Label htmlFor="effective-from">Date d&apos;entrée en vigueur</Label>
            <Input
              id="effective-from"
              type="date"
              value={effectiveFrom}
              onChange={(e) => setEffectiveFrom(e.target.value)}
            />
          </div>
          {error && (
            <p className="text-sm text-destructive">{error}</p>
          )}
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Annuler
          </Button>
          <Button onClick={handleSave} disabled={saving}>
            {saving ? 'Enregistrement...' : 'Enregistrer'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/components/remuneration/salary-dialog.tsx
git commit -m "feat(ui): add SalaryDialog component for annual salary input"
```

---

### Task 7: Create `SalaryHistory` component

**Files:**
- Create: `dashboard/src/components/remuneration/salary-history.tsx`

- [ ] **Step 1: Create the salary history component**

Create `dashboard/src/components/remuneration/salary-history.tsx`:

```typescript
'use client';

import { useState, useEffect } from 'react';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { getEmployeeSalaryHistory } from '@/lib/api/remuneration';
import type { EmployeeAnnualSalaryWithCreator } from '@/types/remuneration';

interface SalaryHistoryProps {
  employeeId: string;
}

export function SalaryHistory({ employeeId }: SalaryHistoryProps) {
  const [history, setHistory] = useState<EmployeeAnnualSalaryWithCreator[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    setLoading(true);
    getEmployeeSalaryHistory(employeeId)
      .then(setHistory)
      .finally(() => setLoading(false));
  }, [employeeId]);

  if (loading) {
    return <div className="text-sm text-muted-foreground">Chargement...</div>;
  }

  if (history.length === 0) {
    return (
      <div className="text-sm text-muted-foreground">
        Aucun historique de salaire pour cet employé.
      </div>
    );
  }

  return (
    <div>
      <h4 className="text-sm font-medium mb-2">Historique des salaires</h4>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Salaire ($/an)</TableHead>
            <TableHead>Aux 2 sem.</TableHead>
            <TableHead>Du</TableHead>
            <TableHead>Au</TableHead>
            <TableHead>Créé par</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {history.map((entry) => (
            <TableRow key={entry.id}>
              <TableCell className="font-mono">
                {entry.salary.toLocaleString('fr-CA')} $
              </TableCell>
              <TableCell className="font-mono text-muted-foreground">
                {(entry.salary / 26).toFixed(2)} $
              </TableCell>
              <TableCell>{entry.effective_from}</TableCell>
              <TableCell>
                {entry.effective_to ?? (
                  <span className="text-green-600 font-medium">En cours</span>
                )}
              </TableCell>
              <TableCell className="text-muted-foreground">
                {entry.creator_name ?? '—'}
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/components/remuneration/salary-history.tsx
git commit -m "feat(ui): add SalaryHistory component for annual salary history"
```

---

### Task 8: Create `PayTypeSwitch` component

**Files:**
- Create: `dashboard/src/components/remuneration/pay-type-switch.tsx`

- [ ] **Step 1: Create the pay type switch dialog**

Create `dashboard/src/components/remuneration/pay-type-switch.tsx`:

```typescript
'use client';

import { useState } from 'react';
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from '@/components/ui/alert-dialog';
import { updateEmployeePayType } from '@/lib/api/remuneration';
import type { EmployeeRateListItem } from '@/types/remuneration';

interface PayTypeSwitchProps {
  employee: EmployeeRateListItem | null;
  onClose: () => void;
  onSaved: () => void;
}

export function PayTypeSwitch({ employee, onClose, onSaved }: PayTypeSwitchProps) {
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (!employee) return null;

  const targetType = employee.pay_type === 'hourly' ? 'annual' : 'hourly';
  const targetLabel = targetType === 'annual' ? 'Annuel' : 'Horaire';

  const handleConfirm = async () => {
    setSaving(true);
    setError(null);
    try {
      await updateEmployeePayType(employee.employee_id, targetType);
      onSaved();
    } catch (e: any) {
      const msg = e.message || 'Erreur lors du changement';
      // Parse the RPC error for a friendlier message
      if (msg.includes('no active')) {
        setError(
          targetType === 'annual'
            ? 'Vous devez d\'abord définir un salaire annuel pour cet employé.'
            : 'Vous devez d\'abord définir un taux horaire pour cet employé.'
        );
      } else {
        setError(msg);
      }
      setSaving(false);
    }
  };

  return (
    <AlertDialog open={employee !== null} onOpenChange={() => onClose()}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>
            Changer le type de rémunération
          </AlertDialogTitle>
          <AlertDialogDescription>
            Changer {employee.full_name} de{' '}
            <strong>{employee.pay_type === 'hourly' ? 'Horaire' : 'Annuel'}</strong> à{' '}
            <strong>{targetLabel}</strong> ?
            {targetType === 'annual'
              ? ' Le salaire annuel sera divisé par 26 périodes.'
              : ' Les heures approuvées seront multipliées par le taux horaire.'}
          </AlertDialogDescription>
        </AlertDialogHeader>
        {error && (
          <p className="text-sm text-destructive px-6">{error}</p>
        )}
        <AlertDialogFooter>
          <AlertDialogCancel disabled={saving}>Annuler</AlertDialogCancel>
          <AlertDialogAction onClick={handleConfirm} disabled={saving}>
            {saving ? 'Changement...' : `Passer à ${targetLabel}`}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/components/remuneration/pay-type-switch.tsx
git commit -m "feat(ui): add PayTypeSwitch confirmation dialog"
```

---

## Chunk 4: Update Existing Components

### Task 9: Update `RatesTable` to show pay type and route to correct dialog/history

**Files:**
- Modify: `dashboard/src/components/remuneration/rates-table.tsx`

- [ ] **Step 1: Update imports and props**

Update imports (lines 1-30) — add Badge, new components, new filter type:

```typescript
'use client';

import { useState, useMemo, Fragment } from 'react';
import {
  useReactTable,
  getCoreRowModel,
  flexRender,
  type ColumnDef,
} from '@tanstack/react-table';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { Badge } from '@/components/ui/badge';
import { ChevronDown, ChevronRight, Pencil, ArrowLeftRight } from 'lucide-react';
import { RateDialog } from './rate-dialog';
import { SalaryDialog } from './salary-dialog';
import { RateHistory } from './rate-history';
import { SalaryHistory } from './salary-history';
import { PayTypeSwitch } from './pay-type-switch';
import type { EmployeeRateListItem } from '@/types/remuneration';
```

Update `RatesTableProps` interface and filter type:

```typescript
type CompensationFilter = 'all' | 'with_compensation' | 'without_compensation' | 'hourly' | 'annual';

interface RatesTableProps {
  employees: EmployeeRateListItem[];
  loading: boolean;
  search: string;
  onSearchChange: (v: string) => void;
  filter: CompensationFilter;
  onFilterChange: (v: CompensationFilter) => void;
  onUpdate: () => void;
}
```

- [ ] **Step 2: Update columns and component body**

Replace the full component function with:

```typescript
export function RatesTable({
  employees,
  loading,
  search,
  onSearchChange,
  filter,
  onFilterChange,
  onUpdate,
}: RatesTableProps) {
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [editingEmployee, setEditingEmployee] = useState<EmployeeRateListItem | null>(null);
  const [switchingEmployee, setSwitchingEmployee] = useState<EmployeeRateListItem | null>(null);

  const columns = useMemo<ColumnDef<EmployeeRateListItem>[]>(
    () => [
      {
        id: 'expand',
        header: '',
        cell: ({ row }) => (
          <Button
            variant="ghost"
            size="sm"
            onClick={() =>
              setExpandedId(
                expandedId === row.original.employee_id
                  ? null
                  : row.original.employee_id
              )
            }
          >
            {expandedId === row.original.employee_id ? (
              <ChevronDown className="h-4 w-4" />
            ) : (
              <ChevronRight className="h-4 w-4" />
            )}
          </Button>
        ),
        size: 40,
      },
      {
        accessorKey: 'full_name',
        header: 'Nom',
        cell: ({ row }) => (
          <span className="font-medium">
            {row.original.full_name || '—'}
          </span>
        ),
      },
      {
        accessorKey: 'employee_id_code',
        header: 'ID employé',
        cell: ({ row }) => (
          <span className="text-muted-foreground">
            {row.original.employee_id_code || '—'}
          </span>
        ),
      },
      {
        id: 'pay_type',
        header: 'Type',
        cell: ({ row }) => (
          <Badge variant={row.original.pay_type === 'annual' ? 'secondary' : 'default'}>
            {row.original.pay_type === 'annual' ? 'Annuel' : 'Horaire'}
          </Badge>
        ),
      },
      {
        id: 'compensation',
        header: 'Compensation',
        cell: ({ row }) => {
          const emp = row.original;
          if (emp.pay_type === 'annual') {
            return emp.current_salary !== null ? (
              <span className="font-mono">
                {emp.current_salary.toLocaleString('fr-CA')} $/an
              </span>
            ) : (
              <span className="text-muted-foreground italic">Non défini</span>
            );
          }
          return emp.current_rate !== null ? (
            <span className="font-mono">
              {emp.current_rate.toFixed(2)} $/h
            </span>
          ) : (
            <span className="text-muted-foreground italic">Non défini</span>
          );
        },
      },
      {
        accessorKey: 'effective_from',
        header: 'En vigueur depuis',
        cell: ({ row }) =>
          row.original.effective_from ? (
            <span>{row.original.effective_from}</span>
          ) : (
            <span className="text-muted-foreground">—</span>
          ),
      },
      {
        id: 'actions',
        header: '',
        cell: ({ row }) => (
          <div className="flex gap-1">
            <Button
              variant="ghost"
              size="sm"
              onClick={() => setEditingEmployee(row.original)}
            >
              <Pencil className="h-4 w-4 mr-1" />
              Modifier
            </Button>
            <Button
              variant="ghost"
              size="sm"
              onClick={() => setSwitchingEmployee(row.original)}
              title="Changer le type de rémunération"
            >
              <ArrowLeftRight className="h-4 w-4" />
            </Button>
          </div>
        ),
      },
    ],
    [expandedId]
  );

  const table = useReactTable({
    data: employees,
    columns,
    getCoreRowModel: getCoreRowModel(),
    getRowId: (row) => row.employee_id,
  });

  return (
    <div className="space-y-4">
      {/* Filters */}
      <div className="flex gap-4">
        <Input
          placeholder="Rechercher par nom..."
          value={search}
          onChange={(e) => onSearchChange(e.target.value)}
          className="max-w-sm"
        />
        <Select value={filter} onValueChange={(v) => onFilterChange(v as CompensationFilter)}>
          <SelectTrigger className="w-[220px]">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Tous les employés</SelectItem>
            <SelectItem value="with_compensation">Avec compensation</SelectItem>
            <SelectItem value="without_compensation">Sans compensation</SelectItem>
            <SelectItem value="hourly">Horaire seulement</SelectItem>
            <SelectItem value="annual">Annuel seulement</SelectItem>
          </SelectContent>
        </Select>
      </div>

      {/* Table */}
      <div className="rounded-md border">
        <Table>
          <TableHeader>
            {table.getHeaderGroups().map((headerGroup) => (
              <TableRow key={headerGroup.id}>
                {headerGroup.headers.map((header) => (
                  <TableHead key={header.id}>
                    {flexRender(header.column.columnDef.header, header.getContext())}
                  </TableHead>
                ))}
              </TableRow>
            ))}
          </TableHeader>
          <TableBody>
            {loading ? (
              Array.from({ length: 5 }).map((_, i) => (
                <TableRow key={i}>
                  {columns.map((_, j) => (
                    <TableCell key={j}>
                      <div className="h-4 bg-muted rounded animate-pulse" />
                    </TableCell>
                  ))}
                </TableRow>
              ))
            ) : table.getRowModel().rows.length === 0 ? (
              <TableRow>
                <TableCell colSpan={columns.length} className="text-center py-8 text-muted-foreground">
                  Aucun employé trouvé
                </TableCell>
              </TableRow>
            ) : (
              table.getRowModel().rows.map((row) => (
                <Fragment key={row.id}>
                  <TableRow>
                    {row.getVisibleCells().map((cell) => (
                      <TableCell key={cell.id}>
                        {flexRender(cell.column.columnDef.cell, cell.getContext())}
                      </TableCell>
                    ))}
                  </TableRow>
                  {expandedId === row.original.employee_id && (
                    <TableRow>
                      <TableCell colSpan={columns.length} className="bg-muted/50 p-4">
                        {row.original.pay_type === 'annual' ? (
                          <SalaryHistory employeeId={row.original.employee_id} />
                        ) : (
                          <RateHistory employeeId={row.original.employee_id} />
                        )}
                      </TableCell>
                    </TableRow>
                  )}
                </Fragment>
              ))
            )}
          </TableBody>
        </Table>
      </div>

      {/* Edit Dialogs — route to correct dialog based on pay_type */}
      {editingEmployee?.pay_type === 'annual' ? (
        <SalaryDialog
          employee={editingEmployee}
          onClose={() => setEditingEmployee(null)}
          onSaved={() => {
            setEditingEmployee(null);
            onUpdate();
          }}
        />
      ) : (
        <RateDialog
          employee={editingEmployee}
          onClose={() => setEditingEmployee(null)}
          onSaved={() => {
            setEditingEmployee(null);
            onUpdate();
          }}
        />
      )}

      {/* Pay Type Switch Dialog */}
      <PayTypeSwitch
        employee={switchingEmployee}
        onClose={() => setSwitchingEmployee(null)}
        onSaved={() => {
          setSwitchingEmployee(null);
          onUpdate();
        }}
      />
    </div>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/components/remuneration/rates-table.tsx
git commit -m "feat(ui): update RatesTable for pay type column, filter, and dual dialogs"
```

---

### Task 10: Update remuneration page for new filter type

**Files:**
- Modify: `dashboard/src/app/dashboard/remuneration/page.tsx`

- [ ] **Step 1: Update filter state and logic**

Replace the page component. Key changes:
- Filter type becomes `CompensationFilter`
- Filter logic updated for new filter values
- Card title updated

Replace lines 16 and 38-47:

Change line 16 from:
```typescript
  const [filter, setFilter] = useState<'all' | 'with_rate' | 'without_rate'>('all');
```
to:
```typescript
  const [filter, setFilter] = useState<'all' | 'with_compensation' | 'without_compensation' | 'hourly' | 'annual'>('all');
```

Replace the filter logic (lines 38-47) with:
```typescript
  const filtered = employees.filter((emp) => {
    const matchesSearch = !search
      || (emp.full_name?.toLowerCase().includes(search.toLowerCase()))
      || (emp.employee_id_code?.toLowerCase().includes(search.toLowerCase()));
    const hasCompensation = emp.pay_type === 'annual'
      ? emp.current_salary !== null
      : emp.current_rate !== null;
    const matchesFilter =
      filter === 'all' ? true
      : filter === 'with_compensation' ? hasCompensation
      : filter === 'without_compensation' ? !hasCompensation
      : filter === 'hourly' ? emp.pay_type === 'hourly'
      : emp.pay_type === 'annual';
    return matchesSearch && matchesFilter;
  });
```

Update the page title (line 53-54) to:
```typescript
        <p className="text-muted-foreground">
          Gérer la rémunération des employés (taux horaires et salaires annuels).
        </p>
```

Update the Card title (line 68) to:
```typescript
          <CardTitle>Compensation des employés</CardTitle>
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/app/dashboard/remuneration/page.tsx
git commit -m "feat(ui): update remuneration page for annual salary filter support"
```

---

### Task 11: Update CSV export for annual employees

**Files:**
- Modify: `dashboard/src/lib/utils/report-export.ts`

- [ ] **Step 1: Update `exportTimesheetToCsv` header and row logic**

In the `exportTimesheetToCsv` function, update the pay column headers and row data to handle annual employees.

Replace lines 120-127 (the pay header fields block) with:
```typescript
  if (hasPay) {
    headerFields.push(
      'Type de paye',
      'Taux horaire ($/h)',
      'Salaire annuel ($/an)',
      'Montant période ($)',
      'Montant de base ($)',
      'Heures ménage weekend',
      'Prime weekend ($)',
      'Montant total ($)',
    );
  }
```

Replace lines 147-159 (the pay data fields block) with:
```typescript
    if (hasPay) {
      const pay = payMap.get(`${row.employee_id}_${row.shift_date}`);
      if (pay) {
        fields.push(
          pay.pay_type ?? 'hourly',
          pay.hourly_rate?.toFixed(2) ?? '',
          pay.annual_salary?.toFixed(2) ?? '',
          pay.period_amount?.toFixed(2) ?? '',
          pay.base_amount.toFixed(2),
          (pay.weekend_cleaning_minutes / 60).toFixed(2),
          pay.premium_amount.toFixed(2),
          pay.total_amount.toFixed(2),
        );
      } else {
        fields.push('', '', '', '', '', '', '', '');
      }
    }
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/lib/utils/report-export.ts
git commit -m "feat(export): update CSV export columns for annual salary support"
```

---

## Chunk 5: Build Verification and Final Test

### Task 12: Build and verify

- [ ] **Step 1: Install dependencies and build**

```bash
cd dashboard
npm install
npm run build
```

Expected: Build succeeds with no TypeScript errors.

- [ ] **Step 2: Fix any build errors**

If build fails, fix TypeScript errors and rebuild. Common issues:
- Missing imports
- Type mismatches between old and new `EmployeeRateListItem` usage
- Filter type mismatch in page.tsx

- [ ] **Step 3: Test the database changes**

Via MCP `execute_sql`, verify:

```sql
-- 1. Verify pay_type column exists with default
SELECT pay_type FROM employee_profiles LIMIT 3;

-- 2. Verify employee_annual_salaries table exists
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'employee_annual_salaries' ORDER BY ordinal_position;

-- 3. Verify update_employee_pay_type RPC exists
SELECT routine_name FROM information_schema.routines
WHERE routine_name = 'update_employee_pay_type';

-- 4. Verify get_timesheet_with_pay returns new columns
SELECT pay_type, annual_salary, period_amount, has_compensation
FROM get_timesheet_with_pay('2026-03-01', '2026-03-13') LIMIT 3;
```

- [ ] **Step 4: Final commit if any fixes were needed**

```bash
git add -A
git commit -m "fix: resolve build errors from annual salary integration"
```
