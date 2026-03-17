-- Add shift-split columns
ALTER TABLE shifts ADD COLUMN work_body_id UUID;
ALTER TABLE shifts ADD COLUMN is_lunch BOOLEAN NOT NULL DEFAULT false;

-- Indexes for efficient querying
CREATE INDEX idx_shifts_work_body_id ON shifts (work_body_id, is_lunch) WHERE work_body_id IS NOT NULL;
CREATE INDEX idx_shifts_is_lunch ON shifts (employee_id, clocked_in_at) WHERE is_lunch = true;

-- Column comments
COMMENT ON COLUMN shifts.work_body_id IS 'Groups shift segments from the same work day. NULL = simple shift without breaks. Set when a lunch split occurs.';
COMMENT ON COLUMN shifts.is_lunch IS 'TRUE for lunch break segments. GPS continues during lunch but activities are auto-rejected in approvals.';
