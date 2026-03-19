-- ============================================================
-- Universal Activity Splitting — Schema
-- 1. Drop cluster_segments (empty in prod — 0 rows)
-- 2. Create activity_segments (universal table for all types)
-- 3. Update activity_overrides CHECK constraint
-- ============================================================

-- 1. Drop old table
DROP TABLE IF EXISTS cluster_segments;

-- 2. Create universal table
CREATE TABLE activity_segments (
    id              UUID PRIMARY KEY,
    activity_type   TEXT NOT NULL CHECK (activity_type IN ('stop', 'trip', 'gap')),
    activity_id     UUID NOT NULL,
    employee_id     UUID NOT NULL REFERENCES employee_profiles(id),
    segment_index   INT NOT NULL,
    starts_at       TIMESTAMPTZ NOT NULL,
    ends_at         TIMESTAMPTZ NOT NULL,
    created_by      UUID NOT NULL REFERENCES employee_profiles(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(activity_type, activity_id, segment_index),
    CHECK (ends_at > starts_at)
);

CREATE INDEX idx_activity_segments_lookup
    ON activity_segments (activity_type, activity_id);

CREATE INDEX idx_activity_segments_employee_date
    ON activity_segments (employee_id, starts_at);

ALTER TABLE activity_segments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage activity_segments"
    ON activity_segments FOR ALL
    USING (is_admin_or_super_admin(auth.uid()));

COMMENT ON TABLE activity_segments IS 'ROLE: Stores time-bounded segments when an admin splits an approval activity (stop/trip/gap). STATUTS: Each segment gets independent approval via activity_overrides. REGLES: Max 2 cut points (3 segments). Segment minimum 1 minute. Parent activity disappears from approval timeline when segmented. RELATIONS: activity_type+activity_id references the parent (stationary_clusters, trips, or computed gap hash). employee_id denormalized for gap segments (no source table). TRIGGERS: None.';

-- 3. Update activity_overrides CHECK to include trip_segment and gap_segment
ALTER TABLE activity_overrides
    DROP CONSTRAINT IF EXISTS activity_overrides_activity_type_check;

ALTER TABLE activity_overrides
    ADD CONSTRAINT activity_overrides_activity_type_check
    CHECK (activity_type IN ('trip', 'stop', 'clock_in', 'clock_out', 'gap', 'lunch_start', 'lunch_end', 'lunch', 'stop_segment', 'trip_segment', 'gap_segment'));

-- ============================================================
-- 4. segment_activity — unified split RPC
-- ============================================================
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
BEGIN
    -- Auth
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can segment activities';
    END IF;

    -- Validate activity type
    IF p_activity_type NOT IN ('stop', 'trip', 'gap') THEN
        RAISE EXCEPTION 'Invalid activity type: %. Must be stop, trip, or gap', p_activity_type;
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

    -- Return updated day detail
    SELECT get_day_approval_detail(v_employee_id, v_date) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ============================================================
-- 5. unsegment_activity — unified unsplit RPC
-- ============================================================
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
    END IF;

    -- Delete all segments
    DELETE FROM activity_segments
    WHERE activity_type = p_activity_type AND activity_id = p_activity_id;

    -- Return updated day detail
    SELECT get_day_approval_detail(v_employee_id, v_date) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ============================================================
-- 6. Drop old segment RPCs
-- ============================================================
DROP FUNCTION IF EXISTS segment_cluster(UUID, TIMESTAMPTZ[]);
DROP FUNCTION IF EXISTS unsegment_cluster(UUID);
