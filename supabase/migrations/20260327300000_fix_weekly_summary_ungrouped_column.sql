-- Fix: "subquery uses ungrouped column s.clocked_in_at from outer query"
-- in get_weekly_approval_summary's day_lunch CTE.
--
-- Root cause: The lunch override patch (20260324400000) added a correlated subquery
-- referencing s.clocked_in_at. The GROUP BY contains the expression
-- (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date, but PostgreSQL requires
-- the raw column itself to be in GROUP BY for it to be usable in correlated subqueries.
--
-- Fix: Wrap the correlated subquery in MAX() so s.clocked_in_at is inside an aggregate.
-- Since all rows in a group share the same (employee_id, date), MAX of the scalar
-- subquery returns the same value — semantically identical, but valid SQL.

DO $migration$
DECLARE
    v_funcdef TEXT;
    v_old1 TEXT;
    v_new1 TEXT;
    v_old2 TEXT;
    v_new2 TEXT;
BEGIN
    SELECT pg_get_functiondef(oid)
    INTO v_funcdef
    FROM pg_proc
    WHERE proname = 'get_weekly_approval_summary'
      AND pronamespace = 'public'::regnamespace;

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');

    -- 1. Opening: add MAX( after COALESCE(
    v_old1 := $str$+ COALESCE((
                SELECT SUM(EXTRACT(EPOCH FROM (aseg2.ends_at - aseg2.starts_at)$str$;

    v_new1 := $str$+ COALESCE(MAX((
                SELECT SUM(EXTRACT(EPOCH FROM (aseg2.ends_at - aseg2.starts_at)$str$;

    -- 2. Closing: add extra ) for MAX
    v_old2 := $o2$AND COALESCE(ao2.override_status, 'rejected') != 'approved'
            ), 0) AS lunch_minutes$o2$;

    v_new2 := $o2$AND COALESCE(ao2.override_status, 'rejected') != 'approved'
            )), 0) AS lunch_minutes$o2$;

    IF v_funcdef NOT LIKE '%' || v_old1 || '%' THEN
        RAISE EXCEPTION 'Pattern 1 (opening) not found in get_weekly_approval_summary — cannot apply fix';
    END IF;
    IF v_funcdef NOT LIKE '%' || v_old2 || '%' THEN
        RAISE EXCEPTION 'Pattern 2 (closing) not found in get_weekly_approval_summary — cannot apply fix';
    END IF;

    v_funcdef := replace(v_funcdef, v_old1, v_new1);
    v_funcdef := replace(v_funcdef, v_old2, v_new2);

    EXECUTE v_funcdef;

    RAISE NOTICE 'Fixed ungrouped s.clocked_in_at in get_weekly_approval_summary day_lunch CTE';
END;
$migration$;
