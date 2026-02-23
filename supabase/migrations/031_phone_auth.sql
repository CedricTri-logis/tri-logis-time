-- Migration 031: Phone authentication support
-- Adds phone_number to employee_profiles and RPCs for phone registration

-- Add phone_number column
ALTER TABLE employee_profiles
  ADD COLUMN IF NOT EXISTS phone_number TEXT;

-- Unique constraint on phone_number (only for non-null values)
ALTER TABLE employee_profiles
  ADD CONSTRAINT employee_profiles_phone_number_unique UNIQUE (phone_number);

-- Index for phone lookups
CREATE INDEX IF NOT EXISTS idx_employee_profiles_phone_number
  ON employee_profiles (phone_number)
  WHERE phone_number IS NOT NULL;

-- Update handle_new_user() to copy phone from auth.users
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
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

-- RPC: Check if the current user has a phone number registered
CREATE OR REPLACE FUNCTION public.check_phone_registered()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_phone TEXT;
BEGIN
  SELECT phone_number INTO v_phone
  FROM public.employee_profiles
  WHERE id = auth.uid();

  RETURN v_phone IS NOT NULL AND v_phone <> '';
END;
$$;

-- Grant execute to authenticated users
GRANT EXECUTE ON FUNCTION public.check_phone_registered() TO authenticated;

-- RPC: Register a phone number for the current user
-- Validates E.164 Canadian format (+1XXXXXXXXXX) and checks uniqueness
CREATE OR REPLACE FUNCTION public.register_phone_number(p_phone TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_existing_id UUID;
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

  -- Save the phone number
  UPDATE public.employee_profiles
  SET phone_number = p_phone,
      updated_at = NOW()
  WHERE id = auth.uid();
END;
$$;

-- Grant execute to authenticated users
GRANT EXECUTE ON FUNCTION public.register_phone_number(TEXT) TO authenticated;
