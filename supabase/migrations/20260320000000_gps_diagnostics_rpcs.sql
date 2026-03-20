-- ============================================================
-- GPS Diagnostics Dashboard RPCs
-- Admin-only functions for the GPS diagnostics dashboard
-- ============================================================

-- Helper: classify diagnostic_logs.message into event types
-- Used by all diagnostics RPCs for consistent classification
CREATE OR REPLACE FUNCTION classify_gps_event(p_message TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_message LIKE 'GPS gap detected%' THEN 'gap'
    WHEN p_message LIKE 'Foreground service died%'
      OR p_message LIKE 'Service dead%'
      OR p_message LIKE 'Foreground service start failed%'
      OR p_message LIKE 'Tracking service error%' THEN 'service_died'
    WHEN p_message LIKE 'GPS lost — SLC activated%' THEN 'slc'
    WHEN p_message LIKE 'GPS stream recovered%'
      OR p_message LIKE 'GPS restored%' THEN 'recovery'
    ELSE 'lifecycle'
  END;
$$;

-- ============================================================
-- 1. get_gps_diagnostics_summary
-- Returns KPI aggregates for primary + comparison periods
-- ============================================================
CREATE OR REPLACE FUNCTION get_gps_diagnostics_summary(
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ,
    p_compare_start_date TIMESTAMPTZ,
    p_compare_end_date TIMESTAMPTZ,
    p_employee_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_primary JSONB;
  v_comparison JSONB;
BEGIN
  -- Aggregate diagnostic_logs counts for a date range
  WITH log_counts AS (
    SELECT
      COUNT(*) FILTER (WHERE classify_gps_event(message) = 'gap') AS gaps_count,
      COUNT(*) FILTER (WHERE classify_gps_event(message) = 'service_died') AS service_died_count,
      COUNT(*) FILTER (WHERE classify_gps_event(message) = 'slc') AS slc_count,
      COUNT(*) FILTER (WHERE classify_gps_event(message) = 'recovery') AS recovery_count
    FROM diagnostic_logs
    WHERE event_category = 'gps'
      AND created_at >= p_start_date
      AND created_at < p_end_date
      AND (p_employee_id IS NULL OR employee_id = p_employee_id)
  ),
  -- Calculate GPS gaps from gps_points via shifts in date range
  shift_gaps AS (
    SELECT
      gp.captured_at,
      LAG(gp.captured_at) OVER (PARTITION BY gp.shift_id ORDER BY gp.captured_at) AS prev_at,
      EXTRACT(EPOCH FROM (gp.captured_at - LAG(gp.captured_at) OVER (PARTITION BY gp.shift_id ORDER BY gp.captured_at))) / 60.0 AS gap_min,
      ep.full_name,
      gp.shift_id
    FROM gps_points gp
    JOIN shifts s ON s.id = gp.shift_id
    JOIN employee_profiles ep ON ep.id = s.employee_id
    WHERE s.clocked_in_at >= p_start_date
      AND s.clocked_in_at < p_end_date
      AND s.status = 'completed'
      AND (p_employee_id IS NULL OR s.employee_id = p_employee_id)
  ),
  gap_stats AS (
    SELECT
      COALESCE(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY gap_min), 0) AS median_gap,
      COALESCE(MAX(gap_min), 0) AS max_gap
    FROM shift_gaps
    WHERE gap_min > 5
  ),
  max_gap_info AS (
    SELECT full_name AS max_gap_employee, captured_at AS max_gap_time
    FROM shift_gaps
    WHERE gap_min > 5
    ORDER BY gap_min DESC
    LIMIT 1
  )
  SELECT jsonb_build_object(
    'gaps_count', lc.gaps_count,
    'service_died_count', lc.service_died_count,
    'slc_count', lc.slc_count,
    'recovery_count', lc.recovery_count,
    'recovery_rate', CASE
      WHEN (lc.gaps_count + lc.service_died_count) > 0
      THEN ROUND(lc.recovery_count::NUMERIC / (lc.gaps_count + lc.service_died_count) * 100, 1)
      ELSE 100
    END,
    'median_gap_minutes', ROUND(gs.median_gap::NUMERIC, 1),
    'max_gap_minutes', ROUND(gs.max_gap::NUMERIC, 1),
    'max_gap_employee_name', mgi.max_gap_employee,
    'max_gap_time', mgi.max_gap_time
  ) INTO v_primary
  FROM log_counts lc
  CROSS JOIN gap_stats gs
  LEFT JOIN max_gap_info mgi ON true;

  -- Same for comparison period
  WITH log_counts AS (
    SELECT
      COUNT(*) FILTER (WHERE classify_gps_event(message) = 'gap') AS gaps_count,
      COUNT(*) FILTER (WHERE classify_gps_event(message) = 'service_died') AS service_died_count,
      COUNT(*) FILTER (WHERE classify_gps_event(message) = 'slc') AS slc_count,
      COUNT(*) FILTER (WHERE classify_gps_event(message) = 'recovery') AS recovery_count
    FROM diagnostic_logs
    WHERE event_category = 'gps'
      AND created_at >= p_compare_start_date
      AND created_at < p_compare_end_date
      AND (p_employee_id IS NULL OR employee_id = p_employee_id)
  ),
  shift_gaps AS (
    SELECT
      EXTRACT(EPOCH FROM (gp.captured_at - LAG(gp.captured_at) OVER (PARTITION BY gp.shift_id ORDER BY gp.captured_at))) / 60.0 AS gap_min
    FROM gps_points gp
    JOIN shifts s ON s.id = gp.shift_id
    WHERE s.clocked_in_at >= p_compare_start_date
      AND s.clocked_in_at < p_compare_end_date
      AND s.status = 'completed'
      AND (p_employee_id IS NULL OR s.employee_id = p_employee_id)
  ),
  gap_stats AS (
    SELECT
      COALESCE(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY gap_min), 0) AS median_gap,
      COALESCE(MAX(gap_min), 0) AS max_gap
    FROM shift_gaps
    WHERE gap_min > 5
  )
  SELECT jsonb_build_object(
    'gaps_count', lc.gaps_count,
    'service_died_count', lc.service_died_count,
    'slc_count', lc.slc_count,
    'recovery_count', lc.recovery_count,
    'recovery_rate', CASE
      WHEN (lc.gaps_count + lc.service_died_count) > 0
      THEN ROUND(lc.recovery_count::NUMERIC / (lc.gaps_count + lc.service_died_count) * 100, 1)
      ELSE 100
    END,
    'median_gap_minutes', ROUND(gs.median_gap::NUMERIC, 1),
    'max_gap_minutes', ROUND(gs.max_gap::NUMERIC, 1)
  ) INTO v_comparison
  FROM log_counts lc
  CROSS JOIN gap_stats gs;

  RETURN jsonb_build_object('primary', v_primary, 'comparison', v_comparison);
