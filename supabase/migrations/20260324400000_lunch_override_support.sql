-- =============================================================
-- Lunch Override Support
-- Allow supervisors to approve lunch as work (full or partial via segments)
--
-- Part 1 (Task 1): CHECK constraints + 4 RPC rewrites
-- Part 2 (Task 2): Patch _get_day_approval_detail_base via pg_proc
-- Part 3 (Task 3): Patch get_weekly_approval_summary via pg_proc
-- =============================================================

-- =============================================
-- PART 1: CHECK constraints + RPC type changes
-- =============================================

-- 1. Update activity_segments CHECK to include 'lunch'
ALTER TABLE activity_segments
    DROP CONSTRAINT IF EXISTS activity_segments_activity_type_check;

ALTER TABLE activity_segments
    ADD CONSTRAINT activity_segments_activity_type_check
    CHECK (activity_type IN ('stop', 'trip', 'gap', 'lunch'));

-- 2. Update activity_overrides CHECK to include 'lunch_segment'
ALTER TABLE activity_overrides
    DROP CONSTRAINT IF EXISTS activity_overrides_activity_type_check;

ALTER TABLE activity_overrides
    ADD CONSTRAINT activity_overrides_activity_type_check
    CHECK (activity_type IN (
        'trip', 'stop', 'clock_in', 'clock_out', 'gap',
        'lunch_start', 'lunch_end', 'lunch',
        'stop_segment', 'trip_segment', 'gap_segment',
        'lunch_segment'
    ));

