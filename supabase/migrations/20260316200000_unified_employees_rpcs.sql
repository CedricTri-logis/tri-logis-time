-- Migration: Extend employee list with categories + rates for unified employees page

-- 1. Drop existing function (RETURNS TABLE signature change requires drop)
DROP FUNCTION IF EXISTS get_employees_paginated(TEXT, TEXT, TEXT, TEXT, TEXT, INT, INT);
-- Safety: if the above didn't match (different overload), this catches it:
DROP FUNCTION IF EXISTS get_employees_paginated;

-- 2. Recreate with active_category_count + current_hourly_rate
CREATE OR REPLACE FUNCTION get_employees_paginated(
    p_search TEXT DEFAULT NULL,
    p_role TEXT DEFAULT NULL,
    p_status TEXT DEFAULT NULL,
    p_sort_field TEXT DEFAULT 'full_name',
    p_sort_order TEXT DEFAULT 'ASC',
    p_limit INT DEFAULT 50,
    p_offset INT DEFAULT 0
)
RETURNS TABLE (
    id UUID,
    email TEXT,
    full_name TEXT,
    employee_id TEXT,
    role TEXT,
    status TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    current_supervisor_id UUID,
    current_supervisor_name TEXT,
    current_supervisor_email TEXT,
    active_category_count INTEGER,
    current_hourly_rate NUMERIC,
    total_count BIGINT
) AS $$
DECLARE
    v_caller_role TEXT;
    v_total_count BIGINT;
BEGIN
    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Only admin/super_admin can access
    IF v_caller_role NOT IN ('admin', 'super_admin') THEN
        RAISE EXCEPTION 'Access denied';
    END IF;

    -- Get total count first
    SELECT COUNT(*) INTO v_total_count
    FROM employee_profiles ep
    WHERE (p_search IS NULL OR
           ep.full_name ILIKE '%' || p_search || '%' OR
           ep.email ILIKE '%' || p_search || '%' OR
           ep.employee_id ILIKE '%' || p_search || '%')
    AND (p_role IS NULL OR ep.role = p_role)
    AND (p_status IS NULL OR ep.status = p_status);

    -- Return results with dynamic sorting
    RETURN QUERY
    SELECT
        ep.id,
        ep.email,
        ep.full_name,
        ep.employee_id,
        ep.role,
        ep.status,
        ep.created_at,
        ep.updated_at,
        es.manager_id as current_supervisor_id,
        mgr.full_name as current_supervisor_name,
        mgr.email as current_supervisor_email,
        COALESCE((
            SELECT COUNT(*)::INTEGER
            FROM employee_categories ec
            WHERE ec.employee_id = ep.id AND ec.ended_at IS NULL
        ), 0) as active_category_count,
        (
            SELECT ehr.rate
            FROM employee_hourly_rates ehr
            WHERE ehr.employee_id = ep.id AND ehr.effective_to IS NULL
            ORDER BY ehr.effective_from DESC
            LIMIT 1
        ) as current_hourly_rate,
        v_total_count as total_count
    FROM employee_profiles ep
    LEFT JOIN employee_supervisors es ON es.employee_id = ep.id
        AND es.effective_to IS NULL
    LEFT JOIN employee_profiles mgr ON mgr.id = es.manager_id
    WHERE (p_search IS NULL OR
           ep.full_name ILIKE '%' || p_search || '%' OR
           ep.email ILIKE '%' || p_search || '%' OR
           ep.employee_id ILIKE '%' || p_search || '%')
    AND (p_role IS NULL OR ep.role = p_role)
    AND (p_status IS NULL OR ep.status = p_status)
    ORDER BY
        CASE WHEN p_sort_order = 'ASC' THEN
            CASE p_sort_field
                WHEN 'full_name' THEN COALESCE(ep.full_name, ep.email)
                WHEN 'email' THEN ep.email
                WHEN 'role' THEN ep.role
                WHEN 'status' THEN ep.status
                WHEN 'employee_id' THEN ep.employee_id
                ELSE COALESCE(ep.full_name, ep.email)
            END
        END ASC NULLS LAST,
        CASE WHEN p_sort_order = 'DESC' THEN
            CASE p_sort_field
                WHEN 'full_name' THEN COALESCE(ep.full_name, ep.email)
                WHEN 'email' THEN ep.email
                WHEN 'role' THEN ep.role
                WHEN 'status' THEN ep.status
                WHEN 'employee_id' THEN ep.employee_id
                ELSE COALESCE(ep.full_name, ep.email)
            END
        END DESC NULLS LAST,
        ep.created_at DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION get_employees_paginated IS 'Get paginated employee list with search, filter, sorting, active category count, and current hourly rate (admin only)';

-- 3. New RPC: get_employee_expand_details
CREATE OR REPLACE FUNCTION get_employee_expand_details(
    p_employee_id UUID
)
RETURNS JSON AS $$
DECLARE
    v_caller_role TEXT;
    v_result JSON;
BEGIN
    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Only admin/super_admin can access
    IF v_caller_role NOT IN ('admin', 'super_admin') THEN
        RAISE EXCEPTION 'Access denied';
    END IF;

    SELECT json_build_object(
        'categories', COALESCE((
            SELECT json_agg(
                json_build_object(
                    'category', ec.category,
                    'started_at', ec.started_at,
                    'ended_at', ec.ended_at
                ) ORDER BY ec.ended_at NULLS FIRST, ec.started_at DESC
            )
            FROM employee_categories ec
            WHERE ec.employee_id = p_employee_id
        ), '[]'::json),
        'rates', COALESCE((
            SELECT json_agg(
                json_build_object(
                    'rate', ehr.rate,
                    'effective_from', ehr.effective_from,
                    'effective_to', ehr.effective_to
                ) ORDER BY ehr.effective_to NULLS FIRST, ehr.effective_from DESC
            )
            FROM employee_hourly_rates ehr
            WHERE ehr.employee_id = p_employee_id
        ), '[]'::json)
    ) INTO v_result;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION get_employee_expand_details IS 'Get employee categories and rate history for expandable list row (admin only)';
