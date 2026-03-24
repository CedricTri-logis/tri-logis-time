# Payroll Period Report — Design Spec

**Date:** 2026-03-24
**Route:** `/dashboard/remuneration/payroll`
**Status:** Draft

---

## 1. Overview

A dedicated payroll validation page under the Remuneration section of the dashboard. Allows admins to select a biweekly pay period, review employee timesheets with full detail (hours, breaks, callbacks, work sessions, premiums), approve payroll per employee, and export to Excel.

This is distinct from the existing `/reports/timesheet` page — it is a **payroll validation workflow**, not a generic report.

---

## 2. Pay Period Logic

### Calculation
- **Anchor date:** Sunday, March 8, 2026
- **Cycle:** 14 days, Sunday 00:00 → Saturday 23:59 (America/Toronto)
- **Formula:** Any period start = anchor ± (N × 14 days)
- **Examples:** ...Feb 22–Mar 7, **Mar 8–Mar 21**, Mar 22–Apr 4...

### Default Period
- On page load, display the **most recent fully completed period** (period_end < today)
- Today = March 24, 2026 → current period is Mar 22–Apr 4 (not finished) → default = **Mar 8–Mar 21**

### Navigation
- Top of page: `← Précédente` | **"8 mars – 21 mars 2026"** | `Suivante →`
- Dropdown to jump to any of the last ~12 periods
- Bookmarkable via query params: `?from=2026-03-08&to=2026-03-21`

### Client-Side Period Calculation
Periods are computed client-side from the anchor date. No server-side period table needed.

```typescript
const PAY_PERIOD_ANCHOR = new Date('2026-03-08'); // Sunday
const PAY_PERIOD_DAYS = 14;

function getPayPeriod(date: Date): { start: Date; end: Date } {
  const diffMs = date.getTime() - PAY_PERIOD_ANCHOR.getTime();
  const diffDays = Math.floor(diffMs / (1000 * 60 * 60 * 24));
  const periodOffset = Math.floor(diffDays / PAY_PERIOD_DAYS);
  const start = addDays(PAY_PERIOD_ANCHOR, periodOffset * PAY_PERIOD_DAYS);
  const end = addDays(start, PAY_PERIOD_DAYS - 1);
  return { start, end };
}

function getLastCompletedPeriod(today: Date): { start: Date; end: Date } {
  const current = getPayPeriod(today);
  if (today > current.end) return current;
  return getPayPeriod(subDays(current.start, 1));
}
```

---

## 3. Employee Filtering & Grouping

### Permissions
- **Admins / super_admins:** See all employees
- **Managers:** See their supervised employees only (via `employee_supervisors`)

### Grouping by Primary Category
Employees are grouped by their **primary** category (`employee_categories.is_primary = true`):
- Ménage
- Maintenance
- Rénovation
- Admin

Employees with a secondary category show it as a tag (e.g., "Maintenance · +ménage").

### Optional Filter
- Filter dropdown by category (show all / ménage only / maintenance only / etc.)

---

## 4. Summary Table (Tableau Sommaire)

One row per employee, grouped by primary category with sub-totals per group and a grand total.

### Columns

| Column | Description |
|---|---|
| Employé | Full name + employee ID code |
| Type paie | `Horaire` / `Annuel` |
| Heures approuvées | Total approved hours for the period (e.g., 76h30) |
| Heures rappel bonus | Extra hours paid due to callback 3h minimum (Art. 58 LNT). Shows only the BONUS portion — e.g., if worked 1h but billed 3h, shows +2h |
| Pause/Dîner | Total break time across the period |
| ⚠️ Jours sans pause | Count of worked days (>5h) with zero break. Red badge if > 0 |
| % Work Sessions | % of approved time covered by work sessions (cleaning + maintenance + admin) |
| Prime FDS ($) | Weekend cleaning premium amount (only for eligible ménage employees) |
| Montant base ($) | Hourly: hours × rate. Annual: salary / 26 |
| Total ($) | Base + premium + callback bonus amount |
| Approbation jours | Badge: "14/14 ✓" (green) or "12/14 ⚠" (orange) — approved days / worked days |
| Approbation paie | Badge: "Approuvée ✓" (green) / "En attente" (grey) / locked icon |

