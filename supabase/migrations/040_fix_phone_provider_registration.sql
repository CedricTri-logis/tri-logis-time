-- Migration 040: Fix phone provider registration
-- After verifyPhoneChange + savePhoneToProfile, auth.users was missing:
--   phone_confirmed_at, providers includes "phone", phone_verified = true
-- This caused signInWithOtp to treat the user as new → trigger blocked → "Database error saving new user"
--
-- Also fixes phone format: GoTrue normalizes input (strips '+') for OTP lookup
-- but stores as-is. Phones stored WITH '+' won't match → must store WITHOUT '+'.
--
-- Fix: register_phone_number RPC now also updates auth.users to mark phone as confirmed
-- and ensures phone is stored without '+' prefix for GoTrue compatibility.

CREATE OR REPLACE FUNCTION public.register_phone_number(p_phone TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_existing_id UUID;
  v_current_providers JSONB;
  v_stored_phone TEXT;
BEGIN
  -- Validate E.164 Canadian format: +1 followed by exactly 10 digits
  IF p_phone !~ '^\+1[2-9]\d{9}$' THEN
    RAISE EXCEPTION 'Format invalide. Utilisez le format +1XXXXXXXXXX.'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Check if phone is already taken by another user
  SELECT id INTO v_existing_id
  FROM public.employee_profiles
  WHERE phone_number = p_phone AND id <> auth.uid();

  IF v_existing_id IS NOT NULL THEN
    RAISE EXCEPTION 'Ce numero est deja associe a un autre employe.'
      USING ERRCODE = 'unique_violation';
  END IF;

  -- Save the phone number to employee_profiles (keep E.164 with '+' for display)
  UPDATE public.employee_profiles
  SET phone_number = p_phone,
      updated_at = NOW()
  WHERE id = auth.uid();

  -- Strip '+' for GoTrue storage compatibility
  -- GoTrue normalizes input (strips '+') for OTP lookup but compares exact match
  v_stored_phone := LTRIM(p_phone, '+');

  -- Fix auth.users: mark phone as confirmed, strip '+', add "phone" to providers
  SELECT raw_app_meta_data->'providers' INTO v_current_providers
  FROM auth.users
  WHERE id = auth.uid();

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
  WHERE id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION public.register_phone_number(TEXT) TO authenticated;
