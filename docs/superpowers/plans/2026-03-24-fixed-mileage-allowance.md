# Fixed Mileage Allowance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Support fixed per-period mileage reimbursement (forfait) for specific employees, alongside the existing per-km CRA-tiered reimbursement.

**Architecture:** New `employee_mileage_allowances` table (same pattern as `employee_vehicle_periods`). RPCs check for active allowance at `period_start` — if found, use forfait amount instead of km × rate calculation. `mileage_approvals` gets `is_forfait` + `forfait_amount` columns for audit trail. Dashboard shows "Forfait" badge and adds an allowance management tab.

**Tech Stack:** PostgreSQL (Supabase migration), TypeScript/Next.js (dashboard), shadcn/ui components

**Spec:** `docs/superpowers/specs/2026-03-24-fixed-mileage-allowance-design.md`

---

### Task 1: Database Migration — Table, Helper, ALTER, RPCs

All database changes go in a single migration file because the RPCs depend on the new table and ALTER.

**Files:**
- Create: `supabase/migrations/20260326400000_mileage_allowance_forfait.sql`

**Reference files to study before implementing:**
- `supabase/migrations/065_employee_vehicle_periods.sql` — pattern for table, overlap trigger, RLS, helper function
- `supabase/migrations/20260326100001_mileage_approval_rpcs.sql` — current RPCs to modify (lines 209-496)
- `supabase/migrations/20260326100002_payroll_report_mileage.sql` — payroll mileage CTE (lines 249-279)
- `supabase/migrations/20260326100000_mileage_approval.sql` — mileage_approvals table (lines 16-32)

- [ ] **Step 1: Create migration file with `employee_mileage_allowances` table**

```sql
-- Migration: Fixed mileage allowance (forfait kilométrage)
-- Some employees have a negotiated fixed amount per pay period instead of per-km reimbursement.

-- ============================================================
-- 1. employee_mileage_allowances table
-- ============================================================

CREATE TABLE employee_mileage_allowances (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
    amount_per_period DECIMAL(10,2) NOT NULL CHECK (amount_per_period > 0),
    started_at DATE NOT NULL,
    ended_at DATE,  -- NULL = ongoing
    notes TEXT,
    created_by UUID REFERENCES employee_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_mileage_allowances_employee ON employee_mileage_allowances(employee_id);
CREATE INDEX idx_mileage_allowances_dates ON employee_mileage_allowances(started_at, ended_at);

-- Prevent overlapping periods for the same employee (no sub-type unlike vehicle_periods)
CREATE OR REPLACE FUNCTION check_mileage_allowance_overlap()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM employee_mileage_allowances
        WHERE employee_id = NEW.employee_id
          AND id != COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::UUID)
          AND started_at <= COALESCE(NEW.ended_at, '9999-12-31'::DATE)
          AND COALESCE(ended_at, '9999-12-31'::DATE) >= NEW.started_at
    ) THEN
        RAISE EXCEPTION 'Overlapping mileage allowance exists for this employee';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_mileage_allowance_overlap
    BEFORE INSERT OR UPDATE ON employee_mileage_allowances
    FOR EACH ROW EXECUTE FUNCTION check_mileage_allowance_overlap();

-- Updated_at trigger
CREATE TRIGGER trg_mileage_allowances_updated_at
    BEFORE UPDATE ON employee_mileage_allowances
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- RLS
ALTER TABLE employee_mileage_allowances ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins manage mileage allowances"
    ON employee_mileage_allowances FOR ALL
    USING (is_admin_or_super_admin(auth.uid()));

CREATE POLICY "Employees view own mileage allowances"
    ON employee_mileage_allowances FOR SELECT
    USING (employee_id = auth.uid());

-- Helper function
CREATE OR REPLACE FUNCTION get_active_mileage_allowance(
    p_employee_id UUID,
    p_date DATE
)
RETURNS DECIMAL
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
    SELECT amount_per_period FROM employee_mileage_allowances
    WHERE employee_id = p_employee_id
      AND started_at <= p_date
      AND (ended_at IS NULL OR ended_at >= p_date)
    ORDER BY started_at DESC
    LIMIT 1;
$$;

COMMENT ON TABLE employee_mileage_allowances IS
'ROLE: Stores fixed mileage reimbursement amounts (forfait) per employee per pay period.
STATUTS: active (ended_at IS NULL or ended_at >= today), expired (ended_at < today).
REGLES: amount_per_period > 0. No overlapping periods per employee. If active at period_start, forfait replaces per-km calculation.
RELATIONS: employee_profiles (employee_id). Checked by approve_mileage, get_mileage_approval_detail, get_mileage_approval_summary, get_payroll_period_report.
TRIGGERS: overlap prevention, updated_at auto-update.';

COMMENT ON COLUMN employee_mileage_allowances.amount_per_period IS 'Fixed reimbursement amount in $ per pay period (replaces per-km calculation)';
COMMENT ON COLUMN employee_mileage_allowances.started_at IS 'Date from which this allowance is active';
COMMENT ON COLUMN employee_mileage_allowances.ended_at IS 'Date until which this allowance is active (NULL = ongoing/indefinite)';

COMMENT ON FUNCTION get_active_mileage_allowance IS 'Returns the forfait amount if employee has active mileage allowance on given date, NULL otherwise';
```

