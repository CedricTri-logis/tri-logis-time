-- ============================================================
-- Migration: Manual Time Corrections
-- Tables: shift_time_edits, cluster_segments
-- Helper: effective_shift_times()
-- Schema changes: activity_overrides CHECK, save_activity_override validation
-- ============================================================

-- 1. shift_time_edits table
CREATE TABLE shift_time_edits (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    shift_id UUID NOT NULL REFERENCES shifts(id) ON DELETE CASCADE,
    field TEXT NOT NULL CHECK (field IN ('clocked_in_at', 'clocked_out_at')),
    old_value TIMESTAMPTZ NOT NULL,
    new_value TIMESTAMPTZ NOT NULL,
    reason TEXT,
    changed_by UUID NOT NULL REFERENCES employee_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_shift_time_edits_shift_id ON shift_time_edits(shift_id);
CREATE INDEX idx_shift_time_edits_lookup ON shift_time_edits(shift_id, field, created_at DESC);

ALTER TABLE shift_time_edits ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage shift_time_edits"
    ON shift_time_edits
    FOR ALL
    USING (is_admin_or_super_admin(auth.uid()))
    WITH CHECK (is_admin_or_super_admin(auth.uid()));

-- 2. cluster_segments table
CREATE TABLE cluster_segments (
    id UUID PRIMARY KEY,  -- deterministic: md5(cluster_id || '-' || segment_index)::UUID
    stationary_cluster_id UUID NOT NULL REFERENCES stationary_clusters(id) ON DELETE CASCADE,
    segment_index INT NOT NULL,
    starts_at TIMESTAMPTZ NOT NULL,
    ends_at TIMESTAMPTZ NOT NULL,
    created_by UUID NOT NULL REFERENCES employee_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(stationary_cluster_id, segment_index)
);

CREATE INDEX idx_cluster_segments_cluster ON cluster_segments(stationary_cluster_id);

ALTER TABLE cluster_segments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage cluster_segments"
    ON cluster_segments
    FOR ALL
    USING (is_admin_or_super_admin(auth.uid()))
    WITH CHECK (is_admin_or_super_admin(auth.uid()));

-- 3. Helper function: effective_shift_times
CREATE OR REPLACE FUNCTION effective_shift_times(p_shift_id UUID)
RETURNS TABLE (
    effective_clocked_in_at TIMESTAMPTZ,
    effective_clocked_out_at TIMESTAMPTZ,
    clock_in_edited BOOLEAN,
    clock_out_edited BOOLEAN
) AS $$
    WITH latest_edits AS (
        SELECT DISTINCT ON (field)
            field,
            new_value
        FROM shift_time_edits
        WHERE shift_id = p_shift_id
        ORDER BY field, created_at DESC
    )
    SELECT
        COALESCE(
            (SELECT new_value FROM latest_edits WHERE field = 'clocked_in_at'),
            s.clocked_in_at
        ) AS effective_clocked_in_at,
        COALESCE(
            (SELECT new_value FROM latest_edits WHERE field = 'clocked_out_at'),
            s.clocked_out_at
        ) AS effective_clocked_out_at,
        EXISTS (SELECT 1 FROM latest_edits WHERE field = 'clocked_in_at') AS clock_in_edited,
        EXISTS (SELECT 1 FROM latest_edits WHERE field = 'clocked_out_at') AS clock_out_edited
    FROM shifts s
    WHERE s.id = p_shift_id;
$$ LANGUAGE sql STABLE;

-- 4. Update activity_overrides CHECK constraint to include 'stop_segment'
ALTER TABLE activity_overrides
    DROP CONSTRAINT IF EXISTS activity_overrides_activity_type_check;

ALTER TABLE activity_overrides
    ADD CONSTRAINT activity_overrides_activity_type_check
    CHECK (activity_type IN ('trip', 'stop', 'clock_in', 'clock_out', 'gap', 'lunch_start', 'lunch_end', 'lunch', 'stop_segment'));

-- 5. Update save_activity_override to accept 'stop_segment'
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

    -- Validate activity type (now includes stop_segment + lunch types)
    IF p_activity_type NOT IN ('trip', 'stop', 'clock_in', 'clock_out', 'gap', 'lunch_start', 'lunch_end', 'lunch', 'stop_segment') THEN
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 6. COMMENT ON for new tables
COMMENT ON TABLE shift_time_edits IS 'ROLE: Audit log of supervisor edits to shift clock-in/out times. STATUTS: Append-only — each row is a historical edit. REGLES: Effective value = latest edit by created_at per (shift_id, field). Original shifts table is never modified. RELATIONS: shift_id → shifts(id). TRIGGERS: None.';
COMMENT ON COLUMN shift_time_edits.field IS 'Which shift timestamp was edited: clocked_in_at or clocked_out_at';
COMMENT ON COLUMN shift_time_edits.old_value IS 'The value before this edit (effective value at time of edit, not necessarily original)';
COMMENT ON COLUMN shift_time_edits.new_value IS 'The new effective value after this edit';
COMMENT ON COLUMN shift_time_edits.changed_by IS 'The admin/supervisor who made the edit';

COMMENT ON TABLE cluster_segments IS 'ROLE: Stores segmentation of stationary clusters into independently approvable parts. STATUTS: Segments exist only when a cluster has been split by a supervisor. REGLES: Deterministic IDs via md5(cluster_id || segment_index). Each segment inherits parent auto_status. Overridable via activity_overrides with type stop_segment. RELATIONS: stationary_cluster_id → stationary_clusters(id). TRIGGERS: None.';
COMMENT ON COLUMN cluster_segments.id IS 'Deterministic UUID: md5(cluster_id || - || segment_index)::UUID for stable references';
COMMENT ON COLUMN cluster_segments.segment_index IS 'Order index: 0, 1, 2... from earliest to latest';
