-- =============================================================
-- Migration: Break deduction for insufficient pause
-- Adds break_deduction_waived to day_approvals.
-- Adds toggle_break_deduction_waiver RPC.
-- Rule: if approved_minutes >= 300 AND break_minutes < 30
--       then deduction = 30 - break_minutes (unless waived).
-- =============================================================

-- 1. Add waiver column to day_approvals
ALTER TABLE day_approvals
  ADD COLUMN break_deduction_waived BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN day_approvals.break_deduction_waived IS
  'When true, the automatic 30-min break deduction is skipped for this day. Admin override.';

-- 2. RPC to toggle the waiver
CREATE OR REPLACE FUNCTION toggle_break_deduction_waiver(
  p_employee_id UUID,
  p_date DATE
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_caller_role TEXT;
  v_new_value BOOLEAN;
BEGIN
  SELECT role INTO v_caller_role
  FROM employee_profiles WHERE id = auth.uid();

  IF v_caller_role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'Insufficient permissions';
  END IF;

  UPDATE day_approvals
  SET break_deduction_waived = NOT break_deduction_waived
  WHERE employee_id = p_employee_id AND date = p_date
  RETURNING break_deduction_waived INTO v_new_value;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Day approval not found for % on %', p_employee_id, p_date;
  END IF;

  RETURN v_new_value;
END;
$$;

COMMENT ON FUNCTION toggle_break_deduction_waiver IS
  'Toggles the break_deduction_waived flag on a day_approval. Admin/super_admin only. Returns new value.';
