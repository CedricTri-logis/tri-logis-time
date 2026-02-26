-- Migration 044: Fix phone identity sync
-- Bug: register_phone_number and admin_update_phone_number updated auth.users.phone
-- but NOT auth.identities.identity_data.phone. Supabase's signInWithOtp looks up
-- the phone identity, so stale/missing identity_data.phone causes "no account" errors.
--
-- Fix: both RPCs now replace the phone identity (DELETE + INSERT) after updating auth.users.

-- =============================================================================
-- PART 1: register_phone_number — add auth.identities sync
-- =============================================================================

CREATE OR REPLACE FUNCTION public.register_phone_number(p_phone TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_existing_id UUID;
  v_current_providers JSONB;
  v_stored_phone TEXT;
  v_user_id UUID;
BEGIN
  v_user_id := auth.uid();

  -- Validate E.164 Canadian format: +1 followed by exactly 10 digits
  IF p_phone !~ '^\+1[2-9]\d{9}$' THEN
    RAISE EXCEPTION 'Format invalide. Utilisez le format +1XXXXXXXXXX.'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Check if phone is already taken by another user
  SELECT id INTO v_existing_id
  FROM public.employee_profiles
  WHERE phone_number = p_phone AND id <> v_user_id;

  IF v_existing_id IS NOT NULL THEN
    RAISE EXCEPTION 'Ce numero est deja associe a un autre employe.'
      USING ERRCODE = 'unique_violation';
  END IF;

  -- Save the phone number to employee_profiles (keep E.164 with '+' for display)
  UPDATE public.employee_profiles
  SET phone_number = p_phone, updated_at = NOW()
  WHERE id = v_user_id;

  -- Strip '+' for GoTrue storage compatibility
  v_stored_phone := LTRIM(p_phone, '+');

  -- Fix auth.users: mark phone as confirmed, strip '+', add "phone" to providers
  SELECT raw_app_meta_data->'providers' INTO v_current_providers
  FROM auth.users WHERE id = v_user_id;

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
  WHERE id = v_user_id;

  -- Sync auth.identities: replace phone identity so signInWithOtp can find it
  -- DELETE + INSERT avoids conflict issues when phone number changes (provider_id changes)
  DELETE FROM auth.identities
  WHERE user_id = v_user_id AND provider = 'phone';

  INSERT INTO auth.identities (
    id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at
  )
  VALUES (
    gen_random_uuid(),
    v_user_id,
    v_stored_phone,
    'phone',
    jsonb_build_object('sub', v_user_id::text, 'phone', v_stored_phone, 'phone_verified', true),
    NOW(),
    NOW(),
    NOW()
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.register_phone_number(TEXT) TO authenticated;

-- =============================================================================
-- PART 2: admin_update_phone_number — add auth.identities sync
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
            'error', jsonb_build_object('code', 'ACCESS_DENIED', 'message', 'Only admins can update phone numbers')
        );
    END IF;

    -- Check target exists
    SELECT ep.role INTO v_target_role
    FROM public.employee_profiles ep
    WHERE ep.id = p_user_id;

    IF v_target_role IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object('code', 'NOT_FOUND', 'message', 'Employee not found')
        );
    END IF;

    -- Super admin protection
    IF v_target_role = 'super_admin' AND v_caller_role != 'super_admin' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object('code', 'PROTECTED_USER', 'message', 'Cannot modify super_admin account')
        );
    END IF;

    -- If phone is provided, validate and check uniqueness
    IF p_phone IS NOT NULL THEN
        IF p_phone !~ '^\+1[2-9]\d{9}$' THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', jsonb_build_object('code', 'INVALID_FORMAT', 'message', 'Phone must be in E.164 Canadian format: +1XXXXXXXXXX')
            );
        END IF;

        SELECT ep.id INTO v_existing_id
        FROM public.employee_profiles ep
        WHERE ep.phone_number = p_phone AND ep.id != p_user_id;

        IF v_existing_id IS NOT NULL THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', jsonb_build_object('code', 'DUPLICATE_PHONE', 'message', 'This phone number is already assigned to another employee')
            );
        END IF;
    END IF;

    -- Update employee_profiles
    UPDATE public.employee_profiles
    SET phone_number = p_phone, updated_at = NOW()
    WHERE id = p_user_id;

    -- Update auth.users + auth.identities
    IF p_phone IS NOT NULL THEN
        v_stored_phone := LTRIM(p_phone, '+');

        SELECT raw_app_meta_data->'providers' INTO v_current_providers
        FROM auth.users WHERE id = p_user_id;

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

        -- Sync auth.identities: replace phone identity
        DELETE FROM auth.identities
        WHERE user_id = p_user_id AND provider = 'phone';

        INSERT INTO auth.identities (
            id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at
        )
        VALUES (
            gen_random_uuid(),
            p_user_id,
            v_stored_phone,
            'phone',
            jsonb_build_object('sub', p_user_id::text, 'phone', v_stored_phone, 'phone_verified', true),
            NOW(),
            NOW(),
            NOW()
        );
    ELSE
        -- Clearing phone: remove from auth.users and delete phone identity
        UPDATE auth.users
        SET phone = NULL, phone_confirmed_at = NULL, updated_at = NOW()
        WHERE id = p_user_id;

        DELETE FROM auth.identities
        WHERE user_id = p_user_id AND provider = 'phone';
    END IF;

    RETURN jsonb_build_object('success', true);
END;
$$;

COMMENT ON FUNCTION admin_update_phone_number IS 'Admin-only RPC to set or clear an employee phone number (updates employee_profiles, auth.users, and auth.identities)';

GRANT EXECUTE ON FUNCTION admin_update_phone_number(UUID, TEXT) TO authenticated;
