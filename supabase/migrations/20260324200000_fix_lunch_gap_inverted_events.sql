-- Fix: inverted lunch events in gap detection (coverage_gap_minutes inflation)
--
-- Bug: In both get_weekly_approval_summary and _get_day_approval_detail_base,
-- the lunch coverage CTE joins ALL lunch shifts from the same work_body_id to
-- each work shift boundary WITHOUT a time overlap filter. When a lunch doesn't
-- overlap the work shift, GREATEST(lunch_start, shift_start) > LEAST(lunch_end,
-- shift_end), creating inverted events (evt_start > evt_end) that corrupt the
-- island-merge gap detection algorithm.
--
-- Impact: Employees with multiple lunch breaks in the same work_body get
-- massively inflated gap_minutes. Example: Irene Pepin 2026-03-23 reported
-- 413 min of gaps (should be 0).
--
-- Fix: Add time overlap conditions to the lunch join:
--   AND s_lunch.clocked_in_at < sb.clocked_out_at
--   AND s_lunch.clocked_out_at > sb.clocked_in_at

DO $$
DECLARE
    v_funcdef TEXT;
    v_old_pattern TEXT := 's_lunch.is_lunch = true AND s_lunch.clocked_out_at IS NOT NULL';
    v_new_pattern TEXT := 's_lunch.is_lunch = true AND s_lunch.clocked_out_at IS NOT NULL
           AND s_lunch.clocked_in_at < sb.clocked_out_at
           AND s_lunch.clocked_out_at > sb.clocked_in_at';
BEGIN
    -- Fix get_weekly_approval_summary
    SELECT pg_get_functiondef(oid) INTO v_funcdef
    FROM pg_proc
    WHERE proname = 'get_weekly_approval_summary'
      AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');
    v_funcdef := replace(v_funcdef, v_old_pattern, v_new_pattern);
    EXECUTE v_funcdef;

    RAISE NOTICE 'Fixed get_weekly_approval_summary';

    -- Fix _get_day_approval_detail_base
    SELECT pg_get_functiondef(oid) INTO v_funcdef
    FROM pg_proc
    WHERE proname = '_get_day_approval_detail_base'
      AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');
    v_funcdef := replace(v_funcdef, v_old_pattern, v_new_pattern);
    EXECUTE v_funcdef;

    RAISE NOTICE 'Fixed _get_day_approval_detail_base';
END $$;
