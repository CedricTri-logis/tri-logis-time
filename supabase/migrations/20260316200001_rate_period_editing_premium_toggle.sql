-- ============================================================
-- Migration: Rate period editing + weekend premium toggle
-- 1. Add weekend_premium_eligible to employee_categories
-- 2. Create update_employee_rate_period RPC
-- 3. Create delete_employee_rate_period RPC
-- 4. Recreate get_timesheet_with_pay with eligibility check
-- ============================================================

-- ── 1. Weekend premium eligibility column ──

ALTER TABLE employee_categories
  ADD COLUMN weekend_premium_eligible BOOLEAN NOT NULL DEFAULT true;

COMMENT ON COLUMN employee_categories.weekend_premium_eligible IS
  'Only meaningful for category = menage. Controls whether this ménage period qualifies for the weekend cleaning premium. Default true for backward compatibility.';

-- ── 2. Update rate period RPC ──

CREATE OR REPLACE FUNCTION update_employee_rate_period(
  p_rate_id UUID,
  p_rate NUMERIC,
  p_effective_from DATE,
  p_effective_to DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_caller_role TEXT;
  v_employee_id UUID;
BEGIN
  -- Auth check
  SELECT ep.role INTO v_caller_role
  FROM employee_profiles ep
  WHERE ep.id = (SELECT auth.uid());

  IF v_caller_role IS NULL OR v_caller_role NOT IN ('admin', 'super_admin') THEN
    RETURN jsonb_build_object('success', false, 'error', jsonb_build_object(
      'code', 'UNAUTHORIZED',
      'message', 'Accès refusé. Rôle admin ou super_admin requis.'
    ));
  END IF;

  -- Get employee_id for this rate
  SELECT employee_id INTO v_employee_id
  FROM employee_hourly_rates WHERE id = p_rate_id;

  IF v_employee_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', jsonb_build_object(
      'code', 'NOT_FOUND',
      'message', 'Période de taux introuvable.'
    ));
  END IF;

  -- Validate: effective_from < effective_to (if both set)
  IF p_effective_to IS NOT NULL AND p_effective_to <= p_effective_from THEN
    RETURN jsonb_build_object('success', false, 'error', jsonb_build_object(
      'code', 'INVALID_DATES',
      'message', 'La date de fin doit être après la date de début.'
    ));
  END IF;

  -- Validate: no overlap with other periods of same employee
  IF EXISTS (
    SELECT 1 FROM employee_hourly_rates
    WHERE employee_id = v_employee_id
      AND id != p_rate_id
      AND effective_from < COALESCE(p_effective_to, '9999-12-31'::date)
      AND COALESCE(effective_to, '9999-12-31'::date) > p_effective_from
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', jsonb_build_object(
      'code', 'OVERLAP',
      'message', 'Cette période chevauche une autre période de taux pour cet employé.'
    ));
  END IF;

  -- Update the row (updated_at handled by existing BEFORE UPDATE trigger)
  UPDATE employee_hourly_rates
  SET rate = p_rate,
      effective_from = p_effective_from,
      effective_to = p_effective_to
  WHERE id = p_rate_id;

  RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION update_employee_rate_period TO authenticated;

-- ── 3. Delete rate period RPC ──

CREATE OR REPLACE FUNCTION delete_employee_rate_period(
  p_rate_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_caller_role TEXT;
  v_employee_id UUID;
  v_effective_to DATE;
  v_total_periods INTEGER;
BEGIN
  -- Auth check
  SELECT ep.role INTO v_caller_role
  FROM employee_profiles ep
  WHERE ep.id = (SELECT auth.uid());

  IF v_caller_role IS NULL OR v_caller_role NOT IN ('admin', 'super_admin') THEN
    RETURN jsonb_build_object('success', false, 'error', jsonb_build_object(
      'code', 'UNAUTHORIZED',
      'message', 'Accès refusé. Rôle admin ou super_admin requis.'
    ));
  END IF;

  -- Get the rate period details
  SELECT employee_id, effective_to INTO v_employee_id, v_effective_to
  FROM employee_hourly_rates WHERE id = p_rate_id;

  IF v_employee_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', jsonb_build_object(
      'code', 'NOT_FOUND',
      'message', 'Période de taux introuvable.'
    ));
  END IF;

  -- Cannot delete the active period (effective_to IS NULL)
  IF v_effective_to IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', jsonb_build_object(
      'code', 'ACTIVE_PERIOD',
      'message', 'Impossible de supprimer la période en cours. Modifiez-la ou ajoutez un nouveau taux.'
    ));
  END IF;

  -- Cannot delete the only remaining period
  SELECT COUNT(*) INTO v_total_periods
  FROM employee_hourly_rates
  WHERE employee_id = v_employee_id;

  IF v_total_periods <= 1 THEN
    RETURN jsonb_build_object('success', false, 'error', jsonb_build_object(
      'code', 'LAST_PERIOD',
      'message', 'Impossible de supprimer la seule période de taux restante.'
    ));
  END IF;

  -- Delete
  DELETE FROM employee_hourly_rates WHERE id = p_rate_id;

  RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION delete_employee_rate_period TO authenticated;

-- ── 4. Recreate get_timesheet_with_pay with weekend premium eligibility check ──

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
      AND EXTRACT(DOW FROM (ws.started_at AT TIME ZONE 'America/Toronto')) IN (0, 6)
      AND (p_employee_ids IS NULL OR ws.employee_id = ANY(p_employee_ids))
      -- Weekend premium eligibility: employee must have an active ménage category
      -- with weekend_premium_eligible = true on the session date
      AND EXISTS (
        SELECT 1 FROM employee_categories ec
        WHERE ec.employee_id = ws.employee_id
          AND ec.category = 'menage'
          AND ec.weekend_premium_eligible = true
          AND ec.started_at <= (ws.started_at AT TIME ZONE 'America/Toronto')::date
          AND (ec.ended_at IS NULL OR ec.ended_at >= (ws.started_at AT TIME ZONE 'America/Toronto')::date)
      )
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
   Weekend premium requires an active ménage category with weekend_premium_eligible = true.
   Timezone: America/Toronto for weekend determination.
   Note: cross-midnight sessions are attributed to their start date (no splitting).';
