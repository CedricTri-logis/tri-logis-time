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
