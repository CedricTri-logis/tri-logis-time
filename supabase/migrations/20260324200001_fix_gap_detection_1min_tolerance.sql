-- Fix: remove the lower-bound time filter on activity joins in gap detection.
--
-- The original condition `started_at >= clocked_in_at - INTERVAL '1 minute'`
-- (then bumped to 5 minutes) rejected long-running stationary clusters that
-- started before the shift. The overlap conditions alone (started_at < clocked_out_at
-- AND ended_at > clocked_in_at) are sufficient — GREATEST/LEAST clamping handles
-- boundary cases correctly.
--
-- Examples:
--   Ozaka Lussier 2026-03-23: cluster started 2m11s before shift → 185 min phantom gap
--   Irene Pepin 2026-03-22: cluster started 5m51s before shift → 173 min phantom gap

DO $$
DECLARE
    v_funcdef TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_funcdef
    FROM pg_proc
    WHERE proname = 'get_weekly_approval_summary'
      AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');

    -- Remove lower bound for stationary_clusters (2 occurrences)
    v_funcdef := replace(v_funcdef,
        'AND sc.started_at >= sb.clocked_in_at - INTERVAL ''5 minutes''
           AND sc.started_at < sb.clocked_out_at AND sc.ended_at > sb.clocked_in_at',
        'AND sc.started_at < sb.clocked_out_at AND sc.ended_at > sb.clocked_in_at');

    -- Remove lower bound for trips (2 occurrences)
    v_funcdef := replace(v_funcdef,
        'AND t.started_at >= sb.clocked_in_at - INTERVAL ''5 minutes''
           AND t.started_at < sb.clocked_out_at AND t.ended_at > sb.clocked_in_at',
        'AND t.started_at < sb.clocked_out_at AND t.ended_at > sb.clocked_in_at');

    EXECUTE v_funcdef;
    RAISE NOTICE 'Removed lower-bound time filter from gap detection';
END $$;
