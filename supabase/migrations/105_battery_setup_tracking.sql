-- Migration 104: battery_setup_tracking
-- Adds server-side tracking for when an employee completes the OEM battery
-- setup wizard. Admins can filter for employees who have never done it.

ALTER TABLE employee_profiles
  ADD COLUMN IF NOT EXISTS battery_setup_completed_at TIMESTAMPTZ;

-- RPC callable by the authenticated employee.
-- SECURITY DEFINER so it can update own row without needing UPDATE policy.
CREATE OR REPLACE FUNCTION mark_battery_setup_completed()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE employee_profiles
  SET battery_setup_completed_at = NOW()
  WHERE user_id = auth.uid()
    AND battery_setup_completed_at IS NULL; -- only first-time, never regress
END;
$$;

-- Grant execute to authenticated users only
REVOKE ALL ON FUNCTION mark_battery_setup_completed() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION mark_battery_setup_completed() TO authenticated;

-- Update get_all_users to return battery_setup_completed_at for admin visibility
CREATE OR REPLACE FUNCTION get_all_users()
RETURNS TABLE (
    id UUID,
    email TEXT,
    full_name TEXT,
    employee_id TEXT,
    status TEXT,
    role TEXT,
    created_at TIMESTAMPTZ,
    battery_setup_completed_at TIMESTAMPTZ
) AS $$
DECLARE
    v_caller_role TEXT;
BEGIN
    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Only admin/super_admin can list all users
    IF v_caller_role NOT IN ('admin', 'super_admin') THEN
        RAISE EXCEPTION 'Access denied';
    END IF;

    RETURN QUERY
    SELECT
        ep.id,
        ep.email,
        ep.full_name,
        ep.employee_id,
        ep.status,
        ep.role,
        ep.created_at,
        ep.battery_setup_completed_at
    FROM employee_profiles ep
    ORDER BY
        CASE ep.role
            WHEN 'super_admin' THEN 1
            WHEN 'admin' THEN 2
            WHEN 'manager' THEN 3
            ELSE 4
        END,
        ep.full_name,
        ep.email;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION get_all_users IS 'Get all users for admin panel (admin/super_admin only)';