- [ ] **Step 2: Add `is_forfait` and `forfait_amount` columns to `mileage_approvals`**

Append to the same migration file:

```sql
-- ============================================================
-- 2. ALTER mileage_approvals for audit trail
-- ============================================================

ALTER TABLE mileage_approvals
    ADD COLUMN is_forfait BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN forfait_amount DECIMAL(10,2);

COMMENT ON COLUMN mileage_approvals.is_forfait IS 'True if this approval used a fixed forfait amount instead of per-km calculation';
COMMENT ON COLUMN mileage_approvals.forfait_amount IS 'The forfait amount frozen at approval time (NULL if per-km)';
```

- [ ] **Step 3: Update `get_mileage_approval_detail` with forfait logic**

This RPC must be updated FIRST because `approve_mileage` delegates to it. Append `CREATE OR REPLACE FUNCTION get_mileage_approval_detail(...)` to the migration. Key changes:

1. After the tiered rate calculation block (current lines 387-399), add a forfait override:

```sql
  -- Check for fixed mileage allowance (forfait)
  v_forfait_amount := get_active_mileage_allowance(p_employee_id, p_period_start);

  IF v_forfait_amount IS NOT NULL THEN
    v_estimated_amount := v_forfait_amount;
  END IF;
```

2. Add `is_forfait` and `forfait_amount` to the v_summary jsonb_build_object:

```sql
  v_summary := jsonb_build_object(
    'reimbursable_km', ROUND(v_reimbursable_km, 2),
    'company_km', ROUND(v_company_km, 2),
    'passenger_km', ROUND(v_passenger_km, 2),
    'needs_review_count', v_needs_review,
    'estimated_amount', ROUND(v_estimated_amount, 2),
    'ytd_km', ROUND(v_ytd_km, 2),
    'rate_per_km', v_rate_per_km,
    'rate_after_threshold', v_rate_after,
    'threshold_km', v_threshold_km,
    'is_forfait', v_forfait_amount IS NOT NULL,
    'forfait_amount', v_forfait_amount
  );
```

3. Declare `v_forfait_amount DECIMAL;` in the DECLARE block.

The full function must be copied and modified (CREATE OR REPLACE). Copy the entire function from `20260326100001_mileage_approval_rpcs.sql` lines 286-426, then apply the changes above.

- [ ] **Step 4: Update `approve_mileage` to freeze forfait fields**

Append `CREATE OR REPLACE FUNCTION approve_mileage(...)` to the migration. Changes to the INSERT/ON CONFLICT:

```sql
  -- Extract forfait info from detail
  v_is_forfait := COALESCE((v_detail->'summary'->>'is_forfait')::BOOLEAN, false);

  INSERT INTO mileage_approvals (
    employee_id, period_start, period_end, status,
    reimbursable_km, reimbursement_amount,
    is_forfait, forfait_amount,
    approved_by, approved_at, notes
  )
  VALUES (
    p_employee_id, p_period_start, p_period_end, 'approved',
    (v_detail->'summary'->>'reimbursable_km')::DECIMAL,
    (v_detail->'summary'->>'estimated_amount')::DECIMAL,
    v_is_forfait,
    CASE WHEN v_is_forfait THEN (v_detail->'summary'->>'forfait_amount')::DECIMAL END,
    v_caller, now(), p_notes
  )
  ON CONFLICT (employee_id, period_start, period_end)
  DO UPDATE SET
    status = 'approved',
    reimbursable_km = EXCLUDED.reimbursable_km,
    reimbursement_amount = EXCLUDED.reimbursement_amount,
    is_forfait = EXCLUDED.is_forfait,
    forfait_amount = EXCLUDED.forfait_amount,
    approved_by = EXCLUDED.approved_by,
    approved_at = EXCLUDED.approved_at,
    notes = EXCLUDED.notes,
    updated_at = now()
  RETURNING * INTO v_result;
```

