-- Defensive guard: filter out inverted events (evt_start >= evt_end) before
-- they reach the island-merge algorithm, in both weekly and daily RPCs.
-- This protects against future regressions in join logic.

DO $$
DECLARE
    v_funcdef TEXT;
    v_old TEXT;
    v_new TEXT;
BEGIN
    v_old := 'coverage_sorted AS (
        SELECT shift_id, employee_id, shift_date, evt_start, evt_end,
               ROW_NUMBER() OVER (PARTITION BY shift_id ORDER BY evt_start, evt_end DESC) AS rn
        FROM activity_events';
    v_new := 'coverage_sorted AS (
        SELECT shift_id, employee_id, shift_date, evt_start, evt_end,
               ROW_NUMBER() OVER (PARTITION BY shift_id ORDER BY evt_start, evt_end DESC) AS rn
        FROM activity_events
        WHERE evt_start < evt_end';

    -- Fix get_weekly_approval_summary
    SELECT pg_get_functiondef(oid) INTO v_funcdef
    FROM pg_proc
    WHERE proname = 'get_weekly_approval_summary'
      AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');
    v_funcdef := replace(v_funcdef, v_old, v_new);
    EXECUTE v_funcdef;
    RAISE NOTICE 'Added defensive filter to get_weekly_approval_summary';

    -- Fix _get_day_approval_detail_base
    SELECT pg_get_functiondef(oid) INTO v_funcdef
    FROM pg_proc
    WHERE proname = '_get_day_approval_detail_base'
      AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');
    v_funcdef := replace(v_funcdef, v_old, v_new);
    EXECUTE v_funcdef;
    RAISE NOTICE 'Added defensive filter to _get_day_approval_detail_base';
END $$;
