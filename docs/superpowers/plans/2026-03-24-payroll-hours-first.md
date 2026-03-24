# Payroll Hours-First Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize the payroll summary table so hours are grouped on the left, then Taux/h + calculated amounts on the right, making the pay calculation readable left-to-right.

**Architecture:** Add `rejected_minutes` to the payroll RPC. Add new fields to TypeScript types (rejected_minutes, hourly rate display). Reorder and regroup columns in the summary table with visual separators. Update Excel export to match.

**Tech Stack:** PostgreSQL (Supabase RPC), TypeScript, Next.js, React, shadcn/ui, xlsx

**Spec:** `docs/superpowers/specs/2026-03-24-payroll-hours-first-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `supabase/migrations/20260327000000_payroll_rejected_minutes.sql` | Create | Add rejected_minutes to payroll RPC |
| `dashboard/src/types/payroll.ts` | Modify | Add rejected_minutes, hourly_rate_display fields |
| `dashboard/src/lib/hooks/use-payroll-report.ts` | Modify | Aggregate rejected_minutes, compute rate display |
| `dashboard/src/components/payroll/payroll-summary-table.tsx` | Modify | Reorder columns, add groups, add Taux/h + Refusées |
| `dashboard/src/lib/utils/export-payroll-excel.ts` | Modify | Match new column order |

---

### Task 1: Add rejected_minutes to payroll RPC

**Files:**
- Modify: `supabase/migrations/20260326100002_payroll_report_mileage.sql` (the current RPC definition)
- Create: `supabase/migrations/20260327000000_payroll_rejected_minutes.sql`

The current `get_payroll_period_report` RPC joins `day_approvals` via the `approvals` CTE but only selects `approved_minutes` and `break_deduction_waived`. We need to also select `rejected_minutes`.

- [ ] **Step 1: Write the migration**

Create `supabase/migrations/20260327000000_payroll_rejected_minutes.sql`. This is a `CREATE OR REPLACE FUNCTION` that copies the existing RPC from `20260326100002_payroll_report_mileage.sql` with these changes:

1. Add to `RETURNS TABLE`: `rejected_minutes INTEGER` (after `break_deduction_waived`)
2. In the `approvals` CTE (line ~124-131), add: `COALESCE(da.rejected_minutes, 0) AS rejected_minutes`
3. In the `combined` CTE, propagate: `a.rejected_minutes`
4. In the final `SELECT`, output: `c.rejected_minutes`

- [ ] **Step 2: Apply migration via Supabase MCP**

Run: `mcp__supabase__apply_migration` with the migration file.

- [ ] **Step 3: Verify the new column is returned**

Run a test query via `mcp__supabase__execute_sql`:
```sql
SELECT employee_id, date, approved_minutes, rejected_minutes
FROM get_payroll_period_report('2026-03-08', '2026-03-21')
LIMIT 5;
```
Expected: rows with `rejected_minutes` column populated (0 or positive integer).

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260327000000_payroll_rejected_minutes.sql
git commit -m "feat: add rejected_minutes to payroll report RPC"
```

---

### Task 2: Update TypeScript types

**Files:**
- Modify: `dashboard/src/types/payroll.ts`

- [ ] **Step 1: Add rejected_minutes to PayrollReportRow**

At line 33 (after `break_deduction_waived`), add:
```typescript
rejected_minutes: number;
```

- [ ] **Step 2: Add new fields to PayrollEmployeeSummary**

After `total_break_deduction_minutes` (around line 48), add:
```typescript
total_rejected_minutes: number;
hourly_rate: number | null;       // exact rate for hourly, equivalent for annual
hourly_rate_display: string;      // "19.33 $/h" or "~25.00 $/h"
annual_salary: number | null;     // for annual employees only
```

- [ ] **Step 3: Add rejected_minutes to PayrollCategoryGroup totals**

In the `totals` object of `PayrollCategoryGroup` (around line 66), add:
```typescript
rejected_minutes: number;
```

