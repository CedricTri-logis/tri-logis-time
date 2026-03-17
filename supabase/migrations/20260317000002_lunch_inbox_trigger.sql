-- =============================================================================
-- Trigger: convert lunch_breaks INSERT/UPDATE into shift splits
-- =============================================================================
-- The lunch_breaks table becomes an "inbox": the Flutter app writes to it as
-- before, but this trigger intercepts each INSERT/UPDATE and converts it into
-- proper shift segments sharing a work_body_id.
--
-- INSERT with ended_at NOT NULL → 3-way split (work → lunch → work)
-- INSERT with ended_at IS NULL  → close work segment, create lunch segment
-- UPDATE ended_at NULL→value    → close lunch segment, create post-lunch segment
-- =============================================================================

CREATE OR REPLACE FUNCTION convert_lunch_to_shift_split()
RETURNS TRIGGER AS $$
DECLARE
  v_shift RECORD;
  v_work_body_id UUID;
  v_lunch_segment_id UUID;
  v_post_lunch_id UUID;
  v_original_status TEXT;
BEGIN
  -- === INSERT TRIGGER ===
  IF TG_OP = 'INSERT' THEN
    -- 1. Find the shift covering this lunch
    -- First try the exact shift_id from the lunch_break row.
    -- If that shift was already split (completed with clock_out_reason='lunch'),
    -- find the latest active work segment in the same work_body_id instead.
    -- This handles the multiple-lunches-per-day case where the Flutter app
    -- still references the original shift_id.
    SELECT * INTO v_shift FROM shifts
    WHERE employee_id = NEW.employee_id
      AND id = NEW.shift_id
      AND clocked_in_at <= NEW.started_at
      AND (clocked_out_at IS NULL OR clocked_out_at >= NEW.started_at);

    -- If parent shift was already split, find the latest active/covering work segment
    IF NOT FOUND OR (v_shift.status = 'completed' AND v_shift.clock_out_reason = 'lunch') THEN
      SELECT * INTO v_shift FROM shifts
      WHERE employee_id = NEW.employee_id
        AND work_body_id = (SELECT work_body_id FROM shifts WHERE id = NEW.shift_id)
        AND is_lunch = false
        AND clocked_in_at <= NEW.started_at
        AND (clocked_out_at IS NULL OR clocked_out_at >= NEW.started_at)
      ORDER BY clocked_in_at DESC
      LIMIT 1;
    END IF;

    IF NOT FOUND THEN
      RETURN NEW; -- No matching shift, skip
    END IF;

    v_original_status := v_shift.status;

    -- 2. Generate work_body_id if not set
    v_work_body_id := COALESCE(v_shift.work_body_id, gen_random_uuid());
    IF v_shift.work_body_id IS NULL THEN
      UPDATE shifts SET work_body_id = v_work_body_id WHERE id = v_shift.id;
    END IF;

    -- 3. Close current segment at lunch start
    UPDATE shifts SET
      clocked_out_at = NEW.started_at,
      clock_out_reason = 'lunch',
      status = 'completed',
      updated_at = NOW()
    WHERE id = v_shift.id;

    -- 4. Create lunch segment
    v_lunch_segment_id := gen_random_uuid();
    INSERT INTO shifts (id, employee_id, work_body_id, is_lunch,
      clocked_in_at, clocked_out_at, clock_out_reason, status,
      shift_type, shift_type_source)
    VALUES (
      v_lunch_segment_id, NEW.employee_id, v_work_body_id, true,
      NEW.started_at,
      CASE WHEN NEW.ended_at IS NOT NULL THEN NEW.ended_at ELSE NULL END,
      CASE WHEN NEW.ended_at IS NOT NULL THEN 'lunch_end' ELSE NULL END,
      CASE WHEN NEW.ended_at IS NOT NULL THEN 'completed' ELSE 'active' END,
      v_shift.shift_type, v_shift.shift_type_source
    );

    -- 5. Create post-lunch work segment (only if lunch has ended)
    IF NEW.ended_at IS NOT NULL THEN
      v_post_lunch_id := gen_random_uuid();
      INSERT INTO shifts (id, employee_id, work_body_id, is_lunch,
        clocked_in_at, clocked_out_at, clock_out_reason, status,
        shift_type, shift_type_source)
      VALUES (
        v_post_lunch_id, NEW.employee_id, v_work_body_id, false,
        NEW.ended_at,
        CASE WHEN v_original_status = 'completed' THEN v_shift.clocked_out_at ELSE NULL END,
        CASE WHEN v_original_status = 'completed' THEN v_shift.clock_out_reason ELSE NULL END,
        v_original_status,
        v_shift.shift_type, v_shift.shift_type_source
      );

      -- 6. Redistribute GPS points to lunch and post-lunch segments
      UPDATE gps_points SET shift_id = v_lunch_segment_id
      WHERE shift_id = v_shift.id
        AND captured_at >= NEW.started_at AND captured_at < NEW.ended_at;

      UPDATE gps_points SET shift_id = v_post_lunch_id
      WHERE shift_id = v_shift.id
        AND captured_at >= NEW.ended_at;

      -- 7. Redistribute work_sessions
      UPDATE work_sessions SET shift_id = v_lunch_segment_id
      WHERE shift_id = v_shift.id
        AND started_at >= NEW.started_at AND started_at < NEW.ended_at;

      UPDATE work_sessions SET shift_id = v_post_lunch_id
      WHERE shift_id = v_shift.id
        AND started_at >= NEW.ended_at;

      -- 8. Delete existing clusters/trips (will be re-detected async)
      DELETE FROM trip_gps_points WHERE trip_id IN (
        SELECT id FROM trips WHERE shift_id = v_shift.id
      );
      DELETE FROM trips WHERE shift_id = v_shift.id;
      DELETE FROM stationary_clusters WHERE shift_id = v_shift.id;
    ELSE
      -- Lunch starting (ended_at NULL): redistribute GPS after lunch start to lunch segment
      UPDATE gps_points SET shift_id = v_lunch_segment_id
      WHERE shift_id = v_shift.id
        AND captured_at >= NEW.started_at;
    END IF;

  -- === UPDATE TRIGGER (lunch ending) ===
  ELSIF TG_OP = 'UPDATE' AND OLD.ended_at IS NULL AND NEW.ended_at IS NOT NULL THEN
    -- Find the active lunch segment
    SELECT * INTO v_shift FROM shifts
    WHERE employee_id = NEW.employee_id
      AND is_lunch = true
      AND work_body_id IS NOT NULL
      AND status = 'active'
      AND clocked_in_at = OLD.started_at
    ORDER BY clocked_in_at DESC LIMIT 1;

    IF NOT FOUND THEN
      RETURN NEW;
    END IF;

    -- Close the lunch segment
    UPDATE shifts SET
      clocked_out_at = NEW.ended_at,
      clock_out_reason = 'lunch_end',
      status = 'completed',
      updated_at = NOW()
    WHERE id = v_shift.id;

    -- Create post-lunch work segment
    v_post_lunch_id := gen_random_uuid();
    INSERT INTO shifts (id, employee_id, work_body_id, is_lunch,
      clocked_in_at, status, shift_type, shift_type_source)
    VALUES (
      v_post_lunch_id, NEW.employee_id, v_shift.work_body_id, false,
      NEW.ended_at, 'active',
      v_shift.shift_type, v_shift.shift_type_source
    );

    -- Redistribute GPS points after lunch end to post-lunch segment
    UPDATE gps_points SET shift_id = v_post_lunch_id
    WHERE shift_id = v_shift.id
      AND captured_at >= NEW.ended_at;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger on INSERT
CREATE TRIGGER trg_lunch_to_shift_split
  AFTER INSERT ON lunch_breaks
  FOR EACH ROW
  EXECUTE FUNCTION convert_lunch_to_shift_split();

-- Trigger on UPDATE (lunch ending)
CREATE TRIGGER trg_lunch_end_to_shift_split
  AFTER UPDATE OF ended_at ON lunch_breaks
  FOR EACH ROW
  WHEN (OLD.ended_at IS NULL AND NEW.ended_at IS NOT NULL)
  EXECUTE FUNCTION convert_lunch_to_shift_split();
