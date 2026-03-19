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
