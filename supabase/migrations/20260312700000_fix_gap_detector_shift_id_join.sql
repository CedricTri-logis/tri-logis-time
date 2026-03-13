-- =============================================================================
-- Fix false gap detection for clusters starting before clock-in
-- =============================================================================
-- Root cause: The gap detector in _get_day_approval_detail_base joined
-- stationary_clusters and trips using a time-based filter:
--   sc.started_at >= sb.clocked_in_at - INTERVAL '1 minute'
-- This excluded clusters that started >1 min before clock-in (e.g. background
-- GPS collecting data before the employee clocks in). The cluster was entirely
-- excluded from coverage, creating a false "Temps non suivi" gap spanning
-- the entire shift.
--
-- Fix: Use shift_id join instead of time-based filter. Both stationary_clusters
-- and trips have a shift_id FK, making the join correct and simpler.
-- Affected: 10 clusters across all completed shifts.
-- =============================================================================

DO $$
DECLARE
    v_funcdef TEXT;
    v_replaced BOOLEAN := FALSE;
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_funcdef
    FROM pg_proc WHERE proname = '_get_day_approval_detail_base';

    -- Fix 1: stationary_clusters - use shift_id instead of time-based filter
    IF v_funcdef LIKE '%sc.started_at >= sb.clocked_in_at - INTERVAL ''1 minute''%' THEN
        v_funcdef := REPLACE(v_funcdef,
            'JOIN stationary_clusters sc ON sc.employee_id = p_employee_id
           AND sc.started_at >= sb.clocked_in_at - INTERVAL ''1 minute''
           AND sc.started_at < sb.clocked_out_at AND sc.ended_at > sb.clocked_in_at
           AND sc.duration_seconds >= 180',
            'JOIN stationary_clusters sc ON sc.shift_id = sb.shift_id
           AND sc.ended_at > sb.clocked_in_at
           AND sc.duration_seconds >= 180'
        );
        v_replaced := TRUE;
    END IF;

    -- Fix 2: trips - use shift_id instead of time-based filter
    IF v_funcdef LIKE '%t.started_at >= sb.clocked_in_at - INTERVAL ''1 minute''%' THEN
        v_funcdef := REPLACE(v_funcdef,
            'JOIN trips t ON t.employee_id = p_employee_id
           AND t.started_at >= sb.clocked_in_at - INTERVAL ''1 minute''
           AND t.started_at < sb.clocked_out_at AND t.ended_at > sb.clocked_in_at',
            'JOIN trips t ON t.shift_id = sb.shift_id
           AND t.ended_at > sb.clocked_in_at'
        );
        v_replaced := TRUE;
    END IF;

    IF NOT v_replaced THEN
        RAISE EXCEPTION 'Pattern not found - function may have changed';
    END IF;

    EXECUTE v_funcdef;
END $$;

-- =============================================================================
-- Same fix for get_weekly_approval_summary (activity_events, quality_gaps)
-- =============================================================================
DO $$
DECLARE
    v_funcdef TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_funcdef
    FROM pg_proc WHERE proname = 'get_weekly_approval_summary';

    -- Fix activity_events + activity_quality_gaps: clusters use shift_id
    v_funcdef := REPLACE(v_funcdef,
        'JOIN stationary_clusters sc ON sc.employee_id = sb.employee_id AND sc.started_at >= sb.clocked_in_at - INTERVAL ''1 minute'' AND sc.started_at < sb.clocked_out_at AND sc.ended_at > sb.clocked_in_at AND sc.duration_seconds >= 180',
        'JOIN stationary_clusters sc ON sc.shift_id = sb.shift_id AND sc.ended_at > sb.clocked_in_at AND sc.duration_seconds >= 180'
    );

    -- Fix activity_events + trip_quality_gaps: trips use shift_id
    v_funcdef := REPLACE(v_funcdef,
        'JOIN trips t ON t.employee_id = sb.employee_id AND t.started_at >= sb.clocked_in_at - INTERVAL ''1 minute'' AND t.started_at < sb.clocked_out_at AND t.ended_at > sb.clocked_in_at',
        'JOIN trips t ON t.shift_id = sb.shift_id AND t.ended_at > sb.clocked_in_at'
    );

    EXECUTE v_funcdef;
END $$;
