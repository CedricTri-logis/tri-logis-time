-- GPS Clock-In Tracker: Employee Management Feature
-- Migration: 011_employee_management
-- Date: 2026-01-15
-- Feature: Employee management with audit logging and supervision management

-- =============================================================================
-- PART 1: AUDIT SCHEMA AND TABLE
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1.1 Create audit schema
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS audit;

-- -----------------------------------------------------------------------------
-- 1.2 Create audit_logs table
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    table_name TEXT NOT NULL,
    table_schema TEXT NOT NULL DEFAULT 'public',
    operation TEXT NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    record_id UUID NOT NULL,
    user_id UUID,
    email TEXT,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    old_values JSONB,
    new_values JSONB,
    ip_address INET,
    change_reason TEXT
);

COMMENT ON TABLE audit.audit_logs IS 'Immutable audit log for tracking changes to audited tables';

-- Create indexes for efficient queries
CREATE INDEX IF NOT EXISTS idx_audit_logs_table_name ON audit.audit_logs(table_name);
CREATE INDEX IF NOT EXISTS idx_audit_logs_user_id ON audit.audit_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_record_id ON audit.audit_logs(record_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_changed_at ON audit.audit_logs(changed_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_table_record ON audit.audit_logs(table_name, record_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_new_values ON audit.audit_logs USING GIN(new_values);

-- -----------------------------------------------------------------------------
-- 1.3 RLS for audit_logs (admin read-only, no direct writes)
-- -----------------------------------------------------------------------------
ALTER TABLE audit.audit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins can view audit logs" ON audit.audit_logs;
CREATE POLICY "Admins can view audit logs"
ON audit.audit_logs FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM employee_profiles ep
        WHERE ep.id = (SELECT auth.uid())
        AND ep.role IN ('admin', 'super_admin')
    )
);

-- No INSERT/UPDATE/DELETE policies - writes only via trigger (SECURITY DEFINER)

-- =============================================================================
-- PART 2: AUDIT LOGGING TRIGGER FUNCTION
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 2.1 Generic audit trigger function
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.log_changes()
RETURNS TRIGGER AS $$
DECLARE
    v_user_id UUID;
    v_email TEXT;
    v_record_id UUID;
    v_old_values JSONB;
    v_new_values JSONB;
BEGIN
    -- Get current user
    v_user_id := (SELECT auth.uid());

    -- Get user email if available
    IF v_user_id IS NOT NULL THEN
        SELECT email INTO v_email
        FROM employee_profiles
        WHERE id = v_user_id;
    END IF;

    -- Determine record ID and values based on operation
    IF TG_OP = 'DELETE' THEN
        v_record_id := OLD.id;
        v_old_values := to_jsonb(OLD);
        v_new_values := NULL;
    ELSIF TG_OP = 'INSERT' THEN
        v_record_id := NEW.id;
        v_old_values := NULL;
        v_new_values := to_jsonb(NEW);
    ELSE -- UPDATE
        v_record_id := NEW.id;
        v_old_values := to_jsonb(OLD);
        v_new_values := to_jsonb(NEW);
    END IF;

    -- Insert audit log entry
    INSERT INTO audit.audit_logs (
        table_name,
        table_schema,
        operation,
        record_id,
        user_id,
        email,
        old_values,
        new_values
    ) VALUES (
        TG_TABLE_NAME,
        TG_TABLE_SCHEMA,
        TG_OP,
        v_record_id,
        v_user_id,
        v_email,
        v_old_values,
        v_new_values
    );

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION audit.log_changes IS 'Generic trigger function for capturing all changes to audited tables';

-- =============================================================================
-- PART 3: ATTACH AUDIT TRIGGERS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 3.1 Audit trigger for employee_profiles
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS audit_employee_profiles ON employee_profiles;
CREATE TRIGGER audit_employee_profiles
AFTER INSERT OR UPDATE OR DELETE ON employee_profiles
FOR EACH ROW EXECUTE FUNCTION audit.log_changes();

-- -----------------------------------------------------------------------------
-- 3.2 Audit trigger for employee_supervisors
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS audit_employee_supervisors ON employee_supervisors;
CREATE TRIGGER audit_employee_supervisors
AFTER INSERT OR UPDATE OR DELETE ON employee_supervisors
FOR EACH ROW EXECUTE FUNCTION audit.log_changes();

-- =============================================================================
-- PART 4: AUTO-END SUPERVISION ON DEACTIVATION
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 4.1 Function to end active supervisions when employee deactivated/suspended
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION end_active_supervisions()
RETURNS TRIGGER AS $$
BEGIN
    -- End all active supervision relationships where this employee is supervised
    UPDATE employee_supervisors
    SET effective_to = CURRENT_DATE
    WHERE employee_id = NEW.id
    AND effective_to IS NULL;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION end_active_supervisions IS 'Auto-ends active supervision relationships when employee is deactivated or suspended';

-- -----------------------------------------------------------------------------
-- 4.2 Trigger for auto-ending supervision on status change
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS end_supervision_on_status_change ON employee_profiles;
CREATE TRIGGER end_supervision_on_status_change
AFTER UPDATE OF status ON employee_profiles
FOR EACH ROW
WHEN (NEW.status IN ('inactive', 'suspended') AND OLD.status = 'active')
EXECUTE FUNCTION end_active_supervisions();

-- =============================================================================
-- PART 5: HELPER FUNCTIONS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 5.1 Check if at least one admin remains after excluding a user
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION check_last_admin(p_exclude_user_id UUID)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM employee_profiles
        WHERE id != p_exclude_user_id
        AND role IN ('admin', 'super_admin')
        AND status = 'active'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION check_last_admin IS 'Returns TRUE if at least one admin/super_admin remains active after excluding the given user';

-- =============================================================================
-- PART 6: EMPLOYEE MANAGEMENT RPC FUNCTIONS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 6.1 get_employees_paginated - List employees with search/filter/pagination
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_employees_paginated(
    p_search TEXT DEFAULT NULL,
    p_role TEXT DEFAULT NULL,
    p_status TEXT DEFAULT NULL,
    p_sort_field TEXT DEFAULT 'full_name',
    p_sort_order TEXT DEFAULT 'ASC',
    p_limit INT DEFAULT 50,
    p_offset INT DEFAULT 0
)
RETURNS TABLE (
    id UUID,
    email TEXT,
    full_name TEXT,
    employee_id TEXT,
    role TEXT,
    status TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    current_supervisor_id UUID,
    current_supervisor_name TEXT,
    current_supervisor_email TEXT,
    total_count BIGINT
) AS $$
DECLARE
    v_caller_role TEXT;
    v_total_count BIGINT;
BEGIN
    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Only admin/super_admin can access
    IF v_caller_role NOT IN ('admin', 'super_admin') THEN
        RAISE EXCEPTION 'Access denied';
    END IF;

    -- Get total count first
    SELECT COUNT(*) INTO v_total_count
    FROM employee_profiles ep
    WHERE (p_search IS NULL OR
           ep.full_name ILIKE '%' || p_search || '%' OR
           ep.email ILIKE '%' || p_search || '%' OR
           ep.employee_id ILIKE '%' || p_search || '%')
    AND (p_role IS NULL OR ep.role = p_role)
    AND (p_status IS NULL OR ep.status = p_status);

    -- Return results with dynamic sorting
    RETURN QUERY
    SELECT
        ep.id,
        ep.email,
        ep.full_name,
        ep.employee_id,
        ep.role,
        ep.status,
        ep.created_at,
        ep.updated_at,
        es.manager_id as current_supervisor_id,
        mgr.full_name as current_supervisor_name,
        mgr.email as current_supervisor_email,
        v_total_count as total_count
    FROM employee_profiles ep
    LEFT JOIN employee_supervisors es ON es.employee_id = ep.id
        AND es.effective_to IS NULL
    LEFT JOIN employee_profiles mgr ON mgr.id = es.manager_id
    WHERE (p_search IS NULL OR
           ep.full_name ILIKE '%' || p_search || '%' OR
           ep.email ILIKE '%' || p_search || '%' OR
           ep.employee_id ILIKE '%' || p_search || '%')
    AND (p_role IS NULL OR ep.role = p_role)
    AND (p_status IS NULL OR ep.status = p_status)
    ORDER BY
        CASE WHEN p_sort_order = 'ASC' THEN
            CASE p_sort_field
                WHEN 'full_name' THEN COALESCE(ep.full_name, ep.email)
                WHEN 'email' THEN ep.email
                WHEN 'role' THEN ep.role
                WHEN 'status' THEN ep.status
                WHEN 'employee_id' THEN ep.employee_id
                ELSE COALESCE(ep.full_name, ep.email)
            END
        END ASC NULLS LAST,
        CASE WHEN p_sort_order = 'DESC' THEN
            CASE p_sort_field
                WHEN 'full_name' THEN COALESCE(ep.full_name, ep.email)
                WHEN 'email' THEN ep.email
                WHEN 'role' THEN ep.role
                WHEN 'status' THEN ep.status
                WHEN 'employee_id' THEN ep.employee_id
                ELSE COALESCE(ep.full_name, ep.email)
            END
        END DESC NULLS LAST,
        ep.created_at DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION get_employees_paginated IS 'Get paginated employee list with search, filter, and sorting (admin only)';

-- -----------------------------------------------------------------------------
-- 6.2 get_employee_detail - Get single employee with supervision history
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_employee_detail(p_employee_id UUID)
RETURNS TABLE (
    id UUID,
    email TEXT,
    full_name TEXT,
    employee_id TEXT,
    role TEXT,
    status TEXT,
    privacy_consent_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    current_supervisor JSONB,
    supervision_history JSONB,
    has_active_shift BOOLEAN
) AS $$
DECLARE
    v_caller_role TEXT;
BEGIN
    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Only admin/super_admin can access
    IF v_caller_role NOT IN ('admin', 'super_admin') THEN
        RAISE EXCEPTION 'Access denied';
    END IF;

    RETURN QUERY
    SELECT
        ep.id,
        ep.email,
        ep.full_name,
        ep.employee_id,
        ep.role,
        ep.status,
        ep.privacy_consent_at,
        ep.created_at,
        ep.updated_at,
        -- Current supervisor
        (
            SELECT jsonb_build_object(
                'id', mgr.id,
                'full_name', mgr.full_name,
                'email', mgr.email
            )
            FROM employee_supervisors es
            JOIN employee_profiles mgr ON mgr.id = es.manager_id
            WHERE es.employee_id = ep.id AND es.effective_to IS NULL
            LIMIT 1
        ) as current_supervisor,
        -- Supervision history
        COALESCE(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'id', es.id,
                        'manager_id', es.manager_id,
                        'manager_name', mgr.full_name,
                        'manager_email', mgr.email,
                        'supervision_type', es.supervision_type,
                        'effective_from', es.effective_from,
                        'effective_to', es.effective_to
                    ) ORDER BY es.effective_from DESC
                )
                FROM employee_supervisors es
                JOIN employee_profiles mgr ON mgr.id = es.manager_id
                WHERE es.employee_id = ep.id
            ),
            '[]'::JSONB
        ) as supervision_history,
        -- Has active shift
        EXISTS (
            SELECT 1 FROM shifts s
            WHERE s.employee_id = ep.id AND s.status = 'active'
        ) as has_active_shift
    FROM employee_profiles ep
    WHERE ep.id = p_employee_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION get_employee_detail IS 'Get employee details with supervision history (admin only)';

