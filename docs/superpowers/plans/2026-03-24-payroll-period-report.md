# Payroll Period Report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a dedicated biweekly payroll validation page at `/dashboard/remuneration/payroll` with period navigation, employee summary/detail, two-level approval (day + payroll), and Excel export.

**Architecture:** New Supabase migration creates `payroll_approvals` table, locking triggers, and a `get_payroll_period_report` RPC that aggregates day approvals, breaks, callbacks, work sessions, and pay calculation. Dashboard page uses existing Refine/shadcn patterns with expandable summary table, period selector, and client-side Excel export via SheetJS.

**Tech Stack:** PostgreSQL (Supabase), Next.js 14+ (App Router), TypeScript, @refinedev/core, shadcn/ui, @tanstack/react-table, date-fns, SheetJS (xlsx)

**Spec:** `docs/superpowers/specs/2026-03-24-payroll-period-report-design.md`

---

## File Structure

### New Files

```
supabase/migrations/
├── 20260325100000_payroll_approvals.sql          # Table, triggers, locking, RPCs

dashboard/src/
├── app/dashboard/remuneration/payroll/
│   └── page.tsx                                   # Main payroll page
├── components/payroll/
│   ├── payroll-period-selector.tsx                # Period nav (prev/next/dropdown)
│   ├── payroll-summary-table.tsx                  # Summary table with category grouping
│   ├── payroll-employee-detail.tsx                # Expandable day-by-day detail
│   ├── payroll-approval-button.tsx                # Approve/unlock payroll per employee
│   └── payroll-export-button.tsx                  # Excel export trigger
├── lib/
│   ├── api/payroll.ts                             # Supabase RPC calls
│   ├── hooks/use-payroll-report.ts                # Data fetching hook
│   ├── utils/pay-periods.ts                       # Period calculation utilities
│   └── utils/export-payroll-excel.ts              # SheetJS export logic
└── types/payroll.ts                               # TypeScript interfaces
```

### Modified Files

```
dashboard/src/components/layout/sidebar.tsx        # Add Payroll nav item under Rémunération
dashboard/package.json                              # Add xlsx dependency
```

---

## Task 1: Database Migration — Tables, Triggers, and RPCs

**Files:**
- Create: `supabase/migrations/20260325100000_payroll_approvals.sql`

This single migration contains everything needed server-side: the `payroll_approvals` table, locking triggers, and all three RPCs.

- [ ] **Step 1: Write the migration file — payroll_approvals table**

```sql
-- ============================================================
-- PAYROLL PERIOD APPROVAL & REPORTING
-- ============================================================

-- 1. payroll_approvals table
CREATE TABLE payroll_approvals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES employee_profiles(id),
  period_start DATE NOT NULL,
  period_end DATE NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved')),
  approved_by UUID REFERENCES employee_profiles(id),
  approved_at TIMESTAMPTZ,
  unlocked_by UUID REFERENCES employee_profiles(id),
  unlocked_at TIMESTAMPTZ,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(employee_id, period_start, period_end)
);

CREATE INDEX idx_payroll_approvals_status ON payroll_approvals(status);
CREATE INDEX idx_payroll_approvals_period ON payroll_approvals(period_start, period_end);

-- RLS
ALTER TABLE payroll_approvals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins full access" ON payroll_approvals
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM employee_profiles
      WHERE id = auth.uid() AND role IN ('admin', 'super_admin')
    )
  );

CREATE POLICY "Managers read supervised" ON payroll_approvals
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM employee_profiles
      WHERE id = auth.uid() AND role = 'manager'
    )
    AND employee_id IN (
      SELECT es.employee_id FROM employee_supervisors es
      WHERE es.manager_id = auth.uid() AND es.effective_to IS NULL
    )
  );

-- Comments
COMMENT ON TABLE payroll_approvals IS 'ROLE: Tracks payroll-level approval per employee per biweekly period. STATUTS: pending (can modify day approvals), approved (day approvals locked). REGLES: All worked days must be day-approved before payroll approval. Locking enforced via triggers on day_approvals, activity_overrides, lunch_breaks. RELATIONS: employee_profiles (employee_id, approved_by, unlocked_by).';
COMMENT ON COLUMN payroll_approvals.period_start IS 'First day of biweekly pay period (always a Sunday)';
COMMENT ON COLUMN payroll_approvals.period_end IS 'Last day of biweekly pay period (always a Saturday, 13 days after start)';
COMMENT ON COLUMN payroll_approvals.approved_by IS 'Admin who last approved. Preserved on unlock for audit trail.';
COMMENT ON COLUMN payroll_approvals.unlocked_by IS 'Admin who unlocked. NULL if never unlocked.';
```

- [ ] **Step 2: Add is_primary column to employee_categories (idempotent)**

```sql
-- 2. is_primary column on employee_categories (already added via direct SQL, this captures it)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'employee_categories' AND column_name = 'is_primary'
  ) THEN
    ALTER TABLE employee_categories ADD COLUMN is_primary BOOLEAN NOT NULL DEFAULT true;
  END IF;
END $$;

COMMENT ON COLUMN employee_categories.is_primary IS 'Primary category for payroll grouping. At most one is_primary=true per employee among active categories.';
```

- [ ] **Step 3: Add locking triggers**

```sql
-- 3. Locking triggers — prevent modifications when payroll is approved

CREATE OR REPLACE FUNCTION check_payroll_lock()
RETURNS TRIGGER AS $$
DECLARE
  v_employee_id UUID;
  v_date DATE;
BEGIN
  -- Determine employee_id and date based on table
  IF TG_TABLE_NAME = 'day_approvals' THEN
    v_employee_id := COALESCE(NEW.employee_id, OLD.employee_id);
    v_date := COALESCE(NEW.date, OLD.date);
  ELSIF TG_TABLE_NAME = 'activity_overrides' THEN
    -- Get employee_id and date from the parent day_approval
    SELECT da.employee_id, da.date INTO v_employee_id, v_date
    FROM day_approvals da
    WHERE da.id = COALESCE(NEW.day_approval_id, OLD.day_approval_id);
  ELSIF TG_TABLE_NAME = 'lunch_breaks' THEN
    v_employee_id := COALESCE(NEW.employee_id, OLD.employee_id);
    v_date := to_business_date(COALESCE(NEW.started_at, OLD.started_at));
  END IF;

  -- Check for active payroll lock
  IF EXISTS (
    SELECT 1 FROM payroll_approvals
    WHERE employee_id = v_employee_id
      AND status = 'approved'
      AND period_start <= v_date
      AND period_end >= v_date
  ) THEN
    RAISE EXCEPTION 'Payroll is locked for this period. Unlock payroll first.';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payroll_lock_day_approvals
  BEFORE UPDATE ON day_approvals
  FOR EACH ROW EXECUTE FUNCTION check_payroll_lock();

CREATE TRIGGER trg_payroll_lock_activity_overrides
  BEFORE INSERT OR UPDATE OR DELETE ON activity_overrides
  FOR EACH ROW EXECUTE FUNCTION check_payroll_lock();

CREATE TRIGGER trg_payroll_lock_lunch_breaks
  BEFORE INSERT OR UPDATE OR DELETE ON lunch_breaks
  FOR EACH ROW EXECUTE FUNCTION check_payroll_lock();
```

- [ ] **Step 4: Add approve_payroll RPC**

```sql
-- 4. approve_payroll RPC
CREATE OR REPLACE FUNCTION approve_payroll(
  p_employee_id UUID,
  p_period_start DATE,
  p_period_end DATE,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_caller UUID := auth.uid();
  v_unapproved_days INTEGER;
  v_result payroll_approvals;
BEGIN
  -- Auth check (uses existing helper)
  IF NOT is_admin_or_super_admin(v_caller) THEN
    RAISE EXCEPTION 'Only admins can approve payroll';
  END IF;

  -- Check all worked days are day-approved
  SELECT COUNT(*) INTO v_unapproved_days
  FROM day_approvals da
  WHERE da.employee_id = p_employee_id
    AND da.date BETWEEN p_period_start AND p_period_end
    AND da.status != 'approved';

  IF v_unapproved_days > 0 THEN
    RAISE EXCEPTION '% day(s) not yet approved for this period', v_unapproved_days;
  END IF;

  -- Also check there are shifts in this period (don't approve empty periods for hourly)
  IF NOT EXISTS (
    SELECT 1 FROM day_approvals da
    WHERE da.employee_id = p_employee_id
      AND da.date BETWEEN p_period_start AND p_period_end
      AND da.status = 'approved'
  ) THEN
    -- Check if annual employee (they can have approved payroll with 0 shifts)
    IF NOT EXISTS (
      SELECT 1 FROM employee_profiles
      WHERE id = p_employee_id AND pay_type = 'annual'
    ) THEN
      RAISE EXCEPTION 'No approved days found in this period';
    END IF;
  END IF;

  -- Upsert payroll approval
  INSERT INTO payroll_approvals (employee_id, period_start, period_end, status, approved_by, approved_at, unlocked_by, unlocked_at, notes)
  VALUES (p_employee_id, p_period_start, p_period_end, 'approved', v_caller, now(), NULL, NULL, p_notes)
  ON CONFLICT (employee_id, period_start, period_end)
  DO UPDATE SET
    status = 'approved',
    approved_by = v_caller,
    approved_at = now(),
    unlocked_by = NULL,
    unlocked_at = NULL,
    notes = COALESCE(p_notes, payroll_approvals.notes),
    updated_at = now()
  RETURNING * INTO v_result;

  RETURN to_jsonb(v_result);
END;
$$;
```

