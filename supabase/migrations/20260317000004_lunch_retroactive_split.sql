-- =============================================================================
-- Retroactive lunch-to-shift-split migration
-- Processes existing 56 completed lunch_breaks and splits their parent shifts
-- into segments (work → lunch → work) sharing a work_body_id.
-- =============================================================================

DO $$
DECLARE
  v_lb RECORD;
  v_shift RECORD;
  v_work_body_id UUID;
  v_lunch_segment_id UUID;
  v_post_lunch_id UUID;
  v_count INTEGER := 0;
  v_gps_moved INTEGER := 0;
BEGIN
  RAISE NOTICE 'Starting retroactive lunch split...';

  FOR v_lb IN
    SELECT lb.*, s.status AS shift_status, s.clocked_out_at AS shift_clock_out,
           s.clock_out_reason AS shift_clock_out_reason,
           s.shift_type, s.shift_type_source, s.work_body_id AS existing_wbi
    FROM lunch_breaks lb
    JOIN shifts s ON s.id = lb.shift_id
    WHERE lb.ended_at IS NOT NULL  -- Only process completed lunches
      AND s.work_body_id IS NULL   -- Skip already-split shifts
    ORDER BY lb.shift_id, lb.started_at
  LOOP
    -- Generate work_body_id
    v_work_body_id := COALESCE(v_lb.existing_wbi, gen_random_uuid());

    -- Set work_body_id on parent shift
    UPDATE shifts SET work_body_id = v_work_body_id WHERE id = v_lb.shift_id;

    -- Close parent shift at lunch start
    UPDATE shifts SET
      clocked_out_at = v_lb.started_at,
      clock_out_reason = 'lunch',
      status = 'completed',
      updated_at = NOW()
    WHERE id = v_lb.shift_id;

    -- Create lunch segment (cap at shift end if lunch outlasted the shift)
    v_lunch_segment_id := gen_random_uuid();
    INSERT INTO shifts (id, employee_id, work_body_id, is_lunch,
      clocked_in_at, clocked_out_at, clock_out_reason, status,
      shift_type, shift_type_source)
    VALUES (
      v_lunch_segment_id, v_lb.employee_id, v_work_body_id, true,
      v_lb.started_at,
      LEAST(v_lb.ended_at, v_lb.shift_clock_out),
      'lunch_end', 'completed',
      v_lb.shift_type, v_lb.shift_type_source
    );

    -- Create post-lunch work segment (only if lunch ended before shift end)
    v_post_lunch_id := NULL;
    IF v_lb.ended_at < v_lb.shift_clock_out THEN
      v_post_lunch_id := gen_random_uuid();
      INSERT INTO shifts (id, employee_id, work_body_id, is_lunch,
        clocked_in_at, clocked_out_at, clock_out_reason, status,
        shift_type, shift_type_source)
      VALUES (
        v_post_lunch_id, v_lb.employee_id, v_work_body_id, false,
        v_lb.ended_at, v_lb.shift_clock_out, v_lb.shift_clock_out_reason,
        v_lb.shift_status, v_lb.shift_type, v_lb.shift_type_source
      );
    ELSE
      RAISE NOTICE 'Skipping post-lunch segment for shift % (lunch outlasted shift)', v_lb.shift_id;
    END IF;

    -- Redistribute GPS points
    UPDATE gps_points SET shift_id = v_lunch_segment_id
    WHERE shift_id = v_lb.shift_id
      AND captured_at >= v_lb.started_at AND captured_at < LEAST(v_lb.ended_at, v_lb.shift_clock_out);
    GET DIAGNOSTICS v_gps_moved = ROW_COUNT;

    IF v_post_lunch_id IS NOT NULL THEN
      UPDATE gps_points SET shift_id = v_post_lunch_id
      WHERE shift_id = v_lb.shift_id
        AND captured_at >= v_lb.ended_at;

      -- Redistribute work_sessions
      UPDATE work_sessions SET shift_id = v_post_lunch_id
      WHERE shift_id = v_lb.shift_id
        AND started_at >= v_lb.ended_at;

      -- Redistribute gps_gaps
      UPDATE gps_gaps SET shift_id = v_post_lunch_id
      WHERE shift_id = v_lb.shift_id
        AND started_at >= v_lb.ended_at;
    END IF;

    UPDATE work_sessions SET shift_id = v_lunch_segment_id
    WHERE shift_id = v_lb.shift_id
      AND started_at >= v_lb.started_at AND started_at < LEAST(v_lb.ended_at, v_lb.shift_clock_out);

    UPDATE gps_gaps SET shift_id = v_lunch_segment_id
    WHERE shift_id = v_lb.shift_id
      AND started_at >= v_lb.started_at AND started_at < LEAST(v_lb.ended_at, v_lb.shift_clock_out);

    -- Delete existing clusters/trips (will be re-detected)
    -- Delete carpool_members first (FK cascade from trips can deadlock with detect_carpools cron)
    DELETE FROM carpool_members WHERE trip_id IN (
      SELECT id FROM trips WHERE shift_id = v_lb.shift_id
    );
    DELETE FROM cluster_segments WHERE stationary_cluster_id IN (
      SELECT id FROM stationary_clusters WHERE shift_id = v_lb.shift_id
    );
    DELETE FROM trip_gps_points WHERE trip_id IN (
      SELECT id FROM trips WHERE shift_id = v_lb.shift_id
    );
    DELETE FROM trips WHERE shift_id = v_lb.shift_id;
    UPDATE gps_points SET stationary_cluster_id = NULL
    WHERE shift_id = v_lb.shift_id OR shift_id = v_lunch_segment_id
       OR (v_post_lunch_id IS NOT NULL AND shift_id = v_post_lunch_id);
    DELETE FROM stationary_clusters WHERE shift_id = v_lb.shift_id;

    v_count := v_count + 1;
    RAISE NOTICE 'Split shift % (lunch #%), GPS moved: %', v_lb.shift_id, v_count, v_gps_moved;
  END LOOP;

  -- Delete day_approvals and activity_overrides for affected shifts
  -- (supervisors will need to re-approve)
  DELETE FROM activity_overrides WHERE day_approval_id IN (
    SELECT da.id FROM day_approvals da
    JOIN shifts s ON s.employee_id = da.employee_id
    WHERE s.work_body_id IS NOT NULL
      AND da.date = (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date
  );

  DELETE FROM day_approvals WHERE id IN (
    SELECT da.id FROM day_approvals da
    JOIN shifts s ON s.employee_id = da.employee_id
    WHERE s.work_body_id IS NOT NULL
      AND da.date = (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date
  );

  RAISE NOTICE 'Retroactive split complete: % lunch breaks processed', v_count;
END $$;

-- Re-run detect_trips on all split segments
DO $$
DECLARE
  v_seg RECORD;
  v_count INTEGER := 0;
BEGIN
  RAISE NOTICE 'Re-running detect_trips on split segments...';

  FOR v_seg IN
    SELECT id FROM shifts
    WHERE work_body_id IS NOT NULL
      AND status = 'completed'
    ORDER BY clocked_in_at
  LOOP
    BEGIN
      PERFORM detect_trips(v_seg.id);
      v_count := v_count + 1;
      IF v_count % 10 = 0 THEN
        RAISE NOTICE 'detect_trips progress: %/total', v_count;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'detect_trips failed for shift %: %', v_seg.id, SQLERRM;
    END;
  END LOOP;

  RAISE NOTICE 'detect_trips re-run complete: % segments processed', v_count;
END $$;