-- -----------------------------------------------------------------------------
-- 6.3 update_employee_profile - Update name and employee_id
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_employee_profile(
    p_employee_id UUID,
    p_full_name TEXT DEFAULT NULL,
    p_employee_id_value TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_caller_role TEXT;
    v_target_role TEXT;
    v_updated_employee RECORD;
BEGIN
    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Get target's role
    SELECT ep.role INTO v_target_role
    FROM employee_profiles ep
    WHERE ep.id = p_employee_id;

    -- Target must exist
    IF v_target_role IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object(
                'code', 'NOT_FOUND',
                'message', 'Employee not found'
            )
        );
    END IF;

    -- Only admin/super_admin can update
    IF v_caller_role NOT IN ('admin', 'super_admin') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object(
                'code', 'ACCESS_DENIED',
                'message', 'Only admins can update employee profiles'
            )
        );
    END IF;

    -- Cannot modify super_admin unless caller is super_admin
    IF v_target_role = 'super_admin' AND v_caller_role != 'super_admin' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object(
                'code', 'PROTECTED_USER',
                'message', 'Cannot modify super_admin account'
            )
        );
    END IF;

    -- Check for duplicate employee_id if provided
    IF p_employee_id_value IS NOT NULL AND p_employee_id_value != '' THEN
        IF EXISTS (
            SELECT 1 FROM employee_profiles
            WHERE employee_id = p_employee_id_value
            AND id != p_employee_id
        ) THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', jsonb_build_object(
                    'code', 'DUPLICATE_EMPLOYEE_ID',
                    'message', 'Employee ID already in use'
                )
            );
        END IF;
    END IF;

    -- Update the employee
    UPDATE employee_profiles
    SET
        full_name = COALESCE(p_full_name, full_name),
        employee_id = CASE
            WHEN p_employee_id_value IS NOT NULL THEN
                NULLIF(p_employee_id_value, '')
            ELSE employee_id
        END,
        updated_at = NOW()
    WHERE id = p_employee_id
    RETURNING * INTO v_updated_employee;

    RETURN jsonb_build_object(
        'success', true,
        'employee', to_jsonb(v_updated_employee)
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION update_employee_profile IS 'Update employee name and employee_id (admin only)';

-- -----------------------------------------------------------------------------
-- 6.4 update_employee_status - Change status with active shift warning
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_employee_status(
    p_employee_id UUID,
    p_new_status TEXT,
    p_force BOOLEAN DEFAULT FALSE
)
RETURNS JSONB AS $$
DECLARE
    v_caller_id UUID;
    v_caller_role TEXT;
    v_target_role TEXT;
    v_target_status TEXT;
    v_has_active_shift BOOLEAN;
    v_updated_employee RECORD;
BEGIN
    v_caller_id := (SELECT auth.uid());

    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = v_caller_id;

    -- Get target's current role and status
    SELECT ep.role, ep.status INTO v_target_role, v_target_status
    FROM employee_profiles ep
    WHERE ep.id = p_employee_id;

    -- Target must exist
    IF v_target_role IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object(
                'code', 'NOT_FOUND',
                'message', 'Employee not found'
            )
        );
    END IF;

    -- Validate status value
    IF p_new_status NOT IN ('active', 'inactive', 'suspended') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object(
                'code', 'INVALID_STATUS',
                'message', 'Invalid status value'
            )
        );
    END IF;

    -- Only admin/super_admin can update status
    IF v_caller_role NOT IN ('admin', 'super_admin') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object(
                'code', 'ACCESS_DENIED',
                'message', 'Only admins can update employee status'
            )
        );
    END IF;

    -- Cannot deactivate self
    IF p_employee_id = v_caller_id AND p_new_status IN ('inactive', 'suspended') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object(
                'code', 'SELF_DEACTIVATION',
                'message', 'Cannot deactivate yourself'
            )
        );
    END IF;

    -- Cannot deactivate super_admin (unless caller is super_admin)
    IF v_target_role = 'super_admin' AND v_caller_role != 'super_admin' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object(
                'code', 'PROTECTED_USER',
                'message', 'Cannot deactivate super_admin account'
            )
        );
    END IF;

    -- Check last admin protection for deactivation
    IF p_new_status IN ('inactive', 'suspended')
       AND v_target_role IN ('admin', 'super_admin')
       AND v_target_status = 'active' THEN
        IF NOT check_last_admin(p_employee_id) THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', jsonb_build_object(
                    'code', 'LAST_ADMIN',
                    'message', 'Cannot deactivate the last admin'
                )
            );
        END IF;
    END IF;

    -- Check for active shift if deactivating
    IF p_new_status IN ('inactive', 'suspended') AND v_target_status = 'active' THEN
        SELECT EXISTS (
            SELECT 1 FROM shifts s
            WHERE s.employee_id = p_employee_id AND s.status = 'active'
        ) INTO v_has_active_shift;

        IF v_has_active_shift AND NOT p_force THEN
            RETURN jsonb_build_object(
                'success', false,
                'warning', 'Employee has an active shift that will remain open',
                'requires_confirmation', true,
                'error', jsonb_build_object(
                    'code', 'ACTIVE_SHIFT_WARNING',
                    'message', 'Employee has active shift (use p_force=true to proceed)'
                )
            );
        END IF;
    END IF;

    -- Update the status
    UPDATE employee_profiles
    SET status = p_new_status, updated_at = NOW()
    WHERE id = p_employee_id
    RETURNING * INTO v_updated_employee;

    RETURN jsonb_build_object(
        'success', true,
        'employee', to_jsonb(v_updated_employee)
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION update_employee_status IS 'Update employee status with active shift warning (admin only)';

-- -----------------------------------------------------------------------------
-- 6.5 assign_supervisor - Assign or reassign supervisor
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION assign_supervisor(
    p_employee_id UUID,
    p_manager_id UUID,
    p_supervision_type TEXT DEFAULT 'direct'
)
RETURNS JSONB AS $$
DECLARE
    v_caller_role TEXT;
    v_manager_role TEXT;
    v_previous_ended BOOLEAN := false;
    v_new_assignment RECORD;
BEGIN
    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Only admin/super_admin can assign
    IF v_caller_role NOT IN ('admin', 'super_admin') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object(
                'code', 'ACCESS_DENIED',
                'message', 'Only admins can assign supervisors'
            )
        );
    END IF;

    -- Validate employee exists
    IF NOT EXISTS (SELECT 1 FROM employee_profiles WHERE id = p_employee_id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object(
                'code', 'EMPLOYEE_NOT_FOUND',
                'message', 'Employee not found'
            )
        );
    END IF;

    -- Validate manager exists and has appropriate role
    SELECT ep.role INTO v_manager_role
    FROM employee_profiles ep
    WHERE ep.id = p_manager_id;

    IF v_manager_role IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object(
                'code', 'MANAGER_NOT_FOUND',
                'message', 'Manager not found'
            )
        );
    END IF;

    IF v_manager_role NOT IN ('manager', 'admin', 'super_admin') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object(
                'code', 'INVALID_MANAGER',
                'message', 'Selected user is not a manager, admin, or super_admin'
            )
        );
    END IF;

    -- Cannot assign to self
    IF p_employee_id = p_manager_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object(
                'code', 'SELF_ASSIGNMENT',
                'message', 'Cannot assign supervisor to themselves'
            )
        );
    END IF;

    -- Validate supervision type
    IF p_supervision_type NOT IN ('direct', 'matrix', 'temporary') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object(
                'code', 'INVALID_SUPERVISION_TYPE',
                'message', 'Invalid supervision type'
            )
        );
    END IF;

    -- End any current supervision
    IF EXISTS (
        SELECT 1 FROM employee_supervisors
        WHERE employee_id = p_employee_id AND effective_to IS NULL
    ) THEN
        UPDATE employee_supervisors
        SET effective_to = CURRENT_DATE
        WHERE employee_id = p_employee_id AND effective_to IS NULL;
        v_previous_ended := true;
    END IF;

    -- Create new assignment
    INSERT INTO employee_supervisors (
        manager_id,
        employee_id,
        supervision_type,
        effective_from
    ) VALUES (
        p_manager_id,
        p_employee_id,
        p_supervision_type,
        CURRENT_DATE
    )
    RETURNING * INTO v_new_assignment;

    RETURN jsonb_build_object(
        'success', true,
        'assignment', jsonb_build_object(
            'id', v_new_assignment.id,
            'manager_id', v_new_assignment.manager_id,
            'employee_id', v_new_assignment.employee_id,
            'effective_from', v_new_assignment.effective_from,
            'supervision_type', v_new_assignment.supervision_type
        ),
        'previous_assignment_ended', v_previous_ended
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION assign_supervisor IS 'Assign or reassign supervisor to an employee (admin only)';

-- -----------------------------------------------------------------------------
-- 6.6 remove_supervisor - End current supervision
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION remove_supervisor(p_employee_id UUID)
RETURNS JSONB AS $$
DECLARE
    v_caller_role TEXT;
    v_ended_assignment RECORD;
BEGIN
    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Only admin/super_admin can remove
    IF v_caller_role NOT IN ('admin', 'super_admin') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object(
                'code', 'ACCESS_DENIED',
                'message', 'Only admins can remove supervisors'
            )
        );
    END IF;

    -- Find and end current assignment
    UPDATE employee_supervisors
    SET effective_to = CURRENT_DATE
    WHERE employee_id = p_employee_id AND effective_to IS NULL
    RETURNING * INTO v_ended_assignment;

    IF v_ended_assignment IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', jsonb_build_object(
                'code', 'NO_ACTIVE_SUPERVISION',
                'message', 'No active supervision to remove'
            )
        );
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'ended_assignment', jsonb_build_object(
            'id', v_ended_assignment.id,
            'manager_id', v_ended_assignment.manager_id,
            'employee_id', v_ended_assignment.employee_id,
            'effective_to', v_ended_assignment.effective_to
        )
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION remove_supervisor IS 'Remove current supervisor from an employee (admin only)';