- [ ] **Step 4: Commit**

```bash
git add dashboard/src/types/payroll.ts
git commit -m "feat: add rejected_minutes and rate display to payroll types"
```

---

### Task 3: Update hook aggregation

**Files:**
- Modify: `dashboard/src/lib/hooks/use-payroll-report.ts`

- [ ] **Step 1: Add rejected_minutes aggregation in employee summary**

In the `employees` useMemo (around line 60-83), after `total_break_deduction_minutes` (line 71), add:
```typescript
total_rejected_minutes: days.reduce((s, d) => s + d.rejected_minutes, 0),
```

Add hourly rate fields after `payroll_approved_at`:
```typescript
hourly_rate: first.pay_type === 'hourly'
  ? first.hourly_rate
  : first.annual_salary ? Math.round((first.annual_salary / 2080) * 100) / 100 : null,
hourly_rate_display: first.pay_type === 'hourly'
  ? (first.hourly_rate ? `${first.hourly_rate.toFixed(2)} $/h` : '—')
  : (first.annual_salary ? `~${(first.annual_salary / 2080).toFixed(2)} $/h` : '—'),
annual_salary: first.annual_salary,
```

- [ ] **Step 2: Add rejected_minutes to category group totals**

In the `categoryGroups` useMemo (around line 105-111), add to the `totals` object:
```typescript
rejected_minutes: emps.reduce((s, e) => s + e.total_rejected_minutes, 0),
```

- [ ] **Step 3: Add rejected_minutes to grandTotal**

In the `grandTotal` useMemo (around line 116-122), add:
```typescript
rejected_minutes: employees.reduce((s, e) => s + e.total_rejected_minutes, 0),
```

- [ ] **Step 4: Commit**

```bash
git add dashboard/src/lib/hooks/use-payroll-report.ts
git commit -m "feat: aggregate rejected_minutes and compute rate display in payroll hook"
```

---

### Task 4: Redesign the summary table

**Files:**
- Modify: `dashboard/src/components/payroll/payroll-summary-table.tsx`

This is the main visual change. The table gets group headers, reordered columns, and new columns.

- [ ] **Step 1: Update the grandTotal type in props**

Add `rejected_minutes: number` to the `grandTotal` prop type (line 23-28).

- [ ] **Step 2: Replace the TableHeader with grouped headers**

Replace the current single header row (lines 49-65) with two rows:

Row 1 — Group labels:
```tsx
<TableRow className="border-b-0">
  <TableHead className="w-8" />
  <TableHead colSpan={2} className="text-xs text-green-600 tracking-wider">EMPLOYÉ</TableHead>
  <TableHead colSpan={6} className="text-xs text-blue-600 tracking-wider text-center border-l-2">TEMPS</TableHead>
  <TableHead className="text-xs text-muted-foreground tracking-wider text-center border-l-2">QUAL.</TableHead>
  <TableHead colSpan={4} className="text-xs text-amber-600 tracking-wider text-center border-l-2">CALCUL PAIE</TableHead>
  <TableHead colSpan={2} className="text-xs text-muted-foreground tracking-wider text-center border-l-2">STATUT</TableHead>
</TableRow>
```

Row 2 — Column labels:
```tsx
<TableRow>
  <TableHead className="w-8" />
  {/* EMPLOYÉ */}
  <TableHead>Employé</TableHead>
  <TableHead>Type</TableHead>
  {/* TEMPS */}
  <TableHead className="text-right border-l-2">Heures</TableHead>
  <TableHead className="text-right text-destructive">Refusées</TableHead>
  <TableHead className="text-right">Rappel</TableHead>
  <TableHead className="text-right">Pause</TableHead>
  <TableHead className="text-center">Sans pause</TableHead>
  <TableHead className="text-right text-destructive">Déd. pause</TableHead>
  {/* QUALITÉ */}
  <TableHead className="text-right border-l-2">% Sess.</TableHead>
  {/* CALCUL PAIE */}
  <TableHead className="text-right border-l-2 text-amber-600">Taux/h</TableHead>
  <TableHead className="text-right">Prime FDS</TableHead>
  <TableHead className="text-right">Rappel $</TableHead>
  <TableHead className="text-right text-amber-600 font-semibold">Total</TableHead>
  {/* STATUT */}
  <TableHead className="text-center border-l-2">Jours</TableHead>
  <TableHead className="text-center">Paie</TableHead>
</TableRow>
```

