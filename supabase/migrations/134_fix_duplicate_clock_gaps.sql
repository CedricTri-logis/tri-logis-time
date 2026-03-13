-- =============================================================================
-- 134: Fix duplicate gap rows in get_day_approval_detail
-- =============================================================================
-- The gap_activities CTE (old GPS gap detector) and the new clock_in/out_gap_data
-- CTEs can both emit a row for the same time period (e.g. gap between last stop
-- and clock-out). Fix: use DISTINCT ON to deduplicate, preferring clock gap rows
-- (which have distance_km) over old gap rows (NULL distance_km).
-- =============================================================================

DO $$
DECLARE
    v_body TEXT;
    v_old  TEXT;
    v_new  TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_body
    FROM pg_proc WHERE proname = 'get_day_approval_detail';

    v_old := 'all_activity_data AS (
        SELECT * FROM activity_data UNION ALL SELECT * FROM gap_activities
        UNION ALL SELECT * FROM clock_in_gap_data UNION ALL SELECT * FROM clock_out_gap_data
    )';

    v_new := 'all_activity_data AS (
        SELECT DISTINCT ON (shift_id, started_at, activity_type) * FROM (
            SELECT * FROM activity_data UNION ALL SELECT * FROM gap_activities
            UNION ALL SELECT * FROM clock_in_gap_data UNION ALL SELECT * FROM clock_out_gap_data
        ) _all ORDER BY shift_id, started_at, activity_type, distance_km DESC NULLS LAST
    )';

    v_body := replace(v_body, v_old, v_new);

    EXECUTE v_body;
END $$;
