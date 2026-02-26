-- =============================================================================
-- Migration 047: Add admin SELECT policy on gps_points table
-- =============================================================================
-- Admins need to see all GPS points (e.g., mileage trip detail maps).
-- The current policy only allows own or supervised employee points.
-- Uses is_admin_or_super_admin() SECURITY DEFINER function (migration 046).

DROP POLICY IF EXISTS "Users can view own or supervised employee GPS points" ON gps_points;

CREATE POLICY "Users can view GPS points based on role"
ON gps_points FOR SELECT TO authenticated
USING (
    -- Own GPS points
    (SELECT auth.uid()) = employee_id
    -- OR admin/super_admin can see all
    OR public.is_admin_or_super_admin((SELECT auth.uid()))
    -- OR manager supervises this employee
    OR EXISTS (
        SELECT 1 FROM employee_supervisors es
        WHERE es.manager_id = (SELECT auth.uid())
        AND es.employee_id = gps_points.employee_id
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
    )
);
