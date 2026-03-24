# Payroll Report Mileage Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `reimbursable_km` and `reimbursement_amount` columns to `get_payroll_period_report` RPC and the `PayrollReportRow` TypeScript type, sourcing frozen values from `mileage_approvals` when approved or live-calculated estimates otherwise.

**Architecture:** One new migration replaces the existing `get_payroll_period_report` function via `CREATE OR REPLACE`, adding a single new CTE (`mileage_data`) that joins `mileage_approvals` and falls back to a live trip aggregation. The two new columns are added at the end of the return signature to preserve backwards compatibility. The TypeScript type gets two optional fields.

**Tech Stack:** PostgreSQL/Supabase (SQL migration), TypeScript (type update), Next.js dashboard (build verification).

---

## Files to Touch

| File | Action | What changes |
|---|---|---|
| `supabase/migrations/20260326100002_payroll_report_mileage.sql` | **Create** | New migration: `CREATE OR REPLACE FUNCTION get_payroll_period_report(...)` with mileage columns added |
| `dashboard/src/types/payroll.ts` | **Modify** | Add `reimbursable_km?: number \| null` and `reimbursement_amount?: number \| null` to `PayrollReportRow` |

---

## Key Business Rules (read before coding)

1. **Frozen values:** When `mileage_approvals.status = 'approved'` for an employee in this period, use the frozen `reimbursable_km` and `reimbursement_amount` columns directly from `mileage_approvals`.

2. **Live estimate (pending/no record):** When status is `'pending'` or no row exists, calculate live:
   - `reimbursable_km` = `SUM(COALESCE(road_distance_km, distance_km))` for trips WHERE `transport_mode = 'driving'` AND `vehicle_type = 'personal'` AND `role = 'driver'`
   - `reimbursement_amount` = `reimbursable_km * rate_per_km` (from `reimbursement_rates` using most recent rate effective on or before `p_period_end`)

3. **Nulls:** Both fields return `NULL` when an employee has no driving trips in the period (i.e. `reimbursable_km = 0` → show `0`, not `NULL`). Use `COALESCE(..., 0)` where appropriate.

4. **Per-employee, per-period:** Mileage is period-level (not day-level). The same `reimbursable_km` and `reimbursement_amount` values repeat on every day row for that employee (since the RPC returns one row per employee per day).

5. **Rate lookup:** Use `SELECT rate_per_km FROM reimbursement_rates WHERE effective_from <= p_period_end ORDER BY effective_from DESC LIMIT 1`. This matches the pattern in `get_mileage_approval_detail`.

---

## Task 1: Create the SQL Migration

**Files:**
- Create: `supabase/migrations/20260326100002_payroll_report_mileage.sql`

- [ ] **Step 1: Read the existing function in full**

  Before writing anything, confirm you have read `supabase/migrations/20260325100000_payroll_approvals.sql` completely. The function `get_payroll_period_report` starts at line 225. Read lines 225–586. Every existing CTE and SELECT clause must be preserved exactly.

- [ ] **Step 2: Identify insertion points in the function**

  The new logic inserts in three places:
  1. **New DECLARE variable** (in the DECLARE block): `v_cra_rate DECIMAL(10,2);`
  2. **New CTE** (after the `payroll` CTE, before `period_days`): `mileage_data AS (...)`
  3. **New columns in the outer SELECT** (after `payroll_approved_at`): `c.reimbursable_km, c.reimbursement_amount`
  4. **New columns in `combined` CTE SELECT**: pulling from `mileage_data`
  5. **New LEFT JOIN** in `combined` CTE: `LEFT JOIN mileage_data md ON md.employee_id = te.id`
  6. **New columns in RETURNS TABLE**: `reimbursable_km DECIMAL(10,2), reimbursement_amount DECIMAL(10,2)`

