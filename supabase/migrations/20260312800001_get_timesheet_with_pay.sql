-- ============================================================
-- RPC: get_timesheet_with_pay
-- Returns per-day pay data for approved days within a date range.
-- Crosses: day_approvals (approved minutes), employee_hourly_rates
--          (rate on that date), work_sessions (cleaning on weekends),
--          pay_settings (weekend premium).
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
  has_rate BOOLEAN
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
      -- Intersect requested with supervised
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

  -- 4. Return per-day rows
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
      AND EXTRACT(DOW FROM (ws.started_at AT TIME ZONE 'America/Toronto')) IN (0, 6) -- 0=Sun, 6=Sat
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
    r.rate IS NOT NULL AS has_rate
  FROM approved_days ad
  JOIN employee_profiles ep ON ep.id = ad.employee_id
  LEFT JOIN rates r ON r.employee_id = ad.employee_id
    AND r.effective_from <= ad.date
    AND (r.effective_to IS NULL OR r.effective_to >= ad.date)
  LEFT JOIN weekend_cleaning wc ON wc.employee_id = ad.employee_id AND wc.ws_date = ad.date
  ORDER BY ep.full_name, ad.date;
END;
$$;

GRANT EXECUTE ON FUNCTION get_timesheet_with_pay TO authenticated;

COMMENT ON FUNCTION get_timesheet_with_pay IS
  'Returns per-employee per-day pay data for approved days.
   Calculates base_amount (approved_minutes x hourly_rate) plus
   weekend cleaning premium (cleaning work_session minutes on Sat/Sun x global premium).
   Timezone: America/Toronto for weekend determination.
   Note: cross-midnight sessions are attributed to their start date (no splitting).';
