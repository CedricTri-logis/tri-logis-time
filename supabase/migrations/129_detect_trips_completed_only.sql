-- =============================================================================
-- 129: Simplify detect_trips to completed-shifts-only + synthetic trips
-- =============================================================================
-- Changes:
-- 1. Return early if shift is not 'completed' (no more active-shift detection)
-- 2. Always create clusters (remove v_create_clusters branching)
-- 3. Always full re-detection (delete all trips+clusters)
-- 4. Post-processing: insert synthetic trips for consecutive cluster pairs without trips
-- =============================================================================

DO $$
DECLARE
  v_funcdef TEXT;
  v_modified TEXT;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_funcdef
  FROM pg_proc p
  WHERE p.proname = 'detect_trips'
  AND p.pronamespace = 'public'::regnamespace;

  IF v_funcdef IS NULL THEN
    RAISE EXCEPTION 'detect_trips function not found';
  END IF;

  v_modified := v_funcdef;

  -- =========================================================================
  -- 1. Add v_gap_rec to DECLARE block
  -- =========================================================================
  v_modified := replace(v_modified,
    'v_has_prev_point BOOLEAN := FALSE;' || E'\n' || 'BEGIN',
    'v_has_prev_point BOOLEAN := FALSE;' || E'\n' || '    v_gap_rec RECORD;' || E'\n' || 'BEGIN'
  );

  -- =========================================================================
  -- 2. Replace validation section: add early return for non-completed shifts
  -- =========================================================================
  v_modified := replace(v_modified,
    E'v_employee_id := v_shift.employee_id;\n    v_is_active := (v_shift.status = \'active\');',
    E'v_employee_id := v_shift.employee_id;\n\n    -- Only process completed shifts\n    IF v_shift.status != \'completed\' THEN\n        RETURN;  -- No-op for active shifts\n    END IF;'
  );

  -- =========================================================================
  -- 3. Replace conditional deletion with full deletion
  -- =========================================================================
  v_modified := replace(v_modified,
    E'IF v_is_active THEN\n        DELETE FROM trips\n        WHERE shift_id = p_shift_id\n          AND match_status IN (\'pending\', \'processing\');\n\n        SELECT MAX(gp.captured_at) INTO v_cutoff_time\n        FROM trips t\n        JOIN trip_gps_points tgp ON tgp.trip_id = t.id\n        JOIN gps_points gp ON gp.id = tgp.gps_point_id\n        WHERE t.shift_id = p_shift_id;\n    ELSE\n        DELETE FROM trips WHERE shift_id = p_shift_id;\n    END IF;\n\n    v_create_clusters := NOT v_is_active;\n    IF v_create_clusters THEN\n        DELETE FROM stationary_clusters WHERE shift_id = p_shift_id;\n    END IF;',
    E'DELETE FROM trip_gps_points WHERE trip_id IN (\n        SELECT id FROM trips WHERE shift_id = p_shift_id\n    );\n    DELETE FROM trips WHERE shift_id = p_shift_id;\n    DELETE FROM stationary_clusters WHERE shift_id = p_shift_id;\n    UPDATE gps_points SET stationary_cluster_id = NULL\n    WHERE shift_id = p_shift_id AND stationary_cluster_id IS NOT NULL;'
  );

  -- =========================================================================
  -- 4. Remove v_cutoff_time filter from main loop query
  -- =========================================================================
  v_modified := replace(v_modified,
    E'AND (v_cutoff_time IS NULL OR gp.captured_at > v_cutoff_time)\n',
    E'\n'
  );

  -- =========================================================================
  -- 5. Remove all "IF v_create_clusters THEN" guards (always create clusters)
  -- =========================================================================
  -- Replace the guard with a comment (the END IF will be harmless as orphan)
  -- Actually, we need to handle the matched END IF; too.
  -- Simpler: just replace all occurrences of the condition to TRUE
  v_modified := replace(v_modified,
    'IF v_create_clusters THEN',
    'IF TRUE THEN -- always create clusters'
  );
  v_modified := replace(v_modified,
    'IF v_create_clusters AND v_has_db_cluster THEN',
    'IF v_has_db_cluster THEN'
  );
  v_modified := replace(v_modified,
    'v_has_db_cluster := v_create_clusters;',
    'v_has_db_cluster := TRUE;'
  );

  -- Remove ELSE branch for active shifts in tentative promotion
  v_modified := replace(v_modified,
    E'ELSE\n                            v_new_cluster_id := NULL;  -- Active shifts: use NULL to avoid FK violation',
    '-- (removed active-shift ELSE branch)'
  );

  -- =========================================================================
  -- 6. Remove "IF NOT v_is_active THEN" guard on end-of-data section 5
  -- =========================================================================
  v_modified := replace(v_modified,
    E'IF NOT v_is_active THEN\n        -- Finalize the current cluster if it qualifies',
    E'-- Finalize the current cluster if it qualifies'
  );

  -- Remove the matching END IF (the last one before section 7)
  -- Pattern: "    END IF;\n\n    -- ====...7."
  v_modified := replace(v_modified,
    E'END IF;\n    END IF;\n\n    -- =========================================================================\n    -- 7.',
    E'END IF;\n\n    -- =========================================================================\n    -- 7.'
  );

  -- =========================================================================
  -- 7. Remove "IF v_create_clusters THEN" / "END IF" around section 7 body
  -- =========================================================================
  v_modified := replace(v_modified,
    E'IF TRUE THEN -- always create clusters\n        PERFORM compute_cluster_effective_types(p_shift_id, v_employee_id);\n    END IF;',
    E'PERFORM compute_cluster_effective_types(p_shift_id, v_employee_id);'
  );

  -- =========================================================================
  -- 8. Add section 9 — synthetic trip post-processing before END;
  -- =========================================================================
  v_modified := replace(v_modified,
    E'PERFORM compute_gps_gaps(p_shift_id);\nEND;',
    E'PERFORM compute_gps_gaps(p_shift_id);\n\n    -- =========================================================================\n    -- 9. Post-processing: fill missing trips between consecutive clusters\n    -- =========================================================================\n    FOR v_gap_rec IN\n        WITH ordered_clusters AS (\n            SELECT\n                sc9.id AS cluster_id,\n                sc9.centroid_latitude,\n                sc9.centroid_longitude,\n                sc9.centroid_accuracy,\n                sc9.started_at,\n                sc9.ended_at,\n                sc9.matched_location_id,\n                ROW_NUMBER() OVER (ORDER BY sc9.started_at) AS seq\n            FROM stationary_clusters sc9\n            WHERE sc9.shift_id = p_shift_id\n        ),\n        consecutive_pairs AS (\n            SELECT\n                c1.cluster_id AS from_cluster_id,\n                c1.centroid_latitude AS from_lat,\n                c1.centroid_longitude AS from_lng,\n                c1.centroid_accuracy AS from_acc,\n                c1.ended_at AS from_ended,\n                c1.matched_location_id AS from_location_id,\n                c2.cluster_id AS to_cluster_id,\n                c2.centroid_latitude AS to_lat,\n                c2.centroid_longitude AS to_lng,\n                c2.centroid_accuracy AS to_acc,\n                c2.started_at AS to_started,\n                c2.matched_location_id AS to_location_id\n            FROM ordered_clusters c1\n            JOIN ordered_clusters c2 ON c2.seq = c1.seq + 1\n        )\n        SELECT cp.*\n        FROM consecutive_pairs cp\n        WHERE NOT EXISTS (\n            SELECT 1 FROM trips t\n            WHERE t.shift_id = p_shift_id\n              AND t.start_cluster_id = cp.from_cluster_id\n              AND t.end_cluster_id = cp.to_cluster_id\n        )\n    LOOP\n        v_trip_id := gen_random_uuid();\n        v_trip_distance := haversine_km(\n            v_gap_rec.from_lat, v_gap_rec.from_lng,\n            v_gap_rec.to_lat, v_gap_rec.to_lng\n        );\n\n        INSERT INTO trips (\n            id, shift_id, employee_id,\n            started_at, ended_at,\n            start_latitude, start_longitude,\n            end_latitude, end_longitude,\n            distance_km, duration_minutes,\n            classification, confidence_score,\n            gps_point_count, low_accuracy_segments,\n            detection_method, transport_mode,\n            start_cluster_id, end_cluster_id,\n            has_gps_gap,\n            start_location_id, end_location_id\n        ) VALUES (\n            v_trip_id, p_shift_id, v_employee_id,\n            v_gap_rec.from_ended,\n            v_gap_rec.to_started,\n            v_gap_rec.from_lat, v_gap_rec.from_lng,\n            v_gap_rec.to_lat, v_gap_rec.to_lng,\n            ROUND(v_trip_distance, 3),\n            GREATEST(0, EXTRACT(EPOCH FROM (v_gap_rec.to_started - v_gap_rec.from_ended)) / 60)::INTEGER,\n            \'business\', 0.00, 0, 0, \'auto\', \'unknown\',\n            v_gap_rec.from_cluster_id, v_gap_rec.to_cluster_id,\n            TRUE,\n            COALESCE(v_gap_rec.from_location_id,\n                match_trip_to_location(v_gap_rec.from_lat, v_gap_rec.from_lng, COALESCE(v_gap_rec.from_acc, 0))),\n            COALESCE(v_gap_rec.to_location_id,\n                match_trip_to_location(v_gap_rec.to_lat, v_gap_rec.to_lng, COALESCE(v_gap_rec.to_acc, 0)))\n        );\n\n        UPDATE trips SET\n            gps_gap_seconds = GREATEST(0, EXTRACT(EPOCH FROM (v_gap_rec.to_started - v_gap_rec.from_ended)))::INTEGER,\n            gps_gap_count = 1\n        WHERE id = v_trip_id;\n\n        RETURN QUERY SELECT\n            v_trip_id, v_gap_rec.from_ended, v_gap_rec.to_started,\n            v_gap_rec.from_lat::DECIMAL(10,8), v_gap_rec.from_lng::DECIMAL(11,8),\n            v_gap_rec.to_lat::DECIMAL(10,8), v_gap_rec.to_lng::DECIMAL(11,8),\n            ROUND(v_trip_distance, 3),\n            GREATEST(0, EXTRACT(EPOCH FROM (v_gap_rec.to_started - v_gap_rec.from_ended)) / 60)::INTEGER,\n            0.00::DECIMAL(3,2), 0;\n    END LOOP;\nEND;'
  );

  EXECUTE v_modified;
  RAISE NOTICE 'detect_trips updated: completed-only + synthetic trips';
END;
$$;
