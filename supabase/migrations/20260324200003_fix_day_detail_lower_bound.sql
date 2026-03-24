-- Fix: remove lower-bound time filter from _get_day_approval_detail_base
-- Same issue as get_weekly_approval_summary — long-running clusters starting
-- before a shift are rejected by the 5-minute tolerance.
--
-- Example: Irene Pepin 2026-03-22 had a 178-min cluster starting 5m51s
-- before the shift, causing the day detail to show "Temps non suivi 173 min"
-- despite having 1637 GPS points and active cleaning sessions.

DO $$
DECLARE
    v_funcdef TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_funcdef
    FROM pg_proc
    WHERE proname = '_get_day_approval_detail_base'
      AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');

    -- Remove lower bound for stationary_clusters
    v_funcdef := replace(v_funcdef,
        'AND sc.started_at >= sb.clocked_in_at - INTERVAL ''5 minutes''
           AND sc.started_at < sb.clocked_out_at',
        'AND sc.started_at < sb.clocked_out_at');

    -- Remove lower bound for trips
    v_funcdef := replace(v_funcdef,
        'AND t.started_at >= sb.clocked_in_at - INTERVAL ''5 minutes''
           AND t.started_at < sb.clocked_out_at',
        'AND t.started_at < sb.clocked_out_at');

    EXECUTE v_funcdef;
    RAISE NOTICE 'Fixed _get_day_approval_detail_base: removed lower-bound time filter';
END $$;