END;
$$;

GRANT EXECUTE ON FUNCTION get_gps_diagnostics_summary TO authenticated;

-- ============================================================
-- 2. get_gps_diagnostics_trend
-- Returns daily counts for the trend chart
-- ============================================================
CREATE OR REPLACE FUNCTION get_gps_diagnostics_trend(
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ,
    p_employee_id UUID DEFAULT NULL
)
RETURNS TABLE(
    day DATE,
    gaps_count BIGINT,
    error_count BIGINT,
    recovery_count BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    (dl.created_at AT TIME ZONE 'America/Montreal')::DATE AS day,
    COUNT(*) FILTER (WHERE classify_gps_event(dl.message) = 'gap') AS gaps_count,
    COUNT(*) FILTER (WHERE classify_gps_event(dl.message) = 'service_died') AS error_count,
    COUNT(*) FILTER (WHERE classify_gps_event(dl.message) = 'recovery') AS recovery_count
  FROM diagnostic_logs dl
  WHERE dl.event_category = 'gps'
    AND dl.created_at >= p_start_date
    AND dl.created_at < p_end_date
    AND (p_employee_id IS NULL OR dl.employee_id = p_employee_id)
  GROUP BY 1
  ORDER BY 1;
END;
$$;

GRANT EXECUTE ON FUNCTION get_gps_diagnostics_trend TO authenticated;

-- ============================================================
-- 3. get_gps_diagnostics_ranking
-- Returns employees ranked by GPS issues
-- ============================================================
CREATE OR REPLACE FUNCTION get_gps_diagnostics_ranking(
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ
)
RETURNS TABLE(
    employee_id UUID,
    full_name TEXT,
    device_platform TEXT,
    device_model TEXT,
    total_gaps BIGINT,
    total_slc BIGINT,
    total_service_died BIGINT,
    total_recoveries BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    dl.employee_id,
    ep.full_name,
    ep.device_platform,
    ep.device_model,
    COUNT(*) FILTER (WHERE classify_gps_event(dl.message) = 'gap') AS total_gaps,
    COUNT(*) FILTER (WHERE classify_gps_event(dl.message) = 'slc') AS total_slc,
    COUNT(*) FILTER (WHERE classify_gps_event(dl.message) = 'service_died') AS total_service_died,
    COUNT(*) FILTER (WHERE classify_gps_event(dl.message) = 'recovery') AS total_recoveries
  FROM diagnostic_logs dl
  JOIN employee_profiles ep ON ep.id = dl.employee_id
  WHERE dl.event_category = 'gps'
    AND dl.created_at >= p_start_date
    AND dl.created_at < p_end_date
  GROUP BY dl.employee_id, ep.full_name, ep.device_platform, ep.device_model
  HAVING SUM(1) FILTER (WHERE classify_gps_event(dl.message) IN ('gap', 'service_died', 'slc')) > 0
  ORDER BY total_gaps DESC, total_service_died DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION get_gps_diagnostics_ranking TO authenticated;

-- ============================================================
-- 4. get_gps_diagnostics_feed
-- Returns paginated incident feed with classification
-- ============================================================
CREATE OR REPLACE FUNCTION get_gps_diagnostics_feed(
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ,
    p_employee_id UUID DEFAULT NULL,
    p_severities TEXT[] DEFAULT ARRAY['warn', 'error', 'critical'],
    p_cursor_time TIMESTAMPTZ DEFAULT NULL,
    p_cursor_id UUID DEFAULT NULL,
    p_limit INT DEFAULT 50
)
RETURNS TABLE(
    id UUID,
    created_at TIMESTAMPTZ,
    employee_id UUID,
    full_name TEXT,
    device_platform TEXT,
    device_model TEXT,
    message TEXT,
    event_type TEXT,
    severity TEXT,
    app_version TEXT,
    metadata JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    dl.id,
    dl.created_at,
    dl.employee_id,
    ep.full_name,
    ep.device_platform,
    ep.device_model,
    dl.message,
    classify_gps_event(dl.message) AS event_type,
    dl.severity,
    dl.app_version,
    dl.metadata
  FROM diagnostic_logs dl
  JOIN employee_profiles ep ON ep.id = dl.employee_id
  WHERE dl.event_category = 'gps'
    AND dl.created_at >= p_start_date
    AND dl.created_at < p_end_date
    AND dl.severity = ANY(p_severities)
    AND (p_employee_id IS NULL OR dl.employee_id = p_employee_id)
    AND (
      p_cursor_time IS NULL
      OR (dl.created_at, dl.id) < (p_cursor_time, p_cursor_id)
    )
  ORDER BY dl.created_at DESC, dl.id DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION get_gps_diagnostics_feed TO authenticated;

-- ============================================================
-- 5. get_employee_gps_gaps
-- Calculates real GPS point gaps using LAG() window function
-- ============================================================
CREATE OR REPLACE FUNCTION get_employee_gps_gaps(
    p_employee_id UUID,
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ,
    p_min_gap_minutes NUMERIC DEFAULT 5
)
RETURNS TABLE(
    shift_id UUID,
    gap_start TIMESTAMPTZ,
    gap_end TIMESTAMPTZ,
    gap_minutes NUMERIC,
    shift_clocked_in_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH point_gaps AS (
    SELECT
      gp.shift_id,
      s.clocked_in_at,
      gp.captured_at,
      LAG(gp.captured_at) OVER (PARTITION BY gp.shift_id ORDER BY gp.captured_at) AS prev_at
    FROM gps_points gp
    JOIN shifts s ON s.id = gp.shift_id
    WHERE s.employee_id = p_employee_id
      AND s.clocked_in_at >= p_start_date
      AND s.clocked_in_at < p_end_date
      AND s.status = 'completed'
  )
  SELECT
    pg.shift_id,
    pg.prev_at AS gap_start,
    pg.captured_at AS gap_end,
    ROUND(EXTRACT(EPOCH FROM (pg.captured_at - pg.prev_at)) / 60.0, 1) AS gap_minutes,
    pg.clocked_in_at AS shift_clocked_in_at
  FROM point_gaps pg
  WHERE pg.prev_at IS NOT NULL
    AND EXTRACT(EPOCH FROM (pg.captured_at - pg.prev_at)) / 60.0 > p_min_gap_minutes
  ORDER BY gap_minutes DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION get_employee_gps_gaps TO authenticated;

-- ============================================================
-- 6. get_employee_gps_events
-- Returns all diagnostic events for one employee (all categories)
-- ============================================================
CREATE OR REPLACE FUNCTION get_employee_gps_events(
    p_employee_id UUID,
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ
)
RETURNS TABLE(
    id UUID,
    created_at TIMESTAMPTZ,
    event_category TEXT,
    severity TEXT,
    message TEXT,
    metadata JSONB,
    app_version TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    dl.id,
    dl.created_at,
    dl.event_category,
    dl.severity,
    dl.message,
    dl.metadata,
    dl.app_version
  FROM diagnostic_logs dl
  WHERE dl.employee_id = p_employee_id
    AND dl.created_at >= p_start_date
    AND dl.created_at < p_end_date
  ORDER BY dl.created_at DESC
  LIMIT 200;
END;
$$;

GRANT EXECUTE ON FUNCTION get_employee_gps_events TO authenticated;
