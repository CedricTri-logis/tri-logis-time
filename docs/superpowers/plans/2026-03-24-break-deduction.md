# Break Deduction for Insufficient Pause Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically deduct missing break time from payroll when an employee works ≥5h but has < 30 min of break, with admin override capability.

**Architecture:** Add `break_deduction_waived` column to `day_approvals`. The `get_payroll_period_report` RPC calculates `break_deduction_minutes = GREATEST(30 - break_minutes, 0)` for qualifying days, respecting the waiver flag. A new RPC `toggle_break_deduction_waiver` lets admins exempt specific days. The dashboard shows the deduction per day with a toggle button, and subtracts it from `base_amount` / `total_amount`.

**Tech Stack:** PostgreSQL (Supabase migration), TypeScript/Next.js (dashboard), shadcn/ui

**Business rule:** If `approved_minutes >= 300` AND `break_minutes < 30` AND NOT `break_deduction_waived`, then `break_deduction_minutes = 30 - break_minutes`. This is subtracted from the billable time before calculating pay.

---

### File Map

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `supabase/migrations/20260326400000_break_deduction.sql` | Column + waiver RPC + payroll RPC update |
| Modify | `dashboard/src/types/payroll.ts` | Add `break_deduction_minutes` + `break_deduction_waived` fields |
| Modify | `dashboard/src/lib/api/payroll.ts` | Add `toggleBreakDeductionWaiver()` API call |
| Modify | `dashboard/src/lib/hooks/use-payroll-report.ts` | Aggregate `total_break_deduction_minutes` in summary |
| Modify | `dashboard/src/components/payroll/payroll-employee-detail.tsx` | Show deduction column + waiver toggle per day |
| Modify | `dashboard/src/components/payroll/payroll-summary-table.tsx` | Show total deduction in summary row |
| Modify | `dashboard/src/lib/utils/export-payroll-excel.ts` | Add deduction column to Excel export |

---

### Task 1: Database migration — column + waiver RPC

**Files:**
- Create: `supabase/migrations/20260326400000_break_deduction.sql`

- [ ] **Step 1: Write the migration file**

```sql
-- =============================================================
-- Migration: Break deduction for insufficient pause
-- Adds break_deduction_waived to day_approvals.
-- Adds toggle_break_deduction_waiver RPC.
-- Updates get_payroll_period_report to return break_deduction_minutes.
-- Rule: if approved_minutes >= 300 AND break_minutes < 30
--       then deduction = 30 - break_minutes (unless waived).
-- =============================================================

-- 1. Add waiver column to day_approvals
ALTER TABLE day_approvals
  ADD COLUMN break_deduction_waived BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN day_approvals.break_deduction_waived IS
  'When true, the automatic 30-min break deduction is skipped for this day. Admin override.';

-- 2. RPC to toggle the waiver
CREATE OR REPLACE FUNCTION toggle_break_deduction_waiver(
  p_employee_id UUID,
  p_date DATE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_caller_role TEXT;
  v_new_value BOOLEAN;
BEGIN
  SELECT role INTO v_caller_role
  FROM employee_profiles WHERE id = auth.uid();

  IF v_caller_role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'Insufficient permissions';
  END IF;

  UPDATE day_approvals
  SET break_deduction_waived = NOT break_deduction_waived
  WHERE employee_id = p_employee_id AND date = p_date
  RETURNING break_deduction_waived INTO v_new_value;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Day approval not found for % on %', p_employee_id, p_date;
  END IF;

  RETURN v_new_value;
END;
$$;

COMMENT ON FUNCTION toggle_break_deduction_waiver IS
  'Toggles the break_deduction_waived flag on a day_approval. Admin/super_admin only. Returns new value.';
```

- [ ] **Step 2: Apply the migration**

Run via Supabase MCP `apply_migration`.

- [ ] **Step 3: Verify the column exists**

```sql
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_name = 'day_approvals' AND column_name = 'break_deduction_waived';
```

