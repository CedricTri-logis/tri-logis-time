# Hour Bank & Sick Leave Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow admins to bank employee hours (as dollars) and apply paid sick leave during payroll approval.

**Architecture:** Two new tables (`hour_bank_transactions`, `sick_leave_usages`) with dollar-based bank storage. RPCs for CRUD operations integrated into the existing payroll lock system. Dashboard modal for adjustments, new columns in payroll table, full transaction history view.

**Tech Stack:** PostgreSQL/Supabase (migration + RPCs), TypeScript/Next.js/React (dashboard), shadcn/ui components, existing Refine patterns.

**Spec:** `docs/superpowers/specs/2026-03-24-hour-bank-sick-leave-design.md`

---

## File Map

### New Files
- `supabase/migrations/20260327200000_hour_bank_sick_leave.sql` — Tables, indexes, constraints, RLS, triggers, all RPCs
- `dashboard/src/components/payroll/payroll-adjustments-modal.tsx` — Modal for bank deposit/withdraw + sick leave
- `dashboard/src/components/payroll/hour-bank-history-dialog.tsx` — Full transaction history dialog

### Modified Files
- `supabase/migrations/20260325100000_payroll_approvals.sql` — Reference only (DO NOT modify — we CREATE OR REPLACE in new migration)
- `dashboard/src/types/payroll.ts` — Add bank/sick fields to PayrollReportRow, PayrollEmployeeSummary, PayrollCategoryGroup
- `dashboard/src/lib/hooks/use-payroll-report.ts` — Aggregate bank/sick fields in employee summaries and category totals
- `dashboard/src/components/payroll/payroll-summary-table.tsx` — Add 4 columns + Ajustements button
- `dashboard/src/lib/utils/export-payroll-excel.ts` — Add Banque and Maladie columns to both sheets

---

## Task 1: Database Tables, Constraints, Indexes, RLS

**Files:**
- Create: `supabase/migrations/20260327200000_hour_bank_sick_leave.sql`

- [ ] **Step 1: Create the migration file with both tables**

```sql
-- ============================================================
-- Hour Bank & Sick Leave — Tables, Constraints, Indexes, RLS
-- ============================================================

-- ── hour_bank_transactions ──
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

COMMENT ON TABLE public.hour_bank_transactions IS 'ROLE: Journal des transactions de banque d''heures (dépôts/retraits). STATUT: Immutable (insert/delete only). REGLES: La banque stocke des dollars (hours × rate = amount). Dépôt = heures retirées de la paie, converties en $. Retrait = $ convertis en heures au taux actuel. Solde = SUM(deposit amounts) - SUM(withdrawal amounts). Ne peut pas devenir négatif. Horaires seulement (pas annuels). RELATIONS: FK employee_profiles, FK auth.users. TRIGGERS: check_payroll_lock (bloque si paie approuvée), prevent_update (immutable).';

CREATE INDEX idx_hour_bank_employee_period ON public.hour_bank_transactions(employee_id, payroll_period_start);
CREATE INDEX idx_hour_bank_employee_type ON public.hour_bank_transactions(employee_id, transaction_type);

-- ── sick_leave_usages ──
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

COMMENT ON TABLE public.sick_leave_usages IS 'ROLE: Journal des heures maladie utilisées. STATUT: Immutable (insert/delete only). REGLES: 14h/année (LNT Art. 79.7, 2 jours × 7h). Reset 1er janvier. Éligibilité: 3 mois service continu (vérifié via premier shift). Taux = taux horaire courant. Disponible horaires ET annuels. RELATIONS: FK employee_profiles, FK auth.users. TRIGGERS: check_payroll_lock, prevent_update, check_sick_leave_limit.';

CREATE INDEX idx_sick_leave_employee_year ON public.sick_leave_usages(employee_id, year);
CREATE INDEX idx_sick_leave_employee_period ON public.sick_leave_usages(employee_id, payroll_period_start);
```

- [ ] **Step 2: Add immutability triggers (prevent UPDATE)**

```sql
-- ── Immutability: prevent UPDATE on both tables ──
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
```

- [ ] **Step 3: Add sick leave limit trigger (safety net)**

```sql
-- ── Sick leave 14h/year safety net trigger ──
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
```

