-- =============================================================================
-- Fix multi-lunch splits: undo corrupted splits and redo them correctly
--
-- The retroactive migration (20260317000004) had a bug: PostgreSQL's
-- FOR...IN SELECT materializes the cursor at start, so all lunch breaks for
-- the same shift got stale data. Each iteration created segments with a NEW
-- work_body_id, orphaning earlier segments.
--
-- This migration:
--   Phase 1: Undo all splits for the 9 affected shifts
--   Phase 2: Re-split correctly (reading fresh state between each lunch)
--   Phase 3: Re-run detect_trips on all resulting segments
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- Phase 1: Undo all corrupted splits
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_orig_ids UUID[] := ARRAY[
    '083e1380-7ebb-4058-8268-892fa6a2c37b',
    '15796579-c006-4ffa-88bb-03301cd8d84e',
    '1c7282b6-f663-4b8e-a6b7-330cfc9f49d6',
    '3a85297d-8ca3-4b91-8001-e4be00ec286f',
    '66be8227-6ff1-4333-ae51-5f096d7eea56',
    '882e3371-5718-4e8f-b122-660805f8c852',
    'a2bfd995-133d-4e92-ad3a-83c41a38d49f',
    'c570cbf5-ad04-44e7-9082-07862372b304',
    'eda32db7-be63-4549-bc90-3af4aeef7afa'
  ];
  v_orig_id UUID;
  v_all_wbis UUID[];
  v_all_segment_ids UUID[];
  v_true_clock_out TIMESTAMPTZ;
  v_true_clock_out_reason TEXT;
  v_true_status TEXT;
  v_emp_id UUID;
  v_shift_date DATE;
  v_deleted INTEGER;
