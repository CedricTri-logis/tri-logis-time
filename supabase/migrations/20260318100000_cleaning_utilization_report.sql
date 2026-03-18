-- =============================================================================
-- Migration: 20260318100000_cleaning_utilization_report
-- Description: RPC for cleaning/work session utilization report per employee
-- Returns: utilization %, GPS accuracy %, time breakdown by location category
-- =============================================================================

CREATE OR REPLACE FUNCTION get_cleaning_utilization_report(
  p_date_from DATE,
  p_date_to DATE,
  p_employee_id UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER STABLE
SET search_path TO public, extensions
AS $$
DECLARE
  v_result JSONB;
  v_office_location_id UUID;
  v_office_geo geography;
  v_office_radius NUMERIC;
BEGIN
  -- Resolve office location (151-159_Principale, is_also_office = true)
  SELECT id, location, radius_meters
  INTO v_office_location_id, v_office_geo, v_office_radius
  FROM locations
  WHERE is_also_office = true AND is_active = true
  LIMIT 1;

  WITH employee_shifts AS (
    -- Completed non-lunch shifts in date range
    SELECT
      s.employee_id,
      s.id AS shift_id,
      s.clocked_in_at,
      s.clocked_out_at,
      EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at)) / 60.0 AS shift_minutes
    FROM shifts s
    WHERE s.status = 'completed'
      AND s.is_lunch IS NOT TRUE
      AND s.clocked_in_at::date BETWEEN p_date_from AND p_date_to
      AND (p_employee_id IS NULL OR s.employee_id = p_employee_id)
  ),
  shift_agg AS (
    SELECT
      employee_id,
      SUM(shift_minutes) AS total_shift_minutes,
      COUNT(*) AS total_shifts
    FROM employee_shifts
    GROUP BY employee_id
  ),
  employee_trips AS (
    -- Sum trip durations for those shifts
    SELECT
      es.employee_id,
      COALESCE(SUM(t.duration_minutes), 0) AS trip_minutes
    FROM employee_shifts es
    LEFT JOIN trips t ON t.shift_id = es.shift_id
    GROUP BY es.employee_id
  ),
  employee_sessions AS (
    -- Session durations with category breakdown
    SELECT
      ws.employee_id,
      SUM(ws.duration_minutes) AS total_session_minutes,
      COUNT(*) AS total_sessions,
      -- Short-term: studio-based
      COALESCE(SUM(ws.duration_minutes)
        FILTER (WHERE ws.studio_id IS NOT NULL AND st.studio_type = 'unit'), 0)
        AS short_term_unit_minutes,
      COALESCE(SUM(ws.duration_minutes)
        FILTER (WHERE ws.studio_id IS NOT NULL AND st.studio_type IN ('common_area', 'conciergerie')), 0)
        AS short_term_common_minutes,
      -- Long-term: property_building-based
      COALESCE(SUM(ws.duration_minutes)
        FILTER (WHERE ws.building_id IS NOT NULL AND ws.activity_type = 'cleaning'), 0)
        AS cleaning_long_term_minutes,
      COALESCE(SUM(ws.duration_minutes)
        FILTER (WHERE ws.building_id IS NOT NULL AND ws.activity_type = 'maintenance'), 0)
        AS maintenance_long_term_minutes
    FROM work_sessions ws
    LEFT JOIN studios st ON st.id = ws.studio_id
    WHERE ws.status IN ('completed', 'auto_closed', 'manually_closed')
      AND ws.started_at::date BETWEEN p_date_from AND p_date_to
      AND (p_employee_id IS NULL OR ws.employee_id = p_employee_id)
    GROUP BY ws.employee_id
  ),
  employee_accuracy AS (
    -- GPS accuracy: % of points within session building's geofence
    SELECT
      ws.employee_id,
      COUNT(gp.id) AS total_gps_points,
      COUNT(gp.id) FILTER (WHERE
        loc.id IS NOT NULL AND
        ST_DWithin(
          loc.location,
          ST_SetSRID(ST_MakePoint(gp.longitude, gp.latitude), 4326)::geography,
          loc.radius_meters
        )
      ) AS points_in_geofence
    FROM work_sessions ws
    JOIN employee_shifts es ON es.shift_id = ws.shift_id
    JOIN gps_points gp ON gp.shift_id = ws.shift_id
      AND gp.captured_at BETWEEN ws.started_at AND ws.completed_at
      AND gp.accuracy <= 50
    LEFT JOIN studios st ON st.id = ws.studio_id
    LEFT JOIN buildings b ON b.id = st.building_id
    LEFT JOIN property_buildings pb ON pb.id = ws.building_id
    LEFT JOIN locations loc ON loc.id = COALESCE(b.location_id, pb.location_id)
    WHERE ws.status IN ('completed', 'auto_closed', 'manually_closed')
      AND ws.started_at::date BETWEEN p_date_from AND p_date_to
      AND (p_employee_id IS NULL OR ws.employee_id = p_employee_id)
    GROUP BY ws.employee_id
  ),
  office_gps AS (
    -- GPS points at office NOT during any work session
    SELECT
      es.employee_id,
      gp.captured_at,
      LAG(gp.captured_at) OVER (
        PARTITION BY es.employee_id, es.shift_id
        ORDER BY gp.captured_at
      ) AS prev_captured_at
    FROM employee_shifts es
    JOIN gps_points gp ON gp.shift_id = es.shift_id
      AND gp.accuracy <= 50
    WHERE v_office_geo IS NOT NULL
      AND ST_DWithin(
        v_office_geo,
        ST_SetSRID(ST_MakePoint(gp.longitude, gp.latitude), 4326)::geography,
        v_office_radius
      )
      -- Exclude GPS during work sessions
      AND NOT EXISTS (
        SELECT 1 FROM work_sessions ws2
        WHERE ws2.shift_id = es.shift_id
          AND ws2.employee_id = es.employee_id
          AND ws2.status IN ('completed', 'auto_closed', 'manually_closed', 'in_progress')
          AND gp.captured_at BETWEEN ws2.started_at AND COALESCE(ws2.completed_at, now())
      )
  ),
  employee_office AS (
    SELECT
      employee_id,
      -- Sum intervals between consecutive GPS points, capped at 5 min each
      COALESCE(SUM(
        LEAST(
          EXTRACT(EPOCH FROM (captured_at - prev_captured_at)) / 60.0,
          5.0
        )
      ), 0) AS office_minutes
    FROM office_gps
    WHERE prev_captured_at IS NOT NULL
    GROUP BY employee_id
  )
  SELECT jsonb_build_object(
    'employees', COALESCE(jsonb_agg(
      jsonb_build_object(
        'employee_id', ep.id,
        'employee_name', ep.full_name,
        'total_shift_minutes', round(COALESCE(sa.total_shift_minutes, 0), 1),
        'total_trip_minutes', round(COALESCE(et.trip_minutes, 0), 1),
        'total_session_minutes', round(COALESCE(esn.total_session_minutes, 0), 1),
        'available_minutes', round(
          GREATEST(COALESCE(sa.total_shift_minutes, 0) - COALESCE(et.trip_minutes, 0), 0), 1),
        'utilization_pct', CASE
          WHEN COALESCE(sa.total_shift_minutes, 0) - COALESCE(et.trip_minutes, 0) > 0
          THEN round(
            COALESCE(esn.total_session_minutes, 0)
            / (sa.total_shift_minutes - COALESCE(et.trip_minutes, 0))
            * 100, 1)
          ELSE 0
        END,
        'accuracy_pct', CASE
          WHEN COALESCE(ea.total_gps_points, 0) > 0
          THEN round(ea.points_in_geofence::numeric / ea.total_gps_points * 100, 1)
          ELSE NULL
        END,
        'short_term_unit_minutes', round(COALESCE(esn.short_term_unit_minutes, 0), 1),
        'short_term_common_minutes', round(COALESCE(esn.short_term_common_minutes, 0), 1),
        'cleaning_long_term_minutes', round(COALESCE(esn.cleaning_long_term_minutes, 0), 1),
        'maintenance_long_term_minutes', round(COALESCE(esn.maintenance_long_term_minutes, 0), 1),
        'office_minutes', round(COALESCE(eo.office_minutes, 0), 1),
        'total_sessions', COALESCE(esn.total_sessions, 0),
        'total_shifts', COALESCE(sa.total_shifts, 0)
      )
    ORDER BY ep.full_name), '[]'::jsonb)
  ) INTO v_result
  FROM shift_agg sa
  JOIN employee_profiles ep ON ep.id = sa.employee_id
  LEFT JOIN employee_trips et ON et.employee_id = sa.employee_id
  LEFT JOIN employee_sessions esn ON esn.employee_id = sa.employee_id
  LEFT JOIN employee_accuracy ea ON ea.employee_id = sa.employee_id
  LEFT JOIN employee_office eo ON eo.employee_id = sa.employee_id;

  RETURN COALESCE(v_result, jsonb_build_object('employees', '[]'::jsonb));
END;
$$;

-- Comments
COMMENT ON FUNCTION get_cleaning_utilization_report IS 'ROLE: Dashboard report — per-employee work session utilization %, GPS accuracy %, and time breakdown by location type.
PARAMS: p_date_from/p_date_to filter shifts by clocked_in_at date; p_employee_id optional single-employee filter.
REGLES: Excludes lunch shifts (is_lunch=true), in-progress shifts/sessions. GPS accuracy filters points <=50m. Office time = GPS at is_also_office location minus work session overlaps.
RELATIONS: shifts, work_sessions, trips, gps_points, studios→buildings→locations, property_buildings→locations';
