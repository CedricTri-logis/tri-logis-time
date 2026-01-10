-- GPS Clock-In Tracker: Employee Dashboard Feature
-- Migration: 008_employee_dashboard
-- Date: 2026-01-10
-- Feature: Employee & Shift Dashboard - Personalized dashboards with live stats

-- =============================================================================
-- RPC FUNCTIONS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- get_dashboard_summary: Optimized dashboard data in single query
-- Reduces round-trips by returning all employee dashboard data at once
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_dashboard_summary(
    p_include_recent_shifts BOOLEAN DEFAULT true,
    p_recent_shifts_limit INT DEFAULT 10
)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID;
    v_active_shift JSONB;
    v_today_stats JSONB;
    v_month_stats JSONB;
    v_recent_shifts JSONB;
    v_today_start TIMESTAMPTZ;
    v_month_start TIMESTAMPTZ;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('error', 'Not authenticated');
    END IF;

    v_today_start := date_trunc('day', NOW());
    v_month_start := date_trunc('month', NOW());

    -- Get active shift
    SELECT jsonb_build_object(
        'id', id,
        'clocked_in_at', clocked_in_at,
        'clock_in_location', clock_in_location
    ) INTO v_active_shift
    FROM shifts
    WHERE employee_id = v_user_id AND status = 'active'
    LIMIT 1;

    -- Get today's stats
    SELECT jsonb_build_object(
        'completed_shifts', COUNT(*) FILTER (WHERE status = 'completed'),
        'total_seconds', COALESCE(
            EXTRACT(EPOCH FROM SUM(
                CASE WHEN status = 'completed'
                THEN clocked_out_at - clocked_in_at
                ELSE INTERVAL '0' END
            ))::INT, 0),
        'active_shift_seconds', COALESCE(
            EXTRACT(EPOCH FROM SUM(
                CASE WHEN status = 'active'
                THEN NOW() - clocked_in_at
                ELSE INTERVAL '0' END
            ))::INT, 0)
    ) INTO v_today_stats
    FROM shifts
    WHERE employee_id = v_user_id AND clocked_in_at >= v_today_start;

    -- Get month stats
    SELECT jsonb_build_object(
        'total_shifts', COUNT(*) FILTER (WHERE status = 'completed'),
        'total_seconds', COALESCE(
            EXTRACT(EPOCH FROM SUM(
                CASE WHEN status = 'completed'
                THEN clocked_out_at - clocked_in_at
                ELSE INTERVAL '0' END
            ))::INT, 0),
        'avg_duration_seconds', CASE
            WHEN COUNT(*) FILTER (WHERE status = 'completed') > 0 THEN
                COALESCE(
                    EXTRACT(EPOCH FROM SUM(
                        CASE WHEN status = 'completed'
                        THEN clocked_out_at - clocked_in_at
                        ELSE INTERVAL '0' END
                    ))::INT, 0) / COUNT(*) FILTER (WHERE status = 'completed')
            ELSE 0
        END
    ) INTO v_month_stats
    FROM shifts
    WHERE employee_id = v_user_id AND clocked_in_at >= v_month_start;

    -- Get recent shifts if requested
    IF p_include_recent_shifts THEN
        SELECT COALESCE(jsonb_agg(shift_row), '[]'::jsonb) INTO v_recent_shifts
        FROM (
            SELECT jsonb_build_object(
                'id', id,
                'status', status,
                'clocked_in_at', clocked_in_at,
                'clocked_out_at', clocked_out_at,
                'duration_seconds', EXTRACT(EPOCH FROM
                    COALESCE(clocked_out_at, NOW()) - clocked_in_at)::INT
            ) as shift_row
            FROM shifts
            WHERE employee_id = v_user_id
            AND clocked_in_at >= NOW() - INTERVAL '7 days'
            ORDER BY clocked_in_at DESC
            LIMIT p_recent_shifts_limit
        ) sub;
    ELSE
        v_recent_shifts := '[]'::jsonb;
    END IF;

    RETURN jsonb_build_object(
        'active_shift', v_active_shift,
        'today_stats', v_today_stats,
        'month_stats', v_month_stats,
        'recent_shifts', v_recent_shifts
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION get_dashboard_summary IS 'Get optimized dashboard data for authenticated employee in single query';

-- -----------------------------------------------------------------------------
-- get_team_employee_hours: Per-employee hours for bar chart visualization
-- Returns hours worked by each supervised employee in a date range
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
BEGIN
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
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION get_team_employee_hours IS 'Get hours worked per supervised employee for chart visualization';

-- -----------------------------------------------------------------------------
-- get_team_active_status: Get current clock-in status for all supervised employees
-- Used for team dashboard to show who is currently working
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
BEGIN
    v_today_start := date_trunc('day', NOW());
    v_month_start := date_trunc('month', NOW());

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
    -- Today's completed shift stats
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
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION get_team_active_status IS 'Get active status and stats for all supervised employees';