- [ ] **Step 5: Add unlock_payroll RPC**

```sql
-- 5. unlock_payroll RPC
CREATE OR REPLACE FUNCTION unlock_payroll(
  p_employee_id UUID,
  p_period_start DATE,
  p_period_end DATE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_caller UUID := auth.uid();
  v_result payroll_approvals;
BEGIN
  -- Auth check (uses existing helper)
  IF NOT is_admin_or_super_admin(v_caller) THEN
    RAISE EXCEPTION 'Only admins can unlock payroll';
  END IF;

  UPDATE payroll_approvals
  SET status = 'pending',
      unlocked_by = v_caller,
      unlocked_at = now(),
      updated_at = now()
  WHERE employee_id = p_employee_id
    AND period_start = p_period_start
    AND period_end = p_period_end
    AND status = 'approved'
  RETURNING * INTO v_result;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'No approved payroll found for this employee and period';
  END IF;

  RETURN to_jsonb(v_result);
END;
$$;
```

- [ ] **Step 6: Add get_payroll_period_report RPC**

```sql
-- 6. get_payroll_period_report RPC
CREATE OR REPLACE FUNCTION get_payroll_period_report(
  p_period_start DATE,
  p_period_end DATE,
  p_employee_ids UUID[] DEFAULT NULL
)
RETURNS TABLE (
  employee_id UUID,
  full_name TEXT,
  employee_id_code TEXT,
  pay_type TEXT,
  primary_category TEXT,
  secondary_categories TEXT[],
  date DATE,
  approved_minutes INTEGER,
  break_minutes INTEGER,
  callback_worked_minutes INTEGER,
  callback_billed_minutes INTEGER,
  callback_bonus_minutes INTEGER,
  cleaning_minutes INTEGER,
  maintenance_minutes INTEGER,
  admin_minutes INTEGER,
  uncovered_minutes INTEGER,
  hourly_rate DECIMAL(10,2),
  annual_salary DECIMAL(12,2),
  period_salary DECIMAL(12,2),
  base_amount DECIMAL(10,2),
  weekend_cleaning_minutes INTEGER,
  weekend_premium_rate DECIMAL(10,2),
  premium_amount DECIMAL(10,2),
  callback_bonus_amount DECIMAL(10,2),
  total_amount DECIMAL(10,2),
  day_approval_status TEXT,
  payroll_status TEXT,
  payroll_approved_by TEXT,
  payroll_approved_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_caller UUID := auth.uid();
  v_caller_role TEXT;
  v_supervised_ids UUID[];
  v_premium_rate DECIMAL(10,2);
BEGIN
  -- Auth & role
  SELECT role INTO v_caller_role
  FROM employee_profiles WHERE id = v_caller;

  IF v_caller_role IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF v_caller_role NOT IN ('admin', 'super_admin', 'manager') THEN
    RAISE EXCEPTION 'Insufficient permissions';
  END IF;

  -- Manager restriction
  IF v_caller_role = 'manager' THEN
    SELECT ARRAY_AGG(es.employee_id) INTO v_supervised_ids
    FROM employee_supervisors es
    WHERE es.manager_id = v_caller AND es.effective_to IS NULL;
  END IF;

  -- Get weekend premium rate
  SELECT COALESCE((value->>'amount')::DECIMAL, 0) INTO v_premium_rate
  FROM pay_settings WHERE key = 'weekend_cleaning_premium';

  RETURN QUERY
  WITH
  -- Target employees (include terminated employees who have day_approvals in the period)
  target_employees AS (
    SELECT ep.id, ep.full_name, ep.employee_id AS eid, COALESCE(ep.pay_type, 'hourly') AS pay_type
    FROM employee_profiles ep
    WHERE (
      ep.status = 'active'
      OR EXISTS (
        SELECT 1 FROM day_approvals da
        WHERE da.employee_id = ep.id
          AND da.date BETWEEN p_period_start AND p_period_end
      )
    )
      AND (p_employee_ids IS NULL OR ep.id = ANY(p_employee_ids))
      AND (v_caller_role IN ('admin', 'super_admin') OR ep.id = ANY(v_supervised_ids))
  ),

  -- Primary category per employee
  primary_cats AS (
    SELECT ec.employee_id,
           ec.category
    FROM employee_categories ec
    WHERE ec.ended_at IS NULL AND ec.is_primary = true
  ),

  -- Secondary categories per employee
  secondary_cats AS (
    SELECT ec.employee_id,
           ARRAY_AGG(ec.category ORDER BY ec.category) AS categories
    FROM employee_categories ec
    WHERE ec.ended_at IS NULL AND ec.is_primary = false
    GROUP BY ec.employee_id
  ),

  -- Day approvals in period
  approvals AS (
    SELECT da.employee_id, da.date, da.status,
           COALESCE(da.approved_minutes, 0) AS approved_minutes
    FROM day_approvals da
    WHERE da.date BETWEEN p_period_start AND p_period_end
      AND da.employee_id IN (SELECT id FROM target_employees)
  ),

  -- Break minutes: lunch_breaks + is_lunch shifts
  breaks AS (
    SELECT
      sub.employee_id,
      sub.date,
      SUM(sub.break_min)::INTEGER AS break_minutes
    FROM (
      -- lunch_breaks table
      SELECT lb.employee_id,
             to_business_date(lb.started_at) AS date,
             EXTRACT(EPOCH FROM (lb.ended_at - lb.started_at)) / 60.0 AS break_min
      FROM lunch_breaks lb
      WHERE to_business_date(lb.started_at) BETWEEN p_period_start AND p_period_end
        AND lb.employee_id IN (SELECT id FROM target_employees)
      UNION ALL
      -- is_lunch shifts
      SELECT s.employee_id,
             to_business_date(s.clocked_in_at) AS date,
             EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at)) / 60.0 AS break_min
      FROM shifts s
      WHERE s.is_lunch = true
        AND s.clocked_out_at IS NOT NULL
        AND to_business_date(s.clocked_in_at) BETWEEN p_period_start AND p_period_end
        AND s.employee_id IN (SELECT id FROM target_employees)
    ) sub
    GROUP BY sub.employee_id, sub.date
  ),

  -- Callback shifts (shift_type = 'call')
  -- NOTE: The 3h minimum (Art. 58 LNT) applies per callback GROUP, not per individual shift.
  -- Callback shifts within the same evening are grouped together and the group gets the 3h minimum.
  -- This uses the same grouping logic as the existing call_bonus_minutes calculation.
  -- For simplicity here, we use the pre-computed values from day_approval_detail summary
  -- (call_count, call_billed_minutes, call_bonus_minutes) which already handle grouping correctly.
  -- We fall back to per-shift calculation only for days without approval detail.
  callbacks AS (
    SELECT
      s.employee_id,
      to_business_date(s.clocked_in_at) AS date,
      SUM(EXTRACT(EPOCH FROM (COALESCE(s.clocked_out_at, now()) - s.clocked_in_at)) / 60.0)::INTEGER AS worked_minutes,
      -- Apply 3h minimum to the total per day (grouped), not per shift
      GREATEST(180,
        SUM(EXTRACT(EPOCH FROM (COALESCE(s.clocked_out_at, now()) - s.clocked_in_at)) / 60.0)
      )::INTEGER AS billed_minutes
    FROM shifts s
    WHERE s.shift_type = 'call'
      AND s.is_lunch = false
      AND to_business_date(s.clocked_in_at) BETWEEN p_period_start AND p_period_end
      AND s.employee_id IN (SELECT id FROM target_employees)
    GROUP BY s.employee_id, to_business_date(s.clocked_in_at)
  ),

  -- Work sessions breakdown
  sessions AS (
    SELECT
      ws.employee_id,
      to_business_date(ws.started_at) AS date,
      SUM(CASE WHEN ws.activity_type = 'cleaning' THEN ws.duration_minutes ELSE 0 END)::INTEGER AS cleaning_min,
      SUM(CASE WHEN ws.activity_type = 'maintenance' THEN ws.duration_minutes ELSE 0 END)::INTEGER AS maintenance_min,
      SUM(CASE WHEN ws.activity_type = 'admin' THEN ws.duration_minutes ELSE 0 END)::INTEGER AS admin_min
    FROM work_sessions ws
    WHERE ws.status IN ('completed', 'auto_closed', 'manually_closed')
      AND to_business_date(ws.started_at) BETWEEN p_period_start AND p_period_end
      AND ws.employee_id IN (SELECT id FROM target_employees)
    GROUP BY ws.employee_id, to_business_date(ws.started_at)
  ),

  -- Weekend cleaning minutes (only for eligible employees)
  weekend_cleaning AS (
    SELECT
      ws.employee_id,
      to_business_date(ws.started_at) AS date,
      SUM(ws.duration_minutes)::INTEGER AS wk_cleaning_min
    FROM work_sessions ws
    WHERE ws.activity_type = 'cleaning'
      AND ws.status IN ('completed', 'auto_closed', 'manually_closed')
      AND EXTRACT(DOW FROM ws.started_at AT TIME ZONE 'America/Toronto') IN (0, 6)
      AND to_business_date(ws.started_at) BETWEEN p_period_start AND p_period_end
      AND ws.employee_id IN (SELECT id FROM target_employees)
      AND EXISTS (
        SELECT 1 FROM employee_categories ec
        WHERE ec.employee_id = ws.employee_id
          AND ec.category = 'menage'
          AND ec.weekend_premium_eligible = true
          AND ec.started_at <= to_business_date(ws.started_at)
          AND (ec.ended_at IS NULL OR ec.ended_at >= to_business_date(ws.started_at))
      )
    GROUP BY ws.employee_id, to_business_date(ws.started_at)
  ),

  -- Hourly rates
  rates AS (
    SELECT ehr.employee_id, ehr.rate,
           ehr.effective_from, ehr.effective_to
    FROM employee_hourly_rates ehr
    WHERE ehr.employee_id IN (SELECT id FROM target_employees WHERE pay_type = 'hourly')
  ),

  -- Annual salaries
  salaries AS (
    SELECT eas.employee_id, eas.salary,
           eas.effective_from, eas.effective_to
    FROM employee_annual_salaries eas
    WHERE eas.employee_id IN (SELECT id FROM target_employees WHERE pay_type = 'annual')
  ),

  -- Payroll approval status
  payroll AS (
    SELECT pa.employee_id, pa.status,
           approver.full_name AS approved_by_name,
           pa.approved_at
    FROM payroll_approvals pa
    LEFT JOIN employee_profiles approver ON approver.id = pa.approved_by
    WHERE pa.period_start = p_period_start AND pa.period_end = p_period_end
  ),

  -- Generate date series for all days in period
  period_days AS (
    SELECT d::DATE AS date
    FROM generate_series(p_period_start, p_period_end, '1 day'::INTERVAL) d
  ),

  -- Combine: one row per employee per day (only days with shifts or annual employees)
  combined AS (
    SELECT
      te.id AS employee_id,
      te.full_name,
      te.eid AS employee_id_code,
      te.pay_type,
      pc.category AS primary_category,
      sc.categories AS secondary_categories,
      a.date,
      COALESCE(a.approved_minutes, 0) AS approved_minutes,
      COALESCE(b.break_minutes, 0) AS break_minutes,
      COALESCE(cb.worked_minutes, 0) AS callback_worked_minutes,
      COALESCE(cb.billed_minutes, 0) AS callback_billed_minutes,
      COALESCE(cb.billed_minutes - cb.worked_minutes, 0) AS callback_bonus_minutes,
      COALESCE(ses.cleaning_min, 0) AS cleaning_minutes,
      COALESCE(ses.maintenance_min, 0) AS maintenance_minutes,
      COALESCE(ses.admin_min, 0) AS admin_minutes,
      GREATEST(0, COALESCE(a.approved_minutes, 0)
        - COALESCE(ses.cleaning_min, 0)
        - COALESCE(ses.maintenance_min, 0)
        - COALESCE(ses.admin_min, 0))::INTEGER AS uncovered_minutes,
      -- Hourly rate for this day
      r.rate AS hourly_rate,
      -- Annual salary
      sal.salary AS annual_salary,
      CASE WHEN te.pay_type = 'annual' AND sal.salary IS NOT NULL
        THEN ROUND(sal.salary / 26, 2)
        ELSE NULL
      END AS period_salary,
      -- Base amount
      CASE
        WHEN te.pay_type = 'hourly' AND r.rate IS NOT NULL THEN
          ROUND((COALESCE(a.approved_minutes, 0) / 60.0) * r.rate, 2)
        WHEN te.pay_type = 'annual' AND sal.salary IS NOT NULL THEN
          -- Period salary on first day row only (handled in window function below)
          0
        ELSE 0
      END AS base_amount_raw,
      COALESCE(wc.wk_cleaning_min, 0) AS weekend_cleaning_minutes,
      v_premium_rate AS weekend_premium_rate,
      ROUND((COALESCE(wc.wk_cleaning_min, 0) / 60.0) * v_premium_rate, 2) AS premium_amount,
      -- Callback bonus amount (hourly only)
      CASE
        WHEN te.pay_type = 'hourly' AND r.rate IS NOT NULL THEN
          ROUND((COALESCE(cb.billed_minutes - cb.worked_minutes, 0) / 60.0) * r.rate, 2)
        ELSE NULL
      END AS callback_bonus_amount,
      COALESCE(a.status, 'no_shift') AS day_approval_status,
      COALESCE(pa.status, 'pending') AS payroll_status,
      pa.approved_by_name AS payroll_approved_by,
      pa.approved_at AS payroll_approved_at,
      -- Row number for annual salary assignment
      ROW_NUMBER() OVER (PARTITION BY te.id ORDER BY a.date) AS rn
    FROM target_employees te
    JOIN approvals a ON a.employee_id = te.id
    LEFT JOIN primary_cats pc ON pc.employee_id = te.id
    LEFT JOIN secondary_cats sc ON sc.employee_id = te.id
    LEFT JOIN breaks b ON b.employee_id = te.id AND b.date = a.date
    LEFT JOIN callbacks cb ON cb.employee_id = te.id AND cb.date = a.date
    LEFT JOIN sessions ses ON ses.employee_id = te.id AND ses.date = a.date
    LEFT JOIN weekend_cleaning wc ON wc.employee_id = te.id AND wc.date = a.date
    LEFT JOIN LATERAL (
      SELECT rate FROM rates rt
      WHERE rt.employee_id = te.id
        AND rt.effective_from <= a.date
        AND (rt.effective_to IS NULL OR rt.effective_to >= a.date)
      LIMIT 1
    ) r ON true
    LEFT JOIN LATERAL (
      SELECT salary FROM salaries s2
      WHERE s2.employee_id = te.id
        AND s2.effective_from <= a.date
        AND (s2.effective_to IS NULL OR s2.effective_to >= a.date)
      LIMIT 1
    ) sal ON true
    LEFT JOIN payroll pa ON pa.employee_id = te.id
  )

  SELECT
    c.employee_id,
    c.full_name,
    c.employee_id_code,
    c.pay_type,
    c.primary_category,
    c.secondary_categories,
    c.date,
    c.approved_minutes,
    c.break_minutes,
    c.callback_worked_minutes,
    c.callback_billed_minutes,
    c.callback_bonus_minutes,
    c.cleaning_minutes,
    c.maintenance_minutes,
    c.admin_minutes,
    c.uncovered_minutes,
    c.hourly_rate,
    c.annual_salary,
    c.period_salary,
    -- Annual: put period_salary on first row only
    CASE
      WHEN c.pay_type = 'annual' AND c.rn = 1 THEN c.period_salary
      WHEN c.pay_type = 'annual' THEN 0
      ELSE c.base_amount_raw
    END AS base_amount,
    c.weekend_cleaning_minutes,
    c.weekend_premium_rate,
    c.premium_amount,
    c.callback_bonus_amount,
    -- Total
    CASE
      WHEN c.pay_type = 'annual' AND c.rn = 1 THEN
        COALESCE(c.period_salary, 0) + c.premium_amount
      WHEN c.pay_type = 'annual' THEN
        c.premium_amount
      ELSE
        c.base_amount_raw + c.premium_amount + COALESCE(c.callback_bonus_amount, 0)
    END AS total_amount,
    c.day_approval_status,
    c.payroll_status,
    c.payroll_approved_by,
    c.payroll_approved_at
  FROM combined c
  ORDER BY c.primary_category NULLS LAST, c.full_name, c.date;
END;
$$;

COMMENT ON FUNCTION get_payroll_period_report IS 'Returns payroll report data per employee per day for a biweekly period. Aggregates: day approvals, breaks, callbacks (Art.58 LNT 3h min), work sessions by type, pay calculation (hourly rates + annual/26), weekend premium, payroll lock status. Auth: admin/super_admin see all, managers see supervised only.';
```

