-- ============================================================================
-- Manual Time Entries table + RLS + constraint updates
-- ============================================================================

-- Table
CREATE TABLE manual_time_entries (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id     UUID NOT NULL REFERENCES employee_profiles(id),
    date            DATE NOT NULL,
    starts_at       TIMESTAMPTZ NOT NULL,
    ends_at         TIMESTAMPTZ NOT NULL,
    reason          TEXT NOT NULL,
    shift_id        UUID REFERENCES shifts(id) ON DELETE CASCADE,
    shift_time_edit_id UUID REFERENCES shift_time_edits(id) ON DELETE CASCADE,
    location_id     UUID REFERENCES locations(id) ON DELETE SET NULL,
    created_by      UUID NOT NULL REFERENCES employee_profiles(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (ends_at > starts_at),
    UNIQUE(shift_time_edit_id)
);

CREATE INDEX idx_manual_time_entries_employee_date ON manual_time_entries(employee_id, date);
CREATE INDEX idx_manual_time_entries_shift ON manual_time_entries(shift_id) WHERE shift_id IS NOT NULL;

-- RLS
ALTER TABLE manual_time_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins full access" ON manual_time_entries
    FOR ALL USING (
        EXISTS (SELECT 1 FROM employee_profiles WHERE id = auth.uid() AND role IN ('admin', 'super_admin'))
    );

CREATE POLICY "Employees read own" ON manual_time_entries
    FOR SELECT USING (employee_id = auth.uid());

-- Schema context
COMMENT ON TABLE manual_time_entries IS
'ROLE: Stores manually-added time segments created by admins.
STATUTS: Active row = visible in approval timeline. Deletion = permanent removal.
REGLES: Two modes: (1) shift_id NOT NULL = clock extension segment within existing shift,
(2) shift_id NULL = standalone manual shift (own quart container).
Reason is always mandatory. Default approval status is needs_review.
RELATIONS: employee_profiles (employee), shifts (optional parent), shift_time_edits (optional audit link), locations (optional project).
TRIGGERS: None.';

COMMENT ON COLUMN manual_time_entries.shift_id IS 'When NOT NULL: clock extension attached to this shift. When NULL: standalone manual quart.';
COMMENT ON COLUMN manual_time_entries.shift_time_edit_id IS 'Links to the shift_time_edits audit row that triggered this manual entry (clock extensions only).';

-- Update activity_overrides CHECK constraint to allow 'manual_time'
ALTER TABLE activity_overrides DROP CONSTRAINT IF EXISTS activity_overrides_activity_type_check;
ALTER TABLE activity_overrides ADD CONSTRAINT activity_overrides_activity_type_check
    CHECK (activity_type IN (
        'trip', 'stop', 'clock_in', 'clock_out', 'gap',
        'lunch_start', 'lunch_end', 'lunch',
        'stop_segment', 'trip_segment', 'gap_segment',
        'lunch_segment', 'manual_time'
    ));
