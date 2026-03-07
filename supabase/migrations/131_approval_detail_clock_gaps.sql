-- =============================================================================
-- 131: Clock-in/out gap entries in get_day_approval_detail
-- =============================================================================
-- Adds clock_in_gap and clock_out_gap CTEs to show movement between
-- clock events and first/last cluster. Gets needs_review auto_status.
-- =============================================================================

DO $$
DECLARE
  v_funcdef TEXT;
  v_modified TEXT;
  v_new_ctes TEXT;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_funcdef
  FROM pg_proc p
  WHERE p.proname = 'get_day_approval_detail'
  AND p.pronamespace = 'public'::regnamespace;

  IF v_funcdef IS NULL THEN
    RAISE EXCEPTION 'get_day_approval_detail function not found';
  END IF;

  v_modified := v_funcdef;

  -- Define the new CTEs
  v_new_ctes := E'clock_in_gap_data AS (\n'
    || E'        SELECT ''gap''::TEXT, s.id, s.id AS shift_id,\n'
    || E'            s.clocked_in_at, first_cluster.started_at,\n'
    || E'            GREATEST(0, EXTRACT(EPOCH FROM (first_cluster.started_at - s.clocked_in_at)) / 60)::INTEGER,\n'
    || E'            NULL::UUID, NULL::TEXT, NULL::TEXT,\n'
    || E'            (s.clock_in_location->>''latitude'')::DECIMAL,\n'
    || E'            (s.clock_in_location->>''longitude'')::DECIMAL,\n'
    || E'            0::INTEGER, 0::INTEGER,\n'
    || E'            ''needs_review''::TEXT,\n'
    || E'            ''Deplacement sans trace GPS entre clock-in et premier arret''::TEXT,\n'
    || E'            ROUND((111.045 * SQRT(\n'
    || E'                POWER(first_cluster.centroid_latitude - (s.clock_in_location->>''latitude'')::DECIMAL, 2) +\n'
    || E'                POWER((first_cluster.centroid_longitude - (s.clock_in_location->>''longitude'')::DECIMAL)\n'
    || E'                    * COS(RADIANS(((s.clock_in_location->>''latitude'')::DECIMAL + first_cluster.centroid_latitude) / 2)), 2)\n'
    || E'            ))::DECIMAL, 3),\n'
    || E'            NULL::TEXT, TRUE,\n'
    || E'            s.clock_in_location_id, ci_loc.name::TEXT, ci_loc.location_type::TEXT,\n'
    || E'            first_cluster.matched_location_id, fc_loc.name::TEXT, fc_loc.location_type::TEXT\n'
    || E'        FROM shift_boundaries sb\n'
    || E'        JOIN shifts s ON s.id = sb.shift_id\n'
    || E'        CROSS JOIN LATERAL (\n'
    || E'            SELECT sc.id, sc.started_at, sc.centroid_latitude, sc.centroid_longitude, sc.matched_location_id\n'
    || E'            FROM stationary_clusters sc WHERE sc.shift_id = s.id ORDER BY sc.started_at ASC LIMIT 1\n'
    || E'        ) first_cluster\n'
    || E'        LEFT JOIN locations ci_loc ON ci_loc.id = s.clock_in_location_id\n'
    || E'        LEFT JOIN locations fc_loc ON fc_loc.id = first_cluster.matched_location_id\n'
    || E'        WHERE s.clock_in_location IS NOT NULL\n'
    || E'          AND EXTRACT(EPOCH FROM (first_cluster.started_at - s.clocked_in_at)) > 60\n'
    || E'          AND (s.clock_in_location_id IS DISTINCT FROM first_cluster.matched_location_id\n'
    || E'               OR s.clock_in_location_id IS NULL OR first_cluster.matched_location_id IS NULL)\n'
    || E'    ),\n'
    || E'    clock_out_gap_data AS (\n'
    || E'        SELECT ''gap''::TEXT, s.id, s.id AS shift_id,\n'
    || E'            last_cluster.ended_at, s.clocked_out_at,\n'
    || E'            GREATEST(0, EXTRACT(EPOCH FROM (s.clocked_out_at - last_cluster.ended_at)) / 60)::INTEGER,\n'
    || E'            NULL::UUID, NULL::TEXT, NULL::TEXT,\n'
    || E'            last_cluster.centroid_latitude,\n'
    || E'            last_cluster.centroid_longitude,\n'
    || E'            0::INTEGER, 0::INTEGER,\n'
    || E'            ''needs_review''::TEXT,\n'
    || E'            ''Deplacement sans trace GPS entre dernier arret et clock-out''::TEXT,\n'
    || E'            ROUND((111.045 * SQRT(\n'
    || E'                POWER((s.clock_out_location->>''latitude'')::DECIMAL - last_cluster.centroid_latitude, 2) +\n'
    || E'                POWER(((s.clock_out_location->>''longitude'')::DECIMAL - last_cluster.centroid_longitude)\n'
    || E'                    * COS(RADIANS((last_cluster.centroid_latitude + (s.clock_out_location->>''latitude'')::DECIMAL) / 2)), 2)\n'
    || E'            ))::DECIMAL, 3),\n'
    || E'            NULL::TEXT, TRUE,\n'
    || E'            last_cluster.matched_location_id, lc_loc.name::TEXT, lc_loc.location_type::TEXT,\n'
    || E'            s.clock_out_location_id, co_loc.name::TEXT, co_loc.location_type::TEXT\n'
    || E'        FROM shift_boundaries sb\n'
    || E'        JOIN shifts s ON s.id = sb.shift_id\n'
    || E'        CROSS JOIN LATERAL (\n'
    || E'            SELECT sc.id, sc.ended_at, sc.centroid_latitude, sc.centroid_longitude, sc.matched_location_id\n'
    || E'            FROM stationary_clusters sc WHERE sc.shift_id = s.id ORDER BY sc.started_at DESC LIMIT 1\n'
    || E'        ) last_cluster\n'
    || E'        LEFT JOIN locations co_loc ON co_loc.id = s.clock_out_location_id\n'
    || E'        LEFT JOIN locations lc_loc ON lc_loc.id = last_cluster.matched_location_id\n'
    || E'        WHERE s.clock_out_location IS NOT NULL AND s.clocked_out_at IS NOT NULL\n'
    || E'          AND EXTRACT(EPOCH FROM (s.clocked_out_at - last_cluster.ended_at)) > 60\n'
    || E'          AND (last_cluster.matched_location_id IS DISTINCT FROM s.clock_out_location_id\n'
    || E'               OR last_cluster.matched_location_id IS NULL OR s.clock_out_location_id IS NULL)\n'
    || E'    ),\n';

  -- Insert the new CTEs before all_activity_data and add to the UNION
  v_modified := replace(v_modified,
    'all_activity_data AS (' || E'\n' || '        SELECT * FROM activity_data UNION ALL SELECT * FROM gap_activities' || E'\n' || '    )',
    v_new_ctes
    || 'all_activity_data AS (' || E'\n'
    || '        SELECT * FROM activity_data UNION ALL SELECT * FROM gap_activities' || E'\n'
    || '        UNION ALL SELECT * FROM clock_in_gap_data UNION ALL SELECT * FROM clock_out_gap_data' || E'\n'
    || '    )'
  );

  EXECUTE v_modified;
  RAISE NOTICE 'get_day_approval_detail updated with clock-in/out gap entries';
END;
$$;