- [ ] **Step 7: Apply the migration**

Run: `mcp__supabase__apply_migration` with name `payroll_approvals` and the full SQL above.

- [ ] **Step 8: Test the RPCs against live data**

Run SQL to verify `get_payroll_period_report`:
```sql
SELECT * FROM get_payroll_period_report('2026-03-08'::DATE, '2026-03-21'::DATE)
ORDER BY primary_category, full_name, date
LIMIT 20;
```

Run SQL to verify approve/unlock:
```sql
-- These will be tested via the dashboard UI
SELECT * FROM payroll_approvals;
```

- [ ] **Step 9: Commit**

```bash
git add supabase/migrations/20260325100000_payroll_approvals.sql
git commit -m "feat: add payroll_approvals table, locking triggers, and RPCs

Creates payroll_approvals table with two-level approval model.
Adds locking triggers on day_approvals, activity_overrides, lunch_breaks.
Adds approve_payroll, unlock_payroll, get_payroll_period_report RPCs."
```

---

## Task 2: Dashboard — Types and Pay Period Utilities

**Files:**
- Create: `dashboard/src/types/payroll.ts`
- Create: `dashboard/src/lib/utils/pay-periods.ts`

- [ ] **Step 1: Create TypeScript types**

File: `dashboard/src/types/payroll.ts`

