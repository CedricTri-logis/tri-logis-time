-- ============================================================
-- Migration: Update get_timesheet_with_pay for annual salary support
-- Must DROP first because return type changed (new columns added)
-- ============================================================

DROP FUNCTION IF EXISTS get_timesheet_with_pay(DATE, DATE, UUID[]);

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

  -- 4. Return rows for HOURLY employees (existing logic unchanged)
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

  -- 5. Return summary rows for ANNUAL employees
  RETURN QUERY
  WITH annual_employees AS (
    SELECT ep.id AS emp_id, ep.full_name AS emp_name, ep.employee_id AS emp_code
    FROM employee_profiles ep
    WHERE ep.pay_type = 'annual'
      AND ep.status = 'active'
      AND (p_employee_ids IS NULL OR ep.id = ANY(p_employee_ids))
  ),
  annual_approved_totals AS (
    SELECT
      da.employee_id,
      SUM(da.approved_minutes)::INTEGER AS total_mins
    FROM day_approvals da
    JOIN annual_employees ae ON ae.emp_id = da.employee_id
    WHERE da.status = 'approved'
      AND da.date BETWEEN p_start_date AND p_end_date
    GROUP BY da.employee_id
  ),
  annual_weekend_cleaning_totals AS (
    SELECT
      ws.employee_id,
      SUM(
        EXTRACT(EPOCH FROM (
          COALESCE(ws.completed_at, now()) - ws.started_at
        )) / 60
      )::INTEGER AS total_cleaning_mins
    FROM work_sessions ws
    JOIN annual_employees ae ON ae.emp_id = ws.employee_id
    WHERE ws.activity_type = 'cleaning'
      AND ws.status IN ('completed', 'auto_closed', 'manually_closed')
      AND (ws.started_at AT TIME ZONE 'America/Toronto')::DATE BETWEEN p_start_date AND p_end_date
      AND EXTRACT(DOW FROM (ws.started_at AT TIME ZONE 'America/Toronto')) IN (0, 6)
    GROUP BY ws.employee_id
  )
  SELECT
    ae.emp_id AS employee_id,
    ae.emp_name AS full_name,
    ae.emp_code AS employee_id_code,
    p_start_date AS date,
    COALESCE(aat.total_mins, 0)::INTEGER AS approved_minutes,
    NULL::DECIMAL(10,2) AS hourly_rate,
    0.00::DECIMAL(10,2) AS base_amount,
    COALESCE(awct.total_cleaning_mins, 0)::INTEGER AS weekend_cleaning_minutes,
    v_premium AS weekend_premium_rate,
    COALESCE(ROUND((COALESCE(awct.total_cleaning_mins, 0) / 60.0) * v_premium, 2), 0.00) AS premium_amount,
    COALESCE(ROUND(sal.salary / 26.0, 2), 0.00)
      + COALESCE(ROUND((COALESCE(awct.total_cleaning_mins, 0) / 60.0) * v_premium, 2), 0.00) AS total_amount,
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
  LEFT JOIN annual_approved_totals aat ON aat.employee_id = ae.emp_id
  LEFT JOIN annual_weekend_cleaning_totals awct ON awct.employee_id = ae.emp_id
  ORDER BY ae.emp_name;
END;
$$;

GRANT EXECUTE ON FUNCTION get_timesheet_with_pay TO authenticated;

COMMENT ON FUNCTION get_timesheet_with_pay IS
  'Returns per-employee pay data for a date range.
   Hourly employees: per-day rows (approved_minutes x hourly_rate + weekend premium).
   Annual employees: one summary row per period (salary / 26 + weekend premium).
   New fields: pay_type, annual_salary, period_amount, has_compensation.
   Timezone: America/Toronto for weekend determination.';