### Visual Indicators
- Row background green if payroll approved
- Row background yellow/orange if days still pending approval
- Red badge on "Jours sans pause" if count > 0
- For annual employees: warning icon if total hours < 80h (2 weeks × 40h)

### Sub-totals
- Per category group: sum of hours, amounts, premiums
- Grand total at bottom

---

## 5. Employee Detail (Expandable)

Clicking an employee row expands a detailed day-by-day view.

### Day-by-Day Table

| Column | Description |
|---|---|
| Jour | Day name + date (e.g., "Dim 8 mars") |
| Heures approuvées | Approved hours for that day |
| Pause/Dîner | Break duration. ⚠️ red badge if 0 min and worked > 5h |
| Rappel bonus | Callback bonus hours (extra time paid, not worked). E.g., worked 1h → billed 3h → shows "+2h" |
| Work Sessions | Colored chips: 🟢 Ménage Xh · 🟠 Entretien Xh · 🔵 Admin Xh · ❌ Non couvert Xh |
| Prime FDS ($) | Weekend premium amount (Sat/Sun only, if eligible) |
| Montant ($) | Day total (base + premium + callback bonus) |
| Statut | ✓ Approuvé / ⚠ En attente |

### Features
- Each day row is clickable → navigates to the existing day approval detail page
- **Weekly sub-totals:** Since the period covers 2 weeks, show a sub-total row after each week (Week 1: Sun–Sat, Week 2: Sun–Sat)
- For annual employees: show hours per week with indicator if < 40h
- Days with no shift are omitted (not shown as empty rows)

### Payroll Approval Controls (bottom of detail)
- **"Approuver la paie de [Nom]"** button
  - Disabled (greyed) if any worked day is not day-approved. Tooltip: "X jour(s) non approuvé(s)"
  - On click: confirmation dialog "Approuver la paie de [Nom] pour la période du [start] au [end] ? Les approbations journalières seront verrouillées."
  - On confirm: creates `payroll_approvals` record, locks day approvals
- **Once approved:** Shows green banner "Paie approuvée le [date] par [admin]" + "Déverrouiller" button
  - Unlock requires confirmation dialog: "Déverrouiller la paie de [Nom] ? Les approbations journalières pourront être modifiées."

---

## 6. Payroll Approval Workflow

### Two-Level Approval Model
1. **Level 1 (existing):** Day-by-day approval in the approval dashboard (`day_approvals`)
2. **Level 2 (new):** Payroll period approval — signals the accountant that payroll can be processed

### Rules
- **Pre-condition:** ALL worked days in the period must have `day_approvals.status = 'approved'` before payroll can be approved
- **Post-condition:** Once payroll is approved, all `day_approvals` and `activity_overrides` for that employee in that period are **locked** (no modifications allowed)
- **Unlock:** An admin can unlock a payroll approval, which re-enables day-level modifications
- **Permissions:** Only `admin` and `super_admin` roles can approve/unlock payroll

### New Table: `payroll_approvals`

```sql
CREATE TABLE payroll_approvals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES employee_profiles(id),
  period_start DATE NOT NULL,
  period_end DATE NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved')),
  approved_by UUID REFERENCES employee_profiles(id),
  approved_at TIMESTAMPTZ,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(employee_id, period_start, period_end)
);
```

### Locking Mechanism
- When `payroll_approvals.status = 'approved'`, a trigger/check on `day_approvals` and `activity_overrides` prevents UPDATE/INSERT for that employee within the period date range
- The `approve_day` and `save_activity_override` RPCs check for an active payroll lock before proceeding

### RPCs

