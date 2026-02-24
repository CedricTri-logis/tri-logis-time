-- Migration 039: Prevent duplicate @phone.local accounts
-- Fixes the bug where OTP login with an unregistered phone creates a phantom account
--
-- Two-level fix:
-- 1. RPC check_phone_exists() — app calls this BEFORE sending OTP
-- 2. Updated handle_new_user() trigger — server-side fail-safe that blocks duplicate profiles

-- ============================================================
-- 1. RPC: Check if a phone number is already registered
--    Accessible to anon (pre-login check) and authenticated
-- ============================================================
CREATE OR REPLACE FUNCTION public.check_phone_exists(p_phone TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_digits TEXT;
BEGIN
  -- Extract digits only for normalized comparison
  v_digits := regexp_replace(p_phone, '[^0-9]', '', 'g');

  RETURN EXISTS (
    SELECT 1 FROM public.employee_profiles
    WHERE regexp_replace(phone_number, '[^0-9]', '', 'g') = v_digits
      AND status = 'active'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_phone_exists(TEXT) TO anon;
GRANT EXECUTE ON FUNCTION public.check_phone_exists(TEXT) TO authenticated;

-- ============================================================
-- 2. Updated handle_new_user() trigger
--    If phone already belongs to another employee, block profile creation
--    (raises exception → rolls back auth.users INSERT → no phantom)
-- ============================================================
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_digits TEXT;
  v_existing_id UUID;
BEGIN
  -- If this is a phone-based signup, check for existing phone
  IF NEW.phone IS NOT NULL AND NEW.phone <> '' THEN
    v_digits := regexp_replace(NEW.phone, '[^0-9]', '', 'g');

    SELECT id INTO v_existing_id
    FROM public.employee_profiles
    WHERE regexp_replace(phone_number, '[^0-9]', '', 'g') = v_digits;

    IF v_existing_id IS NOT NULL THEN
      -- Phone already registered — block the duplicate account creation
      RAISE EXCEPTION 'Ce numero est deja associe a un compte existant. Contactez votre superviseur.'
        USING ERRCODE = 'unique_violation';
    END IF;
  END IF;

  -- Normal flow: create the employee profile
  INSERT INTO public.employee_profiles (id, email, full_name, phone_number, status, role)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data ->> 'full_name', ''),
    NEW.phone,
    'active',
    'employee'
  )
  ON CONFLICT (id) DO UPDATE SET
    email = EXCLUDED.email,
    phone_number = COALESCE(EXCLUDED.phone_number, public.employee_profiles.phone_number);
  RETURN NEW;
END;
$$;

-- ============================================================
-- 3. Normalize existing phone_number data
--    Ensure all phones use E.164 format (+1XXXXXXXXXX)
-- ============================================================
UPDATE employee_profiles
SET phone_number = '+' || phone_number, updated_at = NOW()
WHERE phone_number IS NOT NULL
  AND phone_number <> ''
  AND phone_number NOT LIKE '+%';