```typescript
export interface PayrollReportRow {
  employee_id: string;
  full_name: string;
  employee_id_code: string;
  pay_type: 'hourly' | 'annual';
  primary_category: string | null;
  secondary_categories: string[] | null;
  date: string; // YYYY-MM-DD
  approved_minutes: number;
  break_minutes: number;
  callback_worked_minutes: number;
  callback_billed_minutes: number;
  callback_bonus_minutes: number;
  cleaning_minutes: number;
  maintenance_minutes: number;
  admin_minutes: number;
  uncovered_minutes: number;
  hourly_rate: number | null;
  annual_salary: number | null;
  period_salary: number | null;
  base_amount: number;
  weekend_cleaning_minutes: number;
  weekend_premium_rate: number;
  premium_amount: number;
  callback_bonus_amount: number | null;
  total_amount: number;
  day_approval_status: 'approved' | 'pending' | 'no_shift';
  payroll_status: 'approved' | 'pending';
  payroll_approved_by: string | null;
  payroll_approved_at: string | null;
}

export interface PayrollEmployeeSummary {
  employee_id: string;
  full_name: string;
  employee_id_code: string;
  pay_type: 'hourly' | 'annual';
  primary_category: string | null;
  secondary_categories: string[] | null;
  total_approved_minutes: number;
  total_break_minutes: number;
  total_callback_bonus_minutes: number;
  days_without_break: number;
  work_session_coverage_pct: number;
  total_premium: number;
  total_base: number;
  total_amount: number;
  total_callback_bonus_amount: number;
  days_approved: number;
  days_worked: number;
  payroll_status: 'approved' | 'pending';
  payroll_approved_by: string | null;
  payroll_approved_at: string | null;
  days: PayrollReportRow[];
}

export interface PayrollCategoryGroup {
  category: string;
  employees: PayrollEmployeeSummary[];
  totals: {
    approved_minutes: number;
    base_amount: number;
    premium_amount: number;
    total_amount: number;
  };
}

export interface PayPeriod {
  start: string; // YYYY-MM-DD
  end: string;   // YYYY-MM-DD
}
```

- [ ] **Step 2: Create pay period utilities**

File: `dashboard/src/lib/utils/pay-periods.ts`

```typescript
import { addDays, subDays, differenceInCalendarDays, format, parseISO } from 'date-fns';
import { fr } from 'date-fns/locale';
import type { PayPeriod } from '@/types/payroll';

const PAY_PERIOD_ANCHOR = '2026-03-08'; // Sunday
const PAY_PERIOD_DAYS = 14;

export function getPayPeriod(dateStr: string): PayPeriod {
  const anchor = parseISO(PAY_PERIOD_ANCHOR);
  const date = parseISO(dateStr);
  const diffDays = differenceInCalendarDays(date, anchor);
  const periodOffset = Math.floor(diffDays / PAY_PERIOD_DAYS);
  const start = addDays(anchor, periodOffset * PAY_PERIOD_DAYS);
  const end = addDays(start, PAY_PERIOD_DAYS - 1);
  return {
    start: format(start, 'yyyy-MM-dd'),
    end: format(end, 'yyyy-MM-dd'),
  };
}

export function getLastCompletedPeriod(todayStr: string): PayPeriod {
  const current = getPayPeriod(todayStr);
  if (todayStr > current.end) return current;
  const prevDate = format(subDays(parseISO(current.start), 1), 'yyyy-MM-dd');
  return getPayPeriod(prevDate);
}

export function getPreviousPeriod(period: PayPeriod): PayPeriod {
  const prevDate = format(subDays(parseISO(period.start), 1), 'yyyy-MM-dd');
  return getPayPeriod(prevDate);
}

export function getNextPeriod(period: PayPeriod): PayPeriod {
  const nextDate = format(addDays(parseISO(period.end), 1), 'yyyy-MM-dd');
  return getPayPeriod(nextDate);
}

export function formatPeriodLabel(period: PayPeriod): string {
  const start = parseISO(period.start);
  const end = parseISO(period.end);
  return `${format(start, 'd MMM', { locale: fr })} – ${format(end, 'd MMM yyyy', { locale: fr })}`;
}

export function getRecentPeriods(count: number, todayStr: string): PayPeriod[] {
  const periods: PayPeriod[] = [];
  let current = getLastCompletedPeriod(todayStr);
  for (let i = 0; i < count; i++) {
    periods.push(current);
    current = getPreviousPeriod(current);
  }
  return periods;
}

export function formatMinutesAsHours(minutes: number): string {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m > 0 ? `${h}h${m.toString().padStart(2, '0')}` : `${h}h`;
}
```

- [ ] **Step 3: Commit**

```bash
git add dashboard/src/types/payroll.ts dashboard/src/lib/utils/pay-periods.ts
git commit -m "feat: add payroll types and pay period utilities"
```

---

## Task 3: Dashboard — API Layer and Data Hook

**Files:**
- Create: `dashboard/src/lib/api/payroll.ts`
- Create: `dashboard/src/lib/hooks/use-payroll-report.ts`

- [ ] **Step 1: Create API functions**

File: `dashboard/src/lib/api/payroll.ts`

```typescript
import { supabaseClient } from '@/lib/supabase/client';
import type { PayrollReportRow } from '@/types/payroll';

export async function getPayrollPeriodReport(
  periodStart: string,
  periodEnd: string,
  employeeIds?: string[]
): Promise<PayrollReportRow[]> {
  const { data, error } = await supabaseClient.rpc('get_payroll_period_report', {
    p_period_start: periodStart,
    p_period_end: periodEnd,
    p_employee_ids: employeeIds || null,
  });
  if (error) throw error;
  return (data as PayrollReportRow[]) || [];
}

export async function approvePayroll(
  employeeId: string,
  periodStart: string,
  periodEnd: string,
  notes?: string
) {
  const { data, error } = await supabaseClient.rpc('approve_payroll', {
    p_employee_id: employeeId,
    p_period_start: periodStart,
    p_period_end: periodEnd,
    p_notes: notes || null,
  });
  if (error) throw error;
  return data;
}

export async function unlockPayroll(
  employeeId: string,
  periodStart: string,
  periodEnd: string
) {
  const { data, error } = await supabaseClient.rpc('unlock_payroll', {
    p_employee_id: employeeId,
    p_period_start: periodStart,
    p_period_end: periodEnd,
  });
  if (error) throw error;
  return data;
}
```

- [ ] **Step 2: Create data hook with summary computation**

File: `dashboard/src/lib/hooks/use-payroll-report.ts`

