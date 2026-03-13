-- =============================================================================
-- Trim trip GPS boundaries
-- =============================================================================
-- When a trip has a GPS gap > 5 min at the start or end, trim the trip
-- boundaries to the first/last actual GPS point. The uncovered time becomes
-- a "gap" activity auto-detected by _get_day_approval_detail_base.
--
-- Cases handled:
-- A. Zero-GPS-point trips with duration > 5 min → DELETE (entire trip is gap)
-- B. Start gap: (first_gps_point - trip.started_at) > 300s → trim started_at
-- C. End gap: (trip.ended_at - last_gps_point) > 300s → trim ended_at
-- =============================================================================

CREATE OR REPLACE FUNCTION trim_trip_gps_boundaries(p_shift_id UUID)
RETURNS VOID AS $$
DECLARE
    v_trip RECORD;
    v_first_point RECORD;
    v_last_point RECORD;
    v_gap_threshold_seconds CONSTANT INTEGER := 300; -- 5 minutes
    v_new_started_at TIMESTAMPTZ;
    v_new_ended_at TIMESTAMPTZ;
    v_changed BOOLEAN;
BEGIN
    FOR v_trip IN
        SELECT t.id, t.started_at, t.ended_at, t.gps_point_count,
               t.gps_gap_seconds, t.gps_gap_count,
               t.start_cluster_id, t.end_cluster_id
        FROM trips t
        WHERE t.shift_id = p_shift_id
          AND (t.gps_gap_seconds > 0 OR t.gps_point_count = 0)
    LOOP
        -- Case A: Zero GPS points and duration > 5 min → delete trip
        IF v_trip.gps_point_count = 0 THEN
            IF EXTRACT(EPOCH FROM (v_trip.ended_at - v_trip.started_at)) > v_gap_threshold_seconds THEN
                DELETE FROM trip_gps_points WHERE trip_id = v_trip.id;
                DELETE FROM trips WHERE id = v_trip.id;
            END IF;
            CONTINUE;
        END IF;

        -- Get first and last GPS points in the trip
        SELECT gp.captured_at, gp.latitude, gp.longitude
        INTO v_first_point
        FROM trip_gps_points tgp
        JOIN gps_points gp ON gp.id = tgp.gps_point_id
        WHERE tgp.trip_id = v_trip.id
        ORDER BY tgp.sequence_order ASC
        LIMIT 1;

        SELECT gp.captured_at, gp.latitude, gp.longitude
        INTO v_last_point
        FROM trip_gps_points tgp
        JOIN gps_points gp ON gp.id = tgp.gps_point_id
        WHERE tgp.trip_id = v_trip.id
        ORDER BY tgp.sequence_order DESC
        LIMIT 1;

        IF v_first_point IS NULL THEN
            CONTINUE; -- Safety check
        END IF;

        v_new_started_at := v_trip.started_at;
        v_new_ended_at := v_trip.ended_at;
        v_changed := FALSE;

        -- Case B: Start gap > 5 min → trim started_at to first GPS point
        IF EXTRACT(EPOCH FROM (v_first_point.captured_at - v_trip.started_at)) > v_gap_threshold_seconds THEN
            v_new_started_at := v_first_point.captured_at;
            v_changed := TRUE;
        END IF;

        -- Case C: End gap > 5 min → trim ended_at to last GPS point
        IF EXTRACT(EPOCH FROM (v_trip.ended_at - v_last_point.captured_at)) > v_gap_threshold_seconds THEN
            v_new_ended_at := v_last_point.captured_at;
            v_changed := TRUE;
        END IF;

        -- Apply changes
        IF v_changed THEN
            -- If trimming makes trip < 0 duration, delete it
            IF v_new_ended_at <= v_new_started_at THEN
                DELETE FROM trip_gps_points WHERE trip_id = v_trip.id;
                DELETE FROM trips WHERE id = v_trip.id;
                CONTINUE;
            END IF;

            UPDATE trips SET
                started_at = v_new_started_at,
                ended_at = v_new_ended_at,
                duration_minutes = GREATEST(1, EXTRACT(EPOCH FROM (v_new_ended_at - v_new_started_at)) / 60)::INTEGER,
                -- Update start coords if start was trimmed
                start_latitude = CASE
                    WHEN v_new_started_at <> v_trip.started_at THEN v_first_point.latitude
                    ELSE start_latitude
                END,
                start_longitude = CASE
                    WHEN v_new_started_at <> v_trip.started_at THEN v_first_point.longitude
                    ELSE start_longitude
                END,
                -- Update end coords if end was trimmed
                end_latitude = CASE
                    WHEN v_new_ended_at <> v_trip.ended_at THEN v_last_point.latitude
                    ELSE end_latitude
                END,
                end_longitude = CASE
                    WHEN v_new_ended_at <> v_trip.ended_at THEN v_last_point.longitude
                    ELSE end_longitude
                END,
                -- Recalculate distance
                distance_km = ROUND(
                    haversine_km(
                        CASE WHEN v_new_started_at <> v_trip.started_at THEN v_first_point.latitude ELSE start_latitude END,
                        CASE WHEN v_new_started_at <> v_trip.started_at THEN v_first_point.longitude ELSE start_longitude END,
                        CASE WHEN v_new_ended_at <> v_trip.ended_at THEN v_last_point.latitude ELSE end_latitude END,
                        CASE WHEN v_new_ended_at <> v_trip.ended_at THEN v_last_point.longitude ELSE end_longitude END
                    ) * 1.3,  -- correction factor
                    3
                )
            WHERE id = v_trip.id;
        END IF;
    END LOOP;

    -- Re-compute GPS gaps for all modified trips
    PERFORM compute_gps_gaps(p_shift_id);
END;
$$ LANGUAGE plpgsql
SET search_path TO public, extensions;

-- =============================================================================
-- Integrate into detect_trips: add PERFORM trim_trip_gps_boundaries(p_shift_id)
-- as Step 10 after merge_same_location_clusters (Step 9).
-- Done dynamically via pg_get_functiondef + REPLACE + EXECUTE to avoid
-- copying the entire 900-line function.
-- =============================================================================
DO $$
DECLARE
    v_funcdef TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_funcdef
    FROM pg_proc WHERE proname = 'detect_trips';

    v_funcdef := REPLACE(v_funcdef,
        '        PERFORM merge_same_location_clusters(p_shift_id);
    END IF;
END;',
        '        PERFORM merge_same_location_clusters(p_shift_id);
    END IF;

    -- =========================================================================
    -- 10. Post-processing: trim trip boundaries at GPS gaps
    -- =========================================================================
    PERFORM trim_trip_gps_boundaries(p_shift_id);
END;'
    );

    EXECUTE v_funcdef;
END $$;

-- =============================================================================
-- Backfill: re-run trim for all completed shifts that have trips with GPS gaps
-- =============================================================================
DO $$
DECLARE
    v_shift_id UUID;
    v_count INTEGER := 0;
BEGIN
    FOR v_shift_id IN
        SELECT DISTINCT t.shift_id
        FROM trips t
        JOIN shifts s ON s.id = t.shift_id
        WHERE s.status = 'completed'
          AND (t.gps_gap_seconds > 0 OR t.gps_point_count = 0)
    LOOP
        PERFORM trim_trip_gps_boundaries(v_shift_id);
        v_count := v_count + 1;
    END LOOP;
    RAISE NOTICE 'Backfilled % shifts', v_count;
END $$;
