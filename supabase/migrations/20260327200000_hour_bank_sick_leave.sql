-- ============================================================
-- Hour Bank & Sick Leave — Tables, Constraints, Indexes, RLS, Triggers, RPCs
-- ============================================================

-- ── 1. hour_bank_transactions ──
CREATE TABLE IF NOT EXISTS public.hour_bank_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES public.employee_profiles(id) ON DELETE CASCADE,
  payroll_period_start DATE NOT NULL,
  payroll_period_end DATE NOT NULL,
  transaction_type TEXT NOT NULL CHECK (transaction_type IN ('deposit', 'withdrawal')),
  hours NUMERIC NOT NULL CHECK (hours > 0),
  hourly_rate NUMERIC NOT NULL CHECK (hourly_rate > 0),
  amount NUMERIC NOT NULL CHECK (amount > 0),
  reason TEXT NOT NULL CHECK (trim(reason) <> ''),
  created_by UUID NOT NULL REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.hour_bank_transactions IS 'ROLE: Journal des transactions de banque d''heures (depots/retraits). STATUT: Immutable (insert/delete only). REGLES: La banque stocke des dollars (hours x rate = amount). Depot = heures retirees de la paie, converties en $. Retrait = $ convertis en heures au taux actuel. Solde = SUM(deposit amounts) - SUM(withdrawal amounts). Ne peut pas devenir negatif. Horaires seulement (pas annuels). RELATIONS: FK employee_profiles, FK auth.users. TRIGGERS: check_payroll_lock (bloque si paie approuvee), prevent_update (immutable).';

CREATE INDEX idx_hour_bank_employee_period ON public.hour_bank_transactions(employee_id, payroll_period_start);
CREATE INDEX idx_hour_bank_employee_type ON public.hour_bank_transactions(employee_id, transaction_type);

-- ── 2. sick_leave_usages ──
CREATE TABLE IF NOT EXISTS public.sick_leave_usages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES public.employee_profiles(id) ON DELETE CASCADE,
  payroll_period_start DATE NOT NULL,
  payroll_period_end DATE NOT NULL,
  hours NUMERIC NOT NULL CHECK (hours > 0),
  absence_date DATE NOT NULL,
  hourly_rate NUMERIC NOT NULL CHECK (hourly_rate > 0),
  amount NUMERIC NOT NULL CHECK (amount > 0),
  reason TEXT NOT NULL CHECK (trim(reason) <> ''),
  year INTEGER NOT NULL,
  created_by UUID NOT NULL REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (absence_date BETWEEN payroll_period_start AND payroll_period_end),
  CHECK (year = EXTRACT(YEAR FROM absence_date)::INTEGER)
);

COMMENT ON TABLE public.sick_leave_usages IS 'ROLE: Journal des heures maladie utilisees. STATUT: Immutable (insert/delete only). REGLES: 14h/annee (LNT Art. 79.7, 2 jours x 7h). Reset 1er janvier. Eligibilite: 3 mois service continu (verifie via premier shift). Taux = taux horaire courant. Disponible horaires ET annuels. RELATIONS: FK employee_profiles, FK auth.users. TRIGGERS: check_payroll_lock, prevent_update, check_sick_leave_limit.';

CREATE INDEX idx_sick_leave_employee_year ON public.sick_leave_usages(employee_id, year);
CREATE INDEX idx_sick_leave_employee_period ON public.sick_leave_usages(employee_id, payroll_period_start);

-- ── 3. Immutability: prevent UPDATE on both tables ──
CREATE OR REPLACE FUNCTION prevent_row_update()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'Updates are not allowed on %. Delete and re-create instead.', TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prevent_update_hour_bank
  BEFORE UPDATE ON public.hour_bank_transactions
  FOR EACH ROW EXECUTE FUNCTION prevent_row_update();

CREATE TRIGGER trg_prevent_update_sick_leave
  BEFORE UPDATE ON public.sick_leave_usages
  FOR EACH ROW EXECUTE FUNCTION prevent_row_update();