Expected: one row, `boolean`, `false`.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260326400000_break_deduction.sql
git commit -m "feat: add break_deduction_waived column and toggle RPC"
```

---

### Task 2: Update payroll report RPC to return break deduction

**Files:**
- Modify: `supabase/migrations/20260326100002_payroll_report_mileage.sql` (CREATE OR REPLACE)

This task updates the existing `get_payroll_period_report` function to:
1. Add `break_deduction_minutes INTEGER` and `break_deduction_waived BOOLEAN` to the RETURNS TABLE
2. Join `day_approvals.break_deduction_waived` in the `approvals` CTE
3. Compute `break_deduction_minutes` in the `combined` CTE
4. Subtract deduction from `base_amount` and `total_amount` for hourly employees

- [ ] **Step 1: Update the RETURNS TABLE** (line 13-44)

Add after line 44 (`reimbursement_amount DECIMAL(10,2)`):

```sql
  break_deduction_minutes INTEGER,
  break_deduction_waived BOOLEAN
```

- [ ] **Step 2: Update the `approvals` CTE** (lines 122-128)

Add `da.break_deduction_waived` to the SELECT:

```sql
  approvals AS (
    SELECT da.employee_id, da.date, da.status,
           COALESCE(da.approved_minutes, 0) AS approved_minutes,
           COALESCE(da.break_deduction_waived, false) AS break_deduction_waived
    FROM day_approvals da
    WHERE da.date BETWEEN p_period_start AND p_period_end
      AND da.employee_id IN (SELECT id FROM target_employees)
  ),
```

- [ ] **Step 3: Compute break_deduction_minutes in `combined` CTE** (around line 340)

Add after `md.reimbursement_amount` (line 338):

```sql
      -- Break deduction: if ≥5h worked and <30min break, deduct (30 - break_minutes)
      CASE
        WHEN COALESCE(a.approved_minutes, 0) >= 300
             AND COALESCE(b.break_minutes, 0) < 30
             AND NOT a.break_deduction_waived
        THEN 30 - COALESCE(b.break_minutes, 0)
        ELSE 0
      END AS break_deduction_minutes,
      a.break_deduction_waived,
```

- [ ] **Step 4: Update base_amount calculation** (lines 315-322)

For hourly employees, subtract break deduction from billable minutes:

```sql
      CASE
        WHEN te.pay_type = 'hourly' AND r.rate IS NOT NULL THEN
          ROUND(((COALESCE(a.approved_minutes, 0)
            - CASE
                WHEN COALESCE(a.approved_minutes, 0) >= 300
                     AND COALESCE(b.break_minutes, 0) < 30
                     AND NOT a.break_deduction_waived
                THEN 30 - COALESCE(b.break_minutes, 0)
                ELSE 0
              END
          ) / 60.0) * r.rate, 2)
        WHEN te.pay_type = 'annual' AND sal.salary IS NOT NULL THEN
          0
        ELSE 0
      END AS base_amount_raw,
```

- [ ] **Step 5: Add break_deduction_minutes and break_deduction_waived to final SELECT** (after line 411)

```sql
    c.break_deduction_minutes,
    c.break_deduction_waived
```

- [ ] **Step 6: Apply the updated function**

Run the full CREATE OR REPLACE via Supabase MCP `execute_sql`.

- [ ] **Step 7: Verify with a test query**

```sql
SELECT employee_id, date, approved_minutes, break_minutes,
       break_deduction_minutes, break_deduction_waived, base_amount
FROM get_payroll_period_report('2026-03-08', '2026-03-21')
WHERE approved_minutes >= 300 AND break_minutes < 30
LIMIT 5;
```

Expected: `break_deduction_minutes` = `30 - break_minutes` for non-waived days.

- [ ] **Step 8: Commit**

```bash
git add supabase/migrations/20260326100002_payroll_report_mileage.sql
git commit -m "feat: add break deduction calculation to payroll report RPC"
```

---

### Task 3: Update TypeScript types

**Files:**
- Modify: `dashboard/src/types/payroll.ts`

- [ ] **Step 1: Add fields to PayrollReportRow** (after line 32)

```typescript
  break_deduction_minutes: number;
  break_deduction_waived: boolean;
```

- [ ] **Step 2: Add fields to PayrollEmployeeSummary** (after line 45)

```typescript
  total_break_deduction_minutes: number;