- [ ] **Step 3: Update employee row cells**

Replace the current employee row cells (lines 85-141) with the new column order. Key changes:

After Heures cell, add Refusées:
```tsx
<TableCell className="text-right font-mono text-destructive">
  {emp.total_rejected_minutes > 0
    ? formatMinutesAsHours(emp.total_rejected_minutes)
    : '—'}
</TableCell>
```

After Déd. pause cell, add Taux/h (in CALCUL PAIE group):
```tsx
<TableCell className="text-right font-mono border-l-2 text-amber-600">
  {emp.hourly_rate_display}
</TableCell>
```

Add Rappel $ (after Prime FDS):
```tsx
<TableCell className="text-right font-mono">
  {emp.total_callback_bonus_amount > 0
    ? `${emp.total_callback_bonus_amount.toFixed(2)} $`
    : '—'}
</TableCell>
```

For the **Total cell**, add annual employee sub-text:
```tsx
<TableCell className="text-right font-mono font-semibold text-amber-600">
  {fmtMoney(emp.total_amount)}
  {emp.pay_type === 'annual' && emp.hourly_rate && (
    <div className="text-xs text-muted-foreground font-normal">
      80h × {emp.hourly_rate.toFixed(2)}
    </div>
  )}
</TableCell>
```

**Remove** the old "Base" cell entirely.

Add `border-l-2` classes to cells at group boundaries (Heures, % Sess., Taux/h, Jours).

- [ ] **Step 4: Update colSpan values**

Update all `colSpan` values in the file:
- Category header row: `colSpan={17}` (was 14)
- Expanded detail row: `colSpan={17}` (was 14)

- [ ] **Step 5: Update sub-total row**

Replace the category sub-total row (lines 159-171) with new columns:
```tsx
<TableRow className="bg-muted/30 font-semibold">
  <TableCell colSpan={3}>
    Sous-total {CATEGORY_LABELS[group.category]}
  </TableCell>
  <TableCell className="text-right font-mono border-l-2">
    {formatMinutesAsHours(group.totals.approved_minutes)}
  </TableCell>
  <TableCell className="text-right font-mono text-destructive">
    {group.totals.rejected_minutes > 0
      ? formatMinutesAsHours(group.totals.rejected_minutes)
      : ''}
  </TableCell>
  <TableCell colSpan={4} />
  <TableCell className="border-l-2" />
  <TableCell className="border-l-2" />
  <TableCell className="text-right font-mono">{fmtMoney(group.totals.premium_amount)}</TableCell>
  <TableCell />
  <TableCell className="text-right font-mono font-semibold text-amber-600">
    {fmtMoney(group.totals.total_amount)}
  </TableCell>
  <TableCell colSpan={2} className="border-l-2" />
</TableRow>
```

- [ ] **Step 6: Update grand total row**

Same pattern as sub-total but with `bg-muted font-bold` and `grandTotal` values.

- [ ] **Step 7: Verify in browser**

Open `https://time.trilogis.ca/dashboard/remuneration/payroll` and verify:
- Group headers appear with correct colors
- Columns are in the correct order
- Border separators visible between groups
- Taux/h shows correct rates
- Refusées shows rejected hours
- Annual employees show "80h × rate" sub-text under Total
- Sub-totals and grand total include new columns

- [ ] **Step 8: Commit**

```bash
git add dashboard/src/components/payroll/payroll-summary-table.tsx
git commit -m "feat: redesign payroll table with grouped columns and hours-first layout"
```

