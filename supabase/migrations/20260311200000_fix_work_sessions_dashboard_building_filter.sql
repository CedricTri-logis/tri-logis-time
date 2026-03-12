-- Fix: building filter in get_work_sessions_dashboard count + pagination queries
-- Must match summary query which includes studios-in-building sub-select.

CREATE OR REPLACE FUNCTION get_work_sessions_dashboard(
  p_date_from date,
  p_date_to date,
  p_activity_type text DEFAULT NULL,
  p_employee_id uuid DEFAULT NULL,
  p_building_id uuid DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_summary jsonb;
  v_sessions jsonb;
  v_total int;
  v_building_filter_clause text;
BEGIN
  -- Summary statistics
  SELECT jsonb_build_object(
    'total_sessions', count(*),
    'completed_sessions', count(*) FILTER (WHERE ws.status IN ('completed', 'auto_closed', 'manually_closed')),
    'active_sessions', count(*) FILTER (WHERE ws.status = 'in_progress'),
    'avg_duration_minutes', round(avg(ws.duration_minutes) FILTER (WHERE ws.duration_minutes IS NOT NULL), 1),
    'total_hours', round(sum(ws.duration_minutes) FILTER (WHERE ws.duration_minutes IS NOT NULL) / 60.0, 1),
    'flagged_count', count(*) FILTER (WHERE ws.is_flagged = true),
    'by_type', jsonb_build_object(
      'cleaning', count(*) FILTER (WHERE ws.activity_type = 'cleaning'),
      'maintenance', count(*) FILTER (WHERE ws.activity_type = 'maintenance'),
      'admin', count(*) FILTER (WHERE ws.activity_type = 'admin')
    )
  ) INTO v_summary
  FROM work_sessions ws
  WHERE ws.started_at::date BETWEEN p_date_from AND p_date_to
    AND (p_activity_type IS NULL OR ws.activity_type = p_activity_type)
    AND (p_employee_id IS NULL OR ws.employee_id = p_employee_id)
    AND (p_building_id IS NULL OR ws.building_id = p_building_id
         OR ws.studio_id IN (SELECT id FROM studios WHERE building_id IN (
           SELECT id FROM buildings WHERE id::text = p_building_id::text
         )))
    AND (p_status IS NULL OR ws.status = p_status);

  -- Count for pagination (same filter as summary)
  SELECT count(*) INTO v_total
  FROM work_sessions ws
  WHERE ws.started_at::date BETWEEN p_date_from AND p_date_to
    AND (p_activity_type IS NULL OR ws.activity_type = p_activity_type)
    AND (p_employee_id IS NULL OR ws.employee_id = p_employee_id)
    AND (p_building_id IS NULL OR ws.building_id = p_building_id
         OR ws.studio_id IN (SELECT id FROM studios WHERE building_id IN (
           SELECT id FROM buildings WHERE id::text = p_building_id::text
         )))
    AND (p_status IS NULL OR ws.status = p_status);

  -- Paginated sessions (same filter as summary)
  SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::jsonb) INTO v_sessions
  FROM (
    SELECT
      ws.id, ws.employee_id, ws.activity_type, ws.location_type,
      ws.status, ws.started_at, ws.completed_at,
      round(ws.duration_minutes, 2) AS duration_minutes,
      ws.is_flagged, ws.flag_reason, ws.notes,
      ep.full_name AS employee_name,
      s.studio_number, s.studio_type::text,
      COALESCE(pb.name, b.name) AS building_name,
      a.unit_number
    FROM work_sessions ws
    JOIN employee_profiles ep ON ep.id = ws.employee_id
    LEFT JOIN studios s ON s.id = ws.studio_id
    LEFT JOIN buildings b ON b.id = s.building_id
    LEFT JOIN property_buildings pb ON pb.id = ws.building_id
    LEFT JOIN apartments a ON a.id = ws.apartment_id
    WHERE ws.started_at::date BETWEEN p_date_from AND p_date_to
      AND (p_activity_type IS NULL OR ws.activity_type = p_activity_type)
      AND (p_employee_id IS NULL OR ws.employee_id = p_employee_id)
      AND (p_building_id IS NULL OR ws.building_id = p_building_id
           OR ws.studio_id IN (SELECT id FROM studios WHERE building_id IN (
             SELECT id FROM buildings WHERE id::text = p_building_id::text
           )))
      AND (p_status IS NULL OR ws.status = p_status)
    ORDER BY ws.started_at DESC
    LIMIT p_limit OFFSET p_offset
  ) t;

  RETURN jsonb_build_object(
    'summary', v_summary,
    'sessions', v_sessions,
    'total_count', v_total
  );
END;
$$;