**`approve_payroll(p_employee_id, p_period_start, p_period_end, p_notes)`**
- Verifies all worked days are day-approved (else raises exception)
- Creates/updates `payroll_approvals` record with `status = 'approved'`
- Sets `approved_by` to current user, `approved_at` to now()
- Returns the payroll approval record

**`unlock_payroll(p_employee_id, p_period_start, p_period_end)`**
- Sets `payroll_approvals.status = 'pending'`, clears `approved_by`/`approved_at`
- Day approvals become modifiable again
- Returns the updated record

---

## 7. New RPC: `get_payroll_period_report`

### Parameters
```
p_period_start DATE
p_period_end DATE
p_employee_ids UUID[] DEFAULT NULL  -- optional filter
```

### Returns (per employee, per day)
```sql
RETURNS TABLE (
  -- Employee info
  employee_id UUID,
  full_name TEXT,
  employee_id_code TEXT,
  pay_type TEXT,                    -- 'hourly' or 'annual'
  primary_category TEXT,            -- from employee_categories WHERE is_primary
  secondary_categories TEXT[],      -- other active categories

  -- Day data
  date DATE,

  -- Hours
  approved_minutes INTEGER,         -- from day_approvals

  -- Breaks
  break_minutes INTEGER,            -- lunch_breaks + is_lunch shifts duration

  -- Callbacks
  callback_worked_minutes INTEGER,  -- actual time worked on callback shifts
  callback_billed_minutes INTEGER,  -- billed time (3h min grouping, Art. 58)
  callback_bonus_minutes INTEGER,   -- billed - worked = bonus paid

  -- Work sessions breakdown
  cleaning_minutes INTEGER,         -- work_sessions activity_type='cleaning'
  maintenance_minutes INTEGER,      -- work_sessions activity_type='maintenance'
  admin_minutes INTEGER,            -- work_sessions activity_type='admin'
  uncovered_minutes INTEGER,        -- approved_minutes - (cleaning + maintenance + admin)

  -- Pay
  hourly_rate DECIMAL(10,2),        -- NULL for annual
  annual_salary DECIMAL(12,2),      -- NULL for hourly
  period_salary DECIMAL(12,2),      -- annual_salary / 26, NULL for hourly
  base_amount DECIMAL(10,2),        -- hourly: (approved_min / 60) × rate. annual: salary/26 (on first day only)
  weekend_cleaning_minutes INTEGER, -- cleaning on Sat/Sun if eligible
  weekend_premium_rate DECIMAL(10,2),
  premium_amount DECIMAL(10,2),     -- weekend_cleaning_min / 60 × premium_rate
  callback_bonus_amount DECIMAL(10,2), -- callback_bonus_min / 60 × hourly_rate
  total_amount DECIMAL(10,2),       -- base + premium + callback bonus

  -- Approval status
  day_approval_status TEXT,         -- 'approved' / 'pending' / 'no_shift'

  -- Payroll approval
  payroll_status TEXT,              -- 'approved' / 'pending' (same for all rows of this employee)
  payroll_approved_by TEXT,         -- admin name
  payroll_approved_at TIMESTAMPTZ
)
```

### Data Sources
- `day_approvals` → approved_minutes, day_approval_status
- `lunch_breaks` + shifts WHERE `is_lunch = true` → break_minutes
- `shifts` WHERE `shift_type = 'call'` + existing call bonus logic → callback fields
- `work_sessions` → cleaning/maintenance/admin minutes
- `employee_hourly_rates` / `employee_annual_salaries` → pay calculation
- `employee_categories` → primary/secondary categories
- `pay_settings` → weekend_premium_rate
- `payroll_approvals` → payroll lock status

### Authorization
- Admin/super_admin: all employees
- Manager: supervised employees only (via `employee_supervisors WHERE effective_to IS NULL`)

---

## 8. Export Excel (.xlsx)