Add `v_is_forfait BOOLEAN;` to the DECLARE block. Copy the full function from lines 428-496 and apply changes.

- [ ] **Step 5: Update `get_mileage_approval_summary` with per-employee forfait check**

Append `CREATE OR REPLACE FUNCTION get_mileage_approval_summary(...)`. Key change: the `estimated_amount` and `is_forfait` fields must be per-employee. Replace the current estimated_amount calculation (line 265-268) with:

```sql
      -- For approved rows: use frozen is_forfait from mileage_approvals
      -- For non-approved: check active allowance
      CASE
        WHEN ma.status = 'approved' THEN COALESCE(ma.is_forfait, false)
        WHEN get_active_mileage_allowance(ep.id, p_period_start) IS NOT NULL THEN true
        ELSE false
      END AS is_forfait,
      CASE
        WHEN ma.status = 'approved' THEN ma.reimbursement_amount
        WHEN get_active_mileage_allowance(ep.id, p_period_start) IS NOT NULL
          THEN get_active_mileage_allowance(ep.id, p_period_start)
        ELSE ROUND(COALESCE(SUM(
          CASE WHEN td.vehicle_type = 'personal' AND td.role = 'driver'
          THEN td.distance ELSE 0 END
        ), 0) * COALESCE(v_rate_per_km, 0), 2)
      END AS estimated_amount,
```

Note: `get_active_mileage_allowance` is called up to 2x per non-approved employee — acceptable since it's a simple indexed lookup. Add `is_forfait` to the GROUP BY if needed (use a subquery or lateral join to avoid multiple function calls if performance matters — but for now, keep it simple).

Copy the full function from lines 209-284, apply changes, and add `is_forfait` to the output JSON fields.

- [ ] **Step 6: Update `get_payroll_period_report` mileage CTE**

Append `CREATE OR REPLACE FUNCTION get_payroll_period_report(...)`. Change the `mileage_data` CTE (current lines 249-279). For the unapproved case, check for forfait:

```sql
  mileage_data AS (
    SELECT
      te.id AS employee_id,
      CASE
        WHEN ma.status = 'approved' THEN ma.reimbursable_km
        ELSE ROUND(COALESCE(SUM(
          CASE WHEN t.vehicle_type = 'personal' AND t.role = 'driver'
          THEN COALESCE(t.road_distance_km, t.distance_km) ELSE 0 END
        ), 0), 2)
      END AS reimbursable_km,
      CASE
        WHEN ma.status = 'approved' THEN ma.reimbursement_amount
        WHEN get_active_mileage_allowance(te.id, p_period_start) IS NOT NULL
          THEN get_active_mileage_allowance(te.id, p_period_start)
        ELSE ROUND(COALESCE(SUM(
          CASE WHEN t.vehicle_type = 'personal' AND t.role = 'driver'
          THEN COALESCE(t.road_distance_km, t.distance_km) ELSE 0 END
        ), 0) * COALESCE(v_cra_rate, 0), 2)
      END AS reimbursement_amount
    FROM target_employees te
    LEFT JOIN mileage_approvals ma
      ON ma.employee_id = te.id
      AND ma.period_start = p_period_start
      AND ma.period_end = p_period_end
    LEFT JOIN trips t
      ON t.employee_id = te.id
      AND to_business_date(t.started_at) BETWEEN p_period_start AND p_period_end
      AND t.transport_mode = 'driving'
      AND (ma.status IS NULL OR ma.status != 'approved')
    GROUP BY te.id, ma.status, ma.reimbursable_km, ma.reimbursement_amount
  ),
```

Copy the ENTIRE `get_payroll_period_report` function from `20260326100002_payroll_report_mileage.sql` and modify just this CTE. The RETURNS TABLE signature does not change — `reimbursable_km` and `reimbursement_amount` are already in the return type.

**Note:** `reopen_mileage_approval` (lines 498-534) does NOT need changes. When a period is reopened and then re-approved, the `ON CONFLICT DO UPDATE` in `approve_mileage` overwrites `is_forfait` and `forfait_amount` with fresh values.

- [ ] **Step 7: Verify migration file is complete and syntactically correct**

