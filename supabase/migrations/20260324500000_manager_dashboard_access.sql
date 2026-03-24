-- Migration: Manager Dashboard Access
-- Gives managers (role='manager') the ability to use approval RPCs
-- scoped to their supervised employees via employee_supervisors.

-- ============================================================
-- 1. Helper function: can_manage_employee()
-- ============================================================
CREATE OR REPLACE FUNCTION public.can_manage_employee(
    caller_id UUID,
    target_employee_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql SECURITY DEFINER STABLE
SET search_path = public
AS $$
    SELECT public.is_admin_or_super_admin(caller_id)
        OR EXISTS (
            SELECT 1 FROM employee_supervisors es
            WHERE es.manager_id = caller_id
              AND es.employee_id = target_employee_id
              AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
        );
$$;

-- ============================================================
-- 2. Patch get_weekly_approval_summary: scope employee_list
-- ============================================================
-- The employee_list CTE currently selects ALL active employees.
-- We add a filter so managers only see their supervised employees.

DO $patch_weekly$
DECLARE
    v_funcdef TEXT;
    v_old TEXT;
    v_new TEXT;
BEGIN
    SELECT pg_get_functiondef(oid)
    INTO v_funcdef
    FROM pg_proc
    WHERE proname = 'get_weekly_approval_summary'
      AND pronamespace = 'public'::regnamespace;

    IF v_funcdef IS NULL THEN
        RAISE EXCEPTION 'get_weekly_approval_summary not found';
    END IF;

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');

    v_old := $str$SELECT ep.id AS employee_id, ep.full_name AS employee_name
        FROM employee_profiles ep
        WHERE ep.status = 'active'
        ORDER BY ep.full_name$str$;

    v_new := $str$SELECT ep.id AS employee_id, ep.full_name AS employee_name
        FROM employee_profiles ep
        WHERE ep.status = 'active'
          AND (
              public.is_admin_or_super_admin(auth.uid())
              OR EXISTS (
                  SELECT 1 FROM employee_supervisors es
                  WHERE es.manager_id = auth.uid()
                    AND es.employee_id = ep.id
                    AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
              )
          )
        ORDER BY ep.full_name$str$;

    IF v_funcdef NOT LIKE '%' || v_old || '%' THEN
        RAISE EXCEPTION 'employee_list CTE pattern not found in get_weekly_approval_summary';
    END IF;

    v_funcdef := replace(v_funcdef, v_old, v_new);
    EXECUTE v_funcdef;

    RAISE NOTICE 'Patched get_weekly_approval_summary: employee_list now scoped by role';
END;
$patch_weekly$;

-- ============================================================
-- 3. Patch get_day_approval_detail: add auth check
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_day_approval_detail(
    p_employee_id UUID,
    p_date DATE
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
    v_base JSONB;
    v_ps JSONB;
BEGIN
    -- Auth check: caller must be admin or supervisor of this employee
    IF NOT can_manage_employee(auth.uid(), p_employee_id) THEN
        RAISE EXCEPTION 'Not authorized to view this employee';
    END IF;

    v_base := _get_day_approval_detail_base(p_employee_id, p_date);
    v_ps := _get_project_sessions(p_employee_id, p_date);
    RETURN v_base || jsonb_build_object('project_sessions', v_ps);
END;
$function$;

-- ============================================================
-- 4. Patch approval action RPCs: replace admin check with can_manage_employee
-- ============================================================

-- 4a. save_activity_override
DO $patch_save$
DECLARE
    v_funcdef TEXT;
BEGIN
    SELECT pg_get_functiondef(oid)
    INTO v_funcdef
    FROM pg_proc
    WHERE proname = 'save_activity_override'
      AND pronamespace = 'public'::regnamespace;

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');

    v_funcdef := replace(v_funcdef,
        'IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION ''Only admins can save overrides'';
    END IF;',
        'IF NOT can_manage_employee(v_caller, p_employee_id) THEN
        RAISE EXCEPTION ''Not authorized to manage this employee'';
    END IF;');

    EXECUTE v_funcdef;
    RAISE NOTICE 'Patched save_activity_override: manager access enabled';
END;
$patch_save$;

-- 4b. remove_activity_override
DO $patch_remove$
DECLARE
    v_funcdef TEXT;
BEGIN
    SELECT pg_get_functiondef(oid)
    INTO v_funcdef
    FROM pg_proc
    WHERE proname = 'remove_activity_override'
      AND pronamespace = 'public'::regnamespace;

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');

    v_funcdef := replace(v_funcdef,
        'IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION ''Only admins can remove overrides'';
    END IF;',
        'IF NOT can_manage_employee(v_caller, p_employee_id) THEN
        RAISE EXCEPTION ''Not authorized to manage this employee'';
    END IF;');

    EXECUTE v_funcdef;
    RAISE NOTICE 'Patched remove_activity_override: manager access enabled';
END;
$patch_remove$;

-- 4c. approve_day
DO $patch_approve$
DECLARE
    v_funcdef TEXT;
BEGIN
    SELECT pg_get_functiondef(oid)
    INTO v_funcdef
    FROM pg_proc
    WHERE proname = 'approve_day'
      AND pronamespace = 'public'::regnamespace;

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');

    v_funcdef := replace(v_funcdef,
        'IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION ''Only admins can approve days'';
    END IF;',
        'IF NOT can_manage_employee(v_caller, p_employee_id) THEN
        RAISE EXCEPTION ''Not authorized to manage this employee'';
    END IF;');

    EXECUTE v_funcdef;
    RAISE NOTICE 'Patched approve_day: manager access enabled';
END;
$patch_approve$;

-- 4d. reopen_day
DO $patch_reopen$
DECLARE
    v_funcdef TEXT;
BEGIN
    SELECT pg_get_functiondef(oid)
    INTO v_funcdef
    FROM pg_proc
    WHERE proname = 'reopen_day'
      AND pronamespace = 'public'::regnamespace;

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');

    v_funcdef := replace(v_funcdef,
        'IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION ''Only admins can reopen days'';
    END IF;',
        'IF NOT can_manage_employee(v_caller, p_employee_id) THEN
        RAISE EXCEPTION ''Not authorized to manage this employee'';
    END IF;');

    EXECUTE v_funcdef;
    RAISE NOTICE 'Patched reopen_day: manager access enabled';
END;
$patch_reopen$;

-- ============================================================
-- 5. RLS Policies: manager write access
-- ============================================================

-- 5a. day_approvals: managers can manage subordinate approvals
CREATE POLICY "manager_manage_subordinate_day_approvals"
    ON day_approvals FOR ALL TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM employee_supervisors es
            WHERE es.manager_id = auth.uid()
              AND es.employee_id = day_approvals.employee_id
              AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM employee_supervisors es
            WHERE es.manager_id = auth.uid()
              AND es.employee_id = day_approvals.employee_id
              AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
        )
    );

-- 5b. activity_overrides: managers can manage subordinate overrides
CREATE POLICY "manager_manage_subordinate_activity_overrides"
    ON activity_overrides FOR ALL TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM day_approvals da
            JOIN employee_supervisors es ON es.employee_id = da.employee_id
            WHERE da.id = activity_overrides.day_approval_id
              AND es.manager_id = auth.uid()
              AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM day_approvals da
            JOIN employee_supervisors es ON es.employee_id = da.employee_id
            WHERE da.id = activity_overrides.day_approval_id
              AND es.manager_id = auth.uid()
              AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
        )
    );
