-- GPS Clock-In Tracker: Super Admin Role Feature
-- Migration: 009_super_admin_role
-- Date: 2026-01-14
-- Feature: Protected super_admin role with global visibility and role management

-- =============================================================================
-- SCHEMA CHANGES
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1.1 Add 'super_admin' to role constraint
-- -----------------------------------------------------------------------------
ALTER TABLE employee_profiles
DROP CONSTRAINT IF EXISTS employee_profiles_role_check;

ALTER TABLE employee_profiles
ADD CONSTRAINT employee_profiles_role_check
CHECK (role IN ('employee', 'manager', 'admin', 'super_admin'));

COMMENT ON COLUMN employee_profiles.role IS 'User role: employee, manager, admin, or super_admin (protected)';

-- -----------------------------------------------------------------------------
-- 1.2 Create protection trigger for super_admin
-- Prevents demotion/deletion of super_admin accounts at database level
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION protect_super_admin()
RETURNS TRIGGER AS $$
BEGIN
    -- On UPDATE: Prevent role change FROM super_admin
    IF TG_OP = 'UPDATE' THEN
        IF OLD.role = 'super_admin' AND NEW.role != 'super_admin' THEN
            RAISE EXCEPTION 'Cannot demote super_admin account';
        END IF;
    END IF;

    -- On DELETE: Prevent deletion of super_admin
    IF TG_OP = 'DELETE' THEN
        IF OLD.role = 'super_admin' THEN
            RAISE EXCEPTION 'Cannot delete super_admin account';
        END IF;
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS protect_super_admin_trigger ON employee_profiles;

CREATE TRIGGER protect_super_admin_trigger
BEFORE UPDATE OR DELETE ON employee_profiles
FOR EACH ROW EXECUTE FUNCTION protect_super_admin();

COMMENT ON FUNCTION protect_super_admin IS 'Trigger function to prevent super_admin demotion or deletion';

-- =============================================================================
-- ROW LEVEL SECURITY UPDATES
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1.3 Update employee_profiles RLS - admin/super_admin can see everyone
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Users can view own or supervised profiles" ON employee_profiles;
DROP POLICY IF EXISTS "Users can view profiles based on role" ON employee_profiles;

CREATE POLICY "Users can view profiles based on role"
ON employee_profiles FOR SELECT TO authenticated
USING (
    -- Own profile
    (SELECT auth.uid()) = id
    -- OR admin/super_admin can see everyone
    OR EXISTS (
        SELECT 1 FROM employee_profiles ep
        WHERE ep.id = (SELECT auth.uid())
        AND ep.role IN ('admin', 'super_admin')
    )
    -- OR manager supervises this employee
    OR EXISTS (
        SELECT 1 FROM employee_supervisors es
        WHERE es.manager_id = (SELECT auth.uid())
        AND es.employee_id = employee_profiles.id
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
    )
);

-- -----------------------------------------------------------------------------
-- 1.3 Update employee_profiles UPDATE RLS - admin can update roles
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Users can update own profile" ON employee_profiles;
DROP POLICY IF EXISTS "Admins can update user roles" ON employee_profiles;

CREATE POLICY "Users can update profiles based on role"
ON employee_profiles FOR UPDATE TO authenticated
USING (
    -- Own profile
    (SELECT auth.uid()) = id
    -- OR caller is admin/super_admin updating non-super_admin
    OR (
        EXISTS (
            SELECT 1 FROM employee_profiles ep
            WHERE ep.id = (SELECT auth.uid())
            AND ep.role IN ('admin', 'super_admin')
        )
        AND role != 'super_admin'  -- Cannot update super_admin's row (extra protection)
    )
)
WITH CHECK (
    -- Own profile updates (but cannot change own role unless super_admin)
    (
        (SELECT auth.uid()) = id
        AND (
            role = (SELECT ep.role FROM employee_profiles ep WHERE ep.id = (SELECT auth.uid()))
            OR EXISTS (
                SELECT 1 FROM employee_profiles ep
                WHERE ep.id = (SELECT auth.uid())
                AND ep.role = 'super_admin'
            )
        )
    )
    -- OR admin/super_admin can update others
    OR (
        EXISTS (
            SELECT 1 FROM employee_profiles ep
            WHERE ep.id = (SELECT auth.uid())
            AND ep.role IN ('admin', 'super_admin')
        )
        AND (SELECT auth.uid()) != id
        -- Only super_admin can assign super_admin role
        AND (
            role != 'super_admin'
            OR EXISTS (
                SELECT 1 FROM employee_profiles ep
                WHERE ep.id = (SELECT auth.uid())
                AND ep.role = 'super_admin'
            )
        )
    )
);

