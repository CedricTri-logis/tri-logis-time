-- Returns all GPS gaps >= threshold, flat rows for frontend grouping
CREATE OR REPLACE FUNCTION get_gps_gaps_by_day(
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ,
    p_employee_id UUID DEFAULT NULL,
    p_min_gap_minutes NUMERIC DEFAULT 5
)
RETURNS TABLE(
    day DATE,
    employee_id UUID,
    full_name TEXT,
    device_platform TEXT,
    device_model TEXT,
    shift_id UUID,
    gap_start TIMESTAMPTZ,
    gap_end TIMESTAMPTZ,
    gap_minutes NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH point_gaps AS (
    SELECT
      s.employee_id,
      gp.shift_id,
      (s.clocked_in_at AT TIME ZONE 'America/Montreal')::DATE AS shift_day,
      gp.captured_at,
      LAG(gp.captured_at) OVER (PARTITION BY gp.shift_id ORDER BY gp.captured_at) AS prev_at
    FROM gps_points gp
    JOIN shifts s ON s.id = gp.shift_id
    WHERE s.clocked_in_at >= p_start_date
      AND s.clocked_in_at < p_end_date
      AND s.status = 'completed'
      AND (p_employee_id IS NULL OR s.employee_id = p_employee_id)
  )
  SELECT
    pg.shift_day AS day,
    pg.employee_id,
    ep.full_name,
    ep.device_platform,
    ep.device_model,
    pg.shift_id,
    pg.prev_at AS gap_start,
    pg.captured_at AS gap_end,
    ROUND(EXTRACT(EPOCH FROM (pg.captured_at - pg.prev_at)) / 60.0, 1) AS gap_minutes
  FROM point_gaps pg
  JOIN employee_profiles ep ON ep.id = pg.employee_id
  WHERE pg.prev_at IS NOT NULL
    AND EXTRACT(EPOCH FROM (pg.captured_at - pg.prev_at)) / 60.0 >= p_min_gap_minutes
  ORDER BY pg.shift_day DESC, gap_minutes DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION get_gps_gaps_by_day TO authenticated;