-- -----------------------------------------------------------------------------
-- 6.7 get_managers_list - Get list of eligible supervisors
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_managers_list()
RETURNS TABLE (
    id UUID,
    email TEXT,
    full_name TEXT,
    role TEXT,
    supervised_count BIGINT
) AS $$
DECLARE
    v_caller_role TEXT;
BEGIN
    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Only admin/super_admin can access
    IF v_caller_role NOT IN ('admin', 'super_admin') THEN
        RAISE EXCEPTION 'Access denied';
    END IF;

    RETURN QUERY
    SELECT
        ep.id,
        ep.email,
        ep.full_name,
        ep.role,
        (
            SELECT COUNT(*) FROM employee_supervisors es
            WHERE es.manager_id = ep.id AND es.effective_to IS NULL
        ) as supervised_count
    FROM employee_profiles ep
    WHERE ep.role IN ('manager', 'admin', 'super_admin')
    AND ep.status = 'active'
    ORDER BY ep.full_name, ep.email;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION get_managers_list IS 'Get list of active managers/admins for supervisor assignment (admin only)';

-- -----------------------------------------------------------------------------
-- 6.8 check_employee_active_shift - Check for active shift
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION check_employee_active_shift(p_employee_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
    v_caller_role TEXT;
BEGIN
    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Only admin/super_admin can check
    IF v_caller_role NOT IN ('admin', 'super_admin') THEN
        RAISE EXCEPTION 'Access denied';
    END IF;

    RETURN EXISTS (
        SELECT 1 FROM shifts
        WHERE employee_id = p_employee_id AND status = 'active'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION check_employee_active_shift IS 'Check if employee has an active shift (admin only)';

-- -----------------------------------------------------------------------------
-- 6.9 get_employee_audit_log - Get audit history for employee
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_employee_audit_log(
    p_employee_id UUID,
    p_limit INT DEFAULT 50,
    p_offset INT DEFAULT 0
)
RETURNS TABLE (
    id UUID,
    operation TEXT,
    user_id UUID,
    user_email TEXT,
    changed_at TIMESTAMPTZ,
    old_values JSONB,
    new_values JSONB,
    change_reason TEXT,
    total_count BIGINT
) AS $$
DECLARE
    v_caller_role TEXT;
    v_total_count BIGINT;
BEGIN
    -- Get caller's role
    SELECT ep.role INTO v_caller_role
    FROM employee_profiles ep
    WHERE ep.id = (SELECT auth.uid());

    -- Only admin/super_admin can access
    IF v_caller_role NOT IN ('admin', 'super_admin') THEN
        RAISE EXCEPTION 'Access denied';
    END IF;

    -- Get total count
    SELECT COUNT(*) INTO v_total_count
    FROM audit.audit_logs al
    WHERE al.record_id = p_employee_id
    AND al.table_name = 'employee_profiles';

    RETURN QUERY
    SELECT
        al.id,
        al.operation,
        al.user_id,
        al.email as user_email,
        al.changed_at,
        al.old_values,
        al.new_values,
        al.change_reason,
        v_total_count as total_count
    FROM audit.audit_logs al
    WHERE al.record_id = p_employee_id
    AND al.table_name = 'employee_profiles'
    ORDER BY al.changed_at DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION get_employee_audit_log IS 'Get audit log entries for an employee (admin only)';

-- =============================================================================
-- DONE
-- =============================================================================