### File
- Name: `Paie_2026-03-08_2026-03-21.xlsx`
- Generated client-side using **SheetJS (xlsx)**
- UTF-8, compatible with Excel

### Sheet 1: "Sommaire"

| Employé | Code | Catégorie | Type paie | Heures approuvées | Heures rappel bonus | Pause totale | Jours sans pause | % Work Sessions | Prime FDS ($) | Montant base ($) | Total ($) | Statut approbation paie |
|---|---|---|---|---|---|---|---|---|---|---|---|---|

- Sub-total rows per category group
- Grand total row at bottom
- Bold headers, category group headers

### Sheet 2: "Détail"

| Employé | Code | Date | Heures approuvées | Pause (min) | Rappel bonus (h) | Ménage (h) | Entretien (h) | Admin (h) | Non couvert (h) | Prime FDS ($) | Montant ($) | Statut jour |
|---|---|---|---|---|---|---|---|---|---|---|---|---|

- Grouped by employee
- Weekly sub-total rows per employee
- Period total row per employee

### Formatting
- Headers in bold
- Currency columns formatted as `$#,##0.00`
- Hours formatted as `#h##` (e.g., 8h30)
- Sub-total/total rows with grey background
- Separator: semicolon for CSV compatibility (if needed)

---

## 9. Dashboard Components

### New Files

```
dashboard/src/app/dashboard/remuneration/payroll/
├── page.tsx                          # Main payroll page
└── components/
    ├── payroll-period-selector.tsx    # Period navigation (prev/next/dropdown)
    ├── payroll-summary-table.tsx      # Summary table with grouping
    ├── payroll-employee-detail.tsx    # Expandable day-by-day detail
    ├── payroll-approval-button.tsx    # Approve/unlock payroll controls
    └── payroll-export-button.tsx      # Excel export trigger

dashboard/src/lib/
├── hooks/use-payroll-report.ts       # Data fetching hook
├── api/payroll.ts                    # Supabase RPC calls
├── utils/pay-periods.ts             # Period calculation utilities
└── utils/export-payroll-excel.ts    # SheetJS export logic

dashboard/src/types/payroll.ts        # TypeScript types
```

### Existing Files Modified
- `dashboard/src/app/dashboard/remuneration/page.tsx` — Add navigation link to payroll page
- `supabase/migrations/` — New migration for `payroll_approvals` table + RPCs + locking triggers

---

## 10. Migration Plan

### New Migration: `YYYYMMDD_payroll_approvals.sql`

1. **Create `payroll_approvals` table** with unique constraint on (employee_id, period_start, period_end)
2. **Add `is_primary` column** to `employee_categories` (already done via direct SQL — migration captures it for reproducibility)
3. **Create `approve_payroll` RPC** — validates all days approved, creates lock record
4. **Create `unlock_payroll` RPC** — removes lock
5. **Create `get_payroll_period_report` RPC** — aggregates all data sources
6. **Add locking triggers** on `day_approvals` and `activity_overrides` — check for active payroll lock before UPDATE/INSERT
7. **RLS policies** on `payroll_approvals` — admin/super_admin full access, managers read-only for supervised employees
8. **COMMENT ON** for all new objects

---

## 11. Edge Cases

- **Employee with no shifts in period:** Omitted from summary (not shown as empty row). Annual employees still shown with 0 hours + period salary.
- **Mid-period rate change:** Day-level calculation uses the rate effective on that specific day (already handled by `employee_hourly_rates.effective_from/to`)
- **Employee category change mid-period:** Uses the category active on each day for work session classification. Summary groups by current primary category.
- **Callback spanning midnight:** Assigned to the day the callback shift started (clocked_in_at)
- **Break detection:** Includes `lunch_breaks` table entries AND shifts with `is_lunch = true` (clock-out/clock-in lunch pattern)
- **Partial period (new hire / termination):** Only days with shifts are counted. No penalty for missing days.
- **Already approved payroll + day unlock attempt:** Blocked by trigger. Must unlock payroll first.