```

- [ ] **Step 3: Add to PayrollCategoryGroup totals** (after line 66)

```typescript
    break_deduction_minutes: number;
```

- [ ] **Step 4: Commit**

```bash
git add dashboard/src/types/payroll.ts
git commit -m "feat: add break deduction fields to payroll types"
```

---

### Task 4: Update payroll hook aggregation

**Files:**
- Modify: `dashboard/src/lib/hooks/use-payroll-report.ts`

- [ ] **Step 1: Update `days_without_break` filter** (lines 49-51)

Change to count days with insufficient break (< 30 min) instead of just 0:

```typescript
      const daysWithoutBreak = days.filter(
        d => d.approved_minutes >= MIN_HOURS_FOR_BREAK_WARNING && d.break_minutes < 30
      ).length;
```

- [ ] **Step 2: Add total_break_deduction_minutes to summary** (after line 70)

```typescript
        total_break_deduction_minutes: days.reduce((s, d) => s + d.break_deduction_minutes, 0),
```

- [ ] **Step 3: Add break_deduction_minutes to category group totals** (around line 104)

```typescript
            break_deduction_minutes: emps.reduce((s, e) => s + e.total_break_deduction_minutes, 0),
```

- [ ] **Step 4: Add to grandTotal** (around line 114)

```typescript
    break_deduction_minutes: employees.reduce((s, e) => s + e.total_break_deduction_minutes, 0),