- [ ] **Step 4: Integrate into check_payroll_lock**

```sql
-- ── Extend check_payroll_lock for new tables ──
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
```

- [ ] **Step 5: Add RLS policies**

```sql
-- ── RLS ──
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
```

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/20260327200000_hour_bank_sick_leave.sql
git commit -m "feat(db): add hour_bank_transactions and sick_leave_usages tables

Tables, indexes, CHECK constraints, RLS policies, immutability triggers,
payroll lock integration, and sick leave 14h/year safety net trigger."
```

---

## Task 2: RPC Functions

**Files:**
- Modify: `supabase/migrations/20260327200000_hour_bank_sick_leave.sql` (append to same migration)

- [ ] **Step 1: Add get_hour_bank_balance RPC**

```sql
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
```

- [ ] **Step 2: Add get_sick_leave_balance RPC**

```sql
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
```

- [ ] **Step 3: Add add_hour_bank_transaction RPC**

```sql
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
```

- [ ] **Step 4: Add add_sick_leave_usage RPC**

```sql
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
```

- [ ] **Step 5: Add delete RPCs**

```sql
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
```

- [ ] **Step 6: Add get_hour_bank_history RPC**

```sql
-- ============================================================
-- RPC: get_hour_bank_history
-- ============================================================
CREATE OR REPLACE FUNCTION get_hour_bank_history(p_employee_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  RETURN (
    SELECT jsonb_agg(row_data ORDER BY created_at DESC)
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
```

- [ ] **Step 7: Commit**

```bash
git add supabase/migrations/20260327200000_hour_bank_sick_leave.sql
git commit -m "feat(db): add hour bank & sick leave RPCs

get/add/delete for both bank transactions and sick leave usages,
plus combined history view. Dollar-based bank with current-rate conversion."
```

---

## Task 3: Modify get_payroll_period_report

**Files:**
- Modify: `supabase/migrations/20260327200000_hour_bank_sick_leave.sql` (append full CREATE OR REPLACE)

**Reference:** Latest full rewrite is `supabase/migrations/20260326400000_mileage_allowance_forfait.sql:442-863`. Then patched by `20260327100000_fix_callback_bonus_use_effective_times.sql:71-108` (callbacks CTE uses `effective_shift_times()`). The version below includes the patch.

- [ ] **Step 1: Read the live function to confirm current state**

Run this SQL to get the actual current function body from the database:
```sql
SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = 'get_payroll_period_report';
```
Verify it matches the version in `20260326400000` + the `20260327100000` callback patch.

- [ ] **Step 2: Append the full CREATE OR REPLACE to the migration**

Append the complete function to `supabase/migrations/20260327200000_hour_bank_sick_leave.sql`. Changes from current version:
- RETURNS TABLE: +9 new columns at end
- +4 new CTEs: `bank_period`, `bank_balance`, `sick_period`, `sick_balance`
- combined CTE: +4 LEFT JOINs (bank/sick CTEs join on `te.id`)
- combined CTE: +9 new columns using `rn = 1` pattern
- Final SELECT: +9 columns, updated `total_amount` CASE (both hourly AND annual branches)

The 4 new CTEs go after `mileage_data` and before `combined`:

```sql
  -- Bank transactions for this period
  bank_period AS (
    SELECT
      employee_id,
      COALESCE(SUM(CASE WHEN transaction_type = 'deposit' THEN hours END), 0) AS deposit_hours,
      COALESCE(SUM(CASE WHEN transaction_type = 'deposit' THEN amount END), 0) AS deposit_amount,
      COALESCE(SUM(CASE WHEN transaction_type = 'withdrawal' THEN hours END), 0) AS withdrawal_hours,
      COALESCE(SUM(CASE WHEN transaction_type = 'withdrawal' THEN amount END), 0) AS withdrawal_amount
    FROM hour_bank_transactions
    WHERE payroll_period_start = p_period_start
      AND payroll_period_end = p_period_end
    GROUP BY employee_id
  ),

  -- Lifetime bank balance (all periods)
  bank_balance AS (
    SELECT
      employee_id,
      COALESCE(SUM(CASE WHEN transaction_type = 'deposit' THEN amount ELSE 0 END), 0) -
      COALESCE(SUM(CASE WHEN transaction_type = 'withdrawal' THEN amount ELSE 0 END), 0) AS balance_dollars
    FROM hour_bank_transactions
    GROUP BY employee_id
  ),

  -- Sick leave for this period
  sick_period AS (
    SELECT
      employee_id,
      COALESCE(SUM(hours), 0) AS hours,
      COALESCE(SUM(amount), 0) AS amount
    FROM sick_leave_usages
    WHERE payroll_period_start = p_period_start
      AND payroll_period_end = p_period_end
    GROUP BY employee_id
  ),

  -- Sick leave yearly balance
  sick_balance AS (
    SELECT
      employee_id,
      14 - COALESCE(SUM(hours), 0) AS remaining
    FROM sick_leave_usages
    WHERE year = EXTRACT(YEAR FROM p_period_start)::INTEGER
    GROUP BY employee_id
  ),
```

In the `combined` CTE, add 4 LEFT JOINs after `LEFT JOIN mileage_data md ON md.employee_id = te.id`:

```sql
    LEFT JOIN bank_period bp ON bp.employee_id = te.id
    LEFT JOIN bank_balance bb ON bb.employee_id = te.id
    LEFT JOIN sick_period sp ON sp.employee_id = te.id
    LEFT JOIN sick_balance sb ON sb.employee_id = te.id
```

In the `combined` CTE SELECT list, add these columns (before `ROW_NUMBER()`):

```sql
      -- Bank/sick data (per-employee, displayed on rn=1 row only in final SELECT)
      COALESCE(bp.deposit_hours, 0) AS bank_deposit_hours,
      COALESCE(bp.deposit_amount, 0) AS bank_deposit_amount,
      COALESCE(bp.withdrawal_hours, 0) AS bank_withdrawal_hours,
      COALESCE(bp.withdrawal_amount, 0) AS bank_withdrawal_amount,
      COALESCE(sp.hours, 0) AS sick_leave_hours,
      COALESCE(sp.amount, 0) AS sick_leave_amount,
      COALESCE(bb.balance_dollars, 0) AS bank_balance_dollars,
      CASE WHEN COALESCE(r.rate, 0) > 0
        THEN ROUND(COALESCE(bb.balance_dollars, 0) / r.rate, 2)
        ELSE 0
      END AS bank_balance_hours,
      COALESCE(sb.remaining, 14) AS sick_leave_remaining,
```

In the final SELECT, add these after `c.rejected_minutes`:

```sql
    -- Bank/sick (first row only per employee)
    CASE WHEN c.rn = 1 THEN c.bank_deposit_hours ELSE NULL END AS bank_deposit_hours,
    CASE WHEN c.rn = 1 THEN c.bank_deposit_amount ELSE NULL END AS bank_deposit_amount,
    CASE WHEN c.rn = 1 THEN c.bank_withdrawal_hours ELSE NULL END AS bank_withdrawal_hours,
    CASE WHEN c.rn = 1 THEN c.bank_withdrawal_amount ELSE NULL END AS bank_withdrawal_amount,
    CASE WHEN c.rn = 1 THEN c.sick_leave_hours ELSE NULL END AS sick_leave_hours,
    CASE WHEN c.rn = 1 THEN c.sick_leave_amount ELSE NULL END AS sick_leave_amount,
    CASE WHEN c.rn = 1 THEN c.bank_balance_dollars ELSE NULL END AS bank_balance_dollars,
    CASE WHEN c.rn = 1 THEN c.bank_balance_hours ELSE NULL END AS bank_balance_hours,
    CASE WHEN c.rn = 1 THEN c.sick_leave_remaining ELSE NULL END AS sick_leave_remaining
```

Update the `total_amount` CASE in the final SELECT to include bank/sick adjustments (rn=1 only):

```sql
    -- Total (updated: includes bank + sick adjustments on first row)
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
```

And add 9 new columns to RETURNS TABLE (after `rejected_minutes INTEGER`):

```sql
  bank_deposit_hours NUMERIC,
  bank_deposit_amount NUMERIC,
  bank_withdrawal_hours NUMERIC,
  bank_withdrawal_amount NUMERIC,
  sick_leave_hours NUMERIC,
  sick_leave_amount NUMERIC,
  bank_balance_dollars NUMERIC,
  bank_balance_hours NUMERIC,
  sick_leave_remaining NUMERIC
```

- [ ] **Step 3: Verify the full function compiles**

Apply the migration and verify no SQL errors.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260327200000_hour_bank_sick_leave.sql
git commit -m "feat(db): add bank/sick columns to get_payroll_period_report

Adds CTEs for period bank transactions, lifetime bank balance,
period sick leave, and yearly sick balance. Adjusts total_amount
for both hourly (bank+sick) and annual (sick only) employees."
```

---

## Task 4: TypeScript Types

**Files:**
- Modify: `dashboard/src/types/payroll.ts`

- [ ] **Step 1: Read current types file**

Read: `dashboard/src/types/payroll.ts`

- [ ] **Step 2: Add fields to PayrollReportRow**

After `rejected_minutes: number;` add:

```typescript
  // Hour bank
  bank_deposit_hours: number | null;
  bank_deposit_amount: number | null;
  bank_withdrawal_hours: number | null;
  bank_withdrawal_amount: number | null;
  bank_balance_dollars: number | null;
  bank_balance_hours: number | null;
  // Sick leave
  sick_leave_hours: number | null;
  sick_leave_amount: number | null;
  sick_leave_remaining: number | null;
```

- [ ] **Step 3: Add fields to PayrollEmployeeSummary**

After `days: PayrollReportRow[];` (or before it), add:

```typescript
  // Hour bank (period totals)
  bank_deposit_hours: number;
  bank_deposit_amount: number;
  bank_withdrawal_hours: number;
  bank_withdrawal_amount: number;
  bank_net_amount: number; // withdrawal - deposit (positive = added to pay)
  bank_balance_dollars: number;
  bank_balance_hours: number;
  // Sick leave (period totals)
  sick_leave_hours: number;
  sick_leave_amount: number;
  sick_leave_remaining: number;
```

- [ ] **Step 4: Add fields to PayrollCategoryGroup.totals**

After `rejected_minutes: number;` add:

```typescript
    bank_net_amount: number;
    sick_leave_amount: number;
```

- [ ] **Step 5: Add HourBankTransaction type for history**

At end of file:

```typescript
export interface HourBankTransaction {
  transaction_id: string;
  created_at: string;
  type: 'deposit' | 'withdrawal' | 'sick_leave';
  hours: number;
  hourly_rate: number;
  amount: number;
  period_start: string;
  period_end: string;
  reason: string;
  created_by_name: string;
  can_delete: boolean;
}
```

- [ ] **Step 6: Commit**

```bash
git add dashboard/src/types/payroll.ts
git commit -m "feat(types): add bank hours and sick leave fields to payroll types"
```

---

## Task 5: Payroll Hook Update

**Files:**
- Modify: `dashboard/src/lib/hooks/use-payroll-report.ts`

- [ ] **Step 1: Read current hook file**

Read: `dashboard/src/lib/hooks/use-payroll-report.ts`

- [ ] **Step 2: Add bank/sick aggregation in employee summary computation**

In the section that builds `PayrollEmployeeSummary` from grouped rows (~lines 37-93), add these aggregations alongside existing ones:

```typescript
// Bank hours — values come from first row only (rn=1), so take from first non-null
const firstRow = rows[0];
const bank_deposit_hours = firstRow.bank_deposit_hours ?? 0;
const bank_deposit_amount = firstRow.bank_deposit_amount ?? 0;
const bank_withdrawal_hours = firstRow.bank_withdrawal_hours ?? 0;
const bank_withdrawal_amount = firstRow.bank_withdrawal_amount ?? 0;
const bank_net_amount = bank_withdrawal_amount - bank_deposit_amount;
const bank_balance_dollars = firstRow.bank_balance_dollars ?? 0;
const bank_balance_hours = firstRow.bank_balance_hours ?? 0;

// Sick leave
const sick_leave_hours = firstRow.sick_leave_hours ?? 0;
const sick_leave_amount = firstRow.sick_leave_amount ?? 0;
const sick_leave_remaining = firstRow.sick_leave_remaining ?? 14;
```

Add these fields to the returned `PayrollEmployeeSummary` object.

- [ ] **Step 3: Add bank/sick to category group totals**

In the category grouping section (~lines 95-123), add to totals:

```typescript
bank_net_amount: employees.reduce((s, e) => s + e.bank_net_amount, 0),
sick_leave_amount: employees.reduce((s, e) => s + e.sick_leave_amount, 0),
```

- [ ] **Step 4: Add bank/sick to grand total**

In the grand total section (~lines 125-132), add the same two fields summed across all employees.

- [ ] **Step 5: Verify build**

Run: `cd dashboard && npm run build`
Expected: No type errors.

- [ ] **Step 6: Commit**

```bash
git add dashboard/src/lib/hooks/use-payroll-report.ts
git commit -m "feat(hook): aggregate bank hours and sick leave in payroll summary"
```

---

## Task 6: Payroll Adjustments Modal

**Files:**
- Create: `dashboard/src/components/payroll/payroll-adjustments-modal.tsx`

- [ ] **Step 1: Create the modal component**

Build `PayrollAdjustmentsModal` with these props:

```typescript
interface PayrollAdjustmentsModalProps {
  open: boolean;
  onClose: () => void;
  employee: PayrollEmployeeSummary;
  period: PayPeriod;
  onSuccess: () => void; // triggers silentRefetch
}
```

Component structure:
- Uses `Dialog` from shadcn/ui
- Header: employee name + period range + approved hours
- **Bank section:**
  - Balance bar: `balance_dollars` + `balance_hours` display
  - Select: "Déposer (← paie)" / "Retirer (→ paie)"
  - Number input: hours (step 0.5)
  - Computed display: `hours × currentRate = $amount`
  - Text input: reason (required)
  - Only visible if `employee.pay_type === 'hourly'`
- **Sick leave section:**
  - Balance bar: `sick_leave_remaining` / 14h + used this year
  - Number input: hours (step 0.5, max = remaining)
  - Date input: absence_date (constrained to period)
  - Text input: reason (required)
- **Impact preview:**
  - Approved hours, bank adjustment (+/-), sick leave (+), deductions, total
- Footer: "Annuler" + "Appliquer les ajustements"

**Key imports:**
```typescript
import { createClient } from '@/lib/supabase/client';
import { toast } from 'sonner';
```

RPC calls on submit:
1. If bank hours > 0: call `add_hour_bank_transaction` via `supabase.rpc()`
2. If sick hours > 0: call `add_sick_leave_usage` via `supabase.rpc()`
3. On success: call `onSuccess()` to trigger refetch, then close
4. On error: show toast with error message, don't close

```typescript
const supabase = createClient();

const handleSubmit = async () => {
  setLoading(true);
  try {
    if (bankHours > 0) {
      const { error } = await supabase.rpc('add_hour_bank_transaction', {
        p_employee_id: employee.employee_id,
        p_period_start: period.start,
        p_period_end: period.end,
        p_type: bankOperation,
        p_hours: bankHours,
        p_reason: bankReason,
      });
      if (error) throw error;
    }
    if (sickHours > 0) {
      const { error } = await supabase.rpc('add_sick_leave_usage', {
        p_employee_id: employee.employee_id,
        p_period_start: period.start,
        p_period_end: period.end,
        p_hours: sickHours,
        p_absence_date: absenceDate,
        p_reason: sickReason,
      });
      if (error) throw error;
    }
    onSuccess();
    onClose();
  } catch (err: any) {
    toast.error(err.message);
  } finally {
    setLoading(false);
  }
};
```

- [ ] **Step 2: Fetch balances on modal open**

Use `useEffect` to fetch both balances when modal opens:

```typescript
useEffect(() => {
  if (!open) return;
  const fetchBalances = async () => {
    if (employee.pay_type === 'hourly') {
      const { data } = await supabase.rpc('get_hour_bank_balance', {
        p_employee_id: employee.employee_id,
      });
      setBankBalance(data);
    }
    const { data } = await supabase.rpc('get_sick_leave_balance', {
      p_employee_id: employee.employee_id,
    });
    setSickBalance(data);
  };
  fetchBalances();
}, [open, employee.employee_id]);
```

- [ ] **Step 3: Verify build**

Run: `cd dashboard && npm run build`

- [ ] **Step 4: Commit**

```bash
git add dashboard/src/components/payroll/payroll-adjustments-modal.tsx
git commit -m "feat(ui): add PayrollAdjustmentsModal for bank hours and sick leave"
```

---

## Task 7: Hour Bank History Dialog

**Files:**
- Create: `dashboard/src/components/payroll/hour-bank-history-dialog.tsx`

- [ ] **Step 1: Create the history dialog component**

**Key imports:**
```typescript
import { createClient } from '@/lib/supabase/client';
import { toast } from 'sonner';
import type { HourBankTransaction } from '@/types/payroll';
```

```typescript
interface HourBankHistoryDialogProps {
  open: boolean;
  onClose: () => void;
  employeeId: string;
  employeeName: string;
  onDelete: () => void; // triggers refetch after deletion
}
```

Component structure:
- Uses `Dialog` from shadcn/ui
- Header: employee name + balance summary (bank $ + hours | sick remaining)
- Table with columns: Date, Type (badge), Heures, Taux, Valeur, Période, Raison, Par, Actions
- Type badges: "Dépôt banque" (blue), "Retrait banque" (green), "Maladie" (red)
- Delete button per row (disabled if `can_delete === false`, shows tooltip "Paie verrouillée")
- Summary footer: total deposited, total withdrawn, current balance, sick used this year

Data fetching:
```typescript
const fetchHistory = async () => {
  const { data } = await supabase.rpc('get_hour_bank_history', {
    p_employee_id: employeeId,
  });
  setTransactions(data ?? []);
};
```

Delete handler:
```typescript
const handleDelete = async (txn: HourBankTransaction) => {
  const rpcName = txn.type === 'sick_leave'
    ? 'delete_sick_leave_usage'
    : 'delete_hour_bank_transaction';
  const paramName = txn.type === 'sick_leave'
    ? 'p_usage_id'
    : 'p_transaction_id';

  const { error } = await supabase.rpc(rpcName, {
    [paramName]: txn.transaction_id,
  });

  if (error) {
    toast.error(error.message);
    return;
  }

  fetchHistory();
  onDelete();
};
```

- [ ] **Step 2: Verify build**

Run: `cd dashboard && npm run build`

- [ ] **Step 3: Commit**

```bash
git add dashboard/src/components/payroll/hour-bank-history-dialog.tsx
git commit -m "feat(ui): add HourBankHistoryDialog with delete support"
```

---

## Task 8: Payroll Summary Table — New Columns

**Files:**
- Modify: `dashboard/src/components/payroll/payroll-summary-table.tsx`

- [ ] **Step 1: Read current table file**

Read: `dashboard/src/components/payroll/payroll-summary-table.tsx`

- [ ] **Step 2: Add 4 new column headers**

After the "Refusées" header (~line 76), add:

```tsx
<th className="text-right text-xs px-2 py-2 text-blue-700 bg-blue-50">Banque +/-</th>
<th className="text-right text-xs px-2 py-2 text-blue-700 bg-blue-50">Solde banque</th>
<th className="text-right text-xs px-2 py-2 text-green-700 bg-green-50">Maladie</th>
<th className="text-right text-xs px-2 py-2 text-green-700 bg-green-50">Solde mal.</th>
```

- [ ] **Step 3: Add 4 new data cells per employee row**

After the rejected_minutes cell, add:

```tsx
{/* Bank +/- */}
<td className="text-right text-xs px-2 py-2 bg-blue-50/50">
  {emp.bank_net_amount !== 0 ? (
    <span className={emp.bank_net_amount > 0 ? 'text-green-600 font-semibold' : 'text-red-600 font-semibold'}>
      {emp.bank_net_amount > 0 ? '+' : ''}{fmtMoney(emp.bank_net_amount)}
    </span>
  ) : '—'}
</td>
{/* Bank balance */}
<td className="text-right text-xs px-2 py-2 bg-blue-50/50">
  {emp.pay_type === 'hourly' ? (
    <span className="inline-flex items-center gap-1">
      <Badge variant="outline" className="text-blue-700 border-blue-200 bg-blue-50">
        {fmtMoney(emp.bank_balance_dollars)}
      </Badge>
      <span className="text-muted-foreground">
        ({formatMinutesAsHours(Math.round(emp.bank_balance_hours * 60))})
      </span>
    </span>
  ) : '—'}
</td>
{/* Sick leave hours */}
<td className="text-right text-xs px-2 py-2 bg-green-50/50">
  {emp.sick_leave_hours > 0 ? (
    <span className="text-green-600 font-semibold">
      {formatMinutesAsHours(Math.round(emp.sick_leave_hours * 60))}
    </span>
  ) : '—'}
</td>
{/* Sick leave remaining */}
<td className="text-right text-xs px-2 py-2 bg-green-50/50">
  <Badge variant="outline" className="text-green-700 border-green-200 bg-green-50">
    {formatMinutesAsHours(Math.round(emp.sick_leave_remaining * 60))}/14h
  </Badge>
</td>
```

- [ ] **Step 4: Add Ajustements button column**

Add header and cell:

```tsx
// Header (after Paie)
<th className="text-center text-xs px-2 py-2"></th>

// Cell
<td className="text-center px-2 py-2">
  <Button
    variant="outline"
    size="sm"
    className="text-xs h-7"
    onClick={(e) => {
      e.stopPropagation();
      setAdjustmentEmployee(emp);
    }}
  >
    Ajustements
  </Button>
</td>
```

- [ ] **Step 5: Add modal and history dialog state + rendering**

At component level:

```tsx
const [adjustmentEmployee, setAdjustmentEmployee] = useState<PayrollEmployeeSummary | null>(null);
const [historyEmployee, setHistoryEmployee] = useState<{id: string; name: string} | null>(null);

// In JSX (after table):
<PayrollAdjustmentsModal
  open={!!adjustmentEmployee}
  onClose={() => setAdjustmentEmployee(null)}
  employee={adjustmentEmployee!}
  period={period}
  onSuccess={silentRefetch}
/>

{historyEmployee && (
  <HourBankHistoryDialog
    open={!!historyEmployee}
    onClose={() => setHistoryEmployee(null)}
    employeeId={historyEmployee.id}
    employeeName={historyEmployee.name}
    onDelete={silentRefetch}
  />
)}
```

- [ ] **Step 6: Update category subtotal and grand total rows**

Add corresponding cells for the new columns in the subtotal and grand total rows:

```tsx
// Subtotal: bank_net_amount and sick_leave_amount
<td className="text-right text-xs px-2 py-2 bg-blue-50/30 font-semibold">
  {group.totals.bank_net_amount !== 0 ? fmtMoney(group.totals.bank_net_amount) : '—'}
</td>
<td className="bg-blue-50/30"></td> {/* no balance subtotal */}
<td className="text-right text-xs px-2 py-2 bg-green-50/30 font-semibold">
  {group.totals.sick_leave_amount !== 0 ? fmtMoney(group.totals.sick_leave_amount) : '—'}
</td>
<td className="bg-green-50/30"></td> {/* no remaining subtotal */}
```

Same pattern for grand total.

- [ ] **Step 7: Verify build**

Run: `cd dashboard && npm run build`

- [ ] **Step 8: Commit**

```bash
git add dashboard/src/components/payroll/payroll-summary-table.tsx
git commit -m "feat(ui): add bank hours and sick leave columns to payroll table

4 new columns (Banque +/-, Solde banque, Maladie, Solde mal.) with
Ajustements button per employee row opening the adjustments modal."
```

---

## Task 9: Excel Export Update

**Files:**
- Modify: `dashboard/src/lib/utils/export-payroll-excel.ts`

- [ ] **Step 1: Read current export file**

Read: `dashboard/src/lib/utils/export-payroll-excel.ts`

- [ ] **Step 2: Add columns to Sommaire sheet**

After "Heures refusees" column, add:

```typescript
// In the Sommaire headers array:
'Banque +/- ($)',
'Solde banque ($)',
'Maladie (h)',
'Solde maladie (h)',

// In the Sommaire data row mapping:
emp.bank_net_amount !== 0 ? emp.bank_net_amount.toFixed(2) : '',
emp.bank_balance_dollars.toFixed(2),
emp.sick_leave_hours > 0 ? emp.sick_leave_hours.toFixed(1) : '',
emp.sick_leave_remaining.toFixed(1),
```

- [ ] **Step 3: Add columns to Detail sheet**

After "Heures refusees" column in the detail sheet:

Bank/sick columns go on the first day row only per employee. Use the `days` array index to detect first row:

```typescript
// In the Detail sheet row loop:
// Headers: add 'Banque +/- ($)', 'Maladie (h)' after 'Heures refusees'

// Data rows:
for (const emp of employees) {
  emp.days.forEach((day, index) => {
    const isFirstRow = index === 0;
    // ... existing columns ...
    // Bank column: only on first row
    isFirstRow && emp.bank_net_amount !== 0 ? emp.bank_net_amount.toFixed(2) : '',
    // Sick column: only on first row
    isFirstRow && emp.sick_leave_hours > 0 ? emp.sick_leave_hours.toFixed(1) : '',
  });
}
```

- [ ] **Step 4: Verify build**

Run: `cd dashboard && npm run build`

- [ ] **Step 5: Commit**

```bash
git add dashboard/src/lib/utils/export-payroll-excel.ts
git commit -m "feat(export): add bank hours and sick leave columns to Excel export"
```

---

## Task 10: Apply Migration & End-to-End Verification

- [ ] **Step 1: Apply migration to Supabase**

Use the Supabase MCP `apply_migration` tool to apply the migration.

- [ ] **Step 2: Verify tables exist**

```sql
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('hour_bank_transactions', 'sick_leave_usages');
```

Expected: 2 rows.

- [ ] **Step 3: Verify RPCs exist**

```sql
SELECT routine_name FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name IN (
    'get_hour_bank_balance', 'get_sick_leave_balance',
    'add_hour_bank_transaction', 'add_sick_leave_usage',
    'delete_hour_bank_transaction', 'delete_sick_leave_usage',
    'get_hour_bank_history'
  );
```

Expected: 7 rows.

- [ ] **Step 4: Test bank deposit + withdrawal flow**

```sql
-- Pick a test hourly employee
SELECT id, full_name, pay_type FROM employee_profiles WHERE pay_type = 'hourly' LIMIT 1;

-- Test deposit (use actual employee_id)
SELECT add_hour_bank_transaction(
  '<employee_id>'::UUID,
  '2026-03-09'::DATE, '2026-03-22'::DATE,
  'deposit', 5.0, 'Test deposit'
);

-- Check balance
SELECT get_hour_bank_balance('<employee_id>'::UUID);

-- Test withdrawal
SELECT add_hour_bank_transaction(
  '<employee_id>'::UUID,
  '2026-03-09'::DATE, '2026-03-22'::DATE,
  'withdrawal', 2.0, 'Test withdrawal'
);

-- Check history
SELECT get_hour_bank_history('<employee_id>'::UUID);
```

- [ ] **Step 5: Test sick leave flow**

```sql
SELECT add_sick_leave_usage(
  '<employee_id>'::UUID,
  '2026-03-09'::DATE, '2026-03-22'::DATE,
  7.0, '2026-03-15'::DATE, 'Test grippe'
);

SELECT get_sick_leave_balance('<employee_id>'::UUID);
```

- [ ] **Step 6: Test payroll report includes new columns**

```sql
SELECT
  full_name,
  bank_deposit_hours, bank_deposit_amount,
  bank_withdrawal_hours, bank_withdrawal_amount,
  sick_leave_hours, sick_leave_amount,
  bank_balance_dollars, bank_balance_hours,
  sick_leave_remaining,
  total_amount
FROM get_payroll_period_report('2026-03-09'::DATE, '2026-03-22'::DATE)
WHERE employee_id = '<employee_id>'
LIMIT 5;
```

- [ ] **Step 7: Clean up test data**

```sql
DELETE FROM hour_bank_transactions WHERE reason LIKE 'Test%';
DELETE FROM sick_leave_usages WHERE reason LIKE 'Test%';
```

- [ ] **Step 8: Verify dashboard build**

Run: `cd dashboard && npm run build`
Expected: Build succeeds with no errors.

- [ ] **Step 9: Final commit**

If any files were missed in earlier commits, stage them specifically:
```bash
git status
# Stage only relevant files
git commit -m "feat: complete hour bank and sick leave payroll adjustments

Includes database tables, RPCs, payroll report integration,
dashboard modal, history dialog, table columns, and Excel export."
```