-- -----------------------------------------------------------------------------
-- 1.3 Update shifts RLS - admin/super_admin can see all shifts
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Users can view own or supervised employee shifts" ON shifts;
DROP POLICY IF EXISTS "Users can view shifts based on role" ON shifts;

CREATE POLICY "Users can view shifts based on role"
ON shifts FOR SELECT TO authenticated
USING (
    -- Own shifts
    (SELECT auth.uid()) = employee_id
    -- OR admin/super_admin can see all
    OR EXISTS (
        SELECT 1 FROM employee_profiles ep
        WHERE ep.id = (SELECT auth.uid())
        AND ep.role IN ('admin', 'super_admin')
    )
    -- OR manager supervises this employee
    OR EXISTS (
        SELECT 1 FROM employee_supervisors es
        WHERE es.manager_id = (SELECT auth.uid())
        AND es.employee_id = shifts.employee_id
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
    )
);

-- -----------------------------------------------------------------------------
-- 1.3 Update gps_points RLS - admin/super_admin can see all GPS points
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Users can view own or supervised employee GPS points" ON gps_points;
DROP POLICY IF EXISTS "Users can view GPS points based on role" ON gps_points;

CREATE POLICY "Users can view GPS points based on role"
ON gps_points FOR SELECT TO authenticated
USING (
    -- Own GPS points
    (SELECT auth.uid()) = employee_id
    -- OR admin/super_admin can see all
    OR EXISTS (
        SELECT 1 FROM employee_profiles ep
        WHERE ep.id = (SELECT auth.uid())
        AND ep.role IN ('admin', 'super_admin')
    )
    -- OR manager supervises this employee
    OR EXISTS (
        SELECT 1 FROM employee_supervisors es
        WHERE es.manager_id = (SELECT auth.uid())
        AND es.employee_id = gps_points.employee_id
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
    )
);

-- -----------------------------------------------------------------------------
-- 1.3 Update employee_supervisors RLS - admin/super_admin can manage
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Only admins can insert supervision relationships" ON employee_supervisors;
DROP POLICY IF EXISTS "Only admins can update supervision relationships" ON employee_supervisors;
DROP POLICY IF EXISTS "Only admins can delete supervision relationships" ON employee_supervisors;

CREATE POLICY "Admins can insert supervision relationships"
ON employee_supervisors FOR INSERT TO authenticated
WITH CHECK (
    EXISTS (
        SELECT 1 FROM employee_profiles ep
        WHERE ep.id = (SELECT auth.uid())
        AND ep.role IN ('admin', 'super_admin')
    )
);

CREATE POLICY "Admins can update supervision relationships"
ON employee_supervisors FOR UPDATE TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM employee_profiles ep
        WHERE ep.id = (SELECT auth.uid())
        AND ep.role IN ('admin', 'super_admin')
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1 FROM employee_profiles ep
        WHERE ep.id = (SELECT auth.uid())
        AND ep.role IN ('admin', 'super_admin')
    )
);

CREATE POLICY "Admins can delete supervision relationships"
ON employee_supervisors FOR DELETE TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM employee_profiles ep
        WHERE ep.id = (SELECT auth.uid())
        AND ep.role IN ('admin', 'super_admin')
    )
);

-- =============================================================================
-- FUNCTION UPDATES
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1.5 get_supervised_employees: Add admin/super_admin bypass to see ALL employees
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_supervised_employees()
RETURNS TABLE (
    id UUID,
    email TEXT,
    full_name TEXT,
    employee_id TEXT,
    status TEXT,
    role TEXT,
    last_shift_at TIMESTAMPTZ,
    total_shifts_this_month INT,
    total_hours_this_month BIGINT
) AS $$
DECLARE
    v_caller_role TEXT;
