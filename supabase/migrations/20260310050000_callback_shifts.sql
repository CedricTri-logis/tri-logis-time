-- Migration: Callback shifts (rappels au travail)
-- Adds shift_type detection for callback shifts per Article 58 LNT Quebec
-- Auto-detects shifts clocked in between 17:00-05:00 (America/Montreal)

-- 1. Add columns to shifts
ALTER TABLE shifts ADD COLUMN shift_type TEXT NOT NULL DEFAULT 'regular';
ALTER TABLE shifts ADD COLUMN shift_type_source TEXT NOT NULL DEFAULT 'auto';
ALTER TABLE shifts ADD COLUMN shift_type_changed_by UUID REFERENCES employee_profiles(id);

-- Add CHECK constraints
ALTER TABLE shifts ADD CONSTRAINT chk_shift_type CHECK (shift_type IN ('regular', 'call'));
ALTER TABLE shifts ADD CONSTRAINT chk_shift_type_source CHECK (shift_type_source IN ('auto', 'manual'));

-- Index for filtering call shifts
CREATE INDEX idx_shifts_type ON shifts(shift_type) WHERE shift_type = 'call';

-- 2. Trigger: auto-detect callback on insert
CREATE OR REPLACE FUNCTION set_shift_type_on_insert()
RETURNS TRIGGER AS $$
DECLARE
  local_hour INTEGER;
BEGIN
  -- Extract hour in Montreal timezone
  local_hour := EXTRACT(HOUR FROM NEW.clocked_in_at AT TIME ZONE 'America/Montreal');
  -- Between 17:00 (17) and 04:59 (< 5) = callback
  IF local_hour >= 17 OR local_hour < 5 THEN
    NEW.shift_type := 'call';
    NEW.shift_type_source := 'auto';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_set_shift_type
  BEFORE INSERT ON shifts
  FOR EACH ROW EXECUTE FUNCTION set_shift_type_on_insert();

-- 3. RPC: update_shift_type (supervisor override)
CREATE OR REPLACE FUNCTION update_shift_type(
  p_shift_id UUID,
  p_shift_type TEXT,
  p_changed_by UUID
)
RETURNS JSONB AS $$
BEGIN
  IF p_shift_type NOT IN ('regular', 'call') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid shift_type: must be regular or call');
  END IF;

  UPDATE shifts
  SET shift_type = p_shift_type,
      shift_type_source = 'manual',
      shift_type_changed_by = p_changed_by
  WHERE id = p_shift_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Shift not found');
  END IF;

  RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. Comments
COMMENT ON COLUMN shifts.shift_type IS 'ROLE: Type de quart | VALUES: regular (normal), call (rappel au travail Art.58 LNT) | DEFAULT: regular | TRIGGER: auto-set to call when clocked_in_at between 17h-5h Montreal';
COMMENT ON COLUMN shifts.shift_type_source IS 'ROLE: Source de la classification | VALUES: auto (trigger), manual (superviseur) | DEFAULT: auto';
COMMENT ON COLUMN shifts.shift_type_changed_by IS 'ROLE: Superviseur ayant modifié la classification | NULL si auto-détecté';
COMMENT ON FUNCTION set_shift_type_on_insert IS 'Auto-detects callback shifts: clocked_in_at between 17:00-04:59 America/Montreal = call';
COMMENT ON FUNCTION update_shift_type IS 'Supervisor override to change shift classification between regular and call';
