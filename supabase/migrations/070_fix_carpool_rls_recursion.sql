-- Migration 070: Fix infinite recursion in carpool_members RLS
--
-- Problem: "Employees view group co-members" policy on carpool_members
-- self-references carpool_members, triggering RLS again → infinite loop.
-- Additionally, carpool_groups "Employees view own carpool groups" queries
-- carpool_members, which triggers carpool_members RLS → recursion.
--
-- Fix: Use SECURITY DEFINER functions to bypass RLS for membership checks.

-- 1. Helper: check if a user is a member of a carpool group (bypasses RLS)
CREATE OR REPLACE FUNCTION is_carpool_member(p_user_id UUID, p_group_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1 FROM carpool_members
        WHERE carpool_group_id = p_group_id
          AND employee_id = p_user_id
    );
$$;

-- 2. Helper: get all group IDs a user belongs to (bypasses RLS)
CREATE OR REPLACE FUNCTION get_user_carpool_group_ids(p_user_id UUID)
RETURNS SETOF UUID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
    SELECT carpool_group_id FROM carpool_members
    WHERE employee_id = p_user_id;
$$;

-- 3. Fix carpool_members policies
-- Drop the self-referencing policy
DROP POLICY IF EXISTS "Employees view group co-members" ON carpool_members;

-- Drop the simple one too — we'll replace with a single combined policy
DROP POLICY IF EXISTS "Employees view own carpool membership" ON carpool_members;

-- Single policy: employees see all members in any group they belong to
CREATE POLICY "Employees view carpool members in own groups"
    ON carpool_members FOR SELECT
    USING (
        carpool_group_id IN (SELECT get_user_carpool_group_ids(auth.uid()))
    );

-- 4. Fix carpool_groups policy
-- Drop the cross-referencing policy
DROP POLICY IF EXISTS "Employees view own carpool groups" ON carpool_groups;

-- Replace with one that uses the SECURITY DEFINER function
CREATE POLICY "Employees view own carpool groups"
    ON carpool_groups FOR SELECT
    USING (
        id IN (SELECT get_user_carpool_group_ids(auth.uid()))
    );
