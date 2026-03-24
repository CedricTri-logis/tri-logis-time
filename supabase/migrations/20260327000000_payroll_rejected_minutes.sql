-- =============================================================
-- Migration: Add rejected_minutes to payroll report
-- Exposes day_approvals.rejected_minutes in get_payroll_period_report
-- so the dashboard can show a "Refusées" column in the payroll summary.
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
  reimbursement_amount DECIMAL(10,2),
  break_deduction_minutes INTEGER,
  break_deduction_waived BOOLEAN,
  rejected_minutes INTEGER
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
           COALESCE(da.approved_minutes, 0) AS approved_minutes,
           COALESCE(da.break_deduction_waived, false) AS break_deduction_waived,
           COALESCE(da.rejected_minutes, 0) AS rejected_minutes
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
      -- Mileage fields (same value repeated on every day row for this employee)
      md.reimbursable_km,
      md.reimbursement_amount,
      -- Break deduction: if ≥5h worked and <30min break, deduct (30 - break_minutes)
      CASE
        WHEN COALESCE(a.approved_minutes, 0) >= 300
             AND COALESCE(b.break_minutes, 0) < 30
             AND NOT a.break_deduction_waived
        THEN 30 - COALESCE(b.break_minutes, 0)
        ELSE 0
      END AS break_deduction_minutes,
      a.break_deduction_waived,
      a.rejected_minutes,
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
    c.reimbursement_amount,
    c.break_deduction_minutes,
    c.break_deduction_waived,
    c.rejected_minutes
  FROM combined c
  ORDER BY c.primary_category NULLS LAST, c.full_name, c.date;
END;
$$;

COMMENT ON FUNCTION get_payroll_period_report IS 'Returns payroll report data per employee per day for a biweekly period. Aggregates: day approvals, breaks, callbacks (Art.58 LNT 3h min), work sessions by type, pay calculation (hourly rates + annual/26), weekend premium, payroll lock status, mileage reimbursement (frozen from mileage_approvals when approved, live estimate otherwise), rejected_minutes for "Refusées" column. Auth: admin/super_admin see all, managers see supervised only.';