-- ── 4. Sick leave 14h/year safety net trigger ──
CREATE OR REPLACE FUNCTION check_sick_leave_limit()
RETURNS TRIGGER AS $$
DECLARE
  v_total NUMERIC;
BEGIN
  SELECT COALESCE(SUM(hours), 0) INTO v_total
  FROM public.sick_leave_usages
  WHERE employee_id = NEW.employee_id
    AND year = NEW.year
    AND id <> NEW.id;

  IF (v_total + NEW.hours) > 14 THEN
    RAISE EXCEPTION 'Sick leave limit exceeded: %.2f + %.2f > 14h for year %',
      v_total, NEW.hours, NEW.year;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_sick_leave_limit
  BEFORE INSERT ON public.sick_leave_usages
  FOR EACH ROW EXECUTE FUNCTION check_sick_leave_limit();

-- ── 5. Extend check_payroll_lock for new tables ──
CREATE OR REPLACE FUNCTION check_payroll_lock()
RETURNS TRIGGER AS $$
DECLARE
  v_employee_id UUID;
  v_date DATE;
  v_period_start DATE;
  v_period_end DATE;
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
  ELSIF TG_TABLE_NAME IN ('hour_bank_transactions', 'sick_leave_usages') THEN
    v_employee_id := COALESCE(NEW.employee_id, OLD.employee_id);
    v_period_start := COALESCE(NEW.payroll_period_start, OLD.payroll_period_start);
    v_period_end := COALESCE(NEW.payroll_period_end, OLD.payroll_period_end);
  END IF;

  -- Check for active payroll lock
  IF v_period_start IS NOT NULL THEN
    -- Period-based check (hour_bank_transactions, sick_leave_usages)
    IF EXISTS (
      SELECT 1 FROM payroll_approvals
      WHERE employee_id = v_employee_id
        AND status = 'approved'
        AND period_start = v_period_start
        AND period_end = v_period_end
    ) THEN
      RAISE EXCEPTION 'Payroll is locked for this period. Unlock payroll first.';
    END IF;
  ELSIF v_date IS NOT NULL THEN
    -- Date-based check (existing tables)
    IF EXISTS (
      SELECT 1 FROM payroll_approvals
      WHERE employee_id = v_employee_id
        AND status = 'approved'
        AND period_start <= v_date
        AND period_end >= v_date
    ) THEN
      RAISE EXCEPTION 'Payroll is locked for this period. Unlock payroll first.';
    END IF;
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create lock triggers on new tables
CREATE TRIGGER trg_payroll_lock_hour_bank
  BEFORE INSERT OR DELETE ON public.hour_bank_transactions
  FOR EACH ROW EXECUTE FUNCTION check_payroll_lock();

CREATE TRIGGER trg_payroll_lock_sick_leave
  BEFORE INSERT OR DELETE ON public.sick_leave_usages
  FOR EACH ROW EXECUTE FUNCTION check_payroll_lock();

-- ── 6. RLS ──
ALTER TABLE public.hour_bank_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sick_leave_usages ENABLE ROW LEVEL SECURITY;

-- hour_bank_transactions
CREATE POLICY "Admins full access" ON public.hour_bank_transactions
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM employee_profiles
      WHERE id = auth.uid() AND role IN ('admin', 'super_admin')
    )
  );

CREATE POLICY "Employees read own" ON public.hour_bank_transactions
  FOR SELECT USING (employee_id = auth.uid());

CREATE POLICY "Managers read supervised" ON public.hour_bank_transactions
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

-- sick_leave_usages (same pattern)
CREATE POLICY "Admins full access" ON public.sick_leave_usages
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM employee_profiles
      WHERE id = auth.uid() AND role IN ('admin', 'super_admin')
    )
  );

CREATE POLICY "Employees read own" ON public.sick_leave_usages
  FOR SELECT USING (employee_id = auth.uid());

CREATE POLICY "Managers read supervised" ON public.sick_leave_usages
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

-- Grants
GRANT ALL ON public.hour_bank_transactions TO authenticated;
GRANT ALL ON public.sick_leave_usages TO authenticated;