BEGIN
    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Admin/super_admin sees ALL employees (except themselves)
    IF v_caller_role IN ('admin', 'super_admin') THEN
        RETURN QUERY
        SELECT
            ep.id,
            ep.email,
            ep.full_name,
            ep.employee_id,
            ep.status,
            ep.role,
            (SELECT MAX(s.clocked_in_at) FROM shifts s WHERE s.employee_id = ep.id) as last_shift_at,
            (SELECT COUNT(*)::INT FROM shifts s
             WHERE s.employee_id = ep.id
             AND s.clocked_in_at >= date_trunc('month', CURRENT_DATE)) as total_shifts_this_month,
            (SELECT COALESCE(
                EXTRACT(EPOCH FROM SUM(
                    CASE WHEN s.clocked_out_at IS NOT NULL
                    THEN s.clocked_out_at - s.clocked_in_at
                    ELSE INTERVAL '0'
                    END))::BIGINT,
                0)
             FROM shifts s
             WHERE s.employee_id = ep.id
             AND s.clocked_in_at >= date_trunc('month', CURRENT_DATE)) as total_hours_this_month
        FROM employee_profiles ep
        WHERE ep.id != (SELECT auth.uid())
        ORDER BY ep.full_name, ep.email;
    ELSE
        -- Regular manager logic (original behavior)
        RETURN QUERY
        SELECT
            ep.id,
            ep.email,
            ep.full_name,
            ep.employee_id,
            ep.status,
            ep.role,
            (SELECT MAX(s.clocked_in_at) FROM shifts s WHERE s.employee_id = ep.id) as last_shift_at,
            (SELECT COUNT(*)::INT FROM shifts s
             WHERE s.employee_id = ep.id
             AND s.clocked_in_at >= date_trunc('month', CURRENT_DATE)) as total_shifts_this_month,
            (SELECT COALESCE(
                EXTRACT(EPOCH FROM SUM(
                    CASE WHEN s.clocked_out_at IS NOT NULL
                    THEN s.clocked_out_at - s.clocked_in_at
                    ELSE INTERVAL '0'
                    END))::BIGINT,
                0)
             FROM shifts s
             WHERE s.employee_id = ep.id
             AND s.clocked_in_at >= date_trunc('month', CURRENT_DATE)) as total_hours_this_month
        FROM employee_profiles ep
        INNER JOIN employee_supervisors es ON es.employee_id = ep.id
        WHERE es.manager_id = (SELECT auth.uid())
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
        ORDER BY ep.full_name, ep.email;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- -----------------------------------------------------------------------------
-- 1.5 get_employee_shifts: Add admin/super_admin bypass
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_employee_shifts(
    p_employee_id UUID,
    p_start_date TIMESTAMPTZ DEFAULT NULL,
    p_end_date TIMESTAMPTZ DEFAULT NULL,
    p_limit INT DEFAULT 50,
    p_offset INT DEFAULT 0
)
RETURNS TABLE (
    id UUID,
    employee_id UUID,
    status TEXT,
    clocked_in_at TIMESTAMPTZ,
    clock_in_location JSONB,
    clock_in_accuracy DECIMAL,
    clocked_out_at TIMESTAMPTZ,
    clock_out_location JSONB,
    clock_out_accuracy DECIMAL,
    duration_seconds INT,
    gps_point_count INT,
    created_at TIMESTAMPTZ
) AS $$
DECLARE
    v_caller_role TEXT;
BEGIN
    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Verify caller has access to this employee
    IF NOT (
        p_employee_id = (SELECT auth.uid())
        OR v_caller_role IN ('admin', 'super_admin')
        OR EXISTS (
            SELECT 1 FROM employee_supervisors
            WHERE manager_id = (SELECT auth.uid())
            AND employee_supervisors.employee_id = p_employee_id
            AND (effective_to IS NULL OR effective_to >= CURRENT_DATE)
        )
    ) THEN
        RAISE EXCEPTION 'Access denied';
    END IF;

    RETURN QUERY
    SELECT
        s.id,
        s.employee_id,
        s.status,
        s.clocked_in_at,
        s.clock_in_location,
        s.clock_in_accuracy,
        s.clocked_out_at,
        s.clock_out_location,
        s.clock_out_accuracy,
        EXTRACT(EPOCH FROM COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at)::INT as duration_seconds,
        (SELECT COUNT(*)::INT FROM gps_points gp WHERE gp.shift_id = s.id) as gps_point_count,
        s.created_at
    FROM shifts s
    WHERE s.employee_id = p_employee_id
    AND (p_start_date IS NULL OR s.clocked_in_at >= p_start_date)
    AND (p_end_date IS NULL OR s.clocked_in_at <= p_end_date)
    ORDER BY s.clocked_in_at DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- -----------------------------------------------------------------------------
