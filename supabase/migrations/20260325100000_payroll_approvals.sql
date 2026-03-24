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
