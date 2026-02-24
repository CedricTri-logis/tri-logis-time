-- Migration 036: Auto-close cleaning & maintenance sessions when shift completes
--
-- Problem: When a shift is closed (from dashboard, midnight cleanup, or if the
-- app-level auto-close fails silently), cleaning and maintenance sessions remain
-- stuck as 'in_progress' forever.
--
-- Solution: Database trigger on shifts table that auto-closes all open sessions
-- whenever a shift transitions to 'completed'. This is the safety net regardless
-- of how/where the shift was closed.

CREATE OR REPLACE FUNCTION auto_close_sessions_on_shift_complete()
RETURNS TRIGGER AS $$
DECLARE
  v_session RECORD;
  v_duration NUMERIC;
  v_flags RECORD;
BEGIN
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

-- Trigger fires AFTER update so the shift row is already committed
CREATE TRIGGER trg_auto_close_sessions_on_shift_complete
  AFTER UPDATE ON shifts
  FOR EACH ROW
  EXECUTE FUNCTION auto_close_sessions_on_shift_complete();