---

### Task 5: Update Excel export

**Files:**
- Modify: `dashboard/src/lib/utils/export-payroll-excel.ts`

- [ ] **Step 1: Update Sheet 1 (Sommaire) columns**

Replace the current summary column order (lines 26-45) with the new order:

```typescript
summaryRows.push({
  Employe: emp.full_name,
  Code: emp.employee_id_code,
  Categorie: emp.primary_category || '',
  'Type paie': emp.pay_type === 'annual' ? 'Annuel' : 'Horaire',
  // TEMPS
  'Heures approuvees': formatMinutesAsHours(emp.total_approved_minutes),
  'Heures refusees': emp.total_rejected_minutes > 0
    ? formatMinutesAsHours(emp.total_rejected_minutes) : '',
  'Rappel (h)': emp.total_callback_bonus_minutes > 0
    ? formatMinutesAsHours(emp.total_callback_bonus_minutes) : '',
  'Pause totale': formatMinutesAsHours(emp.total_break_minutes),
  'Jours sans pause': emp.days_without_break || '',
  'Ded. pause (min)': emp.total_break_deduction_minutes > 0
    ? emp.total_break_deduction_minutes : '',
  // QUALITÉ
  '% Sessions': `${emp.work_session_coverage_pct}%`,
  // CALCUL PAIE
  'Taux horaire': emp.hourly_rate_display,
  'Prime FDS ($)': emp.total_premium > 0 ? emp.total_premium : '',
  'Rappel ($)': emp.total_callback_bonus_amount > 0
    ? emp.total_callback_bonus_amount : '',
  'Total ($)': emp.total_amount,
  // STATUT
  'Approbation paie': emp.payroll_status === 'approved' ? 'Approuvee' : 'En attente',
});
```

Note: "Montant base ($)" column is removed.

- [ ] **Step 2: Update sub-total row**

Add `'Heures refusees'` to the sub-total row:
```typescript
summaryRows.push({
  Employe: `Sous-total ${CATEGORY_LABELS[group.category]}`,
  'Heures approuvees': formatMinutesAsHours(group.totals.approved_minutes),
  'Heures refusees': group.totals.rejected_minutes > 0
    ? formatMinutesAsHours(group.totals.rejected_minutes) : '',
  'Prime FDS ($)': group.totals.premium_amount,
  'Total ($)': group.totals.total_amount,
});
```

- [ ] **Step 3: Update Sheet 2 (Detail) columns**

Add `'Heures refusees'` column after `'Heures approuvees'` in the detail rows, and add `'Taux horaire'`:
```typescript
'Heures refusees': day.rejected_minutes > 0
  ? formatMinutesAsHours(day.rejected_minutes) : '',
```

Also replace `'Montant ($)'` with `'Total ($)'` for consistency.

- [ ] **Step 4: Commit**

```bash
git add dashboard/src/lib/utils/export-payroll-excel.ts
git commit -m "feat: update Excel export to match hours-first column layout"
```

---

### Task 6: Visual verification and cleanup

- [ ] **Step 1: Build check**

```bash
cd dashboard && npx next build
```

Fix any TypeScript errors (likely: grandTotal type mismatches, missing fields).

- [ ] **Step 2: Browser verification**

Open payroll page and verify with real data:
- All group headers render with correct colors
- Taux/h shows real rates from the database
- Refusées shows actual rejected hours (may be 0/— for most)
- Annual employees show ~rate and "80h × rate" sub-text
- Sub-totals and grand total align correctly
- No horizontal scroll issues (if too wide, consider reducing column padding)

- [ ] **Step 3: Excel export verification**

Click "Exporter Excel" and verify:
- New columns present (Heures refusées, Taux horaire, Rappel $)
- "Montant base" column removed
- Sub-totals include rejected hours

- [ ] **Step 4: Final commit if any fixes needed**

```bash
git add -A
git commit -m "fix: adjust payroll table alignment and type errors"
```