-- 1.5 get_shift_gps_points: Add admin/super_admin bypass
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_shift_gps_points(p_shift_id UUID)
RETURNS TABLE (
    id UUID,
    latitude DECIMAL,
    longitude DECIMAL,
    accuracy DECIMAL,
    captured_at TIMESTAMPTZ
) AS $$
DECLARE
    v_employee_id UUID;
    v_caller_role TEXT;
BEGIN
    -- Get employee ID for the shift
    SELECT s.employee_id INTO v_employee_id FROM shifts s WHERE s.id = p_shift_id;

    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Verify caller has access
    IF NOT (
        v_employee_id = (SELECT auth.uid())
        OR v_caller_role IN ('admin', 'super_admin')
        OR EXISTS (
            SELECT 1 FROM employee_supervisors
            WHERE manager_id = (SELECT auth.uid())
            AND employee_supervisors.employee_id = v_employee_id
            AND (effective_to IS NULL OR effective_to >= CURRENT_DATE)
        )
    ) THEN
        RAISE EXCEPTION 'Access denied';
    END IF;

    RETURN QUERY
    SELECT
        gp.id,
        gp.latitude,
        gp.longitude,
        gp.accuracy,
        gp.captured_at
    FROM gps_points gp
    WHERE gp.shift_id = p_shift_id
    ORDER BY gp.captured_at ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- -----------------------------------------------------------------------------
-- 1.5 get_employee_statistics: Add admin/super_admin bypass
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_employee_statistics(
    p_employee_id UUID,
    p_start_date TIMESTAMPTZ DEFAULT NULL,
    p_end_date TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
    total_shifts INT,
    total_seconds BIGINT,
    avg_duration_seconds INT,
    earliest_shift TIMESTAMPTZ,
    latest_shift TIMESTAMPTZ,
    total_gps_points BIGINT
) AS $$
DECLARE
    v_caller_role TEXT;
BEGIN
    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Verify caller has access
    IF NOT (
        p_employee_id = (SELECT auth.uid())
        OR v_caller_role IN ('admin', 'super_admin')
        OR EXISTS (
            SELECT 1 FROM employee_supervisors
            WHERE manager_id = (SELECT auth.uid())
            AND employee_supervisors.employee_id = p_employee_id
            AND (effective_to IS NULL OR effective_to >= CURRENT_DATE)
        )
    ) THEN
        RAISE EXCEPTION 'Access denied';
    END IF;

    RETURN QUERY
    SELECT
        COUNT(s.id)::INT as total_shifts,
        COALESCE(
            EXTRACT(EPOCH FROM SUM(COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at))::BIGINT,
            0
        ) as total_seconds,
        CASE
            WHEN COUNT(s.id) > 0 THEN
                (EXTRACT(EPOCH FROM SUM(COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at)) / COUNT(s.id))::INT
            ELSE 0
        END as avg_duration_seconds,
        MIN(s.clocked_in_at) as earliest_shift,
        MAX(s.clocked_in_at) as latest_shift,
        (SELECT COUNT(*) FROM gps_points gp
         INNER JOIN shifts sh ON gp.shift_id = sh.id
         WHERE sh.employee_id = p_employee_id
         AND (p_start_date IS NULL OR sh.clocked_in_at >= p_start_date)
         AND (p_end_date IS NULL OR sh.clocked_in_at <= p_end_date)) as total_gps_points
    FROM shifts s
    WHERE s.employee_id = p_employee_id
    AND s.status = 'completed'
    AND (p_start_date IS NULL OR s.clocked_in_at >= p_start_date)
    AND (p_end_date IS NULL OR s.clocked_in_at <= p_end_date);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- -----------------------------------------------------------------------------
-- 1.5 get_team_statistics: Add admin/super_admin global stats
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_team_statistics(
    p_start_date TIMESTAMPTZ DEFAULT NULL,
    p_end_date TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
    total_employees INT,
    total_shifts INT,
    total_seconds BIGINT,
    avg_duration_seconds INT,
    avg_shifts_per_employee DECIMAL
) AS $$
DECLARE
    v_caller_role TEXT;
    v_employee_count INT;
