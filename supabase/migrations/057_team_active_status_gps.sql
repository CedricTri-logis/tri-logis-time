-- Migration 057: Add latest GPS captured_at to get_team_active_status
-- Shows how long ago the last GPS position was updated for active employees

-- Must DROP first because we're adding a column to the return type
DROP FUNCTION IF EXISTS get_team_active_status();

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
    monthly_shift_count INT,
    latest_gps_captured_at TIMESTAMPTZ
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
            COALESCE(month_stats.shift_count, 0) as monthly_shift_count,
            latest_gps.captured_at as latest_gps_captured_at
        FROM employee_profiles ep
        -- Active shift subquery
        LEFT JOIN LATERAL (
            SELECT
                true as is_active,
                s.clocked_in_at,
                s.id as shift_id
            FROM shifts s
            WHERE s.employee_id = ep.id AND s.status = 'active'
            LIMIT 1
        ) active_shift ON true
        -- Latest GPS point for active shift
        LEFT JOIN LATERAL (
            SELECT gp.captured_at
            FROM gps_points gp
            WHERE gp.shift_id = active_shift.shift_id
            ORDER BY gp.captured_at DESC
            LIMIT 1
        ) latest_gps ON active_shift.shift_id IS NOT NULL
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
            COALESCE(month_stats.shift_count, 0) as monthly_shift_count,
            latest_gps.captured_at as latest_gps_captured_at
        FROM employee_profiles ep
        INNER JOIN employee_supervisors es ON es.employee_id = ep.id
        -- Active shift subquery
        LEFT JOIN LATERAL (
            SELECT
                true as is_active,
                s.clocked_in_at,
                s.id as shift_id
            FROM shifts s
            WHERE s.employee_id = ep.id AND s.status = 'active'
            LIMIT 1
        ) active_shift ON true
        -- Latest GPS point for active shift
        LEFT JOIN LATERAL (
            SELECT gp.captured_at
            FROM gps_points gp
            WHERE gp.shift_id = active_shift.shift_id
            ORDER BY gp.captured_at DESC
            LIMIT 1
        ) latest_gps ON active_shift.shift_id IS NOT NULL
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
