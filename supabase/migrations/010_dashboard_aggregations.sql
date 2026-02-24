-- Migration: 010_dashboard_aggregations.sql
-- Purpose: Add RPC functions for the admin dashboard
-- Date: 2026-01-15

-- =============================================================================
-- FUNCTION: get_org_dashboard_summary()
-- Returns aggregated organization-wide statistics. Admin/super_admin only.
-- =============================================================================
CREATE OR REPLACE FUNCTION get_org_dashboard_summary()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_result JSONB;
  v_caller_role TEXT;
BEGIN
  -- Check caller is admin or super_admin
  SELECT role INTO v_caller_role
  FROM employee_profiles
  WHERE id = auth.uid();

  IF v_caller_role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'Access denied: admin or super_admin role required';
  END IF;

  SELECT jsonb_build_object(
    'employee_counts', jsonb_build_object(
      'total', (SELECT COUNT(*) FROM employee_profiles),
      'by_role', (
        SELECT jsonb_object_agg(role, cnt)
        FROM (
          SELECT role, COUNT(*) as cnt
          FROM employee_profiles
          GROUP BY role
        ) r
      ),
      'active_status', (
        SELECT jsonb_object_agg(status, cnt)
        FROM (
          SELECT status, COUNT(*) as cnt
          FROM employee_profiles
          GROUP BY status
        ) s
      )
    ),
    'shift_stats', jsonb_build_object(
      'active_shifts', (SELECT COUNT(*) FROM shifts WHERE status = 'active'),
      'completed_today', (
        SELECT COUNT(*) FROM shifts
        WHERE status = 'completed'
        AND clocked_in_at >= CURRENT_DATE
      ),
      'total_hours_today', COALESCE((
        SELECT SUM(
          EXTRACT(EPOCH FROM (COALESCE(clocked_out_at, NOW()) - clocked_in_at)) / 3600
        )
        FROM shifts
        WHERE clocked_in_at >= CURRENT_DATE
      ), 0),
      'total_hours_this_week', COALESCE((
        SELECT SUM(
          EXTRACT(EPOCH FROM (COALESCE(clocked_out_at, NOW()) - clocked_in_at)) / 3600
        )
        FROM shifts
        WHERE clocked_in_at >= date_trunc('week', CURRENT_DATE)
      ), 0),
      'total_hours_this_month', COALESCE((
        SELECT SUM(
          EXTRACT(EPOCH FROM (COALESCE(clocked_out_at, NOW()) - clocked_in_at)) / 3600
        )
        FROM shifts
        WHERE clocked_in_at >= date_trunc('month', CURRENT_DATE)
      ), 0)
    ),
    'generated_at', NOW()
  ) INTO v_result;

  RETURN v_result;
END;
$$;

-- =============================================================================
-- FUNCTION: get_manager_team_summaries()
-- Returns all managers with their team aggregates for comparison. Admin/super_admin only.
-- =============================================================================
CREATE OR REPLACE FUNCTION get_manager_team_summaries(
  p_start_date TIMESTAMPTZ DEFAULT date_trunc('month', CURRENT_DATE),
  p_end_date TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE (
  manager_id UUID,
  manager_name TEXT,
  manager_email TEXT,
  team_size BIGINT,
  active_employees BIGINT,
  total_hours NUMERIC,
  total_shifts BIGINT,
  avg_hours_per_employee NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_caller_role TEXT;
BEGIN
  -- Check caller is admin or super_admin
  SELECT role INTO v_caller_role
  FROM employee_profiles
  WHERE id = auth.uid();

  IF v_caller_role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'Access denied: admin or super_admin role required';
  END IF;

  RETURN QUERY
  SELECT
    m.id AS manager_id,
    m.full_name AS manager_name,
    m.email AS manager_email,
    COUNT(DISTINCT es.employee_id) AS team_size,
    COUNT(DISTINCT CASE WHEN s.status = 'active' THEN s.employee_id END) AS active_employees,
    COALESCE(SUM(
      EXTRACT(EPOCH FROM (
        COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at
      )) / 3600
    ), 0)::NUMERIC(10,2) AS total_hours,
    COUNT(s.id) AS total_shifts,
    CASE
      WHEN COUNT(DISTINCT es.employee_id) > 0 THEN
        (COALESCE(SUM(
          EXTRACT(EPOCH FROM (
            COALESCE(s.clocked_out_at, NOW()) - s.clocked_in_at
          )) / 3600
        ), 0) / COUNT(DISTINCT es.employee_id))::NUMERIC(10,2)
      ELSE 0
    END AS avg_hours_per_employee
  FROM employee_profiles m
  INNER JOIN employee_supervisors es ON es.manager_id = m.id
    AND es.effective_to IS NULL  -- Active supervision only
  LEFT JOIN shifts s ON s.employee_id = es.employee_id
    AND s.clocked_in_at >= p_start_date
    AND s.clocked_in_at < p_end_date
  WHERE m.role IN ('manager', 'admin', 'super_admin')
  GROUP BY m.id, m.full_name, m.email
  ORDER BY total_hours DESC;
END;
$$;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION get_org_dashboard_summary() TO authenticated;
GRANT EXECUTE ON FUNCTION get_manager_team_summaries(TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