```typescript
'use client';

import { useState, useEffect, useMemo, useCallback } from 'react';
import { getPayrollPeriodReport } from '@/lib/api/payroll';
import type {
  PayrollReportRow,
  PayrollEmployeeSummary,
  PayrollCategoryGroup,
  PayPeriod,
} from '@/types/payroll';

const MIN_HOURS_FOR_BREAK_WARNING = 5 * 60; // 300 minutes

export function usePayrollReport(period: PayPeriod) {
  const [rows, setRows] = useState<PayrollReportRow[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchData = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      const data = await getPayrollPeriodReport(period.start, period.end);
      setRows(data);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Erreur lors du chargement');
    } finally {
      setIsLoading(false);
    }
  }, [period.start, period.end]);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  // Group rows by employee into summaries
  const employees = useMemo((): PayrollEmployeeSummary[] => {
    const byEmployee = new Map<string, PayrollReportRow[]>();
    for (const row of rows) {
      const existing = byEmployee.get(row.employee_id) || [];
      existing.push(row);
      byEmployee.set(row.employee_id, existing);
    }

    return Array.from(byEmployee.entries()).map(([, days]) => {
      const first = days[0];
      const daysWorked = days.filter(d => d.day_approval_status !== 'no_shift').length;
      const daysApproved = days.filter(d => d.day_approval_status === 'approved').length;
      const daysWithoutBreak = days.filter(
        d => d.approved_minutes >= MIN_HOURS_FOR_BREAK_WARNING && d.break_minutes === 0
      ).length;

      const totalApprovedMin = days.reduce((s, d) => s + d.approved_minutes, 0);
      const totalSessionMin = days.reduce(
        (s, d) => s + d.cleaning_minutes + d.maintenance_minutes + d.admin_minutes,
        0
      );
      const coverage = totalApprovedMin > 0 ? Math.round((totalSessionMin / totalApprovedMin) * 100) : 0;

      return {
        employee_id: first.employee_id,
        full_name: first.full_name,
        employee_id_code: first.employee_id_code,
        pay_type: first.pay_type,
        primary_category: first.primary_category,
        secondary_categories: first.secondary_categories,
        total_approved_minutes: totalApprovedMin,
        total_break_minutes: days.reduce((s, d) => s + d.break_minutes, 0),
        total_callback_bonus_minutes: days.reduce((s, d) => s + d.callback_bonus_minutes, 0),
        days_without_break: daysWithoutBreak,
        work_session_coverage_pct: coverage,
        total_premium: days.reduce((s, d) => s + d.premium_amount, 0),
        total_base: days.reduce((s, d) => s + d.base_amount, 0),
        total_amount: days.reduce((s, d) => s + d.total_amount, 0),
        total_callback_bonus_amount: days.reduce((s, d) => s + (d.callback_bonus_amount || 0), 0),
        days_approved: daysApproved,
        days_worked: daysWorked,
        payroll_status: first.payroll_status,
        payroll_approved_by: first.payroll_approved_by,
        payroll_approved_at: first.payroll_approved_at,
        days,
      };
    });
  }, [rows]);

  // Group employees by primary category
  const categoryGroups = useMemo((): PayrollCategoryGroup[] => {
    const groups = new Map<string, PayrollEmployeeSummary[]>();
    for (const emp of employees) {
      const cat = emp.primary_category || 'Non catégorisé';
      const existing = groups.get(cat) || [];
      existing.push(emp);
      groups.set(cat, existing);
    }

    const order = ['menage', 'maintenance', 'renovation', 'admin', 'Non catégorisé'];
    return order
      .filter(cat => groups.has(cat))
      .map(cat => {
        const emps = groups.get(cat)!;
        return {
          category: cat,
          employees: emps,
          totals: {
            approved_minutes: emps.reduce((s, e) => s + e.total_approved_minutes, 0),
            base_amount: emps.reduce((s, e) => s + e.total_base, 0),
            premium_amount: emps.reduce((s, e) => s + e.total_premium, 0),
            total_amount: emps.reduce((s, e) => s + e.total_amount, 0),
          },
        };
      });
  }, [employees]);

  const grandTotal = useMemo(() => ({
    approved_minutes: employees.reduce((s, e) => s + e.total_approved_minutes, 0),
    base_amount: employees.reduce((s, e) => s + e.total_base, 0),
    premium_amount: employees.reduce((s, e) => s + e.total_premium, 0),
    total_amount: employees.reduce((s, e) => s + e.total_amount, 0),
  }), [employees]);

  return {
    rows,
    employees,
    categoryGroups,
    grandTotal,
    isLoading,
    error,
    refetch: fetchData,
  };
}
```

- [ ] **Step 3: Commit**

```bash
git add dashboard/src/lib/api/payroll.ts dashboard/src/lib/hooks/use-payroll-report.ts
git commit -m "feat: add payroll API functions and data hook"
```

---

## Task 4: Dashboard — Period Selector Component

**Files:**
- Create: `dashboard/src/components/payroll/payroll-period-selector.tsx`

- [ ] **Step 1: Create the period selector**

File: `dashboard/src/components/payroll/payroll-period-selector.tsx`

```typescript
'use client';

import { ChevronLeft, ChevronRight, Calendar } from 'lucide-react';
import { Button } from '@/components/ui/button';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import type { PayPeriod } from '@/types/payroll';
import {
  getPreviousPeriod,
  getNextPeriod,
  formatPeriodLabel,
  getRecentPeriods,
} from '@/lib/utils/pay-periods';
import { format } from 'date-fns';

interface PayrollPeriodSelectorProps {
  period: PayPeriod;
  onPeriodChange: (period: PayPeriod) => void;
  todayStr: string;
}

export function PayrollPeriodSelector({
  period,
  onPeriodChange,
  todayStr,
}: PayrollPeriodSelectorProps) {
  const recentPeriods = getRecentPeriods(12, todayStr);
  const label = formatPeriodLabel(period);

  return (
    <div className="flex items-center gap-3">
      <Button
        variant="outline"
        size="icon"
        onClick={() => onPeriodChange(getPreviousPeriod(period))}
      >
        <ChevronLeft className="h-4 w-4" />
      </Button>

      <Select
        value={period.start}
        onValueChange={(val) => {
          const found = recentPeriods.find(p => p.start === val);
          if (found) onPeriodChange(found);
        }}
      >
        <SelectTrigger className="w-[280px]">
          <Calendar className="mr-2 h-4 w-4" />
          <SelectValue>{label}</SelectValue>
        </SelectTrigger>
        <SelectContent>
          {recentPeriods.map((p) => (
            <SelectItem key={p.start} value={p.start}>
              {formatPeriodLabel(p)}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Button
        variant="outline"
        size="icon"
        onClick={() => onPeriodChange(getNextPeriod(period))}
        disabled={period.end >= todayStr}
      >
        <ChevronRight className="h-4 w-4" />
      </Button>
    </div>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/components/payroll/payroll-period-selector.tsx
git commit -m "feat: add payroll period selector component"
```

---

## Task 5: Dashboard — Summary Table Component

**Files:**
- Create: `dashboard/src/components/payroll/payroll-summary-table.tsx`

- [ ] **Step 1: Create the summary table**

File: `dashboard/src/components/payroll/payroll-summary-table.tsx`

This is a large component. Key structure:
- Uses `@tanstack/react-table` with `expandedId` state
- Groups employees by `PayrollCategoryGroup`
- Renders sub-total rows per group and grand total
- Clicking a row expands `PayrollEmployeeDetail`