```

- [ ] **Step 5: Commit**

```bash
git add dashboard/src/lib/hooks/use-payroll-report.ts
git commit -m "feat: aggregate break deduction minutes in payroll hook"
```

---

### Task 5: Add waiver toggle API function

**Files:**
- Modify: `dashboard/src/lib/api/payroll.ts`

- [ ] **Step 1: Add toggleBreakDeductionWaiver function** (after `unlockPayroll`)

```typescript
export async function toggleBreakDeductionWaiver(
  employeeId: string,
  date: string
): Promise<boolean> {
  const { data, error } = await supabaseClient.rpc('toggle_break_deduction_waiver', {
    p_employee_id: employeeId,
    p_date: date,
  });
  if (error) throw error;
  return data as boolean;
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/lib/api/payroll.ts
git commit -m "feat: add toggleBreakDeductionWaiver API function"
```

---

### Task 6: Update payroll employee detail UI

**Files:**
- Modify: `dashboard/src/components/payroll/payroll-employee-detail.tsx`

- [ ] **Step 1: Add imports**

Add `toggleBreakDeductionWaiver` import and `Coffee`, `Undo2` icons:

```typescript
import { AlertTriangle, Coffee, Undo2 } from 'lucide-react';
import { toast } from 'sonner';
import { toggleBreakDeductionWaiver } from '@/lib/api/payroll';
```

- [ ] **Step 2: Add waiver toggle handler** (inside `PayrollEmployeeDetail`, before `renderDay`)

```typescript
  const handleToggleWaiver = async (day: PayrollReportRow) => {
    try {
      const newValue = await toggleBreakDeductionWaiver(employee.employee_id, day.date);
      toast.success(newValue ? 'Déduction annulée' : 'Déduction appliquée');
      onRefetch();
    } catch {
      toast.error('Erreur lors de la modification');
    }
  };
```

- [ ] **Step 3: Add "Déd. pause" column header** (after "Pause" TableHead, line 150)

```typescript
            <TableHead className="text-right">Déd. pause</TableHead>
```

- [ ] **Step 4: Add deduction cell in renderDay** (after the break_minutes TableCell, line 101)

```typescript
        <TableCell className="text-right font-mono">
          {day.break_deduction_minutes > 0 ? (
            <span className="flex items-center justify-end gap-1">
              <span className="text-destructive">-{day.break_deduction_minutes}min</span>
              <button
                onClick={(e) => { e.stopPropagation(); handleToggleWaiver(day); }}
                className="text-muted-foreground hover:text-primary"
                title="Annuler la déduction"
              >
                <Undo2 className="h-3 w-3" />
              </button>
            </span>
          ) : day.break_deduction_waived && day.approved_minutes >= 300 && day.break_minutes < 30 ? (
            <span className="flex items-center justify-end gap-1">
              <span className="text-muted-foreground line-through">-{30 - day.break_minutes}min</span>
              <button
                onClick={(e) => { e.stopPropagation(); handleToggleWaiver(day); }}
                className="text-muted-foreground hover:text-primary"
                title="Réappliquer la déduction"
              >
                <Coffee className="h-3 w-3" />
              </button>
            </span>
          ) : (
            '—'
          )}
        </TableCell>
```

- [ ] **Step 5: Update WeekSubtotal** to add empty cell for the new column (line 43)

Add after the break total cell:

```typescript
      <TableCell className="text-right font-mono text-destructive">
        {(() => {
          const totalDed = days.reduce((s, d) => s + d.break_deduction_minutes, 0);
          return totalDed > 0 ? `-${totalDed}min` : '';
        })()}
      </TableCell>
```

- [ ] **Step 6: Verify the table renders correctly**

Run `npm run dev` in the dashboard, navigate to `/dashboard/remuneration/payroll`, expand an employee.

- [ ] **Step 7: Commit**

```bash
git add dashboard/src/components/payroll/payroll-employee-detail.tsx
git commit -m "feat: show break deduction column with waiver toggle in payroll detail"
```

---

### Task 7: Update payroll summary table

**Files:**
- Modify: `dashboard/src/components/payroll/payroll-summary-table.tsx`

- [ ] **Step 1: Add "Déd. pause" column header** (after "Sans pause" TableHead, line 57)

```typescript
          <TableHead className="text-right">Déd. pause</TableHead>
```

- [ ] **Step 2: Add deduction cell in employee row** (after days_without_break cell, line 119)

```typescript
                  <TableCell className="text-right font-mono text-destructive">
                    {emp.total_break_deduction_minutes > 0
                      ? `-${formatMinutesAsHours(emp.total_break_deduction_minutes)}`
                      : '—'}
                  </TableCell>
```

- [ ] **Step 3: Update colSpan values**

Update all `colSpan` values to account for the new column:
- Category header row (line 71): `colSpan={13}` → `colSpan={14}`
- Expanded detail row (line 146): `colSpan={13}` → `colSpan={14}`
- Sub-total row (line 166): adjust `colSpan` values
- Grand total row (line 185): adjust `colSpan` values

- [ ] **Step 4: Commit**

```bash
git add dashboard/src/components/payroll/payroll-summary-table.tsx
git commit -m "feat: show total break deduction in payroll summary table"
```

---

### Task 8: Update Excel export

**Files:**
- Modify: `dashboard/src/lib/utils/export-payroll-excel.ts`

- [ ] **Step 1: Add deduction column to summary sheet** (after "Jours sans pause", line 37)

```typescript
        'Déd. pause (min)': emp.total_break_deduction_minutes > 0
          ? emp.total_break_deduction_minutes
          : '',
```

- [ ] **Step 2: Add deduction column to detail sheet** (after "Pause (min)", line 69)

```typescript
          'Déd. pause (min)': day.break_deduction_minutes > 0
            ? day.break_deduction_minutes
            : '',
```

- [ ] **Step 3: Commit**

```bash
git add dashboard/src/lib/utils/export-payroll-excel.ts
git commit -m "feat: add break deduction column to payroll Excel export"
```

---

### Task 9: Verify end-to-end

- [ ] **Step 1: Run `npm run build` in dashboard** to verify no TypeScript errors

```bash
cd dashboard && npm run build
```

- [ ] **Step 2: Test in browser**

1. Navigate to `/dashboard/remuneration/payroll`
2. Find an employee with ≥5h worked and < 30 min break
3. Verify "Déd. pause" column shows `-Xmin`
4. Click the Undo2 icon → verify deduction becomes strikethrough (waived)
5. Click the Coffee icon → verify deduction reapplies
6. Verify the weekly subtotal and summary totals update
7. Export to Excel → verify deduction column appears

- [ ] **Step 3: Final commit if any fixes needed**

```bash
git add -A && git commit -m "fix: break deduction adjustments from testing"
```