BEGIN
    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Admin/super_admin gets stats for ALL employees
    IF v_caller_role IN ('admin', 'super_admin') THEN
        -- Count all employees except self
        SELECT COUNT(*)::INT INTO v_employee_count
        FROM employee_profiles ep
        WHERE ep.id != (SELECT auth.uid());

        RETURN QUERY
        SELECT
            v_employee_count as total_employees,
            COUNT(s.id)::INT as total_shifts,
            COALESCE(
                EXTRACT(EPOCH FROM SUM(COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at))::BIGINT,
                0
            ) as total_seconds,
            CASE
                WHEN COUNT(s.id) > 0 THEN
                    (EXTRACT(EPOCH FROM SUM(COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at)) / COUNT(s.id))::INT
                ELSE 0
            END as avg_duration_seconds,
            CASE
                WHEN v_employee_count > 0
                THEN COUNT(s.id)::DECIMAL / v_employee_count
                ELSE 0
            END as avg_shifts_per_employee
        FROM shifts s
        WHERE s.employee_id != (SELECT auth.uid())
        AND s.status = 'completed'
        AND (p_start_date IS NULL OR s.clocked_in_at >= p_start_date)
        AND (p_end_date IS NULL OR s.clocked_in_at <= p_end_date);
    ELSE
        -- Regular manager logic (original behavior)
        RETURN QUERY
        SELECT
            (SELECT COUNT(DISTINCT es.employee_id)::INT
             FROM employee_supervisors es
             WHERE es.manager_id = (SELECT auth.uid())
             AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)) as total_employees,
            COUNT(s.id)::INT as total_shifts,
            COALESCE(
                EXTRACT(EPOCH FROM SUM(COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at))::BIGINT,
                0
            ) as total_seconds,
            CASE
                WHEN COUNT(s.id) > 0 THEN
                    (EXTRACT(EPOCH FROM SUM(COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at)) / COUNT(s.id))::INT
                ELSE 0
            END as avg_duration_seconds,
            CASE
                WHEN (SELECT COUNT(DISTINCT es2.employee_id)
                      FROM employee_supervisors es2
                      WHERE es2.manager_id = (SELECT auth.uid())
                      AND (es2.effective_to IS NULL OR es2.effective_to >= CURRENT_DATE)) > 0
                THEN COUNT(s.id)::DECIMAL / (SELECT COUNT(DISTINCT es2.employee_id)
                      FROM employee_supervisors es2
                      WHERE es2.manager_id = (SELECT auth.uid())
                      AND (es2.effective_to IS NULL OR es2.effective_to >= CURRENT_DATE))
                ELSE 0
            END as avg_shifts_per_employee
        FROM shifts s
        INNER JOIN employee_supervisors es ON es.employee_id = s.employee_id
        WHERE es.manager_id = (SELECT auth.uid())
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
        AND s.status = 'completed'
        AND (p_start_date IS NULL OR s.clocked_in_at >= p_start_date)
        AND (p_end_date IS NULL OR s.clocked_in_at <= p_end_date);
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- -----------------------------------------------------------------------------
-- 1.5 get_team_employee_hours: Add admin/super_admin global view
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_team_employee_hours(
    p_start_date TIMESTAMPTZ DEFAULT NULL,
    p_end_date TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
    employee_id UUID,
    display_name TEXT,
    total_hours DECIMAL
) AS $$
DECLARE
    v_caller_role TEXT;
