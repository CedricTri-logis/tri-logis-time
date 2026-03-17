-- =============================================================================
-- Update existing triggers for lunch shift-split support
-- =============================================================================

-- A) auto_close_sessions_on_shift_complete: skip lunch clock-outs
-- The employee is returning after lunch, so sessions should stay open.
CREATE OR REPLACE FUNCTION auto_close_sessions_on_shift_complete()
RETURNS TRIGGER AS $$
DECLARE
  v_session RECORD;
  v_duration NUMERIC;
  v_flags RECORD;
BEGIN
  -- Skip auto-close for lunch clock-outs (employee is returning)
  IF NEW.clock_out_reason = 'lunch' OR NEW.clock_out_reason = 'lunch_end' THEN
    RETURN NEW;
  END IF;

  -- Only fire when shift transitions TO completed
  IF NEW.status = 'completed' AND (OLD.status IS DISTINCT FROM 'completed') THEN

    -- Auto-close cleaning sessions
    FOR v_session IN
      SELECT cs.id, cs.started_at, s.studio_type
      FROM cleaning_sessions cs
      JOIN studios s ON cs.studio_id = s.id
      WHERE cs.shift_id = NEW.id
        AND cs.employee_id = NEW.employee_id
        AND cs.status = 'in_progress'
    LOOP
      v_duration := EXTRACT(EPOCH FROM (COALESCE(NEW.clocked_out_at, NOW()) - v_session.started_at)) / 60.0;
      SELECT * INTO v_flags FROM _compute_cleaning_flags(v_session.studio_type, v_duration);

      UPDATE cleaning_sessions
      SET status = 'auto_closed',
          completed_at = COALESCE(NEW.clocked_out_at, NOW()),
          duration_minutes = ROUND(v_duration, 2),
          is_flagged = v_flags.is_flagged,
          flag_reason = v_flags.flag_reason,
          updated_at = NOW()
      WHERE id = v_session.id;
    END LOOP;

    -- Auto-close maintenance sessions
    UPDATE maintenance_sessions
    SET status = 'auto_closed',
        completed_at = COALESCE(NEW.clocked_out_at, NOW()),
        duration_minutes = ROUND(EXTRACT(EPOCH FROM (COALESCE(NEW.clocked_out_at, NOW()) - started_at)) / 60.0, 2),
        updated_at = NOW()
    WHERE shift_id = NEW.id
      AND employee_id = NEW.employee_id
      AND status = 'in_progress';

  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- B) set_shift_type_on_insert: inherit shift_type from work_body_id siblings
CREATE OR REPLACE FUNCTION set_shift_type_on_insert()
RETURNS TRIGGER AS $$
DECLARE
  v_existing RECORD;
  local_hour INTEGER;
BEGIN
  -- If this shift has a work_body_id, inherit from existing segments
  IF NEW.work_body_id IS NOT NULL THEN
    SELECT shift_type, shift_type_source INTO v_existing
    FROM shifts
    WHERE work_body_id = NEW.work_body_id
      AND id != NEW.id
    ORDER BY clocked_in_at ASC
    LIMIT 1;

    IF FOUND AND v_existing.shift_type IS NOT NULL THEN
      NEW.shift_type := v_existing.shift_type;
      NEW.shift_type_source := v_existing.shift_type_source;
      RETURN NEW;
    END IF;
  END IF;

  -- Auto-classify by Montreal hour (existing logic)
  local_hour := EXTRACT(HOUR FROM NEW.clocked_in_at AT TIME ZONE 'America/Montreal');
  IF local_hour >= 17 OR local_hour < 5 THEN
    NEW.shift_type := 'call';
    NEW.shift_type_source := 'auto';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Drop the old trigger and create with updated name
DROP TRIGGER IF EXISTS trg_set_shift_type ON shifts;
DROP TRIGGER IF EXISTS trg_set_shift_type_on_insert ON shifts;

CREATE TRIGGER trg_set_shift_type_on_insert
  BEFORE INSERT ON shifts
  FOR EACH ROW
  EXECUTE FUNCTION set_shift_type_on_insert();

-- C) flag_gpsless_shifts: skip post-lunch segments (recently split)
CREATE OR REPLACE FUNCTION flag_gpsless_shifts()
RETURNS void AS $$
DECLARE
    v_shift RECORD;
BEGIN
    FOR v_shift IN
        SELECT s.id, s.employee_id, s.clocked_in_at, s.last_heartbeat_at
        FROM shifts s
        WHERE s.status = 'active'
          AND s.clocked_in_at < NOW() - INTERVAL '10 minutes'
          AND NOT EXISTS (
              SELECT 1 FROM gps_points gp WHERE gp.shift_id = s.id
          )
          -- Skip post-lunch segments that were just created (GPS will flow in soon)
          AND NOT (
            s.work_body_id IS NOT NULL
            AND EXISTS (
              SELECT 1 FROM shifts s2
              WHERE s2.work_body_id = s.work_body_id
                AND s2.clock_out_reason = 'lunch'
                AND s2.clocked_out_at > NOW() - INTERVAL '30 minutes'
            )
          )
    LOOP
        UPDATE shifts SET
            status = 'completed',
            clocked_out_at = COALESCE(v_shift.last_heartbeat_at, NOW()),
            clock_out_reason = 'no_gps_auto_close'
        WHERE id = v_shift.id;

        -- Run trip/cluster detection so clock_in/out_location_id gets set
        PERFORM detect_trips(v_shift.id);

        RAISE NOTICE 'Auto-closed GPS-less shift % for employee %',
            v_shift.id, v_shift.employee_id;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