- [ ] **Step 3: Write the migration**

  Create `/Users/cedric/Desktop/PROJECT/GPS_Tracker_repo/supabase/migrations/20260326100002_payroll_report_mileage.sql` with content:

  ```sql
  -- =============================================================
  -- Migration: Add mileage reimbursement columns to payroll report
  -- Adds reimbursable_km and reimbursement_amount to get_payroll_period_report.
  -- Uses frozen values from mileage_approvals when approved;
  -- live-calculated estimate otherwise.
  -- =============================================================

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
    payroll_approved_at TIMESTAMPTZ,
    reimbursable_km DECIMAL(10,2),
    reimbursement_amount DECIMAL(10,2)
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  AS $$
  DECLARE
    v_caller UUID := auth.uid();
    v_caller_role TEXT;
    v_supervised_ids UUID[];
    v_premium_rate DECIMAL(10,2);
    v_cra_rate DECIMAL(10,2);
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

    -- Get CRA mileage rate (most recent rate effective on or before period end)
    SELECT rr.rate_per_km INTO v_cra_rate
    FROM reimbursement_rates rr
    WHERE rr.effective_from <= p_period_end
    ORDER BY rr.effective_from DESC
    LIMIT 1;

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
    callbacks AS (
      SELECT
        s.employee_id,
        to_business_date(s.clocked_in_at) AS date,
        SUM(EXTRACT(EPOCH FROM (COALESCE(s.clocked_out_at, now()) - s.clocked_in_at)) / 60.0)::INTEGER AS worked_minutes,
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
      WHERE ehr.employee_id IN (SELECT te2.id FROM target_employees te2 WHERE te2.pay_type = 'hourly')
    ),

    -- Annual salaries
    salaries AS (
      SELECT eas.employee_id, eas.salary,
             eas.effective_from, eas.effective_to
      FROM employee_annual_salaries eas
      WHERE eas.employee_id IN (SELECT te2.id FROM target_employees te2 WHERE te2.pay_type = 'annual')
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

    -- Mileage data per employee (frozen if approved, live estimate otherwise)
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
        -- Only join trips when NOT approved (approved values come from ma directly)
        AND (ma.status IS NULL OR ma.status != 'approved')
      GROUP BY te.id, ma.status, ma.reimbursable_km, ma.reimbursement_amount
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
        -- Mileage fields (same value repeated on every day row for this employee)
        md.reimbursable_km,
        md.reimbursement_amount,
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
      LEFT JOIN mileage_data md ON md.employee_id = te.id
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
      c.payroll_approved_at,
      c.reimbursable_km,
      c.reimbursement_amount
    FROM combined c
    ORDER BY c.primary_category NULLS LAST, c.full_name, c.date;
  END;
  $$;

  COMMENT ON FUNCTION get_payroll_period_report IS 'Returns payroll report data per employee per day for a biweekly period. Aggregates: day approvals, breaks, callbacks (Art.58 LNT 3h min), work sessions by type, pay calculation (hourly rates + annual/26), weekend premium, payroll lock status, mileage reimbursement (frozen from mileage_approvals when approved, live estimate otherwise). Auth: admin/super_admin see all, managers see supervised only.';
  ```

- [ ] **Step 4: Apply the migration**

  Use the MCP tool `mcp__supabase__apply_migration` with:
  - `name`: `20260326100002_payroll_report_mileage`
  - `query`: the full SQL content above

- [ ] **Step 5: Verify the migration applied**

  Run via `mcp__supabase__execute_sql`:
  ```sql
  SELECT get_payroll_period_report('2026-03-09', '2026-03-22');
  ```
  Confirm the result set includes columns `reimbursable_km` and `reimbursement_amount` at the end. If the period has no data, the query should return 0 rows with no error (not a crash).

  Also verify the function signature with:
  ```sql
  SELECT column_name
  FROM information_schema.columns
  WHERE table_name = 'get_payroll_period_report'
  ORDER BY ordinal_position;
  ```
  Wait — that won't work for functions. Instead, verify via:
  ```sql
  SELECT proname, pg_get_function_result(oid) AS return_type
  FROM pg_proc
  WHERE proname = 'get_payroll_period_report';
  ```
  The return type string should include `reimbursable_km` and `reimbursement_amount`.

---

## Task 2: Update TypeScript Type

**Files:**
- Modify: `dashboard/src/types/payroll.ts`

- [ ] **Step 1: Read the current file**

  Read `/Users/cedric/Desktop/PROJECT/GPS_Tracker_repo/dashboard/src/types/payroll.ts` in full (31 lines). Confirm the `PayrollReportRow` interface ends at line 31.

- [ ] **Step 2: Add the new fields**

  Add two optional fields after `payroll_approved_at` in `PayrollReportRow`:

  ```typescript
  payroll_approved_at: string | null;
  reimbursable_km?: number | null;
  reimbursement_amount?: number | null;
  ```

  The fields are optional (`?`) so existing code that doesn't destructure them won't break, and so TypeScript won't require them when constructing mock objects in tests.

- [ ] **Step 3: Run the build**

  ```bash
  cd /Users/cedric/Desktop/PROJECT/GPS_Tracker_repo/dashboard && npm run build
  ```
  Expected: build succeeds with no TypeScript errors.

  If build fails with a type error referencing the new fields: trace the error to the component using `PayrollReportRow` and fix the access pattern.

---

## Task 3: Commit

- [ ] **Step 1: Stage files**

  ```bash
  git add supabase/migrations/20260326100002_payroll_report_mileage.sql dashboard/src/types/payroll.ts
  ```

- [ ] **Step 2: Commit**

  ```bash
  git commit -m "feat: add mileage reimbursement columns to payroll report"
  ```

---

## Common Failure Modes

| Symptom | Root cause | Fix |
|---|---|---|
| `ERROR: column "reimbursable_km" does not exist` in the `combined` CTE | `mileage_data` CTE not joined in `combined` | Confirm `LEFT JOIN mileage_data md ON md.employee_id = te.id` exists in the `combined` FROM clause |
| `ERROR: GROUP BY clause` in `mileage_data` | The CASE WHEN referencing `ma.status` is both selected and grouped differently | Make sure `ma.status, ma.reimbursable_km, ma.reimbursement_amount` are all in the GROUP BY |
| `ERROR: cannot change return type of existing function` | Postgres cached the old function signature | This shouldn't happen with `CREATE OR REPLACE` if column order is preserved; if it does, `DROP FUNCTION get_payroll_period_report CASCADE` first then re-apply |
| TypeScript build error on `PayrollReportRow` | New fields not marked optional in an existing spread/destructure | Add `?.` access or provide default values |