Run: `cd supabase && grep -c 'CREATE OR REPLACE FUNCTION' migrations/20260326400000_mileage_allowance_forfait.sql`
Expected: 6 (check_mileage_allowance_overlap, get_active_mileage_allowance, get_mileage_approval_detail, approve_mileage, get_mileage_approval_summary, get_payroll_period_report).

- [ ] **Step 8: Apply migration via Supabase MCP**

Use `mcp__supabase__apply_migration` to apply the migration.

- [ ] **Step 9: Verify with a quick SQL test**

```sql
-- Test helper function returns NULL for non-existent allowance
SELECT get_active_mileage_allowance('00000000-0000-0000-0000-000000000001', '2026-03-24') IS NULL;
```

- [ ] **Step 10: Commit**

```bash
git add supabase/migrations/20260326400000_mileage_allowance_forfait.sql
git commit -m "feat: add employee_mileage_allowances table and forfait logic in RPCs"
```

---

### Task 2: TypeScript Types Update

**Files:**
- Modify: `dashboard/src/types/mileage.ts` (lines 347-425)

- [ ] **Step 1: Add `is_forfait` to `MileageApprovalSummaryRow`**

At `dashboard/src/types/mileage.ts:359`, add before the closing brace:

```typescript
  is_forfait: boolean;
```

- [ ] **Step 2: Add forfait fields to `MileageApprovalDetailSummary`**

At `dashboard/src/types/mileage.ts:404`, add before the closing brace:

```typescript
  is_forfait: boolean;
  forfait_amount: number | null;
```

- [ ] **Step 3: Add forfait fields to `MileageApproval`**

At `dashboard/src/types/mileage.ts:419`, add before the closing brace:

```typescript
  is_forfait: boolean;
  forfait_amount: number | null;
```

- [ ] **Step 4: Add `EmployeeMileageAllowance` interface**

After the `MileageApprovalDetail` interface (line 425), add:

```typescript
export interface EmployeeMileageAllowance {
  id: string;
  employee_id: string;
  amount_per_period: number;
  started_at: string;
  ended_at: string | null;
  notes: string | null;
  created_by: string | null;
  created_at: string;
  updated_at: string;
}
```

- [ ] **Step 5: Commit**

```bash
git add dashboard/src/types/mileage.ts
git commit -m "feat: add forfait fields to mileage TypeScript types"
```

---

### Task 3: Dashboard — "Forfait" Badge in Mileage Approval Grid

**Files:**
- Modify: `dashboard/src/components/mileage-approval/mileage-employee-list.tsx` — add badge next to amount
- Modify: `dashboard/src/components/mileage-approval/mileage-approval-summary.tsx` — show forfait info in footer

- [ ] **Step 1: Add "Forfait" badge in employee list**

In `mileage-employee-list.tsx`, at approximately line 73 (after the amount ternary, before the carpool count check at line 74), add the forfait badge:

```tsx
                  : ''}
                {emp.is_forfait && (
                  <Badge variant="secondary" className="text-xs ml-1">Forfait</Badge>
                )}
                {emp.carpool_group_count > 0 && (
```

Read the full file first to confirm exact location.

- [ ] **Step 2: Update summary footer for forfait employees**

In `mileage-approval-summary.tsx`, at lines 38-43 (the third `<div>` with YTD/rate info), replace with a conditional:

```tsx
          {summary.is_forfait ? (
            <div className="text-muted-foreground text-xs">
              Forfait: {summary.forfait_amount?.toFixed(2)}$ / paye
            </div>
          ) : (
            <div className="text-muted-foreground text-xs">
              YTD: {summary.ytd_km.toFixed(0)} km · Taux: {summary.rate_per_km}$/km
              {summary.rate_after_threshold && (
                <> (après {summary.threshold_km} km: {summary.rate_after_threshold}$/km)</>
              )}
            </div>
          )}
```

The main amount display (lines 46-54) stays unchanged — it already shows `estimated_amount` or `approved_amount`.

- [ ] **Step 3: Verify the dashboard builds**

Run: `cd dashboard && npx next build`
Expected: Build succeeds with no type errors.

- [ ] **Step 4: Commit**

```bash
git add dashboard/src/components/mileage-approval/mileage-employee-list.tsx dashboard/src/components/mileage-approval/mileage-approval-summary.tsx
git commit -m "feat: show Forfait badge in mileage approval UI"
```

---

### Task 4: Dashboard — Mileage Allowance Management Tab

