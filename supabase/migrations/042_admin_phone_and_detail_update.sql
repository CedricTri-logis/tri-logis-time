-- Migration 042: Admin phone number management + phone_number in get_employee_detail
-- 1. New RPC: admin_update_phone_number — lets admins set/clear an employee's phone
-- 2. Updated: get_employee_detail — adds phone_number to returned columns

-- =============================================================================
-- PART 1: admin_update_phone_number RPC
-- =============================================================================

CREATE OR REPLACE FUNCTION admin_update_phone_number(
    p_user_id UUID,
    p_phone TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_caller_role TEXT;
    v_target_role TEXT;
    v_existing_id UUID;
    v_current_providers JSONB;
    v_stored_phone TEXT;
BEGIN
    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM public.employee_profiles ep
    WHERE ep.id = auth.uid();

    -- Only admin/super_admin can access
    IF v_caller_role NOT IN ('admin', 'super_admin') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object(
                'code', 'ACCESS_DENIED',
                'message', 'Only admins can update phone numbers'
            )
        );
    END IF;

    -- Check target exists
    SELECT ep.role INTO v_target_role
    FROM public.employee_profiles ep
    WHERE ep.id = p_user_id;

    IF v_target_role IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object(
                'code', 'NOT_FOUND',
                'message', 'Employee not found'
            )
        );
    END IF;

    -- Super admin protection: non-super_admin cannot modify super_admin
    IF v_target_role = 'super_admin' AND v_caller_role != 'super_admin' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object(
                'code', 'PROTECTED_USER',
                'message', 'Cannot modify super_admin account'
            )
        );
    END IF;

    -- If phone is provided, validate and check uniqueness
    IF p_phone IS NOT NULL THEN
        -- Validate E.164 Canadian format: +1 followed by area code (2-9) + 9 digits
        IF p_phone !~ '^\+1[2-9]\d{9}$' THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', jsonb_build_object(
                    'code', 'INVALID_FORMAT',
                    'message', 'Phone must be in E.164 Canadian format: +1XXXXXXXXXX'
                )
            );
        END IF;

        -- Check uniqueness across employee_profiles
        SELECT ep.id INTO v_existing_id
        FROM public.employee_profiles ep
        WHERE ep.phone_number = p_phone AND ep.id != p_user_id;

        IF v_existing_id IS NOT NULL THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', jsonb_build_object(
                    'code', 'DUPLICATE_PHONE',
                    'message', 'This phone number is already assigned to another employee'
                )
            );
        END IF;
    END IF;

    -- Update employee_profiles (keep E.164 with '+' for display, or NULL to clear)
    UPDATE public.employee_profiles
    SET phone_number = p_phone,
        updated_at = NOW()
    WHERE id = p_user_id;

    -- Update auth.users phone field
    IF p_phone IS NOT NULL THEN
        -- Strip '+' for GoTrue storage compatibility (same pattern as register_phone_number)
        v_stored_phone := LTRIM(p_phone, '+');

        -- Get current providers
        SELECT raw_app_meta_data->'providers' INTO v_current_providers
        FROM auth.users
        WHERE id = p_user_id;

        UPDATE auth.users
        SET
            phone = v_stored_phone,
            phone_confirmed_at = COALESCE(phone_confirmed_at, NOW()),
            raw_app_meta_data = raw_app_meta_data || jsonb_build_object(
                'providers',
                CASE
                    WHEN v_current_providers IS NULL THEN '["email", "phone"]'::jsonb
                    WHEN NOT v_current_providers @> '"phone"'::jsonb THEN v_current_providers || '"phone"'::jsonb
                    ELSE v_current_providers
                END
            ),
            raw_user_meta_data = raw_user_meta_data || '{"phone_verified": true}'::jsonb,
            updated_at = NOW()
        WHERE id = p_user_id;
    ELSE
        -- Clearing phone: remove from auth.users as well
        UPDATE auth.users
        SET
            phone = NULL,
            phone_confirmed_at = NULL,
            updated_at = NOW()
        WHERE id = p_user_id;
    END IF;

    RETURN jsonb_build_object('success', true);
END;
$$;

COMMENT ON FUNCTION admin_update_phone_number IS 'Admin-only RPC to set or clear an employee phone number (updates both employee_profiles and auth.users)';

GRANT EXECUTE ON FUNCTION admin_update_phone_number(UUID, TEXT) TO authenticated;

-- =============================================================================
-- PART 2: Updated get_employee_detail — add phone_number column
-- =============================================================================

CREATE OR REPLACE FUNCTION get_employee_detail(p_employee_id UUID)
RETURNS TABLE (
    id UUID,
    email TEXT,
    full_name TEXT,
    employee_id TEXT,
    phone_number TEXT,
    role TEXT,
    status TEXT,
    privacy_consent_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    current_supervisor JSONB,
    supervision_history JSONB,
    has_active_shift BOOLEAN
) AS $$
DECLARE
    v_caller_role TEXT;
BEGIN
    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Only admin/super_admin can access
    IF v_caller_role NOT IN ('admin', 'super_admin') THEN
        RAISE EXCEPTION 'Access denied';
    END IF;

    RETURN QUERY
    SELECT
        ep.id,
        ep.email,
        ep.full_name,
        ep.employee_id,
        ep.phone_number,
        ep.role,
        ep.status,
        ep.privacy_consent_at,
        ep.created_at,
        ep.updated_at,
        -- Current supervisor
        (
            SELECT jsonb_build_object(
                'id', mgr.id,
                'full_name', mgr.full_name,
                'email', mgr.email
            )
            FROM employee_supervisors es
            JOIN employee_profiles mgr ON mgr.id = es.manager_id
            WHERE es.employee_id = ep.id
            AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
            ORDER BY es.effective_from DESC
            LIMIT 1
        ) as current_supervisor,
        -- Supervision history
        COALESCE(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'id', es.id,
                        'manager_id', es.manager_id,
                        'manager_name', mgr.full_name,
                        'manager_email', mgr.email,
                        'supervision_type', es.supervision_type,
                        'effective_from', es.effective_from,
                        'effective_to', es.effective_to
                    ) ORDER BY es.effective_from DESC
                )
                FROM employee_supervisors es
                JOIN employee_profiles mgr ON mgr.id = es.manager_id
                WHERE es.employee_id = ep.id
            ),
            '[]'::JSONB
        ) as supervision_history,
        -- Has active shift
        EXISTS (
            SELECT 1 FROM shifts s
            WHERE s.employee_id = ep.id AND s.status = 'active'
        ) as has_active_shift
    FROM employee_profiles ep
    WHERE ep.id = p_employee_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION get_employee_detail IS 'Get employee details with supervision history (admin only)';