-- ============================================================
-- RPC: get_hour_bank_balance
-- ============================================================
CREATE OR REPLACE FUNCTION get_hour_bank_balance(p_employee_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_pay_type TEXT;
  v_deposit_total NUMERIC;
  v_withdrawal_total NUMERIC;
  v_balance_dollars NUMERIC;
  v_current_rate NUMERIC;
  v_balance_hours NUMERIC;
  v_last_date TIMESTAMPTZ;
BEGIN
  -- Validate hourly employee
  SELECT pay_type INTO v_pay_type
  FROM employee_profiles WHERE id = p_employee_id;

  IF v_pay_type = 'annual' THEN
    RAISE EXCEPTION 'Hour bank is only available for hourly employees';
  END IF;

  -- Calculate balance
  SELECT
    COALESCE(SUM(CASE WHEN transaction_type = 'deposit' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN transaction_type = 'withdrawal' THEN amount ELSE 0 END), 0),
    MAX(created_at)
  INTO v_deposit_total, v_withdrawal_total, v_last_date
  FROM hour_bank_transactions
  WHERE employee_id = p_employee_id;

  v_balance_dollars := v_deposit_total - v_withdrawal_total;

  -- Get current hourly rate
  SELECT rate INTO v_current_rate
  FROM employee_hourly_rates
  WHERE employee_id = p_employee_id
    AND effective_from <= CURRENT_DATE
    AND (effective_to IS NULL OR effective_to >= CURRENT_DATE)
  ORDER BY effective_from DESC
  LIMIT 1;

  v_balance_hours := CASE
    WHEN v_current_rate > 0 THEN ROUND(v_balance_dollars / v_current_rate, 2)
    ELSE 0
  END;

  RETURN jsonb_build_object(
    'balance_dollars', ROUND(v_balance_dollars, 2),
    'balance_hours', v_balance_hours,
    'current_hourly_rate', v_current_rate,
    'last_transaction_date', v_last_date
  );
END;
$$;

-- ============================================================
-- RPC: get_sick_leave_balance
-- ============================================================
CREATE OR REPLACE FUNCTION get_sick_leave_balance(
  p_employee_id UUID,
  p_year INTEGER DEFAULT EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_used NUMERIC;
  v_first_shift TIMESTAMPTZ;
  v_eligible BOOLEAN;
BEGIN
  SELECT COALESCE(SUM(hours), 0) INTO v_used
  FROM sick_leave_usages
  WHERE employee_id = p_employee_id AND year = p_year;

  SELECT MIN(clocked_in_at) INTO v_first_shift
  FROM shifts
  WHERE employee_id = p_employee_id;

  v_eligible := v_first_shift IS NOT NULL
    AND v_first_shift <= (CURRENT_DATE - INTERVAL '3 months');

  RETURN jsonb_build_object(
    'total_hours', 14,
    'used_hours', ROUND(v_used, 2),
    'remaining_hours', ROUND(14 - v_used, 2),
    'eligible', v_eligible,
    'first_shift_date', v_first_shift::DATE
  );
END;
$$;

-- ============================================================
-- RPC: add_hour_bank_transaction
-- ============================================================
CREATE OR REPLACE FUNCTION add_hour_bank_transaction(
  p_employee_id UUID,
  p_period_start DATE,
  p_period_end DATE,
  p_type TEXT,
  p_hours NUMERIC,
  p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_pay_type TEXT;
  v_rate NUMERIC;
  v_amount NUMERIC;
  v_balance NUMERIC;
  v_txn_id UUID;
BEGIN
  -- Validate employee is hourly
  SELECT pay_type INTO v_pay_type
  FROM employee_profiles WHERE id = p_employee_id;

  IF v_pay_type = 'annual' THEN
    RAISE EXCEPTION 'Hour bank is only available for hourly employees';
  END IF;

  -- Validate type
  IF p_type NOT IN ('deposit', 'withdrawal') THEN
    RAISE EXCEPTION 'Invalid transaction type: %', p_type;
  END IF;

  -- Get current hourly rate for the period
  SELECT rate INTO v_rate
  FROM employee_hourly_rates
  WHERE employee_id = p_employee_id
    AND effective_from <= p_period_end
    AND (effective_to IS NULL OR effective_to >= p_period_start)
  ORDER BY effective_from DESC
  LIMIT 1;

  IF v_rate IS NULL THEN
    RAISE EXCEPTION 'No hourly rate found for employee in this period';
  END IF;

  v_amount := ROUND(p_hours * v_rate, 2);

  -- For withdrawal: validate sufficient balance
  IF p_type = 'withdrawal' THEN
    SELECT
      COALESCE(SUM(CASE WHEN transaction_type = 'deposit' THEN amount ELSE 0 END), 0) -
      COALESCE(SUM(CASE WHEN transaction_type = 'withdrawal' THEN amount ELSE 0 END), 0)
    INTO v_balance
    FROM hour_bank_transactions
    WHERE employee_id = p_employee_id;

    IF v_balance < v_amount THEN
      RAISE EXCEPTION 'Insufficient bank balance: $% available, $% requested',
        ROUND(v_balance, 2), v_amount;
    END IF;
  END IF;

  -- Insert (triggers check_payroll_lock will fire)
  INSERT INTO hour_bank_transactions (
    employee_id, payroll_period_start, payroll_period_end,
    transaction_type, hours, hourly_rate, amount,
    reason, created_by
  ) VALUES (
    p_employee_id, p_period_start, p_period_end,
    p_type, p_hours, v_rate, v_amount,
    p_reason, auth.uid()
  )
  RETURNING id INTO v_txn_id;

  -- Return transaction + updated balance
  RETURN (SELECT get_hour_bank_balance(p_employee_id)) ||
    jsonb_build_object('transaction_id', v_txn_id);
END;
$$;

-- ============================================================
-- RPC: add_sick_leave_usage
-- ============================================================
CREATE OR REPLACE FUNCTION add_sick_leave_usage(
  p_employee_id UUID,
  p_period_start DATE,
  p_period_end DATE,
  p_hours NUMERIC,
  p_absence_date DATE,
  p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_rate NUMERIC;
  v_amount NUMERIC;
  v_year INTEGER;
  v_remaining NUMERIC;
  v_first_shift TIMESTAMPTZ;
  v_usage_id UUID;
BEGIN
  v_year := EXTRACT(YEAR FROM p_absence_date)::INTEGER;

  -- Validate absence_date in period
  IF p_absence_date < p_period_start OR p_absence_date > p_period_end THEN
    RAISE EXCEPTION 'Absence date % is outside pay period % to %',
      p_absence_date, p_period_start, p_period_end;
  END IF;

  -- Validate 3-month eligibility
  SELECT MIN(clocked_in_at) INTO v_first_shift
  FROM shifts WHERE employee_id = p_employee_id;

  IF v_first_shift IS NULL OR v_first_shift > (p_absence_date - INTERVAL '3 months') THEN
    RAISE EXCEPTION 'Employee is not eligible for paid sick leave (requires 3 months service)';
  END IF;

  -- Validate remaining balance
  SELECT 14 - COALESCE(SUM(hours), 0) INTO v_remaining
  FROM sick_leave_usages
  WHERE employee_id = p_employee_id AND year = v_year;

  IF v_remaining < p_hours THEN
    RAISE EXCEPTION 'Insufficient sick leave balance: %.2fh remaining, %.2fh requested',
      v_remaining, p_hours;
  END IF;

  -- Get current hourly rate
  SELECT rate INTO v_rate
  FROM employee_hourly_rates
  WHERE employee_id = p_employee_id
    AND effective_from <= p_absence_date
    AND (effective_to IS NULL OR effective_to >= p_absence_date)
  ORDER BY effective_from DESC
  LIMIT 1;

  IF v_rate IS NULL THEN
    -- For annual employees, derive rate from salary
    SELECT (salary / 2080)::NUMERIC(10,2) INTO v_rate
    FROM employee_annual_salaries
    WHERE employee_id = p_employee_id
      AND effective_from <= p_absence_date
      AND (effective_to IS NULL OR effective_to >= p_absence_date)
    ORDER BY effective_from DESC
    LIMIT 1;
  END IF;

  IF v_rate IS NULL THEN
    RAISE EXCEPTION 'No hourly rate or salary found for employee on %', p_absence_date;
  END IF;

  v_amount := ROUND(p_hours * v_rate, 2);

  -- Insert (triggers check_payroll_lock + check_sick_leave_limit will fire)
  INSERT INTO sick_leave_usages (
    employee_id, payroll_period_start, payroll_period_end,
    hours, absence_date, hourly_rate, amount,
    reason, year, created_by
  ) VALUES (
    p_employee_id, p_period_start, p_period_end,
    p_hours, p_absence_date, v_rate, v_amount,
    p_reason, v_year, auth.uid()
  )
  RETURNING id INTO v_usage_id;

  RETURN (SELECT get_sick_leave_balance(p_employee_id, v_year)) ||
    jsonb_build_object('usage_id', v_usage_id);
END;
$$;

-- ============================================================
-- RPC: delete_hour_bank_transaction
-- ============================================================
CREATE OR REPLACE FUNCTION delete_hour_bank_transaction(p_transaction_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_employee_id UUID;
  v_type TEXT;
  v_amount NUMERIC;
  v_balance NUMERIC;
BEGIN
  SELECT employee_id, transaction_type, amount
  INTO v_employee_id, v_type, v_amount
  FROM hour_bank_transactions WHERE id = p_transaction_id;

  IF v_employee_id IS NULL THEN
    RAISE EXCEPTION 'Transaction not found';
  END IF;

  -- For deposit deletion: check balance won't go negative
  IF v_type = 'deposit' THEN
    SELECT
      COALESCE(SUM(CASE WHEN transaction_type = 'deposit' THEN amount ELSE 0 END), 0) -
      COALESCE(SUM(CASE WHEN transaction_type = 'withdrawal' THEN amount ELSE 0 END), 0)
    INTO v_balance
    FROM hour_bank_transactions
    WHERE employee_id = v_employee_id;

    IF (v_balance - v_amount) < 0 THEN
      RAISE EXCEPTION 'Cannot delete deposit: balance would become negative ($%)',
        ROUND(v_balance - v_amount, 2);
    END IF;
  END IF;

  -- Delete (trigger check_payroll_lock will fire)
  DELETE FROM hour_bank_transactions WHERE id = p_transaction_id;

  RETURN (SELECT get_hour_bank_balance(v_employee_id));
END;
$$;

-- ============================================================
-- RPC: delete_sick_leave_usage
-- ============================================================
CREATE OR REPLACE FUNCTION delete_sick_leave_usage(p_usage_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_employee_id UUID;
  v_year INTEGER;
BEGIN
  SELECT employee_id, year INTO v_employee_id, v_year
  FROM sick_leave_usages WHERE id = p_usage_id;

  IF v_employee_id IS NULL THEN
    RAISE EXCEPTION 'Sick leave usage not found';
  END IF;

  -- Delete (trigger check_payroll_lock will fire)
  DELETE FROM sick_leave_usages WHERE id = p_usage_id;

  RETURN (SELECT get_sick_leave_balance(v_employee_id, v_year));
END;
$$;

-- ============================================================
-- RPC: get_hour_bank_history
-- ============================================================
CREATE OR REPLACE FUNCTION get_hour_bank_history(p_employee_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  RETURN (
    SELECT COALESCE(jsonb_agg(row_data ORDER BY created_at DESC), '[]'::jsonb)
    FROM (
      -- Bank transactions
      SELECT
        hbt.id AS transaction_id,
        hbt.created_at,
        hbt.transaction_type AS type,
        hbt.hours,
        hbt.hourly_rate,
        hbt.amount,
        hbt.payroll_period_start AS period_start,
        hbt.payroll_period_end AS period_end,
        hbt.reason,
        ep.full_name AS created_by_name,
        NOT EXISTS (
          SELECT 1 FROM payroll_approvals pa
          WHERE pa.employee_id = hbt.employee_id
            AND pa.status = 'approved'
            AND pa.period_start = hbt.payroll_period_start
            AND pa.period_end = hbt.payroll_period_end
        ) AS can_delete
      FROM hour_bank_transactions hbt
      JOIN employee_profiles ep ON ep.id = hbt.created_by
      WHERE hbt.employee_id = p_employee_id

      UNION ALL

      -- Sick leave usages
      SELECT
        slu.id AS transaction_id,
        slu.created_at,
        'sick_leave'::TEXT AS type,
        slu.hours,
        slu.hourly_rate,
        slu.amount,
        slu.payroll_period_start AS period_start,
        slu.payroll_period_end AS period_end,
        slu.reason,
        ep.full_name AS created_by_name,
        NOT EXISTS (
          SELECT 1 FROM payroll_approvals pa
          WHERE pa.employee_id = slu.employee_id
            AND pa.status = 'approved'
            AND pa.period_start = slu.payroll_period_start
            AND pa.period_end = slu.payroll_period_end
        ) AS can_delete
      FROM sick_leave_usages slu
      JOIN employee_profiles ep ON ep.id = slu.created_by
      WHERE slu.employee_id = p_employee_id
    ) row_data
  );
END;
$$;

-- Grants for new RPCs
GRANT EXECUTE ON FUNCTION get_hour_bank_balance TO authenticated;
GRANT EXECUTE ON FUNCTION get_sick_leave_balance TO authenticated;
GRANT EXECUTE ON FUNCTION add_hour_bank_transaction TO authenticated;
GRANT EXECUTE ON FUNCTION add_sick_leave_usage TO authenticated;
GRANT EXECUTE ON FUNCTION delete_hour_bank_transaction TO authenticated;
GRANT EXECUTE ON FUNCTION delete_sick_leave_usage TO authenticated;
GRANT EXECUTE ON FUNCTION get_hour_bank_history TO authenticated;
GRANT EXECUTE ON FUNCTION get_sick_leave_history TO authenticated;

-- ============================================================
-- Task 3: Extend get_payroll_period_report with bank/sick columns
-- ============================================================
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
  rejected_minutes INTEGER,
  bank_deposit_hours NUMERIC,
  bank_deposit_amount NUMERIC,
  bank_withdrawal_hours NUMERIC,
  bank_withdrawal_amount NUMERIC,
  sick_leave_hours NUMERIC,
  sick_leave_amount NUMERIC,
  bank_balance_dollars NUMERIC,
  bank_balance_hours NUMERIC,
  sick_leave_remaining NUMERIC
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

  -- Callback shifts (shift_type = 'call') — uses effective_shift_times()
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

  -- Hour bank transactions for this period
  bank_period AS (
    SELECT employee_id,
      COALESCE(SUM(CASE WHEN transaction_type = 'deposit' THEN hours END), 0) AS deposit_hours,
      COALESCE(SUM(CASE WHEN transaction_type = 'deposit' THEN amount END), 0) AS deposit_amount,
      COALESCE(SUM(CASE WHEN transaction_type = 'withdrawal' THEN hours END), 0) AS withdrawal_hours,
      COALESCE(SUM(CASE WHEN transaction_type = 'withdrawal' THEN amount END), 0) AS withdrawal_amount
    FROM hour_bank_transactions
    WHERE payroll_period_start = p_period_start AND payroll_period_end = p_period_end
    GROUP BY employee_id
  ),

  -- Hour bank running balance (all time)
  bank_balance AS (
    SELECT employee_id,
      COALESCE(SUM(CASE WHEN transaction_type = 'deposit' THEN amount ELSE 0 END), 0) -
      COALESCE(SUM(CASE WHEN transaction_type = 'withdrawal' THEN amount ELSE 0 END), 0) AS balance_dollars
    FROM hour_bank_transactions
    GROUP BY employee_id
  ),

  -- Sick leave usages for this period
  sick_period AS (
    SELECT employee_id,
      COALESCE(SUM(hours), 0) AS hours,
      COALESCE(SUM(amount), 0) AS amount
    FROM sick_leave_usages
    WHERE payroll_period_start = p_period_start AND payroll_period_end = p_period_end
    GROUP BY employee_id
  ),

  -- Sick leave remaining for this year (14h annual entitlement)
  sick_balance AS (
    SELECT employee_id, 14 - COALESCE(SUM(hours), 0) AS remaining
    FROM sick_leave_usages
    WHERE year = EXTRACT(YEAR FROM p_period_start)::INTEGER
    GROUP BY employee_id
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
      -- Hour bank columns
      COALESCE(bp.deposit_hours, 0) AS bank_deposit_hours,
      COALESCE(bp.deposit_amount, 0) AS bank_deposit_amount,
      COALESCE(bp.withdrawal_hours, 0) AS bank_withdrawal_hours,
      COALESCE(bp.withdrawal_amount, 0) AS bank_withdrawal_amount,
      -- Sick leave columns
      COALESCE(sp.hours, 0) AS sick_leave_hours,
      COALESCE(sp.amount, 0) AS sick_leave_amount,
      -- Balances
      COALESCE(bb.balance_dollars, 0) AS bank_balance_dollars,
      CASE WHEN COALESCE(r.rate, 0) > 0
        THEN ROUND(COALESCE(bb.balance_dollars, 0) / r.rate, 2)
        ELSE 0
      END AS bank_balance_hours,
      COALESCE(sb.remaining, 14) AS sick_leave_remaining,
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
    LEFT JOIN bank_period bp ON bp.employee_id = te.id
    LEFT JOIN bank_balance bb ON bb.employee_id = te.id
    LEFT JOIN sick_period sp ON sp.employee_id = te.id
    LEFT JOIN sick_balance sb ON sb.employee_id = te.id
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
    -- Total (adjusted for bank deposits/withdrawals and sick leave)
    CASE
      WHEN c.pay_type = 'annual' AND c.rn = 1 THEN
        COALESCE(c.period_salary, 0) + c.premium_amount
        + COALESCE(c.sick_leave_amount, 0)
      WHEN c.pay_type = 'annual' THEN
        c.premium_amount
      WHEN c.rn = 1 THEN
        c.base_amount_raw + c.premium_amount + COALESCE(c.callback_bonus_amount, 0)
        - COALESCE(c.bank_deposit_amount, 0)
        + COALESCE(c.bank_withdrawal_amount, 0)
        + COALESCE(c.sick_leave_amount, 0)
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
    c.rejected_minutes,
    -- Bank/sick columns (first row only per employee)
    CASE WHEN c.rn = 1 THEN c.bank_deposit_hours ELSE NULL END AS bank_deposit_hours,
    CASE WHEN c.rn = 1 THEN c.bank_deposit_amount ELSE NULL END AS bank_deposit_amount,
    CASE WHEN c.rn = 1 THEN c.bank_withdrawal_hours ELSE NULL END AS bank_withdrawal_hours,
    CASE WHEN c.rn = 1 THEN c.bank_withdrawal_amount ELSE NULL END AS bank_withdrawal_amount,
    CASE WHEN c.rn = 1 THEN c.sick_leave_hours ELSE NULL END AS sick_leave_hours,
    CASE WHEN c.rn = 1 THEN c.sick_leave_amount ELSE NULL END AS sick_leave_amount,
    CASE WHEN c.rn = 1 THEN c.bank_balance_dollars ELSE NULL END AS bank_balance_dollars,
    CASE WHEN c.rn = 1 THEN c.bank_balance_hours ELSE NULL END AS bank_balance_hours,
    CASE WHEN c.rn = 1 THEN c.sick_leave_remaining ELSE NULL END AS sick_leave_remaining
  FROM combined c
  ORDER BY c.primary_category NULLS LAST, c.full_name, c.date;
END;
$$;

COMMENT ON FUNCTION get_payroll_period_report IS 'Payroll report with day-level breakdown per employee. Includes approved/break/callback/cleaning/maintenance/admin minutes, hourly/annual pay, weekend premium, callback bonus (Art.58 3h min with effective_shift_times), mileage reimbursement (CRA or forfait), break deduction, rejected minutes, hour bank deposits/withdrawals/balance, and sick leave usage/remaining.';
