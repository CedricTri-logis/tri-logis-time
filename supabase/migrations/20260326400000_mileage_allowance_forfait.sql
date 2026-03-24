-- Migration: Fixed mileage allowance (forfait kilometrage)
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


-- ============================================================
-- 2. ALTER mileage_approvals for audit trail
-- ============================================================

ALTER TABLE mileage_approvals
    ADD COLUMN is_forfait BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN forfait_amount DECIMAL(10,2);

COMMENT ON COLUMN mileage_approvals.is_forfait IS 'True if this approval used a fixed forfait amount instead of per-km calculation';
COMMENT ON COLUMN mileage_approvals.forfait_amount IS 'The forfait amount frozen at approval time (NULL if per-km)';


-- ============================================================
-- 3. Updated get_mileage_approval_detail with forfait logic
-- ============================================================

CREATE OR REPLACE FUNCTION get_mileage_approval_detail(
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
  v_trips JSONB;
  v_summary JSONB;
  v_approval JSONB;
  v_reimbursable_km DECIMAL;
  v_company_km DECIMAL;
  v_passenger_km DECIMAL;
  v_needs_review INTEGER;
  v_estimated_amount DECIMAL;
  v_ytd_km DECIMAL;
  v_rate_per_km DECIMAL;
  v_threshold_km DECIMAL;
  v_rate_after DECIMAL;
  v_forfait_amount DECIMAL;
BEGIN
  IF NOT is_admin_or_super_admin(v_caller) THEN
    RAISE EXCEPTION 'Only admins can view mileage approval detail';
  END IF;

  SELECT jsonb_agg(trip_row ORDER BY trip_date, started_at)
  INTO v_trips
  FROM (
    SELECT
      to_business_date(t.started_at) AS trip_date,
      t.id AS trip_id,
      t.started_at,
      t.ended_at,
      t.start_address,
      t.end_address,
      t.start_location_id,
      t.end_location_id,
      COALESCE(t.road_distance_km, t.distance_km) AS distance_km,
      t.vehicle_type,
      t.role,
      t.transport_mode,
      t.has_gps_gap,
      cm.carpool_group_id,
      cm.role AS carpool_detected_role,
      (
        SELECT jsonb_agg(jsonb_build_object(
          'employee_id', cm2.employee_id,
          'employee_name', ep2.full_name,
          'role', cm2.role,
          'trip_id', cm2.trip_id
        ))
        FROM carpool_members cm2
        JOIN employee_profiles ep2 ON ep2.id = cm2.employee_id
        WHERE cm2.carpool_group_id = cm.carpool_group_id
          AND cm2.employee_id != p_employee_id
      ) AS carpool_members,
      CASE
        WHEN t.transport_mode != 'driving' THEN FALSE
        ELSE TRUE
      END AS eligible
    FROM trips t
    LEFT JOIN carpool_members cm ON cm.trip_id = t.id
    WHERE t.employee_id = p_employee_id
      AND to_business_date(t.started_at) BETWEEN p_period_start AND p_period_end
      AND t.transport_mode = 'driving'
  ) trip_row;

  SELECT
    COALESCE(SUM(CASE WHEN t.vehicle_type = 'personal' AND t.role = 'driver'
      THEN COALESCE(t.road_distance_km, t.distance_km) ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN t.vehicle_type = 'company'
      THEN COALESCE(t.road_distance_km, t.distance_km) ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN t.role = 'passenger'
      THEN COALESCE(t.road_distance_km, t.distance_km) ELSE 0 END), 0),
    COUNT(CASE WHEN t.vehicle_type IS NULL OR t.role IS NULL THEN 1 END)
  INTO v_reimbursable_km, v_company_km, v_passenger_km, v_needs_review
  FROM trips t
  WHERE t.employee_id = p_employee_id
    AND to_business_date(t.started_at) BETWEEN p_period_start AND p_period_end
    AND t.transport_mode = 'driving';

  SELECT rr.rate_per_km, rr.threshold_km, rr.rate_after_threshold
  INTO v_rate_per_km, v_threshold_km, v_rate_after
  FROM reimbursement_rates rr
  WHERE rr.effective_from <= p_period_end
  ORDER BY rr.effective_from DESC
  LIMIT 1;

  SELECT COALESCE(SUM(COALESCE(t.road_distance_km, t.distance_km)), 0)
  INTO v_ytd_km
  FROM trips t
  WHERE t.employee_id = p_employee_id
    AND to_business_date(t.started_at) >= date_trunc('year', p_period_end::TIMESTAMP)::DATE
    AND to_business_date(t.started_at) < p_period_start
    AND t.transport_mode = 'driving'
    AND t.vehicle_type = 'personal'
    AND t.role = 'driver';

  IF v_threshold_km IS NOT NULL AND v_rate_after IS NOT NULL THEN
    IF v_ytd_km >= v_threshold_km THEN
      v_estimated_amount := v_reimbursable_km * v_rate_after;
    ELSIF (v_ytd_km + v_reimbursable_km) <= v_threshold_km THEN
      v_estimated_amount := v_reimbursable_km * v_rate_per_km;
    ELSE
      v_estimated_amount :=
        (v_threshold_km - v_ytd_km) * v_rate_per_km +
        (v_reimbursable_km - (v_threshold_km - v_ytd_km)) * v_rate_after;
    END IF;
  ELSE
    v_estimated_amount := v_reimbursable_km * v_rate_per_km;
  END IF;

  -- Forfait override: if employee has active mileage allowance, use it instead of per-km
  v_forfait_amount := get_active_mileage_allowance(p_employee_id, p_period_start);
  IF v_forfait_amount IS NOT NULL THEN
    v_estimated_amount := v_forfait_amount;
  END IF;

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

  SELECT to_jsonb(ma)
  INTO v_approval
  FROM mileage_approvals ma
  WHERE ma.employee_id = p_employee_id
    AND ma.period_start = p_period_start
    AND ma.period_end = p_period_end;

  RETURN jsonb_build_object(
    'trips', COALESCE(v_trips, '[]'::JSONB),
    'summary', v_summary,
    'approval', v_approval
  );
END;
$$;


-- ============================================================
-- 4. Updated approve_mileage to freeze forfait fields
-- ============================================================

CREATE OR REPLACE FUNCTION approve_mileage(
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
  v_needs_review INTEGER;
  v_unapproved_days INTEGER;
  v_detail JSONB;
  v_result mileage_approvals;
  v_is_forfait BOOLEAN;
BEGIN
  IF NOT is_admin_or_super_admin(v_caller) THEN
    RAISE EXCEPTION 'Only admins can approve mileage';
  END IF;

  SELECT COUNT(*) INTO v_unapproved_days
  FROM day_approvals da
  WHERE da.employee_id = p_employee_id
    AND da.date BETWEEN p_period_start AND p_period_end
    AND da.status != 'approved';

  IF v_unapproved_days > 0 THEN
    RAISE EXCEPTION '% day(s) not yet approved for this period', v_unapproved_days;
  END IF;

  SELECT COUNT(*) INTO v_needs_review
  FROM trips t
  WHERE t.employee_id = p_employee_id
    AND to_business_date(t.started_at) BETWEEN p_period_start AND p_period_end
    AND t.transport_mode = 'driving'
    AND (t.vehicle_type IS NULL OR t.role IS NULL);

  IF v_needs_review > 0 THEN
    RAISE EXCEPTION '% trip(s) still need vehicle/role assignment', v_needs_review;
  END IF;

  v_detail := get_mileage_approval_detail(p_employee_id, p_period_start, p_period_end);

  v_is_forfait := COALESCE((v_detail->'summary'->>'is_forfait')::BOOLEAN, false);

  INSERT INTO mileage_approvals (
    employee_id, period_start, period_end, status,
    reimbursable_km, reimbursement_amount,
    approved_by, approved_at, notes,
    is_forfait, forfait_amount
  )
  VALUES (
    p_employee_id, p_period_start, p_period_end, 'approved',
    (v_detail->'summary'->>'reimbursable_km')::DECIMAL,
    (v_detail->'summary'->>'estimated_amount')::DECIMAL,
    v_caller, now(), p_notes,
    v_is_forfait,
    CASE WHEN v_is_forfait THEN (v_detail->'summary'->>'forfait_amount')::DECIMAL END
  )
  ON CONFLICT (employee_id, period_start, period_end)
  DO UPDATE SET
    status = 'approved',
    reimbursable_km = EXCLUDED.reimbursable_km,
    reimbursement_amount = EXCLUDED.reimbursement_amount,
    approved_by = EXCLUDED.approved_by,
    approved_at = EXCLUDED.approved_at,
    notes = EXCLUDED.notes,
    is_forfait = EXCLUDED.is_forfait,
    forfait_amount = EXCLUDED.forfait_amount,
    updated_at = now()
  RETURNING * INTO v_result;

  RETURN to_jsonb(v_result);
END;
$$;


-- ============================================================
-- 5. Updated get_mileage_approval_summary with per-employee forfait
-- ============================================================

CREATE OR REPLACE FUNCTION get_mileage_approval_summary(
  p_period_start DATE,
  p_period_end DATE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_caller UUID := auth.uid();
  v_result JSONB;
  v_rate_per_km DECIMAL;
BEGIN
  IF NOT is_admin_or_super_admin(v_caller) THEN
    RAISE EXCEPTION 'Only admins can view mileage approval summary';
  END IF;

  SELECT rr.rate_per_km INTO v_rate_per_km
  FROM reimbursement_rates rr
  WHERE rr.effective_from <= p_period_end
  ORDER BY rr.effective_from DESC LIMIT 1;

  WITH trip_data AS (
    SELECT
      t.id AS trip_id,
      t.employee_id,
      COALESCE(t.road_distance_km, t.distance_km) AS distance,
      t.vehicle_type,
      t.role
    FROM trips t
    WHERE to_business_date(t.started_at) BETWEEN p_period_start AND p_period_end
      AND t.transport_mode = 'driving'
  ),
  carpool_counts AS (
    SELECT td.employee_id, COUNT(DISTINCT cm.carpool_group_id) AS carpool_group_count
    FROM trip_data td
    JOIN carpool_members cm ON cm.trip_id = td.trip_id
    GROUP BY td.employee_id
  )
  SELECT jsonb_agg(row_data ORDER BY needs_review_count DESC, employee_name)
  INTO v_result
  FROM (
    SELECT
      ep.id AS employee_id,
      ep.full_name AS employee_name,
      COUNT(td.trip_id) AS trip_count,
      COALESCE(SUM(
        CASE WHEN td.vehicle_type = 'personal' AND td.role = 'driver'
        THEN td.distance ELSE 0 END
      ), 0) AS reimbursable_km,
      COALESCE(SUM(
        CASE WHEN td.vehicle_type = 'company'
        THEN td.distance ELSE 0 END
      ), 0) AS company_km,
      COUNT(CASE WHEN td.vehicle_type IS NULL OR td.role IS NULL THEN 1 END) AS needs_review_count,
      COALESCE(cc.carpool_group_count, 0) AS carpool_group_count,
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
      ma.status AS mileage_status,
      ma.reimbursable_km AS approved_km,
      ma.reimbursement_amount AS approved_amount
    FROM trip_data td
    JOIN employee_profiles ep ON ep.id = td.employee_id
    LEFT JOIN carpool_counts cc ON cc.employee_id = td.employee_id
    LEFT JOIN mileage_approvals ma
      ON ma.employee_id = td.employee_id
      AND ma.period_start = p_period_start
      AND ma.period_end = p_period_end
    GROUP BY ep.id, ep.full_name, cc.carpool_group_count, ma.status, ma.reimbursable_km, ma.reimbursement_amount, ma.is_forfait
  ) row_data;

  RETURN COALESCE(v_result, '[]'::JSONB);
END;
$$;


-- ============================================================
-- 6. Updated get_payroll_period_report with forfait in mileage CTE
-- ============================================================

DROP FUNCTION IF EXISTS get_payroll_period_report(DATE, DATE, UUID[]);

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
  callbacks AS (
    SELECT
      s.employee_id,
      to_business_date(s.clocked_in_at) AS date,
      SUM(EXTRACT(EPOCH FROM (COALESCE(est.effective_clocked_out_at, now()) - est.effective_clocked_in_at)) / 60.0)::INTEGER AS worked_minutes,
      GREATEST(180,
        SUM(EXTRACT(EPOCH FROM (COALESCE(est.effective_clocked_out_at, now()) - est.effective_clocked_in_at)) / 60.0)
      )::INTEGER AS billed_minutes
    FROM shifts s, effective_shift_times(s.id) est
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

  -- Mileage data per employee (frozen if approved, forfait if active, live estimate otherwise)
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
      -- Break deduction: if >=5h worked and <30min break, deduct (30 - break_minutes)
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

COMMENT ON FUNCTION get_payroll_period_report IS 'Returns payroll report data per employee per day for a biweekly period. Aggregates: day approvals, breaks, callbacks (Art.58 LNT 3h min), work sessions by type, pay calculation (hourly rates + annual/26), weekend premium, payroll lock status, mileage reimbursement (frozen from mileage_approvals when approved, forfait if active allowance, live estimate otherwise). Auth: admin/super_admin see all, managers see supervised only.';