BEGIN
    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Admin/super_admin gets hours for ALL employees
    IF v_caller_role IN ('admin', 'super_admin') THEN
        RETURN QUERY
        SELECT
            ep.id as employee_id,
            COALESCE(ep.full_name, ep.email) as display_name,
            COALESCE(
                ROUND(
                    EXTRACT(EPOCH FROM SUM(
                        COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at
                    )) / 3600.0,
                    1
                ),
                0
            ) as total_hours
        FROM employee_profiles ep
        LEFT JOIN shifts s ON s.employee_id = ep.id
            AND s.status = 'completed'
            AND (p_start_date IS NULL OR s.clocked_in_at >= p_start_date)
            AND (p_end_date IS NULL OR s.clocked_in_at <= p_end_date)
        WHERE ep.id != (SELECT auth.uid())
        GROUP BY ep.id, ep.full_name, ep.email
        ORDER BY total_hours DESC;
    ELSE
        -- Regular manager logic (original behavior)
        RETURN QUERY
        SELECT
            ep.id as employee_id,
            COALESCE(ep.full_name, ep.email) as display_name,
            COALESCE(
                ROUND(
                    EXTRACT(EPOCH FROM SUM(
                        COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at
                    )) / 3600.0,
                    1
                ),
                0
            ) as total_hours
        FROM employee_profiles ep
        INNER JOIN employee_supervisors es ON es.employee_id = ep.id
        LEFT JOIN shifts s ON s.employee_id = ep.id
            AND s.status = 'completed'
            AND (p_start_date IS NULL OR s.clocked_in_at >= p_start_date)
            AND (p_end_date IS NULL OR s.clocked_in_at <= p_end_date)
        WHERE es.manager_id = (SELECT auth.uid())
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
        GROUP BY ep.id, ep.full_name, ep.email
        ORDER BY total_hours DESC;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- -----------------------------------------------------------------------------
-- 1.5 get_team_active_status: Add admin/super_admin global view
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_team_active_status()
RETURNS TABLE (
    employee_id UUID,
    display_name TEXT,
    email TEXT,
    employee_number TEXT,
    is_active BOOLEAN,
    current_shift_started_at TIMESTAMPTZ,
    today_hours_seconds INT,
    monthly_hours_seconds INT,
    monthly_shift_count INT
) AS $$
DECLARE
    v_today_start TIMESTAMPTZ;
    v_month_start TIMESTAMPTZ;
    v_caller_role TEXT;
BEGIN
    v_today_start := date_trunc('day', NOW());
    v_month_start := date_trunc('month', NOW());

    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Admin/super_admin gets status for ALL employees
    IF v_caller_role IN ('admin', 'super_admin') THEN
        RETURN QUERY
        SELECT
            ep.id as employee_id,
            COALESCE(ep.full_name, ep.email) as display_name,
            ep.email,
            ep.employee_id as employee_number,
            COALESCE(active_shift.is_active, false) as is_active,
            active_shift.clocked_in_at as current_shift_started_at,
            COALESCE(today_stats.total_seconds, 0) as today_hours_seconds,
            COALESCE(month_stats.total_seconds, 0) as monthly_hours_seconds,
            COALESCE(month_stats.shift_count, 0) as monthly_shift_count
        FROM employee_profiles ep
        -- Active shift subquery
        LEFT JOIN LATERAL (
            SELECT
                true as is_active,
                s.clocked_in_at
            FROM shifts s
            WHERE s.employee_id = ep.id AND s.status = 'active'
            LIMIT 1
        ) active_shift ON true
        -- Today's shift stats
        LEFT JOIN LATERAL (
            SELECT
                COALESCE(
                    EXTRACT(EPOCH FROM SUM(
                        COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at
                    ))::INT, 0
                ) as total_seconds
            FROM shifts s
            WHERE s.employee_id = ep.id
            AND s.clocked_in_at >= v_today_start
        ) today_stats ON true
        -- Monthly stats
        LEFT JOIN LATERAL (
            SELECT
                COUNT(*) FILTER (WHERE s.status = 'completed')::INT as shift_count,
                COALESCE(
                    EXTRACT(EPOCH FROM SUM(
                        CASE WHEN s.status = 'completed'
                        THEN s.clocked_out_at - s.clocked_in_at
                        ELSE INTERVAL '0' END
                    ))::INT, 0
                ) as total_seconds
            FROM shifts s
            WHERE s.employee_id = ep.id
            AND s.clocked_in_at >= v_month_start
        ) month_stats ON true
        WHERE ep.id != (SELECT auth.uid())
        ORDER BY
            COALESCE(active_shift.is_active, false) DESC,
            COALESCE(ep.full_name, ep.email);
    ELSE
        -- Regular manager logic (original behavior)
        RETURN QUERY
        SELECT
            ep.id as employee_id,
            COALESCE(ep.full_name, ep.email) as display_name,
            ep.email,
            ep.employee_id as employee_number,
            COALESCE(active_shift.is_active, false) as is_active,
            active_shift.clocked_in_at as current_shift_started_at,
            COALESCE(today_stats.total_seconds, 0) as today_hours_seconds,
            COALESCE(month_stats.total_seconds, 0) as monthly_hours_seconds,
            COALESCE(month_stats.shift_count, 0) as monthly_shift_count
        FROM employee_profiles ep
        INNER JOIN employee_supervisors es ON es.employee_id = ep.id
        -- Active shift subquery
        LEFT JOIN LATERAL (
            SELECT
                true as is_active,
                s.clocked_in_at
            FROM shifts s
            WHERE s.employee_id = ep.id AND s.status = 'active'
            LIMIT 1
        ) active_shift ON true
        -- Today's shift stats
        LEFT JOIN LATERAL (
            SELECT
                COALESCE(
                    EXTRACT(EPOCH FROM SUM(
                        COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at
                    ))::INT, 0
                ) as total_seconds
            FROM shifts s
            WHERE s.employee_id = ep.id
            AND s.clocked_in_at >= v_today_start
        ) today_stats ON true
        -- Monthly stats
        LEFT JOIN LATERAL (
            SELECT
                COUNT(*) FILTER (WHERE s.status = 'completed')::INT as shift_count,
                COALESCE(
                    EXTRACT(EPOCH FROM SUM(
                        CASE WHEN s.status = 'completed'
                        THEN s.clocked_out_at - s.clocked_in_at
                        ELSE INTERVAL '0' END
                    ))::INT, 0
                ) as total_seconds
            FROM shifts s
            WHERE s.employee_id = ep.id
            AND s.clocked_in_at >= v_month_start
        ) month_stats ON true
        WHERE es.manager_id = (SELECT auth.uid())
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
        ORDER BY
            COALESCE(active_shift.is_active, false) DESC,
            COALESCE(ep.full_name, ep.email);
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- -----------------------------------------------------------------------------
-- 1.6 update_user_role: New RPC function for role management
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_user_role(
    p_user_id UUID,
    p_new_role TEXT
)
RETURNS BOOLEAN AS $$
DECLARE
    v_caller_role TEXT;
    v_target_role TEXT;