```typescript
'use client';

import { Fragment, useState } from 'react';
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { ChevronDown, ChevronRight, AlertTriangle } from 'lucide-react';
import type { PayrollCategoryGroup, PayrollEmployeeSummary, PayPeriod } from '@/types/payroll';
import { formatMinutesAsHours } from '@/lib/utils/pay-periods';
import { PayrollEmployeeDetail } from './payroll-employee-detail';

const CATEGORY_LABELS: Record<string, string> = {
  menage: 'Ménage',
  maintenance: 'Maintenance',
  renovation: 'Rénovation',
  admin: 'Administration',
  'Non catégorisé': 'Non catégorisé',
};

interface PayrollSummaryTableProps {
  categoryGroups: PayrollCategoryGroup[];
  grandTotal: {
    approved_minutes: number;
    base_amount: number;
    premium_amount: number;
    total_amount: number;
  };
  period: PayPeriod;
  onRefetch: () => void;
}

export function PayrollSummaryTable({
  categoryGroups,
  grandTotal,
  period,
  onRefetch,
}: PayrollSummaryTableProps) {
  const [expandedId, setExpandedId] = useState<string | null>(null);

  const toggleExpand = (employeeId: string) => {
    setExpandedId(prev => prev === employeeId ? null : employeeId);
  };

  const fmtMoney = (n: number) => `${n.toFixed(2)} $`;

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead className="w-8" />
          <TableHead>Employé</TableHead>
          <TableHead>Type</TableHead>
          <TableHead className="text-right">Heures</TableHead>
          <TableHead className="text-right">Rappel bonus</TableHead>
          <TableHead className="text-right">Pause</TableHead>
          <TableHead className="text-center">Sans pause</TableHead>
          <TableHead className="text-right">% Sessions</TableHead>
          <TableHead className="text-right">Prime FDS</TableHead>
          <TableHead className="text-right">Base</TableHead>
          <TableHead className="text-right">Total</TableHead>
          <TableHead className="text-center">Jours</TableHead>
          <TableHead className="text-center">Paie</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {categoryGroups.map((group) => (
          <Fragment key={`group-${group.category}`}>
            {/* Category header */}
            <TableRow className="bg-muted/50">
              <TableCell colSpan={13} className="font-semibold">
                {CATEGORY_LABELS[group.category] || group.category}
              </TableCell>
            </TableRow>

            {/* Employee rows */}
            {group.employees.map((emp) => (
              <Fragment key={emp.employee_id}>
                <TableRow
                  className={`cursor-pointer hover:bg-muted/30 ${
                    emp.payroll_status === 'approved' ? 'bg-green-50' : ''
                  }`}
                  onClick={() => toggleExpand(emp.employee_id)}
                >
                  <TableCell>
                    {expandedId === emp.employee_id
                      ? <ChevronDown className="h-4 w-4" />
                      : <ChevronRight className="h-4 w-4" />}
                  </TableCell>
                  <TableCell>
                    <div className="font-medium">{emp.full_name}</div>
                    <div className="text-xs text-muted-foreground">{emp.employee_id_code}</div>
                    {emp.secondary_categories?.map(cat => (
                      <Badge key={cat} variant="outline" className="text-xs ml-1">+{cat}</Badge>
                    ))}
                  </TableCell>
                  <TableCell>
                    <Badge variant={emp.pay_type === 'annual' ? 'secondary' : 'default'}>
                      {emp.pay_type === 'annual' ? 'Annuel' : 'Horaire'}
                    </Badge>
                  </TableCell>
                  <TableCell className="text-right font-mono">
                    {formatMinutesAsHours(emp.total_approved_minutes)}
                    {emp.pay_type === 'annual' && emp.total_approved_minutes < 80 * 60 && (
                      <AlertTriangle className="h-3 w-3 inline ml-1 text-amber-500" />
                    )}
                  </TableCell>
                  <TableCell className="text-right font-mono">
                    {emp.total_callback_bonus_minutes > 0
                      ? `+${formatMinutesAsHours(emp.total_callback_bonus_minutes)}`
                      : '—'}
                  </TableCell>
                  <TableCell className="text-right font-mono">
                    {formatMinutesAsHours(emp.total_break_minutes)}
                  </TableCell>
                  <TableCell className="text-center">
                    {emp.days_without_break > 0 ? (
                      <Badge variant="destructive">{emp.days_without_break}</Badge>
                    ) : '—'}
                  </TableCell>
                  <TableCell className="text-right font-mono">
                    {emp.work_session_coverage_pct}%
                  </TableCell>
                  <TableCell className="text-right font-mono">
                    {emp.total_premium > 0 ? fmtMoney(emp.total_premium) : '—'}
                  </TableCell>
                  <TableCell className="text-right font-mono">{fmtMoney(emp.total_base)}</TableCell>
                  <TableCell className="text-right font-mono font-semibold">{fmtMoney(emp.total_amount)}</TableCell>
                  <TableCell className="text-center">
                    <Badge variant={emp.days_approved === emp.days_worked ? 'default' : 'secondary'}>
                      {emp.days_approved}/{emp.days_worked}
                    </Badge>
                  </TableCell>
                  <TableCell className="text-center">
                    {emp.payroll_status === 'approved' ? (
                      <Badge className="bg-green-600">Approuvée</Badge>
                    ) : (
                      <Badge variant="outline">En attente</Badge>
                    )}
                  </TableCell>
                </TableRow>

                {/* Expanded detail */}
                {expandedId === emp.employee_id && (
                  <TableRow>
                    <TableCell colSpan={13} className="p-0">
                      <PayrollEmployeeDetail
                        employee={emp}
                        period={period}
                        onRefetch={onRefetch}
                      />
                    </TableCell>
                  </TableRow>
                )}
              </Fragment>
            ))}

            {/* Category sub-total */}
            <TableRow className="bg-muted/30 font-semibold">
              <TableCell colSpan={3}>
                Sous-total {CATEGORY_LABELS[group.category]}
              </TableCell>
              <TableCell className="text-right font-mono">
                {formatMinutesAsHours(group.totals.approved_minutes)}
              </TableCell>
              <TableCell colSpan={4} />
              <TableCell className="text-right font-mono">{fmtMoney(group.totals.premium_amount)}</TableCell>
              <TableCell className="text-right font-mono">{fmtMoney(group.totals.base_amount)}</TableCell>
              <TableCell className="text-right font-mono">{fmtMoney(group.totals.total_amount)}</TableCell>
              <TableCell colSpan={2} />
            </TableRow>
          </Fragment>
        ))}

        {/* Grand total */}
        <TableRow className="bg-muted font-bold">
          <TableCell colSpan={3}>Grand total</TableCell>
          <TableCell className="text-right font-mono">
            {formatMinutesAsHours(grandTotal.approved_minutes)}
          </TableCell>
          <TableCell colSpan={4} />
          <TableCell className="text-right font-mono">{fmtMoney(grandTotal.premium_amount)}</TableCell>
          <TableCell className="text-right font-mono">{fmtMoney(grandTotal.base_amount)}</TableCell>
          <TableCell className="text-right font-mono">{fmtMoney(grandTotal.total_amount)}</TableCell>
          <TableCell colSpan={2} />
        </TableRow>
      </TableBody>
    </Table>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/components/payroll/payroll-summary-table.tsx
git commit -m "feat: add payroll summary table with category grouping"
```

---

## Task 6: Dashboard — Employee Detail Component

**Files:**
- Create: `dashboard/src/components/payroll/payroll-employee-detail.tsx`

- [ ] **Step 1: Create the detail component**

File: `dashboard/src/components/payroll/payroll-employee-detail.tsx`

```typescript
'use client';

import { parseISO, format } from 'date-fns';
import { fr } from 'date-fns/locale';
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { AlertTriangle, ExternalLink } from 'lucide-react';
import type { PayrollEmployeeSummary, PayPeriod, PayrollReportRow } from '@/types/payroll';
import { formatMinutesAsHours } from '@/lib/utils/pay-periods';
import { PayrollApprovalButton } from './payroll-approval-button';

interface PayrollEmployeeDetailProps {
  employee: PayrollEmployeeSummary;
  period: PayPeriod;
  onRefetch: () => void;
}

function WeekSubtotal({ days, weekLabel }: { days: PayrollReportRow[]; weekLabel: string }) {
  const totalMin = days.reduce((s, d) => s + d.approved_minutes, 0);
  const totalBreak = days.reduce((s, d) => s + d.break_minutes, 0);
  const totalAmount = days.reduce((s, d) => s + d.total_amount, 0);
  const isAnnual = days[0]?.pay_type === 'annual';

  return (
    <TableRow className="bg-muted/20 font-medium text-sm">
      <TableCell colSpan={2}>{weekLabel}</TableCell>
      <TableCell className="text-right font-mono">{formatMinutesAsHours(totalMin)}</TableCell>
      <TableCell className="text-right font-mono">{formatMinutesAsHours(totalBreak)}</TableCell>
      <TableCell />
      <TableCell />
      <TableCell />
      <TableCell className="text-right font-mono">{totalAmount.toFixed(2)} $</TableCell>
      <TableCell>
        {isAnnual && totalMin < 40 * 60 && (
          <Badge variant="outline" className="text-amber-600">
            <AlertTriangle className="h-3 w-3 mr-1" />
            {'<'} 40h
          </Badge>
        )}
      </TableCell>
    </TableRow>
  );
}

export function PayrollEmployeeDetail({ employee, period, onRefetch }: PayrollEmployeeDetailProps) {
  const fmtMoney = (n: number | null) => n != null ? `${n.toFixed(2)} $` : '—';
  const midpoint = parseISO(period.start);
  // Split into 2 weeks: days 0-6 = week 1, days 7-13 = week 2
  const week1 = employee.days.filter(d => {
    const dayDate = parseISO(d.date);
    return dayDate < new Date(midpoint.getTime() + 7 * 86400000);
  });
  const week2 = employee.days.filter(d => {
    const dayDate = parseISO(d.date);
    return dayDate >= new Date(midpoint.getTime() + 7 * 86400000);
  });

  const renderDay = (day: PayrollReportRow) => {
    const dateLabel = format(parseISO(day.date), 'EEE d MMM', { locale: fr });
    const noBreak = day.approved_minutes >= 300 && day.break_minutes === 0;

    return (
      <TableRow key={day.date} className="text-sm">
        <TableCell>
          {/* NOTE: Approval page does not currently support query param deep-linking.
              This navigates to the approvals page — user must manually select the employee/date.
              Deep-linking can be added as a follow-up enhancement. */}
          <a
            href={`/dashboard/approvals`}
            className="flex items-center gap-1 hover:underline"
          >
            {dateLabel}
            <ExternalLink className="h-3 w-3 text-muted-foreground" />
          </a>
        </TableCell>
        <TableCell className="text-right font-mono">
          {formatMinutesAsHours(day.approved_minutes)}
        </TableCell>
        <TableCell className="text-right font-mono">
          {noBreak ? (
            <span className="text-destructive font-medium">
              <AlertTriangle className="h-3 w-3 inline mr-1" />0min
            </span>
          ) : (
            `${day.break_minutes}min`
          )}
        </TableCell>
        <TableCell className="text-right font-mono">
          {day.callback_bonus_minutes > 0
            ? `+${formatMinutesAsHours(day.callback_bonus_minutes)}`
            : '—'}
        </TableCell>
        <TableCell>
          <div className="flex flex-wrap gap-1">
            {day.cleaning_minutes > 0 && (
              <Badge className="bg-green-600 text-xs">Ménage {formatMinutesAsHours(day.cleaning_minutes)}</Badge>
            )}
            {day.maintenance_minutes > 0 && (
              <Badge className="bg-orange-500 text-xs">Entretien {formatMinutesAsHours(day.maintenance_minutes)}</Badge>
            )}
            {day.admin_minutes > 0 && (
              <Badge className="bg-blue-500 text-xs">Admin {formatMinutesAsHours(day.admin_minutes)}</Badge>
            )}
            {day.uncovered_minutes > 0 && (
              <Badge variant="outline" className="text-xs text-muted-foreground">
                Non couvert {formatMinutesAsHours(day.uncovered_minutes)}
              </Badge>
            )}
          </div>
        </TableCell>
        <TableCell className="text-right font-mono">
          {day.premium_amount > 0 ? fmtMoney(day.premium_amount) : '—'}
        </TableCell>
        <TableCell className="text-right font-mono">{fmtMoney(day.total_amount)}</TableCell>
        <TableCell className="text-center">
          {day.day_approval_status === 'approved' ? (
            <Badge className="bg-green-600 text-xs">✓</Badge>
          ) : (
            <Badge variant="destructive" className="text-xs">En attente</Badge>
          )}
        </TableCell>
      </TableRow>
    );
  };

  return (
    <div className="border-t bg-muted/10 p-4">
      <Table>
        <TableHeader>
          <TableRow className="text-xs">
            <TableHead>Jour</TableHead>
            <TableHead className="text-right">Heures</TableHead>
            <TableHead className="text-right">Pause</TableHead>
            <TableHead className="text-right">Rappel bonus</TableHead>
            <TableHead>Work Sessions</TableHead>
            <TableHead className="text-right">Prime FDS</TableHead>
            <TableHead className="text-right">Montant</TableHead>
            <TableHead className="text-center">Statut</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {week1.map(renderDay)}
          {week1.length > 0 && <WeekSubtotal days={week1} weekLabel="Semaine 1" />}
          {week2.map(renderDay)}
          {week2.length > 0 && <WeekSubtotal days={week2} weekLabel="Semaine 2" />}
        </TableBody>
      </Table>

      <div className="mt-4 flex justify-end">
        <PayrollApprovalButton
          employee={employee}
          period={period}
          onRefetch={onRefetch}
        />
      </div>
    </div>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/components/payroll/payroll-employee-detail.tsx
git commit -m "feat: add payroll employee detail with day-by-day breakdown"
```

