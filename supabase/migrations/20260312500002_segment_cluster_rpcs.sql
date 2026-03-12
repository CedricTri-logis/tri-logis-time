-- ============================================================
-- segment_cluster: Split a stationary cluster into N segments
-- unsegment_cluster: Revert a cluster to its original single block
-- ============================================================

CREATE OR REPLACE FUNCTION segment_cluster(
    p_cluster_id UUID,
    p_cut_points TIMESTAMPTZ[]
)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
    v_cluster RECORD;
    v_employee_id UUID;
    v_date DATE;
    v_cut_points TIMESTAMPTZ[];
    v_segment_start TIMESTAMPTZ;
    v_segment_end TIMESTAMPTZ;
    v_seg_idx INT;
    v_day_approval_id UUID;
    v_result JSONB;
BEGIN
    -- Auth
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can segment clusters';
    END IF;

    -- Get cluster
    SELECT id, employee_id, started_at, ended_at
    INTO v_cluster
    FROM stationary_clusters
    WHERE id = p_cluster_id;

    IF v_cluster IS NULL THEN
        RAISE EXCEPTION 'Stationary cluster not found';
    END IF;

    v_employee_id := v_cluster.employee_id;
    v_date := to_business_date(v_cluster.started_at);

    -- Check day not approved
    IF EXISTS (
        SELECT 1 FROM day_approvals
        WHERE employee_id = v_employee_id AND date = v_date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Day is approved. Reopen it before segmenting.';
    END IF;

    -- Sort and validate cut points
    SELECT array_agg(cp ORDER BY cp) INTO v_cut_points FROM unnest(p_cut_points) cp;

    -- Validate all cut points within bounds
    FOR v_seg_idx IN 1..array_length(v_cut_points, 1) LOOP
        IF v_cut_points[v_seg_idx] <= v_cluster.started_at OR v_cut_points[v_seg_idx] >= v_cluster.ended_at THEN
            RAISE EXCEPTION 'Cut point % is outside cluster bounds [%, %]',
                v_cut_points[v_seg_idx], v_cluster.started_at, v_cluster.ended_at;
        END IF;
    END LOOP;

    -- Validate minimum 1 minute per segment
    v_segment_start := v_cluster.started_at;
    FOR v_seg_idx IN 1..array_length(v_cut_points, 1) LOOP
        IF (v_cut_points[v_seg_idx] - v_segment_start) < INTERVAL '1 minute' THEN
            RAISE EXCEPTION 'Segment % would be less than 1 minute', v_seg_idx - 1;
        END IF;
        v_segment_start := v_cut_points[v_seg_idx];
    END LOOP;
    -- Check last segment
    IF (v_cluster.ended_at - v_segment_start) < INTERVAL '1 minute' THEN
        RAISE EXCEPTION 'Last segment would be less than 1 minute';
    END IF;

    -- Delete existing segments and their overrides
    SELECT id INTO v_day_approval_id
    FROM day_approvals
    WHERE employee_id = v_employee_id AND date = v_date;

    IF v_day_approval_id IS NOT NULL THEN
        -- Delete overrides for existing segments
        DELETE FROM activity_overrides
        WHERE day_approval_id = v_day_approval_id
        AND activity_type = 'stop_segment'
        AND activity_id IN (
            SELECT id FROM cluster_segments WHERE stationary_cluster_id = p_cluster_id
        );

        -- Delete parent cluster override (if any)
        DELETE FROM activity_overrides
        WHERE day_approval_id = v_day_approval_id
        AND activity_type = 'stop'
        AND activity_id = p_cluster_id;
    END IF;

    DELETE FROM cluster_segments WHERE stationary_cluster_id = p_cluster_id;

    -- Create new segments
    v_segment_start := v_cluster.started_at;
    FOR v_seg_idx IN 0..array_length(v_cut_points, 1) LOOP
        IF v_seg_idx < array_length(v_cut_points, 1) THEN
            v_segment_end := v_cut_points[v_seg_idx + 1];
        ELSE
            v_segment_end := v_cluster.ended_at;
        END IF;

        INSERT INTO cluster_segments (id, stationary_cluster_id, segment_index, starts_at, ends_at, created_by)
        VALUES (
            md5(p_cluster_id::TEXT || '-' || v_seg_idx::TEXT)::UUID,
            p_cluster_id,
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

CREATE OR REPLACE FUNCTION unsegment_cluster(p_cluster_id UUID)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
    v_cluster RECORD;
    v_employee_id UUID;
    v_date DATE;
    v_day_approval_id UUID;
    v_result JSONB;
BEGIN
    -- Auth
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can unsegment clusters';
    END IF;

    -- Get cluster
    SELECT id, employee_id, started_at
    INTO v_cluster
    FROM stationary_clusters
    WHERE id = p_cluster_id;

    IF v_cluster IS NULL THEN
        RAISE EXCEPTION 'Stationary cluster not found';
    END IF;

    v_employee_id := v_cluster.employee_id;
    v_date := to_business_date(v_cluster.started_at);

    -- Check day not approved
    IF EXISTS (
        SELECT 1 FROM day_approvals
        WHERE employee_id = v_employee_id AND date = v_date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Day is approved. Reopen it before unsegmenting.';
    END IF;

    -- Delete overrides for segments
    SELECT id INTO v_day_approval_id
    FROM day_approvals
    WHERE employee_id = v_employee_id AND date = v_date;

    IF v_day_approval_id IS NOT NULL THEN
        DELETE FROM activity_overrides
        WHERE day_approval_id = v_day_approval_id
        AND activity_type = 'stop_segment'
        AND activity_id IN (
            SELECT id FROM cluster_segments WHERE stationary_cluster_id = p_cluster_id
        );
    END IF;

    -- Delete all segments
    DELETE FROM cluster_segments WHERE stationary_cluster_id = p_cluster_id;

    -- Return updated day detail
    SELECT get_day_approval_detail(v_employee_id, v_date) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
