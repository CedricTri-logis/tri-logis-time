-- =============================================================================
-- Migration 045: Add admin/super_admin SELECT policy on trips table
-- =============================================================================
-- The trips table was missing an admin policy, so admins could only see
-- their own trips and supervised employee trips (not all trips).

-- Admin/Super Admin can view ALL trips
CREATE POLICY "Admins can view all trips"
ON trips FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM employee_profiles
        WHERE id = (SELECT auth.uid())
        AND role IN ('admin', 'super_admin')
    )
);

-- Admin/Super Admin can update ALL trips (for classification changes, etc.)
CREATE POLICY "Admins can update all trips"
ON trips FOR UPDATE TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM employee_profiles
        WHERE id = (SELECT auth.uid())
        AND role IN ('admin', 'super_admin')
    )
);

-- Admin/Super Admin can delete ALL trips (for re-detection)
CREATE POLICY "Admins can delete all trips"
ON trips FOR DELETE TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM employee_profiles
        WHERE id = (SELECT auth.uid())
        AND role IN ('admin', 'super_admin')
    )
);