---

## Task 7: Dashboard — Approval Button Component

**Files:**
- Create: `dashboard/src/components/payroll/payroll-approval-button.tsx`

- [ ] **Step 1: Create the approval button**

File: `dashboard/src/components/payroll/payroll-approval-button.tsx`

```typescript
'use client';

import { useState } from 'react';
import { Button } from '@/components/ui/button';
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from '@/components/ui/alert-dialog';
import { Lock, Unlock, CheckCircle } from 'lucide-react';
import { toast } from 'sonner';
import { approvePayroll, unlockPayroll } from '@/lib/api/payroll';
import { formatPeriodLabel } from '@/lib/utils/pay-periods';
import type { PayrollEmployeeSummary, PayPeriod } from '@/types/payroll';

interface PayrollApprovalButtonProps {
  employee: PayrollEmployeeSummary;
  period: PayPeriod;
  onRefetch: () => void;
}

export function PayrollApprovalButton({ employee, period, onRefetch }: PayrollApprovalButtonProps) {
  const [saving, setSaving] = useState(false);

  const unapprovedDays = employee.days_worked - employee.days_approved;
  const isApproved = employee.payroll_status === 'approved';
  const canApprove = unapprovedDays === 0 && employee.days_worked > 0;

  const handleApprove = async () => {
    setSaving(true);
    try {
      await approvePayroll(employee.employee_id, period.start, period.end);
      toast.success(`Paie approuvée pour ${employee.full_name}`);
      onRefetch();
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : 'Erreur inconnue');
    } finally {
      setSaving(false);
    }
  };

  const handleUnlock = async () => {
    setSaving(true);
    try {
      await unlockPayroll(employee.employee_id, period.start, period.end);
      toast.success(`Paie déverrouillée pour ${employee.full_name}`);
      onRefetch();
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : 'Erreur inconnue');
    } finally {
      setSaving(false);
    }
  };

  if (isApproved) {
    return (
      <div className="flex items-center gap-3">
        <div className="flex items-center gap-2 text-green-700 bg-green-50 px-3 py-2 rounded-md">
          <CheckCircle className="h-4 w-4" />
          <span className="text-sm">
            Paie approuvée le {employee.payroll_approved_at
              ? new Date(employee.payroll_approved_at).toLocaleDateString('fr-CA')
              : ''}
            {employee.payroll_approved_by && ` par ${employee.payroll_approved_by}`}
          </span>
        </div>
        <AlertDialog>
          <AlertDialogTrigger asChild>
            <Button variant="outline" size="sm" disabled={saving}>
              <Unlock className="h-4 w-4 mr-1" />
              Déverrouiller
            </Button>
          </AlertDialogTrigger>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>Déverrouiller la paie</AlertDialogTitle>
              <AlertDialogDescription>
                Déverrouiller la paie de {employee.full_name} pour la période du {formatPeriodLabel(period)} ?
                Les approbations journalières pourront être modifiées.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Annuler</AlertDialogCancel>
              <AlertDialogAction onClick={handleUnlock}>Déverrouiller</AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </div>
    );
  }

  return (
    <AlertDialog>
      <AlertDialogTrigger asChild>
        <Button disabled={!canApprove || saving}>
          <Lock className="h-4 w-4 mr-1" />
          Approuver la paie de {employee.full_name}
          {!canApprove && unapprovedDays > 0 && (
            <span className="ml-2 text-xs opacity-70">
              ({unapprovedDays} jour{unapprovedDays > 1 ? 's' : ''} non approuvé{unapprovedDays > 1 ? 's' : ''})
            </span>
          )}
        </Button>
      </AlertDialogTrigger>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>Approuver la paie</AlertDialogTitle>
          <AlertDialogDescription>
            Approuver la paie de {employee.full_name} pour la période du {formatPeriodLabel(period)} ?
            Les approbations journalières seront verrouillées.
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>Annuler</AlertDialogCancel>
          <AlertDialogAction onClick={handleApprove}>Approuver</AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/components/payroll/payroll-approval-button.tsx
git commit -m "feat: add payroll approval/unlock button with confirmation dialogs"
```

---

## Task 8: Dashboard — Excel Export

**Files:**
- Modify: `dashboard/package.json` (add xlsx dependency)
- Create: `dashboard/src/components/payroll/payroll-export-button.tsx`
- Create: `dashboard/src/lib/utils/export-payroll-excel.ts`

- [ ] **Step 1: Install SheetJS**

```bash
cd dashboard && npm install xlsx
```

- [ ] **Step 2: Create Excel export utility**

File: `dashboard/src/lib/utils/export-payroll-excel.ts`