-- 3. save_activity_override — remove lunch block, add lunch_segment
CREATE OR REPLACE FUNCTION save_activity_override(
    p_employee_id UUID,
    p_date DATE,
    p_activity_type TEXT,
    p_activity_id UUID,
    p_status TEXT,
    p_reason TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
    v_day_approval_id UUID;
    v_result JSONB;
BEGIN
    -- Auth check
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can save overrides';
    END IF;

    -- Validate override status
    IF p_status NOT IN ('approved', 'rejected') THEN
        RAISE EXCEPTION 'Override status must be approved or rejected';
    END IF;

    -- Validate activity type (lunch_segment added)
    IF p_activity_type NOT IN (
        'trip', 'stop', 'clock_in', 'clock_out', 'gap',
        'lunch_start', 'lunch_end', 'lunch',
        'stop_segment', 'trip_segment', 'gap_segment',
        'lunch_segment'
    ) THEN
        RAISE EXCEPTION 'Invalid activity type: %', p_activity_type;
    END IF;

    -- Get or create day_approval
    INSERT INTO day_approvals (employee_id, date, status)
    VALUES (p_employee_id, p_date, 'pending')
    ON CONFLICT (employee_id, date) DO NOTHING;

    SELECT id INTO v_day_approval_id
    FROM day_approvals
    WHERE employee_id = p_employee_id AND date = p_date;

    -- Cannot override on approved days
    IF (SELECT status FROM day_approvals WHERE id = v_day_approval_id) = 'approved' THEN
        RAISE EXCEPTION 'Cannot modify overrides on an approved day';
    END IF;

    -- Upsert override
    INSERT INTO activity_overrides (day_approval_id, activity_type, activity_id, override_status, reason, created_by)
    VALUES (v_day_approval_id, p_activity_type, p_activity_id, p_status, p_reason, v_caller)
    ON CONFLICT (day_approval_id, activity_type, activity_id)
    DO UPDATE SET
        override_status = EXCLUDED.override_status,
        reason = EXCLUDED.reason,
        created_by = EXCLUDED.created_by,
        created_at = now();

    -- Return updated day detail
    SELECT get_day_approval_detail(p_employee_id, p_date) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;

-- 4. remove_activity_override — add lunch_segment
CREATE OR REPLACE FUNCTION remove_activity_override(
    p_employee_id UUID,
    p_date DATE,
    p_activity_type TEXT,
    p_activity_id UUID
)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
BEGIN
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can remove overrides';
    END IF;

    -- Validate activity type (lunch_segment added)
    IF p_activity_type NOT IN (
        'trip', 'stop', 'clock_in', 'clock_out', 'gap',
        'lunch_start', 'lunch_end', 'lunch',
        'stop_segment', 'trip_segment', 'gap_segment',
        'lunch_segment'
    ) THEN
        RAISE EXCEPTION 'Invalid activity type: %', p_activity_type;
    END IF;

    -- Check day is not already approved
    IF EXISTS(
        SELECT 1 FROM day_approvals
        WHERE employee_id = p_employee_id AND date = p_date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Cannot modify overrides on an already approved day';
    END IF;

    DELETE FROM activity_overrides ao
    USING day_approvals da
    WHERE ao.day_approval_id = da.id
      AND da.employee_id = p_employee_id
      AND da.date = p_date
      AND ao.activity_type = p_activity_type
      AND ao.activity_id = p_activity_id;

    RETURN get_day_approval_detail(p_employee_id, p_date);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;

-- 5. segment_activity — add lunch support
-- Based on 20260320000000_gap_split_auto_segment_stop.sql version
-- which includes auto-segment overlapping stops logic for gaps
CREATE OR REPLACE FUNCTION segment_activity(
    p_activity_type TEXT,
    p_activity_id   UUID,
    p_cut_points    TIMESTAMPTZ[],
    p_employee_id   UUID DEFAULT NULL,
    p_starts_at     TIMESTAMPTZ DEFAULT NULL,
    p_ends_at       TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
    v_employee_id UUID;
    v_started_at TIMESTAMPTZ;
    v_ended_at TIMESTAMPTZ;
    v_date DATE;
    v_cut_points TIMESTAMPTZ[];
    v_segment_start TIMESTAMPTZ;
    v_segment_end TIMESTAMPTZ;
    v_seg_idx INT;
    v_day_approval_id UUID;
    v_result JSONB;
    v_segment_type TEXT;
    -- Auto-segment variables
    v_stop RECORD;
    v_stop_seg_start TIMESTAMPTZ;
    v_stop_seg_end TIMESTAMPTZ;
    v_stop_seg_idx INT;
    v_clamped_cuts TIMESTAMPTZ[];
    v_cp TIMESTAMPTZ;
BEGIN
    -- Auth
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can segment activities';
    END IF;

    -- Validate activity type (lunch added)
    IF p_activity_type NOT IN ('stop', 'trip', 'gap', 'lunch') THEN
        RAISE EXCEPTION 'Invalid activity type: %. Must be stop, trip, gap, or lunch', p_activity_type;
    END IF;

    -- Max 2 cut points
    IF array_length(p_cut_points, 1) > 2 THEN
        RAISE EXCEPTION 'Maximum 2 cut points allowed (3 segments)';
    END IF;

    -- Resolve bounds and employee_id per type
    IF p_activity_type = 'stop' THEN
        SELECT employee_id, started_at, ended_at
        INTO v_employee_id, v_started_at, v_ended_at
        FROM stationary_clusters WHERE id = p_activity_id;
        IF v_employee_id IS NULL THEN
            RAISE EXCEPTION 'Stationary cluster not found';
        END IF;

    ELSIF p_activity_type = 'trip' THEN
        SELECT employee_id, started_at, ended_at
        INTO v_employee_id, v_started_at, v_ended_at
        FROM trips WHERE id = p_activity_id;
        IF v_employee_id IS NULL THEN
            RAISE EXCEPTION 'Trip not found';
        END IF;

    ELSIF p_activity_type = 'gap' THEN
        IF p_employee_id IS NULL OR p_starts_at IS NULL OR p_ends_at IS NULL THEN
            RAISE EXCEPTION 'Gap segmentation requires p_employee_id, p_starts_at, p_ends_at';
        END IF;
        v_employee_id := p_employee_id;
        v_started_at := p_starts_at;
        v_ended_at := p_ends_at;

    ELSIF p_activity_type = 'lunch' THEN
        SELECT employee_id, clocked_in_at, clocked_out_at
        INTO v_employee_id, v_started_at, v_ended_at
        FROM shifts WHERE id = p_activity_id AND is_lunch = true;
        IF v_employee_id IS NULL THEN
            RAISE EXCEPTION 'Lunch shift not found';
        END IF;
    END IF;

    v_date := to_business_date(v_started_at);

    -- Check day not approved
    IF EXISTS (
        SELECT 1 FROM day_approvals
        WHERE employee_id = v_employee_id AND date = v_date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Day is approved. Reopen it before segmenting.';
    END IF;

    -- Sort cut points
    SELECT array_agg(cp ORDER BY cp) INTO v_cut_points FROM unnest(p_cut_points) cp;

    -- Validate all cut points within bounds
    FOR v_seg_idx IN 1..array_length(v_cut_points, 1) LOOP
        IF v_cut_points[v_seg_idx] <= v_started_at OR v_cut_points[v_seg_idx] >= v_ended_at THEN
            RAISE EXCEPTION 'Cut point % is outside activity bounds [%, %]',
                v_cut_points[v_seg_idx], v_started_at, v_ended_at;
        END IF;
    END LOOP;

    -- Validate minimum 1 minute per segment
    v_segment_start := v_started_at;
    FOR v_seg_idx IN 1..array_length(v_cut_points, 1) LOOP
        IF (v_cut_points[v_seg_idx] - v_segment_start) < INTERVAL '1 minute' THEN
            RAISE EXCEPTION 'Segment % would be less than 1 minute', v_seg_idx - 1;
        END IF;
        v_segment_start := v_cut_points[v_seg_idx];
    END LOOP;
    IF (v_ended_at - v_segment_start) < INTERVAL '1 minute' THEN
        RAISE EXCEPTION 'Last segment would be less than 1 minute';
    END IF;

    -- Determine segment type suffix
    v_segment_type := p_activity_type || '_segment';

    -- Delete existing segments and overrides
    SELECT id INTO v_day_approval_id
    FROM day_approvals
    WHERE employee_id = v_employee_id AND date = v_date;

    IF v_day_approval_id IS NOT NULL THEN
        -- Delete overrides for existing segments
        DELETE FROM activity_overrides
        WHERE day_approval_id = v_day_approval_id
          AND activity_type = v_segment_type
          AND activity_id IN (
              SELECT id FROM activity_segments
              WHERE activity_type = p_activity_type AND activity_id = p_activity_id
          );

        -- Delete parent activity override
        DELETE FROM activity_overrides
        WHERE day_approval_id = v_day_approval_id
          AND activity_type = p_activity_type
          AND activity_id = p_activity_id;
    END IF;

    DELETE FROM activity_segments
    WHERE activity_type = p_activity_type AND activity_id = p_activity_id;

    -- Create new segments
    v_segment_start := v_started_at;
    FOR v_seg_idx IN 0..array_length(v_cut_points, 1) LOOP
        IF v_seg_idx < array_length(v_cut_points, 1) THEN
            v_segment_end := v_cut_points[v_seg_idx + 1];
        ELSE
            v_segment_end := v_ended_at;
        END IF;

        INSERT INTO activity_segments (id, activity_type, activity_id, employee_id, segment_index, starts_at, ends_at, created_by)
        VALUES (
            md5(p_activity_type || ':' || p_activity_id::TEXT || ':' || v_seg_idx::TEXT)::UUID,
            p_activity_type,
            p_activity_id,
            v_employee_id,
            v_seg_idx,
            v_segment_start,
            v_segment_end,
            v_caller
        );

        v_segment_start := v_segment_end;
    END LOOP;

    -- =====================================================================
    -- Auto-segment overlapping stops when splitting a gap
    -- =====================================================================
    IF p_activity_type = 'gap' THEN
        FOR v_stop IN
            SELECT sc.id, sc.started_at, sc.ended_at
            FROM stationary_clusters sc
            WHERE sc.employee_id = v_employee_id
              AND sc.started_at < v_ended_at
              AND sc.ended_at > v_started_at
              AND sc.duration_seconds >= 180
              -- Skip stops that are already manually segmented
              AND sc.id NOT IN (
                  SELECT aseg.activity_id FROM activity_segments aseg
                  WHERE aseg.activity_type = 'stop'
                    AND aseg.auto_created_from IS NULL
              )
              -- Skip stops that were already auto-segmented by this gap
              AND sc.id NOT IN (
                  SELECT aseg.activity_id FROM activity_segments aseg
                  WHERE aseg.activity_type = 'stop'
                    AND aseg.auto_created_from = p_activity_id
              )
        LOOP
            -- Clean up any existing auto-created segments for this stop from previous gap splits
            IF v_day_approval_id IS NOT NULL THEN
                DELETE FROM activity_overrides
                WHERE day_approval_id = v_day_approval_id
                  AND activity_type = 'stop_segment'
                  AND activity_id IN (
                      SELECT id FROM activity_segments
                      WHERE activity_type = 'stop' AND activity_id = v_stop.id
                  );
            END IF;

            -- Delete parent stop override
            IF v_day_approval_id IS NOT NULL THEN
                DELETE FROM activity_overrides
                WHERE day_approval_id = v_day_approval_id
                  AND activity_type = 'stop'
                  AND activity_id = v_stop.id;
            END IF;

            DELETE FROM activity_segments
            WHERE activity_type = 'stop' AND activity_id = v_stop.id;

            -- Build clamped cut points for this stop
            v_clamped_cuts := ARRAY[]::TIMESTAMPTZ[];
            FOREACH v_cp IN ARRAY v_cut_points LOOP
                -- Only include cut points that fall within the stop bounds (with 1-min margin)
                IF v_cp > v_stop.started_at + INTERVAL '1 minute'
                   AND v_cp < v_stop.ended_at - INTERVAL '1 minute' THEN
                    v_clamped_cuts := array_append(v_clamped_cuts, v_cp);
                END IF;
            END LOOP;

            -- Only create segments if we have at least one valid cut point
            IF array_length(v_clamped_cuts, 1) IS NOT NULL AND array_length(v_clamped_cuts, 1) > 0 THEN
                v_stop_seg_start := v_stop.started_at;
                v_stop_seg_idx := 0;

                FOR v_seg_idx IN 1..array_length(v_clamped_cuts, 1) LOOP
                    v_stop_seg_end := v_clamped_cuts[v_seg_idx];

                    -- Only create segment if >= 1 minute
                    IF (v_stop_seg_end - v_stop_seg_start) >= INTERVAL '1 minute' THEN
                        INSERT INTO activity_segments (id, activity_type, activity_id, employee_id, segment_index, starts_at, ends_at, created_by, auto_created_from)
                        VALUES (
                            md5('stop:' || v_stop.id::TEXT || ':' || v_stop_seg_idx::TEXT)::UUID,
                            'stop',
                            v_stop.id,
                            v_employee_id,
                            v_stop_seg_idx,
                            v_stop_seg_start,
                            v_stop_seg_end,
                            v_caller,
                            p_activity_id
                        );
                        v_stop_seg_idx := v_stop_seg_idx + 1;
                    END IF;

                    v_stop_seg_start := v_stop_seg_end;
                END LOOP;

                -- Last segment: from last cut to stop end
                v_stop_seg_end := v_stop.ended_at;
                IF (v_stop_seg_end - v_stop_seg_start) >= INTERVAL '1 minute' THEN
                    INSERT INTO activity_segments (id, activity_type, activity_id, employee_id, segment_index, starts_at, ends_at, created_by, auto_created_from)
                    VALUES (
                        md5('stop:' || v_stop.id::TEXT || ':' || v_stop_seg_idx::TEXT)::UUID,
                        'stop',
                        v_stop.id,
                        v_employee_id,
                        v_stop_seg_idx,
                        v_stop_seg_start,
                        v_stop_seg_end,
                        v_caller,
                        p_activity_id
                    );
                END IF;
            END IF;
        END LOOP;
    END IF;

    -- Return updated day detail
    SELECT get_day_approval_detail(v_employee_id, v_date) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;

-- 6. unsegment_activity — add lunch support
-- Based on 20260320000000_gap_split_auto_segment_stop.sql version
-- which includes auto-created stop cleanup for gaps
CREATE OR REPLACE FUNCTION unsegment_activity(
    p_activity_type TEXT,
    p_activity_id   UUID
)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
    v_employee_id UUID;
    v_date DATE;
    v_day_approval_id UUID;
    v_segment_type TEXT;
    v_result JSONB;
BEGIN
    -- Auth
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can unsegment activities';
    END IF;

    -- Resolve employee_id and date
    IF p_activity_type = 'stop' THEN
        SELECT employee_id, to_business_date(started_at)
        INTO v_employee_id, v_date
        FROM stationary_clusters WHERE id = p_activity_id;

    ELSIF p_activity_type = 'trip' THEN
        SELECT employee_id, to_business_date(started_at)
        INTO v_employee_id, v_date
        FROM trips WHERE id = p_activity_id;

    ELSIF p_activity_type = 'gap' THEN
        -- Gaps have no source table — read from activity_segments
        SELECT employee_id, to_business_date(starts_at)
        INTO v_employee_id, v_date
        FROM activity_segments
        WHERE activity_type = 'gap' AND activity_id = p_activity_id
        LIMIT 1;

    ELSIF p_activity_type = 'lunch' THEN
        SELECT employee_id, to_business_date(clocked_in_at)
        INTO v_employee_id, v_date
        FROM shifts WHERE id = p_activity_id AND is_lunch = true;

    ELSE
        RAISE EXCEPTION 'Invalid activity type: %', p_activity_type;
    END IF;

    IF v_employee_id IS NULL THEN
        RAISE EXCEPTION 'Activity not found';
    END IF;

    -- Check day not approved
    IF EXISTS (
        SELECT 1 FROM day_approvals
        WHERE employee_id = v_employee_id AND date = v_date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Day is approved. Reopen it before unsegmenting.';
    END IF;

    v_segment_type := p_activity_type || '_segment';

    -- Delete overrides for segments
    SELECT id INTO v_day_approval_id
    FROM day_approvals
    WHERE employee_id = v_employee_id AND date = v_date;

    IF v_day_approval_id IS NOT NULL THEN
        DELETE FROM activity_overrides
        WHERE day_approval_id = v_day_approval_id
          AND activity_type = v_segment_type
          AND activity_id IN (
              SELECT id FROM activity_segments
              WHERE activity_type = p_activity_type AND activity_id = p_activity_id
          );

        -- Clean up auto-created stop segments when unsegmenting a gap
        IF p_activity_type = 'gap' THEN
            -- Delete overrides for auto-created stop segments
            DELETE FROM activity_overrides
            WHERE day_approval_id = v_day_approval_id
              AND activity_type = 'stop_segment'
              AND activity_id IN (
                  SELECT id FROM activity_segments
                  WHERE auto_created_from = p_activity_id
              );
        END IF;
    END IF;

    -- Delete all segments for this activity
    DELETE FROM activity_segments
    WHERE activity_type = p_activity_type AND activity_id = p_activity_id;

    -- Delete auto-created stop segments when unsegmenting a gap
    IF p_activity_type = 'gap' THEN
        DELETE FROM activity_segments
        WHERE auto_created_from = p_activity_id;
    END IF;

    -- Return updated day detail
    SELECT get_day_approval_detail(v_employee_id, v_date) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;


-- =============================================
-- PART 2: Patch _get_day_approval_detail_base
--         via pg_proc string replacement
-- =============================================
DO $outer$
DECLARE
    v_src TEXT;
    v_original TEXT;
BEGIN
    SELECT prosrc INTO v_src
    FROM pg_proc
    WHERE proname = '_get_day_approval_detail_base'
      AND pronamespace = 'public'::regnamespace;

    IF v_src IS NULL THEN
        RAISE EXCEPTION '_get_day_approval_detail_base not found';
    END IF;

    v_original := v_src;

    -- =========================================================================
    -- PATCH A: Replace v_lunch_minutes calculation to be override-aware
    -- Old: simple sum of all lunch shifts
    -- New: exclude approved lunches, exclude segmented lunches, add non-approved
    --      segment durations
    -- =========================================================================
    v_src := replace(
        v_src,
        '-- Calculate lunch minutes from lunch shift segments
    SELECT COALESCE(SUM(
        EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at)) / 60
    )::INTEGER, 0)
    INTO v_lunch_minutes
    FROM shifts s
    WHERE s.employee_id = p_employee_id
      AND s.is_lunch = true
      AND (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date = p_date
      AND s.clocked_out_at IS NOT NULL;',
        '-- Calculate lunch minutes (only non-overridden, non-segmented lunches)
    SELECT COALESCE(SUM(
        EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at)) / 60
    )::INTEGER, 0)
    INTO v_lunch_minutes
    FROM shifts s
    LEFT JOIN day_approvals da ON da.employee_id = s.employee_id
        AND da.date = (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date
    LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
        AND ao.activity_type = ''lunch'' AND ao.activity_id = s.id
    WHERE s.employee_id = p_employee_id
      AND s.is_lunch = true
      AND (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date = p_date
      AND s.clocked_out_at IS NOT NULL
      -- Exclude approved (converted to work)
      AND COALESCE(ao.override_status, ''rejected'') != ''approved''
      -- Exclude segmented (handled below)
      AND s.id NOT IN (SELECT activity_id FROM activity_segments WHERE activity_type = ''lunch'');

    -- Add non-approved segment durations for segmented lunches
    v_lunch_minutes := v_lunch_minutes + COALESCE((
        SELECT SUM(
            EXTRACT(EPOCH FROM (aseg.ends_at - aseg.starts_at)) / 60
        )::INTEGER
        FROM activity_segments aseg
        JOIN shifts s ON s.id = aseg.activity_id AND s.is_lunch = true
        LEFT JOIN day_approvals da ON da.employee_id = aseg.employee_id AND da.date = p_date
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = ''lunch_segment'' AND ao.activity_id = aseg.id
        WHERE aseg.activity_type = ''lunch''
          AND aseg.employee_id = p_employee_id
          AND (aseg.starts_at AT TIME ZONE ''America/Montreal'')::date = p_date
          AND COALESCE(ao.override_status, ''rejected'') != ''approved''
    ), 0);'
    );

    -- =========================================================================
    -- PATCH B: Replace hardcoded override_status/final_status in lunch_data
    -- Old: NULL::TEXT AS override_status, NULL::TEXT AS override_reason,
    --      'rejected'::TEXT AS final_status,
    -- New: ao.override_status, NULL::TEXT AS override_reason,
    --      COALESCE(ao.override_status, 'rejected') AS final_status,
    -- =========================================================================
    v_src := replace(
        v_src,
        '''Pause dîner (non payée)''::TEXT AS auto_reason,
            NULL::TEXT AS override_status,
            NULL::TEXT AS override_reason,
            ''rejected''::TEXT AS final_status,
            NULL::DECIMAL AS distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type,
            NULL::TEXT AS shift_type,
            NULL::TEXT AS shift_type_source,
            FALSE AS is_edited,
            NULL::TIMESTAMPTZ AS original_value,
            -- Children: stops and trips during lunch
            (SELECT jsonb_agg(child ORDER BY child->>''started_at'')',
        '''Pause dîner (non payée)''::TEXT AS auto_reason,
            ao.override_status,
            NULL::TEXT AS override_reason,
            COALESCE(ao.override_status, ''rejected'') AS final_status,
            NULL::DECIMAL AS distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type,
            NULL::TEXT AS shift_type,
            NULL::TEXT AS shift_type_source,
            FALSE AS is_edited,
            NULL::TIMESTAMPTZ AS original_value,
            -- Children: stops and trips during lunch (only when not approved)
            CASE WHEN COALESCE(ao.override_status, ''rejected'') != ''approved'' THEN
                (SELECT jsonb_agg(child ORDER BY child->>''started_at'')'
    );

    -- =========================================================================
    -- PATCH C: Replace FROM shifts s WHERE in lunch_data to add JOINs +
    --          exclude segmented parents + close the CASE WHEN + inject
    --          lunch_segments CTE
    -- Old: ) AS children
    --     FROM shifts s
    --     WHERE s.employee_id = p_employee_id
    --       AND s.is_lunch = true
    --       AND (...)::date = p_date
    --       AND s.clocked_out_at IS NOT NULL
    -- ),
    -- New: ) AS children
    --     ELSE NULL END AS children
    --     FROM shifts s
    --     LEFT JOIN day_approvals da ...
    --     LEFT JOIN activity_overrides ao ...
    --     WHERE ... AND NOT IN segments
    -- ),
    -- lunch_segments AS ( ... ),
    -- =========================================================================
    v_src := replace(
        v_src,
        ') AS children
        FROM shifts s
        WHERE s.employee_id = p_employee_id
          AND s.is_lunch = true
          AND (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date = p_date
          AND s.clocked_out_at IS NOT NULL
    ),',
        ') AS children
            ELSE NULL
            END AS children
        FROM shifts s
        LEFT JOIN day_approvals da
            ON da.employee_id = s.employee_id
            AND da.date = (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date
        LEFT JOIN activity_overrides ao
            ON ao.day_approval_id = da.id
            AND ao.activity_type = ''lunch''
            AND ao.activity_id = s.id
        WHERE s.employee_id = p_employee_id
          AND s.is_lunch = true
          AND (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date = p_date
          AND s.clocked_out_at IS NOT NULL
          -- Exclude segmented lunches (segments are shown instead)
          AND s.id NOT IN (SELECT activity_id FROM activity_segments WHERE activity_type = ''lunch'')
    ),
    lunch_segments AS (
        SELECT
            ''lunch_segment''::TEXT AS activity_type,
            aseg.id AS activity_id,
            s.id AS shift_id,
            aseg.starts_at AS started_at,
            aseg.ends_at AS ended_at,
            (EXTRACT(EPOCH FROM (aseg.ends_at - aseg.starts_at)) / 60)::INTEGER AS duration_minutes,
            NULL::UUID AS matched_location_id,
            NULL::TEXT AS location_name,
            NULL::TEXT AS location_type,
            NULL::DECIMAL AS latitude,
            NULL::DECIMAL AS longitude,
            NULL::INTEGER AS gps_gap_seconds,
            NULL::INTEGER AS gps_gap_count,
            ''rejected''::TEXT AS auto_status,
            ''Pause dîner (non payée)''::TEXT AS auto_reason,
            ao.override_status,
            NULL::TEXT AS override_reason,
            COALESCE(ao.override_status, ''rejected'') AS final_status,
            NULL::DECIMAL AS distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type,
            NULL::TEXT AS shift_type,
            NULL::TEXT AS shift_type_source,
            FALSE AS is_edited,
            NULL::TIMESTAMPTZ AS original_value,
            NULL::JSONB AS children
        FROM activity_segments aseg
        JOIN shifts s ON s.id = aseg.activity_id AND s.is_lunch = true
        LEFT JOIN day_approvals da ON da.employee_id = aseg.employee_id AND da.date = p_date
        LEFT JOIN activity_overrides ao
            ON ao.day_approval_id = da.id
            AND ao.activity_type = ''lunch_segment''
            AND ao.activity_id = aseg.id
        WHERE aseg.activity_type = ''lunch''
          AND aseg.employee_id = p_employee_id
          AND (aseg.starts_at AT TIME ZONE ''America/Montreal'')::date = p_date
    ),'
    );

    -- =========================================================================
    -- PATCH D: Add lunch_segments to the combined activities UNION
    -- Replace the existing Lunch block to add lunch_segments before lunch_data
    -- =========================================================================
    v_src := replace(
        v_src,
        '-- Lunch
        SELECT
            ld.activity_type, ld.activity_id, ld.shift_id,
            ld.started_at, ld.ended_at, ld.duration_minutes,
            ld.matched_location_id, ld.location_name, ld.location_type,
            ld.latitude, ld.longitude, ld.gps_gap_seconds, ld.gps_gap_count,
            ld.auto_status, ld.auto_reason,
            ld.override_status, ld.override_reason, ld.final_status,
            ld.distance_km, ld.transport_mode, ld.has_gps_gap,
            ld.start_location_id, ld.start_location_name, ld.start_location_type,
            ld.end_location_id, ld.end_location_name, ld.end_location_type,
            ld.shift_type, ld.shift_type_source,
            ld.is_edited, ld.original_value,
            ld.children
        FROM lunch_data ld',
        '-- Lunch segments
        SELECT
            ls.activity_type, ls.activity_id, ls.shift_id,
            ls.started_at, ls.ended_at, ls.duration_minutes,
            ls.matched_location_id, ls.location_name, ls.location_type,
            ls.latitude, ls.longitude, ls.gps_gap_seconds, ls.gps_gap_count,
            ls.auto_status, ls.auto_reason,
            ls.override_status, ls.override_reason, ls.final_status,
            ls.distance_km, ls.transport_mode, ls.has_gps_gap,
            ls.start_location_id, ls.start_location_name, ls.start_location_type,
            ls.end_location_id, ls.end_location_name, ls.end_location_type,
            ls.shift_type, ls.shift_type_source,
            ls.is_edited, ls.original_value,
            ls.children
        FROM lunch_segments ls

        UNION ALL

        -- Lunch
        SELECT
            ld.activity_type, ld.activity_id, ld.shift_id,
            ld.started_at, ld.ended_at, ld.duration_minutes,
            ld.matched_location_id, ld.location_name, ld.location_type,
            ld.latitude, ld.longitude, ld.gps_gap_seconds, ld.gps_gap_count,
            ld.auto_status, ld.auto_reason,
            ld.override_status, ld.override_reason, ld.final_status,
            ld.distance_km, ld.transport_mode, ld.has_gps_gap,
            ld.start_location_id, ld.start_location_name, ld.start_location_type,
            ld.end_location_id, ld.end_location_name, ld.end_location_type,
            ld.shift_type, ld.shift_type_source,
            ld.is_edited, ld.original_value,
            ld.children
        FROM lunch_data ld'
    );

    -- =========================================================================
    -- PATCH E: Update summary filters — remove lunch exclusion from
    --          approved_minutes and rejected_minutes.
    -- Current live state (after gap inclusion patch):
    --   approved: a->>'activity_type' <> 'lunch'
    --   rejected: a->>'activity_type' <> 'lunch'
    -- New: no activity_type exclusion — lunch/lunch_segment now participate
    --       in approved/rejected, and gaps remain included (per gap inclusion fix)
    -- =========================================================================
    -- Approved filter: remove the lunch exclusion entirely
    v_src := replace(
        v_src,
        'a->>''final_status'' = ''approved'' AND a->>''activity_type'' <> ''lunch''',
        'a->>''final_status'' = ''approved'''
    );

    -- Rejected filter: remove the lunch exclusion entirely
    v_src := replace(
        v_src,
        'a->>''final_status'' = ''rejected'' AND a->>''activity_type'' <> ''lunch''',
        'a->>''final_status'' = ''rejected'''
    );

    -- =========================================================================
    -- PATCH F: Update needs_review filter to also exclude 'lunch_segment'
    -- Current live state (after microshift patch):
    --   AND a->>'activity_type' NOT IN ('clock_in', 'clock_out', 'lunch')
    -- New: add 'lunch_segment'
    -- =========================================================================
    v_src := replace(
        v_src,
        'AND a->>''activity_type'' NOT IN (''clock_in'', ''clock_out'', ''lunch'')',
        'AND a->>''activity_type'' NOT IN (''clock_in'', ''clock_out'', ''lunch'', ''lunch_segment'')'
    );

    IF v_src = v_original THEN
        RAISE NOTICE 'No changes made to _get_day_approval_detail_base — patterns not found (may already be patched)';
        RETURN;
    END IF;

    EXECUTE format(
        'CREATE OR REPLACE FUNCTION _get_day_approval_detail_base(p_employee_id UUID, p_date DATE) RETURNS JSONB AS %s LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions',
        quote_literal(v_src)
    );

    RAISE NOTICE 'Part 2: Patched _get_day_approval_detail_base — lunch overrides + lunch_segments support';
END;
$outer$;


-- =============================================
-- PART 3: Patch get_weekly_approval_summary
--         Replace day_lunch CTE via pg_proc
-- =============================================
DO $outer$
DECLARE
    v_src TEXT;
    v_original TEXT;
BEGIN
    SELECT prosrc INTO v_src
    FROM pg_proc
    WHERE proname = 'get_weekly_approval_summary'
      AND pronamespace = 'public'::regnamespace;

    IF v_src IS NULL THEN
        RAISE EXCEPTION 'get_weekly_approval_summary not found';
    END IF;

    v_original := v_src;

    -- Replace the simple day_lunch CTE with override-aware version
    v_src := replace(
        v_src,
        '-- Lunch minutes from lunch shift segments
    day_lunch AS (
        SELECT
            s.employee_id,
            (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date AS lunch_date,
            COALESCE(SUM(EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at))::INTEGER / 60), 0) AS lunch_minutes
        FROM shifts s
        WHERE s.is_lunch = true AND s.clocked_out_at IS NOT NULL
          AND (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date BETWEEN p_week_start AND v_week_end
          AND s.employee_id IN (SELECT employee_id FROM employee_list)
        GROUP BY s.employee_id, (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date
    ),',
        '-- Lunch minutes from lunch shift segments (override-aware)
    day_lunch AS (
        SELECT
            s.employee_id,
            (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date AS lunch_date,
            COALESCE(SUM(
                CASE
                    -- Segmented lunch: exclude from this CTE (segments handled separately)
                    WHEN EXISTS (SELECT 1 FROM activity_segments aseg WHERE aseg.activity_type = ''lunch'' AND aseg.activity_id = s.id)
                        THEN 0
                    -- Non-segmented, approved: exclude (converted to work)
                    WHEN COALESCE(ao.override_status, ''rejected'') = ''approved''
                        THEN 0
                    -- Non-segmented, not approved: count as lunch
                    ELSE EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at))::INTEGER / 60
                END
            ), 0)
            -- Add non-approved segment minutes
            + COALESCE((
                SELECT SUM(EXTRACT(EPOCH FROM (aseg2.ends_at - aseg2.starts_at))::INTEGER / 60)
                FROM activity_segments aseg2
                JOIN shifts s2 ON s2.id = aseg2.activity_id AND s2.is_lunch = true AND s2.employee_id = s.employee_id
                LEFT JOIN day_approvals da2 ON da2.employee_id = aseg2.employee_id
                    AND da2.date = (aseg2.starts_at AT TIME ZONE ''America/Montreal'')::date
                LEFT JOIN activity_overrides ao2 ON ao2.day_approval_id = da2.id
                    AND ao2.activity_type = ''lunch_segment'' AND ao2.activity_id = aseg2.id
                WHERE aseg2.activity_type = ''lunch''
                  AND (aseg2.starts_at AT TIME ZONE ''America/Montreal'')::date = (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date
                  AND COALESCE(ao2.override_status, ''rejected'') != ''approved''
            ), 0) AS lunch_minutes
        FROM shifts s
        LEFT JOIN day_approvals da ON da.employee_id = s.employee_id
            AND da.date = (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = ''lunch'' AND ao.activity_id = s.id
        WHERE s.is_lunch = true AND s.clocked_out_at IS NOT NULL
          AND (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date BETWEEN p_week_start AND v_week_end
          AND s.employee_id IN (SELECT employee_id FROM employee_list)
        GROUP BY s.employee_id, (s.clocked_in_at AT TIME ZONE ''America/Montreal'')::date
    ),'
    );

    IF v_src = v_original THEN
        RAISE NOTICE 'No changes made to get_weekly_approval_summary — patterns not found (may already be patched)';
        RETURN;
    END IF;

    EXECUTE format(
        'CREATE OR REPLACE FUNCTION get_weekly_approval_summary(p_week_start DATE) RETURNS JSONB AS %s LANGUAGE plpgsql SECURITY DEFINER',
        quote_literal(v_src)
    );

    RAISE NOTICE 'Part 3: Patched get_weekly_approval_summary — lunch overrides in day_lunch CTE';
END;
$outer$;
