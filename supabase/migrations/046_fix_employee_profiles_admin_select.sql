-- =============================================================================
-- Migration 046: Fix employee_profiles SELECT policy to include admin access
-- =============================================================================
-- The current SELECT policy only allows viewing own profile or supervised
-- employees. Admins/super_admins cannot see all employees.
--
-- The admin check requires a SECURITY DEFINER function to avoid infinite
-- recursion — the RLS policy cannot query employee_profiles from within
-- itself without triggering the same policy again.

-- Helper function to check if a user is admin (bypasses RLS)
CREATE OR REPLACE FUNCTION public.is_admin_or_super_admin(user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM employee_profiles
    WHERE id = user_id
    AND role IN ('admin', 'super_admin')
  );
$$;

-- Drop the current restrictive policy
DROP POLICY IF EXISTS "Users can view own or supervised profiles" ON employee_profiles;
DROP POLICY IF EXISTS "Users can view profiles based on role" ON employee_profiles;

-- Create the correct policy with admin override (using SECURITY DEFINER function)
CREATE POLICY "Users can view profiles based on role"
ON employee_profiles FOR SELECT TO authenticated
USING (
    -- Own profile
    (SELECT auth.uid()) = id
    -- OR admin/super_admin can see everyone
    OR public.is_admin_or_super_admin((SELECT auth.uid()))
    -- OR manager supervises this employee
    OR EXISTS (
        SELECT 1 FROM employee_supervisors es
        WHERE es.manager_id = (SELECT auth.uid())
        AND es.employee_id = employee_profiles.id
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
    )
);