BEGIN
  RAISE NOTICE 'Phase 1: Undoing corrupted splits for 9 shifts...';

  FOREACH v_orig_id IN ARRAY v_orig_ids
  LOOP
    RAISE NOTICE 'Undoing shift %', v_orig_id;

    -- Step 1: Find ALL related work_body_ids
    -- (a) The parent's current work_body_id
    -- (b) Orphaned work_body_ids: lunch segments matching lunch_breaks for this shift
    SELECT ARRAY_AGG(DISTINCT wbi) INTO v_all_wbis
    FROM (
      -- Parent's work_body_id
      SELECT work_body_id AS wbi FROM shifts WHERE id = v_orig_id AND work_body_id IS NOT NULL
      UNION
      -- Orphaned: lunch segments whose clocked_in_at matches a lunch_break.started_at for this shift
      SELECT s.work_body_id AS wbi
      FROM shifts s
      JOIN lunch_breaks lb ON s.is_lunch = true
        AND s.clocked_in_at = lb.started_at
        AND s.employee_id = lb.employee_id
      WHERE lb.shift_id = v_orig_id
        AND s.work_body_id IS NOT NULL
    ) sub;

    IF v_all_wbis IS NULL OR array_length(v_all_wbis, 1) IS NULL THEN
      RAISE NOTICE 'No work_body_ids found for shift %, skipping', v_orig_id;
      CONTINUE;
    END IF;

    RAISE NOTICE '  Found % work_body_ids: %', array_length(v_all_wbis, 1), v_all_wbis;

    -- Step 2: Collect ALL segment IDs (excluding the original)
    SELECT ARRAY_AGG(id) INTO v_all_segment_ids
    FROM shifts
    WHERE work_body_id = ANY(v_all_wbis)
      AND id != v_orig_id;

    -- Step 3: Find the "true" original clocked_out_at
    -- It's the MAX(clocked_out_at) from the last non-lunch segment across all work_body_ids
    SELECT s.clocked_out_at, s.clock_out_reason, s.status
    INTO v_true_clock_out, v_true_clock_out_reason, v_true_status
    FROM shifts s
    WHERE s.work_body_id = ANY(v_all_wbis)
      AND s.is_lunch = false
    ORDER BY s.clocked_out_at DESC NULLS LAST
    LIMIT 1;

    -- Get employee_id and date for later day_approvals cleanup
    SELECT employee_id INTO v_emp_id FROM shifts WHERE id = v_orig_id;
    SELECT (clocked_in_at AT TIME ZONE 'America/Montreal')::date INTO v_shift_date
    FROM shifts WHERE id = v_orig_id;

    RAISE NOTICE '  True clock_out: %, reason: %, segments to delete: %',
      v_true_clock_out, v_true_clock_out_reason,
      COALESCE(array_length(v_all_segment_ids, 1), 0);

    IF v_all_segment_ids IS NOT NULL AND array_length(v_all_segment_ids, 1) > 0 THEN
      -- Step 4: Move GPS points, work_sessions, gps_gaps back to the original shift
      UPDATE gps_points SET shift_id = v_orig_id
      WHERE shift_id = ANY(v_all_segment_ids);
      GET DIAGNOSTICS v_deleted = ROW_COUNT;
      RAISE NOTICE '  Moved % GPS points back to original', v_deleted;

      UPDATE work_sessions SET shift_id = v_orig_id
      WHERE shift_id = ANY(v_all_segment_ids);

      UPDATE gps_gaps SET shift_id = v_orig_id
      WHERE shift_id = ANY(v_all_segment_ids);

      -- Step 5: Delete dependent data for ALL segments AND original
      -- carpool_members (FK to trips)
      DELETE FROM carpool_members WHERE trip_id IN (
        SELECT id FROM trips WHERE shift_id = ANY(v_all_segment_ids)
        UNION SELECT id FROM trips WHERE shift_id = v_orig_id
      );

      -- cluster_segments (FK to stationary_clusters)
      DELETE FROM cluster_segments WHERE stationary_cluster_id IN (
        SELECT id FROM stationary_clusters WHERE shift_id = ANY(v_all_segment_ids)
        UNION SELECT id FROM stationary_clusters WHERE shift_id = v_orig_id
      );

      -- trip_gps_points (FK to trips)
      DELETE FROM trip_gps_points WHERE trip_id IN (
        SELECT id FROM trips WHERE shift_id = ANY(v_all_segment_ids)
        UNION SELECT id FROM trips WHERE shift_id = v_orig_id
      );

      -- trips
      DELETE FROM trips WHERE shift_id = ANY(v_all_segment_ids) OR shift_id = v_orig_id;

      -- Step 6: NULL out stationary_cluster_id on gps_points for original shift
      UPDATE gps_points SET stationary_cluster_id = NULL
      WHERE shift_id = v_orig_id;

      -- stationary_clusters
      DELETE FROM stationary_clusters WHERE shift_id = ANY(v_all_segment_ids) OR shift_id = v_orig_id;

      -- cleaning_sessions: move any on segments back to original (shouldn't happen but be safe)
      UPDATE cleaning_sessions SET shift_id = v_orig_id
      WHERE shift_id = ANY(v_all_segment_ids);

      -- Step 7: Delete ALL non-original segments
      DELETE FROM shifts WHERE id = ANY(v_all_segment_ids);
      GET DIAGNOSTICS v_deleted = ROW_COUNT;
      RAISE NOTICE '  Deleted % segments', v_deleted;
    ELSE
      -- Still need to clean trips/clusters on the original
      DELETE FROM carpool_members WHERE trip_id IN (
        SELECT id FROM trips WHERE shift_id = v_orig_id
      );
      DELETE FROM cluster_segments WHERE stationary_cluster_id IN (
        SELECT id FROM stationary_clusters WHERE shift_id = v_orig_id
      );
      DELETE FROM trip_gps_points WHERE trip_id IN (
        SELECT id FROM trips WHERE shift_id = v_orig_id
      );
      DELETE FROM trips WHERE shift_id = v_orig_id;
      UPDATE gps_points SET stationary_cluster_id = NULL WHERE shift_id = v_orig_id;
      DELETE FROM stationary_clusters WHERE shift_id = v_orig_id;
    END IF;

    -- Step 8: Reset original shift
    UPDATE shifts SET
      work_body_id = NULL,
      is_lunch = false,
      clocked_out_at = v_true_clock_out,
      clock_out_reason = v_true_clock_out_reason,
      status = v_true_status,
      updated_at = NOW()
    WHERE id = v_orig_id;

    -- Step 9: Delete day_approvals + activity_overrides for affected employee+date
    DELETE FROM activity_overrides WHERE day_approval_id IN (
      SELECT id FROM day_approvals
      WHERE employee_id = v_emp_id AND date = v_shift_date
    );
    DELETE FROM day_approvals
    WHERE employee_id = v_emp_id AND date = v_shift_date;

    RAISE NOTICE '  Shift % fully restored', v_orig_id;
  END LOOP;

  RAISE NOTICE 'Phase 1 complete: all 9 shifts restored to pre-split state';
END $$;


-- ─────────────────────────────────────────────────────────────────────────────
-- Phase 2: Re-split correctly (reading fresh state between each lunch)
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_orig_ids UUID[] := ARRAY[
    '083e1380-7ebb-4058-8268-892fa6a2c37b',
    '15796579-c006-4ffa-88bb-03301cd8d84e',
    '1c7282b6-f663-4b8e-a6b7-330cfc9f49d6',
    '3a85297d-8ca3-4b91-8001-e4be00ec286f',
    '66be8227-6ff1-4333-ae51-5f096d7eea56',
    '882e3371-5718-4e8f-b122-660805f8c852',
    'a2bfd995-133d-4e92-ad3a-83c41a38d49f',
    'c570cbf5-ad04-44e7-9082-07862372b304',
    'eda32db7-be63-4549-bc90-3af4aeef7afa'
  ];
  v_orig_id UUID;
  v_lb RECORD;
  v_shift RECORD;
  v_work_body_id UUID;
  v_lunch_id UUID;
  v_post_id UUID;
  v_is_first_lunch BOOLEAN;
  v_lunch_end TIMESTAMPTZ;
  v_gps_moved INTEGER;
BEGIN
  RAISE NOTICE 'Phase 2: Re-splitting correctly...';

  FOREACH v_orig_id IN ARRAY v_orig_ids
  LOOP
    RAISE NOTICE 'Re-splitting shift %', v_orig_id;
    v_is_first_lunch := true;

    FOR v_lb IN
      SELECT * FROM lunch_breaks
      WHERE shift_id = v_orig_id
        AND ended_at IS NOT NULL
      ORDER BY started_at
    LOOP
      -- Find the CURRENT covering work segment (re-read from DB each time!)
      IF v_is_first_lunch THEN
        SELECT * INTO v_shift FROM shifts WHERE id = v_orig_id;
        v_is_first_lunch := false;
      ELSE
        -- Find the work segment that covers this lunch break
        SELECT * INTO v_shift FROM shifts
        WHERE employee_id = v_lb.employee_id
          AND work_body_id = (SELECT work_body_id FROM shifts WHERE id = v_orig_id)
          AND is_lunch = false
          AND clocked_in_at <= v_lb.started_at
          AND (clocked_out_at IS NULL OR clocked_out_at >= v_lb.started_at)
        ORDER BY clocked_in_at DESC
        LIMIT 1;
      END IF;

      IF v_shift IS NULL OR v_shift.id IS NULL THEN
        RAISE WARNING 'No covering work segment found for lunch at % on shift %, skipping',
          v_lb.started_at, v_orig_id;
        CONTINUE;
      END IF;

      RAISE NOTICE '  Processing lunch % -> % on segment %',
        v_lb.started_at AT TIME ZONE 'America/Montreal',
        v_lb.ended_at AT TIME ZONE 'America/Montreal',
        v_shift.id;

      -- Generate/reuse work_body_id
      v_work_body_id := COALESCE(v_shift.work_body_id, gen_random_uuid());
      IF v_shift.work_body_id IS NULL THEN
        UPDATE shifts SET work_body_id = v_work_body_id WHERE id = v_shift.id;
      END IF;

      -- Cap lunch end at shift end (lunch that outlasted the shift)
      v_lunch_end := LEAST(v_lb.ended_at, v_shift.clocked_out_at);

      -- Close current segment at lunch start
      UPDATE shifts SET
        clocked_out_at = v_lb.started_at,
        clock_out_reason = 'lunch',
        status = 'completed',
        updated_at = NOW()
      WHERE id = v_shift.id;

      -- Create lunch segment
      v_lunch_id := gen_random_uuid();
      INSERT INTO shifts (id, employee_id, work_body_id, is_lunch,
        clocked_in_at, clocked_out_at, clock_out_reason, status,
        shift_type, shift_type_source)
      VALUES (
        v_lunch_id, v_lb.employee_id, v_work_body_id, true,
        v_lb.started_at, v_lunch_end, 'lunch_end', 'completed',
        v_shift.shift_type, v_shift.shift_type_source
      );

      -- Create post-lunch work segment (only if lunch ended before shift end)
      v_post_id := NULL;
      IF v_lb.ended_at < v_shift.clocked_out_at THEN
        v_post_id := gen_random_uuid();
        INSERT INTO shifts (id, employee_id, work_body_id, is_lunch,
          clocked_in_at, clocked_out_at, clock_out_reason, status,
          shift_type, shift_type_source)
        VALUES (
          v_post_id, v_lb.employee_id, v_work_body_id, false,
          v_lb.ended_at, v_shift.clocked_out_at, v_shift.clock_out_reason,
          v_shift.status, v_shift.shift_type, v_shift.shift_type_source
        );
      ELSE
        RAISE NOTICE '  Skipping post-lunch segment (lunch outlasted shift)';
      END IF;

      -- Redistribute GPS points to lunch segment
      UPDATE gps_points SET shift_id = v_lunch_id
      WHERE shift_id = v_shift.id
        AND captured_at >= v_lb.started_at
        AND captured_at < v_lunch_end;
      GET DIAGNOSTICS v_gps_moved = ROW_COUNT;
      RAISE NOTICE '  GPS moved to lunch: %', v_gps_moved;

      -- Redistribute GPS points to post-lunch segment
      IF v_post_id IS NOT NULL THEN
        UPDATE gps_points SET shift_id = v_post_id
        WHERE shift_id = v_shift.id
          AND captured_at >= v_lb.ended_at;

        -- Redistribute work_sessions to post-lunch
        UPDATE work_sessions SET shift_id = v_post_id
        WHERE shift_id = v_shift.id
          AND started_at >= v_lb.ended_at;

        -- Redistribute gps_gaps to post-lunch
        UPDATE gps_gaps SET shift_id = v_post_id
        WHERE shift_id = v_shift.id
          AND started_at >= v_lb.ended_at;

        -- Redistribute cleaning_sessions to post-lunch
        UPDATE cleaning_sessions SET shift_id = v_post_id
        WHERE shift_id = v_shift.id
          AND started_at >= v_lb.ended_at;
      END IF;

      -- Redistribute work_sessions to lunch segment
      UPDATE work_sessions SET shift_id = v_lunch_id
      WHERE shift_id = v_shift.id
        AND started_at >= v_lb.started_at
        AND started_at < v_lunch_end;

      -- Redistribute gps_gaps to lunch segment
      UPDATE gps_gaps SET shift_id = v_lunch_id
      WHERE shift_id = v_shift.id
        AND started_at >= v_lb.started_at
        AND started_at < v_lunch_end;

      -- Redistribute cleaning_sessions to lunch segment
      UPDATE cleaning_sessions SET shift_id = v_lunch_id
      WHERE shift_id = v_shift.id
        AND started_at >= v_lb.started_at
        AND started_at < v_lunch_end;

    END LOOP;

    RAISE NOTICE 'Shift % re-split complete', v_orig_id;
  END LOOP;

  RAISE NOTICE 'Phase 2 complete: all 9 shifts correctly re-split';
END $$;


-- ─────────────────────────────────────────────────────────────────────────────
-- Phase 3: Re-run detect_trips on all completed segments
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_orig_ids UUID[] := ARRAY[
    '083e1380-7ebb-4058-8268-892fa6a2c37b',
    '15796579-c006-4ffa-88bb-03301cd8d84e',
    '1c7282b6-f663-4b8e-a6b7-330cfc9f49d6',
    '3a85297d-8ca3-4b91-8001-e4be00ec286f',
    '66be8227-6ff1-4333-ae51-5f096d7eea56',
    '882e3371-5718-4e8f-b122-660805f8c852',
    'a2bfd995-133d-4e92-ad3a-83c41a38d49f',
    'c570cbf5-ad04-44e7-9082-07862372b304',
    'eda32db7-be63-4549-bc90-3af4aeef7afa'
  ];
  v_wbis UUID[];
  v_seg RECORD;
  v_count INTEGER := 0;
BEGIN
  RAISE NOTICE 'Phase 3: Re-running detect_trips...';

  -- Collect all work_body_ids from the 9 fixed shifts
  SELECT ARRAY_AGG(DISTINCT work_body_id) INTO v_wbis
  FROM shifts
  WHERE id = ANY(v_orig_ids)
    AND work_body_id IS NOT NULL;

  FOR v_seg IN
    SELECT id FROM shifts
    WHERE work_body_id = ANY(v_wbis)
      AND status = 'completed'
    ORDER BY clocked_in_at
  LOOP
    BEGIN
      PERFORM detect_trips(v_seg.id);
      v_count := v_count + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'detect_trips failed for segment %: %', v_seg.id, SQLERRM;
    END;
  END LOOP;

  RAISE NOTICE 'Phase 3 complete: detect_trips ran on % segments', v_count;
END $$;