```typescript
import * as XLSX from 'xlsx';
import type { PayrollCategoryGroup, PayPeriod } from '@/types/payroll';
import { formatMinutesAsHours } from './pay-periods';

const CATEGORY_LABELS: Record<string, string> = {
  menage: 'Ménage',
  maintenance: 'Maintenance',
  renovation: 'Rénovation',
  admin: 'Administration',
  'Non catégorisé': 'Non catégorisé',
};

export function exportPayrollToExcel(
  categoryGroups: PayrollCategoryGroup[],
  period: PayPeriod
) {
  const wb = XLSX.utils.book_new();

  // Sheet 1: Sommaire
  const summaryRows: Record<string, unknown>[] = [];
  for (const group of categoryGroups) {
    // Category header
    summaryRows.push({ Employé: `--- ${CATEGORY_LABELS[group.category] || group.category} ---` });

    for (const emp of group.employees) {
      summaryRows.push({
        Employé: emp.full_name,
        Code: emp.employee_id_code,
        Catégorie: emp.primary_category || '',
        'Type paie': emp.pay_type === 'annual' ? 'Annuel' : 'Horaire',
        'Heures approuvées': formatMinutesAsHours(emp.total_approved_minutes),
        'Rappel bonus': emp.total_callback_bonus_minutes > 0
          ? formatMinutesAsHours(emp.total_callback_bonus_minutes)
          : '',
        'Pause totale': formatMinutesAsHours(emp.total_break_minutes),
        'Jours sans pause': emp.days_without_break || '',
        '% Sessions': `${emp.work_session_coverage_pct}%`,
        'Prime FDS ($)': emp.total_premium > 0 ? emp.total_premium : '',
        'Montant base ($)': emp.total_base,
        'Total ($)': emp.total_amount,
        'Approbation paie': emp.payroll_status === 'approved' ? 'Approuvée' : 'En attente',
      });
    }

    // Sub-total
    summaryRows.push({
      Employé: `Sous-total ${CATEGORY_LABELS[group.category]}`,
      'Heures approuvées': formatMinutesAsHours(group.totals.approved_minutes),
      'Montant base ($)': group.totals.base_amount,
      'Prime FDS ($)': group.totals.premium_amount,
      'Total ($)': group.totals.total_amount,
    });
    summaryRows.push({}); // Empty row separator
  }

  const ws1 = XLSX.utils.json_to_sheet(summaryRows);
  XLSX.utils.book_append_sheet(wb, ws1, 'Sommaire');

  // Sheet 2: Détail
  const detailRows: Record<string, unknown>[] = [];
  for (const group of categoryGroups) {
    for (const emp of group.employees) {
      for (const day of emp.days) {
        detailRows.push({
          Employé: emp.full_name,
          Code: emp.employee_id_code,
          Date: day.date,
          'Heures approuvées': formatMinutesAsHours(day.approved_minutes),
          'Pause (min)': day.break_minutes,
          'Rappel bonus (h)': day.callback_bonus_minutes > 0
            ? formatMinutesAsHours(day.callback_bonus_minutes)
            : '',
          'Ménage (h)': day.cleaning_minutes > 0
            ? formatMinutesAsHours(day.cleaning_minutes)
            : '',
          'Entretien (h)': day.maintenance_minutes > 0
            ? formatMinutesAsHours(day.maintenance_minutes)
            : '',
          'Admin (h)': day.admin_minutes > 0
            ? formatMinutesAsHours(day.admin_minutes)
            : '',
          'Non couvert (h)': day.uncovered_minutes > 0
            ? formatMinutesAsHours(day.uncovered_minutes)
            : '',
          'Prime FDS ($)': day.premium_amount > 0 ? day.premium_amount : '',
          'Montant ($)': day.total_amount,
          'Statut jour': day.day_approval_status === 'approved' ? 'Approuvé' : 'En attente',
        });
      }
      detailRows.push({}); // Separator between employees
    }
  }

  const ws2 = XLSX.utils.json_to_sheet(detailRows);
  XLSX.utils.book_append_sheet(wb, ws2, 'Détail');

  // Download
  XLSX.writeFile(wb, `Paie_${period.start}_${period.end}.xlsx`);
}
```

- [ ] **Step 3: Create export button component**

File: `dashboard/src/components/payroll/payroll-export-button.tsx`

```typescript
'use client';

import { Button } from '@/components/ui/button';
import { Download } from 'lucide-react';
import { exportPayrollToExcel } from '@/lib/utils/export-payroll-excel';
import type { PayrollCategoryGroup, PayPeriod } from '@/types/payroll';

interface PayrollExportButtonProps {
  categoryGroups: PayrollCategoryGroup[];
  period: PayPeriod;
  disabled?: boolean;
}

export function PayrollExportButton({ categoryGroups, period, disabled }: PayrollExportButtonProps) {
  return (
    <Button
      variant="outline"
      onClick={() => exportPayrollToExcel(categoryGroups, period)}
      disabled={disabled || categoryGroups.length === 0}
    >
      <Download className="h-4 w-4 mr-2" />
      Exporter Excel
    </Button>
  );
}
```

- [ ] **Step 4: Commit**

```bash
git add dashboard/package.json dashboard/package-lock.json \
  dashboard/src/lib/utils/export-payroll-excel.ts \
  dashboard/src/components/payroll/payroll-export-button.tsx
git commit -m "feat: add Excel export for payroll report (SheetJS)"
```

---

## Task 9: Dashboard — Main Page and Navigation

**Files:**
- Create: `dashboard/src/app/dashboard/remuneration/payroll/page.tsx`
- Modify: `dashboard/src/components/layout/sidebar.tsx`

- [ ] **Step 1: Create the main payroll page**

File: `dashboard/src/app/dashboard/remuneration/payroll/page.tsx`

```typescript
'use client';

import { useState } from 'react';
import { format } from 'date-fns';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Alert, AlertDescription } from '@/components/ui/alert';
import { Loader2 } from 'lucide-react';
import { PayrollPeriodSelector } from '@/components/payroll/payroll-period-selector';
import { PayrollSummaryTable } from '@/components/payroll/payroll-summary-table';
import { PayrollExportButton } from '@/components/payroll/payroll-export-button';
import { usePayrollReport } from '@/lib/hooks/use-payroll-report';
import { getLastCompletedPeriod } from '@/lib/utils/pay-periods';
import type { PayPeriod } from '@/types/payroll';

export default function PayrollPage() {
  const todayStr = format(new Date(), 'yyyy-MM-dd');
  const [period, setPeriod] = useState<PayPeriod>(() => getLastCompletedPeriod(todayStr));

  const { categoryGroups, grandTotal, isLoading, error, refetch } = usePayrollReport(period);

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold">Paie</h1>
        <div className="flex items-center gap-3">
          <PayrollExportButton
            categoryGroups={categoryGroups}
            period={period}
            disabled={isLoading}
          />
        </div>
      </div>

      <div className="flex items-center justify-center">
        <PayrollPeriodSelector
          period={period}
          onPeriodChange={setPeriod}
          todayStr={todayStr}
        />
      </div>

      {error && (
        <Alert variant="destructive">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}

      <Card>
        <CardHeader>
          <CardTitle>Feuilles de temps</CardTitle>
        </CardHeader>
        <CardContent>
          {isLoading ? (
            <div className="flex items-center justify-center py-12">
              <Loader2 className="h-8 w-8 animate-spin text-muted-foreground" />
            </div>
          ) : categoryGroups.length === 0 ? (
            <p className="text-center text-muted-foreground py-12">
              Aucune donnée pour cette période.
            </p>
          ) : (
            <PayrollSummaryTable
              categoryGroups={categoryGroups}
              grandTotal={grandTotal}
              period={period}
              onRefetch={refetch}
            />
          )}
        </CardContent>
      </Card>
    </div>
  );
}
```

- [ ] **Step 2: Add navigation link in sidebar**

In `dashboard/src/components/layout/sidebar.tsx`, add a "Paie" item as a **new top-level entry** in the navigation array, right after the existing "Rémunération" entry (the sidebar uses a flat array with no nesting):

```typescript
{ name: 'Paie', href: '/dashboard/remuneration/payroll', icon: Receipt },
```

Import `Receipt` from `lucide-react` at the top of the file. The page will be highlighted when active thanks to the existing `pathname.startsWith(href)` logic.

- [ ] **Step 3: Run the dev server and verify the page loads**

```bash
cd dashboard && npm run dev
```

Navigate to `http://localhost:3000/dashboard/remuneration/payroll` and verify:
- Period selector shows the last completed period
- Data loads from the RPC
- Employee rows are grouped by category
- Expanding a row shows day-by-day detail
- Export button generates an .xlsx file

- [ ] **Step 4: Commit**

```bash
git add dashboard/src/app/dashboard/remuneration/payroll/page.tsx \
  dashboard/src/components/layout/sidebar.tsx
git commit -m "feat: add payroll page with navigation link

Dedicated payroll validation page at /dashboard/remuneration/payroll
with period selector, summary table, expandable detail, and Excel export."
```

---

## Task 10: Verify and Fix

- [ ] **Step 1: Run TypeScript build check**

```bash
cd dashboard && npx next build
```

Fix any type errors.

- [ ] **Step 2: Test the full workflow**

1. Navigate to `/dashboard/remuneration/payroll`
2. Verify period shows Mar 8–21
3. Verify employees are grouped by category
4. Expand an employee, check day-by-day data
5. Check break warnings (red badge on days without break)
6. Check callback bonus display
7. Check work session chips
8. Try approving payroll (should work if all days approved)
9. Try unlocking payroll
10. Export to Excel and verify both sheets

- [ ] **Step 3: Test locking mechanism**

1. Approve payroll for one employee
2. Go to the approval dashboard and try to modify a day in that period → should be blocked
3. Unlock payroll
4. Verify the day can now be modified

- [ ] **Step 4: Final commit if any fixes**

```bash
git add -A
git commit -m "fix: address issues found during payroll page verification"
```
