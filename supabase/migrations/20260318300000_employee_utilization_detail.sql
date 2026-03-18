-- =============================================================================
-- Migration: 20260318300000_employee_utilization_detail
-- Description: Drill-down RPC for a single employee's utilization detail
-- Returns: clusters, trips, sessions grouped by day/shift with location match info
-- =============================================================================

CREATE OR REPLACE FUNCTION get_employee_utilization_detail(
  p_employee_id UUID,
  p_date_from DATE,
  p_date_to DATE
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER STABLE
SET search_path TO public, extensions
AS $$
DECLARE
  v_result JSONB;
  v_employee_name TEXT;
  v_summary JSONB;
  v_days JSONB;
BEGIN
  -- Get employee name
  SELECT full_name INTO v_employee_name
  FROM employee_profiles WHERE id = p_employee_id;

  IF v_employee_name IS NULL THEN
    RETURN jsonb_build_object('error', 'EMPLOYEE_NOT_FOUND');
  END IF;

  -- Summary (reuse main report logic for single employee)
  SELECT r->'employees'->0 INTO v_summary
  FROM get_cleaning_utilization_report(p_date_from, p_date_to, p_employee_id) r;

  -- Days: one entry per shift with clusters and trips
  WITH employee_shifts AS (
    SELECT s.id AS shift_id, s.clocked_in_at, s.clocked_out_at,
      s.clocked_in_at::date AS shift_date,
      EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at)) / 60.0 AS shift_minutes
    FROM shifts s
    WHERE s.employee_id = p_employee_id
      AND s.status = 'completed' AND s.is_lunch IS NOT TRUE
      AND s.clocked_in_at::date BETWEEN p_date_from AND p_date_to
  ),
  -- Per-cluster sessions: all work sessions overlapping each cluster
  cluster_sessions AS (
    SELECT
      sc.id AS cluster_id,
      sc.shift_id,
      sc.matched_location_id,
      jsonb_agg(jsonb_build_object(
        'session_name', CASE
          WHEN ws.activity_type = 'admin' THEN 'Admin'
          WHEN st.id IS NOT NULL THEN ws.activity_type || ' @ ' || COALESCE(b.name, 'Inconnu') || ' - ' || st.studio_number
          WHEN apt.id IS NOT NULL THEN ws.activity_type || ' @ ' || COALESCE(pb.name, 'Inconnu') || ' - ' || COALESCE(apt.apartment_name, apt.unit_number, '')
          ELSE ws.activity_type || ' @ ' || COALESCE(b.name, pb.name, 'Inconnu')
        END,
        'activity_type', ws.activity_type,
        'duration_minutes', round(EXTRACT(EPOCH FROM (
          LEAST(ws.completed_at, sc.ended_at) - GREATEST(ws.started_at, sc.started_at)
        )) / 60.0, 1),
        'match', CASE
          WHEN ws.activity_type = 'admin' THEN NULL
          WHEN COALESCE(b_loc.id, pb_loc.id) IS NULL THEN NULL
          ELSE sc.matched_location_id = COALESCE(b_loc.id, pb_loc.id)
        END,
        'location_category', CASE
          WHEN ws.activity_type = 'admin' AND loc.is_also_office = true THEN 'office'
          WHEN ws.activity_type = 'admin' AND loc.is_employee_home = true THEN 'home'
          WHEN ws.activity_type = 'admin' THEN NULL
          WHEN COALESCE(b_loc.id, pb_loc.id) IS NOT NULL
            AND sc.matched_location_id = COALESCE(b_loc.id, pb_loc.id) THEN 'match'
          ELSE 'mismatch'
        END
      ) ORDER BY ws.started_at) AS sessions,
      SUM(EXTRACT(EPOCH FROM (
        LEAST(ws.completed_at, sc.ended_at) - GREATEST(ws.started_at, sc.started_at)
      )) / 60.0) AS covered_minutes
    FROM stationary_clusters sc
    JOIN employee_shifts es ON es.shift_id = sc.shift_id
    LEFT JOIN locations loc ON loc.id = sc.matched_location_id
    JOIN work_sessions ws ON ws.shift_id = sc.shift_id
      AND ws.employee_id = p_employee_id
      AND ws.status IN ('completed', 'auto_closed', 'manually_closed')
      AND sc.started_at < ws.completed_at AND sc.ended_at > ws.started_at
    LEFT JOIN studios st ON st.id = ws.studio_id
    LEFT JOIN buildings b ON b.id = st.building_id
    LEFT JOIN locations b_loc ON b_loc.id = b.location_id
    LEFT JOIN property_buildings pb ON pb.id = ws.building_id
    LEFT JOIN locations pb_loc ON pb_loc.id = pb.location_id
    LEFT JOIN apartments apt ON apt.id = ws.apartment_id
    GROUP BY sc.id, sc.shift_id, sc.matched_location_id, loc.is_also_office, loc.is_employee_home
  ),
  shift_clusters AS (
    SELECT
      sc.shift_id,
      jsonb_agg(jsonb_build_object(
        'started_at', sc.started_at,
        'ended_at', sc.ended_at,
        'duration_minutes', round(sc.duration_seconds / 60.0, 1),
        'physical_location', COALESCE(loc.name, 'Non identifie'),
        'physical_location_id', sc.matched_location_id,
        'sessions', COALESCE(cs.sessions, '[]'::jsonb),
        'uncovered_minutes', round(GREATEST(sc.duration_seconds / 60.0 - COALESCE(cs.covered_minutes, 0), 0), 1),
        -- Overall match: true if ANY session matches, false if all mismatch, null if no sessions
        'match', CASE
          WHEN cs.sessions IS NULL THEN NULL
          WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(cs.sessions) s WHERE (s->>'match')::boolean = true) THEN true
          WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(cs.sessions) s WHERE (s->>'match')::boolean = false) THEN false
          ELSE NULL
        END,
        'location_category', CASE
          WHEN cs.sessions IS NULL THEN NULL
          WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(cs.sessions) s WHERE s->>'location_category' = 'office') THEN 'office'
          WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(cs.sessions) s WHERE s->>'location_category' = 'home') THEN 'home'
          WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(cs.sessions) s WHERE s->>'location_category' = 'match') THEN 'match'
          WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(cs.sessions) s WHERE s->>'location_category' = 'mismatch') THEN 'mismatch'
          ELSE NULL
        END
      ) ORDER BY sc.started_at) AS clusters
    FROM stationary_clusters sc
    JOIN employee_shifts es ON es.shift_id = sc.shift_id
    LEFT JOIN locations loc ON loc.id = sc.matched_location_id
    LEFT JOIN cluster_sessions cs ON cs.cluster_id = sc.id
    GROUP BY sc.shift_id
  ),
  shift_trips AS (
    SELECT t.shift_id,
      jsonb_agg(jsonb_build_object(
        'started_at', t.started_at,
        'ended_at', t.ended_at,
        'duration_minutes', t.duration_minutes
      ) ORDER BY t.started_at) AS trips
    FROM trips t
    JOIN employee_shifts es ON es.shift_id = t.shift_id
    GROUP BY t.shift_id
  ),
  shift_session_minutes AS (
    SELECT ws.shift_id,
      SUM(GREATEST(EXTRACT(EPOCH FROM (
        LEAST(ws.completed_at, es.clocked_out_at) - GREATEST(ws.started_at, es.clocked_in_at)
      )) / 60.0, 0)) AS session_minutes
    FROM work_sessions ws
    JOIN employee_shifts es ON es.shift_id = ws.shift_id
    WHERE ws.employee_id = p_employee_id
      AND ws.status IN ('completed', 'auto_closed', 'manually_closed')
    GROUP BY ws.shift_id
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'date', es.shift_date,
    'shift_id', es.shift_id,
    'clocked_in_at', es.clocked_in_at,
    'clocked_out_at', es.clocked_out_at,
    'shift_minutes', round(es.shift_minutes, 1),
    'session_minutes', round(COALESCE(ssm.session_minutes, 0), 1),
    'trip_minutes', COALESCE((
      SELECT SUM((t->>'duration_minutes')::numeric) FROM jsonb_array_elements(st2.trips) t
    ), 0),
    'clusters', COALESCE(sc2.clusters, '[]'::jsonb),
    'trips', COALESCE(st2.trips, '[]'::jsonb)
  ) ORDER BY es.shift_date, es.clocked_in_at), '[]'::jsonb)
  INTO v_days
  FROM employee_shifts es
  LEFT JOIN shift_clusters sc2 ON sc2.shift_id = es.shift_id
  LEFT JOIN shift_trips st2 ON st2.shift_id = es.shift_id
  LEFT JOIN shift_session_minutes ssm ON ssm.shift_id = es.shift_id;

  RETURN jsonb_build_object(
    'employee_name', v_employee_name,
    'employee_id', p_employee_id,
    'summary', v_summary,
    'days', v_days
  );
END;
$$;

COMMENT ON FUNCTION get_employee_utilization_detail IS 'ROLE: Drill-down for single employee utilization.
PARAMS: p_employee_id, p_date_from, p_date_to.
REGLES: Returns clusters with location_category (match/mismatch/office/home/null), trips, and session overlap per shift/day.
RELATIONS: shifts, stationary_clusters, work_sessions, trips, locations, studios→buildings, property_buildings';