BEGIN
    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Get target's current role
    SELECT ep.role INTO v_target_role
    FROM employee_profiles ep
    WHERE ep.id = p_user_id;

    -- Target must exist
    IF v_target_role IS NULL THEN
        RAISE EXCEPTION 'User not found';
    END IF;

    -- Validate caller is admin or super_admin
    IF v_caller_role NOT IN ('admin', 'super_admin') THEN
        RAISE EXCEPTION 'Only admins can change roles';
    END IF;

    -- Cannot modify super_admin
    IF v_target_role = 'super_admin' THEN
        RAISE EXCEPTION 'Cannot modify super_admin role';
    END IF;

    -- Only super_admin can assign super_admin role
    IF p_new_role = 'super_admin' AND v_caller_role != 'super_admin' THEN
        RAISE EXCEPTION 'Only super_admin can assign super_admin role';
    END IF;

    -- Validate new role
    IF p_new_role NOT IN ('employee', 'manager', 'admin', 'super_admin') THEN
        RAISE EXCEPTION 'Invalid role: %', p_new_role;
    END IF;

    -- Cannot change own role (unless super_admin)
    IF p_user_id = (SELECT auth.uid()) AND v_caller_role != 'super_admin' THEN
        RAISE EXCEPTION 'Cannot change own role';
    END IF;

    -- Update the role
    UPDATE employee_profiles
    SET role = p_new_role, updated_at = NOW()
    WHERE id = p_user_id;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION update_user_role IS 'Update a user role (admin/super_admin only, cannot modify super_admin)';

-- -----------------------------------------------------------------------------
-- 1.6 get_all_users: New RPC function to get all users for admin panel
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_all_users()
RETURNS TABLE (
    id UUID,
    email TEXT,
    full_name TEXT,
    employee_id TEXT,
    status TEXT,
    role TEXT,
    created_at TIMESTAMPTZ
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
        ep.created_at
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

-- =============================================================================
-- SET SUPER_ADMIN
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1.7 Set cedric@tri-logis.ca as super_admin
-- -----------------------------------------------------------------------------
UPDATE employee_profiles
SET role = 'super_admin', updated_at = NOW()
WHERE email = 'cedric@tri-logis.ca';
