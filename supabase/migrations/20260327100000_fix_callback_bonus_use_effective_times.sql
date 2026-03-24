-- Migration: Fix callback bonus calculation to use effective shift times
--
-- Bug: The callback bonus (Art.58 LNT, 3h minimum) in _get_day_approval_detail_base uses raw
-- shifts.clocked_in_at/clocked_out_at instead of effective_shift_times(). When a shift's effective
-- time is adjusted (e.g. clock_out edited from 07:24 to 01:00 due to GPS gap), the raw duration
-- (402 min) exceeds the 3h minimum, so no bonus is applied — even though the actual worked time
-- (18 min) should trigger the bonus.
--
-- Fix: Replace call_shifts_ordered CTE in _get_day_approval_detail_base to use
-- effective_shift_times() instead of raw shift times.
--
-- Note: get_weekly_approval_summary already uses effective_shift_times for callback billing.

-- ============================================================
-- Patch _get_day_approval_detail_base
-- ============================================================
DO $$
DECLARE
    v_funcdef TEXT;
    v_old TEXT;
    v_new TEXT;
BEGIN
    SELECT pg_get_functiondef(oid)
    INTO v_funcdef
    FROM pg_proc
    WHERE proname = '_get_day_approval_detail_base'
      AND pronamespace = 'public'::regnamespace;

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');

    v_old := 'call_shifts_ordered AS (
        SELECT
            id,
            clocked_in_at,
            clocked_out_at,
            ROW_NUMBER() OVER (ORDER BY clocked_in_at) AS rn
        FROM shifts
        WHERE employee_id = p_employee_id
          AND clocked_in_at::DATE = p_date
          AND shift_type = ''call''
          AND status = ''completed''
          AND is_lunch = false
    ),';

    v_new := 'call_shifts_ordered AS (
        SELECT
            s.id,
            est.effective_clocked_in_at AS clocked_in_at,
            est.effective_clocked_out_at AS clocked_out_at,
            ROW_NUMBER() OVER (ORDER BY est.effective_clocked_in_at) AS rn
        FROM shifts s, effective_shift_times(s.id) est
        WHERE s.employee_id = p_employee_id
          AND s.clocked_in_at::DATE = p_date
          AND s.shift_type = ''call''
          AND s.status = ''completed''
          AND s.is_lunch = false
    ),';

    IF v_funcdef LIKE '%' || v_old || '%' THEN
        v_funcdef := replace(v_funcdef, v_old, v_new);
        EXECUTE v_funcdef;
    ELSE
        RAISE EXCEPTION 'Could not find call_shifts_ordered pattern in _get_day_approval_detail_base';
    END IF;
END;
$$;