**Files:**
- Create: `dashboard/src/components/mileage/mileage-allowances-tab.tsx`
- Modify: `dashboard/src/app/dashboard/activity/page.tsx` — add tab for the new component

**Reference file:** `dashboard/src/components/mileage/vehicle-periods-tab.tsx` — follow this exact pattern for the new tab.

**Note:** Tasks 3 and 4 are independent and can be parallelized.

- [ ] **Step 1: Read the parent page**

Read `dashboard/src/app/dashboard/activity/page.tsx` to understand the tab structure and where to add the new tab.

- [ ] **Step 2: Create `mileage-allowances-tab.tsx`**

Follow the exact pattern of `vehicle-periods-tab.tsx`:
- State: allowances list, employees list, loading, dialogs
- Fetch: query `employee_mileage_allowances` table (with two-query pattern for employee profiles)
- Display: table with columns: Employee, Amount/paye, Start Date, End Date, Notes, Actions
- Add dialog: employee selector, amount input, start date input, notes
- End dialog: set `ended_at` on an allowance
- No delete (keep audit trail — just end the allowance)

Key differences from vehicle-periods-tab:
- No `vehicle_type` filter (there's no sub-type)
- Amount column instead of vehicle type
- Status filter: active (ended_at IS NULL or >= today) / expired (ended_at < today)

The component should be ~250-350 lines, similar in structure to vehicle-periods-tab.

```typescript
'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
// ... same imports as vehicle-periods-tab ...
import type { EmployeeMileageAllowance } from '@/types/mileage';

// Follow exact same patterns: fetch, filter, add/edit dialogs, table display
```

- [ ] **Step 3: Add tab to parent page**

Add a new tab alongside the vehicle periods tab. Label: "Forfaits kilométrage" or "Allocations fixes".

- [ ] **Step 4: Verify build**

Run: `cd dashboard && npx next build`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add dashboard/src/components/mileage/mileage-allowances-tab.tsx
git add <parent-page-file>
git commit -m "feat: add mileage allowance management tab in dashboard"
```

---

### Task 5: Seed Irène's Allowance

**Files:**
- Uses SQL via Supabase MCP (no migration file — this is data, not schema)

- [ ] **Step 1: Find Irène's employee_id**

```sql
SELECT id, full_name, email FROM employee_profiles WHERE full_name ILIKE '%irene%' OR full_name ILIKE '%irène%';
```

- [ ] **Step 2: Insert her allowance**

```sql
INSERT INTO employee_mileage_allowances (employee_id, amount_per_period, started_at, notes)
VALUES ('<irene_id>', 100.00, '2026-01-01', 'Entente forfaitaire 100$/paye pour kilométrage');
```

Confirm start date with user if unclear. Using 2026-01-01 as default.

- [ ] **Step 3: Verify**

```sql
SELECT ema.*, ep.full_name
FROM employee_mileage_allowances ema
JOIN employee_profiles ep ON ep.id = ema.employee_id;
```

---

### Task 6: End-to-End Verification

- [ ] **Step 1: Verify forfait in mileage approval summary**

```sql
-- Pick a period where Irène has trips
SELECT get_mileage_approval_summary('2026-03-10', '2026-03-23');
-- Check that Irène's row has is_forfait=true and estimated_amount=100.00
```

- [ ] **Step 2: Verify forfait in mileage approval detail**

```sql
SELECT get_mileage_approval_detail('<irene_id>', '2026-03-10', '2026-03-23');
-- Check summary.is_forfait=true, summary.forfait_amount=100, summary.estimated_amount=100
-- Check that reimbursable_km is still calculated (informational)
```

- [ ] **Step 3: Verify payroll report uses forfait**

```sql
SELECT * FROM get_payroll_period_report('2026-03-10', '2026-03-23')
WHERE employee_id = '<irene_id>'
LIMIT 1;
-- Check reimbursement_amount = 100.00
```

- [ ] **Step 4: Verify dashboard build passes**

Run: `cd dashboard && npx next build`
Expected: Clean build, no errors.

- [ ] **Step 5: Verify a non-forfait employee is unaffected**

```sql
-- Pick another employee who does NOT have a mileage allowance
SELECT get_mileage_approval_detail('<other_id>', '2026-03-10', '2026-03-23');
-- Check summary.is_forfait=false, estimated_amount uses km × rate calculation
```

- [ ] **Step 6: Final commit if any fixes were needed**

```bash
git add -A && git commit -m "fix: adjustments from e2e verification"
```
