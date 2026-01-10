-- GPS Clock-In Tracker: Employee History Feature
-- Migration: 006_employee_history
-- Date: 2026-01-10
-- Feature: Employee History - Manager supervision and history access

-- =============================================================================
-- SCHEMA CHANGES
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Add role column to employee_profiles
-- -----------------------------------------------------------------------------
ALTER TABLE employee_profiles
ADD COLUMN role TEXT NOT NULL DEFAULT 'employee'
    CHECK (role IN ('employee', 'manager', 'admin'));

COMMENT ON COLUMN employee_profiles.role IS 'User role for access control: employee, manager, or admin';

-- Index for role-based queries
CREATE INDEX idx_employee_profiles_role ON employee_profiles(role);

-- -----------------------------------------------------------------------------
-- employee_supervisors: Manager-employee supervision relationships
-- -----------------------------------------------------------------------------
CREATE TABLE employee_supervisors (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    manager_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
    supervision_type TEXT NOT NULL DEFAULT 'direct'
        CHECK (supervision_type IN ('direct', 'matrix', 'temporary')),
    effective_from DATE NOT NULL DEFAULT CURRENT_DATE,
    effective_to DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT no_self_supervision CHECK (manager_id != employee_id),
    CONSTRAINT valid_date_range CHECK (effective_to IS NULL OR effective_to > effective_from),
    CONSTRAINT unique_active_supervision UNIQUE (manager_id, employee_id, effective_from)
);

COMMENT ON TABLE employee_supervisors IS 'Manager-employee supervision relationships with effective dates';
COMMENT ON COLUMN employee_supervisors.supervision_type IS 'Type of supervision: direct (primary), matrix (secondary), temporary';
COMMENT ON COLUMN employee_supervisors.effective_to IS 'NULL indicates currently active supervision';

-- Indexes for supervision queries
CREATE INDEX idx_employee_supervisors_manager ON employee_supervisors(manager_id);
CREATE INDEX idx_employee_supervisors_employee ON employee_supervisors(employee_id);
CREATE INDEX idx_employee_supervisors_active ON employee_supervisors(manager_id)
    WHERE effective_to IS NULL;

-- Index for efficient shift date range filtering
CREATE INDEX idx_shifts_employee_date ON shifts(employee_id, clocked_in_at DESC);

-- =============================================================================
-- ROW LEVEL SECURITY
-- =============================================================================

ALTER TABLE employee_supervisors ENABLE ROW LEVEL SECURITY;

-- -----------------------------------------------------------------------------
-- Update employee_profiles RLS - allow managers to view supervised employees
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Users can view own profile" ON employee_profiles;

CREATE POLICY "Users can view own or supervised profiles"
ON employee_profiles FOR SELECT TO authenticated
USING (
    (SELECT auth.uid()) = id
    OR EXISTS (
        SELECT 1 FROM employee_supervisors es
        WHERE es.manager_id = (SELECT auth.uid())
        AND es.employee_id = employee_profiles.id
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
    )
);

-- -----------------------------------------------------------------------------
-- Update shifts RLS - allow managers to view supervised employee shifts
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Users can view own shifts" ON shifts;

CREATE POLICY "Users can view own or supervised employee shifts"
ON shifts FOR SELECT TO authenticated
USING (
    (SELECT auth.uid()) = employee_id
    OR EXISTS (
        SELECT 1 FROM employee_supervisors es
        WHERE es.manager_id = (SELECT auth.uid())
        AND es.employee_id = shifts.employee_id
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
    )
);

-- -----------------------------------------------------------------------------
-- Update gps_points RLS - allow managers to view supervised employee GPS points
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Users can view own GPS points" ON gps_points;

CREATE POLICY "Users can view own or supervised employee GPS points"
ON gps_points FOR SELECT TO authenticated
USING (
    (SELECT auth.uid()) = employee_id
    OR EXISTS (
        SELECT 1 FROM employee_supervisors es
        WHERE es.manager_id = (SELECT auth.uid())
        AND es.employee_id = gps_points.employee_id
        AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
    )
);

-- -----------------------------------------------------------------------------
-- employee_supervisors RLS policies
-- -----------------------------------------------------------------------------

-- Users can view supervision relationships they are part of
CREATE POLICY "Users can view own supervision relationships"
ON employee_supervisors FOR SELECT TO authenticated
USING (
    (SELECT auth.uid()) = manager_id
    OR (SELECT auth.uid()) = employee_id
);

-- Only admins can manage supervision relationships
CREATE POLICY "Only admins can insert supervision relationships"
ON employee_supervisors FOR INSERT TO authenticated
WITH CHECK (
    EXISTS (
        SELECT 1 FROM employee_profiles ep
        WHERE ep.id = (SELECT auth.uid())
        AND ep.role = 'admin'
    )
);

CREATE POLICY "Only admins can update supervision relationships"
ON employee_supervisors FOR UPDATE TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM employee_profiles ep
        WHERE ep.id = (SELECT auth.uid())
        AND ep.role = 'admin'
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1 FROM employee_profiles ep
        WHERE ep.id = (SELECT auth.uid())
        AND ep.role = 'admin'
    )
);

CREATE POLICY "Only admins can delete supervision relationships"
ON employee_supervisors FOR DELETE TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM employee_profiles ep
        WHERE ep.id = (SELECT auth.uid())
        AND ep.role = 'admin'
    )
);

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- get_supervised_employees: Get list of employees supervised by current manager
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
BEGIN
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
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- -----------------------------------------------------------------------------
-- get_employee_shifts: Get paginated shift history for an employee
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
BEGIN
    -- Verify caller has access to this employee
    IF NOT (
        p_employee_id = (SELECT auth.uid())
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
-- get_shift_gps_points: Get GPS points for a specific shift
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
BEGIN
    -- Get employee ID for the shift
    SELECT s.employee_id INTO v_employee_id FROM shifts s WHERE s.id = p_shift_id;

    -- Verify caller has access
    IF NOT (
        v_employee_id = (SELECT auth.uid())
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
-- get_employee_statistics: Get shift statistics for an employee
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
BEGIN
    -- Verify caller has access
    IF NOT (
        p_employee_id = (SELECT auth.uid())
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
-- get_team_statistics: Get aggregate statistics for manager's team
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
BEGIN
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
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
