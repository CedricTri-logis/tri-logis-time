-- ============================================================
-- Forward sync: old tables -> work_sessions (one-directional)
-- Active during Phase 1 only. Removed in Phase 3.
-- ============================================================

-- A) cleaning_sessions -> work_sessions
CREATE OR REPLACE FUNCTION sync_cleaning_to_work_sessions()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO work_sessions (
      id, employee_id, shift_id, activity_type, location_type,
      studio_id, status, started_at, completed_at, duration_minutes,
      is_flagged, flag_reason,
      start_latitude, start_longitude, start_accuracy,
      end_latitude, end_longitude, end_accuracy,
      sync_status, created_at, updated_at
    ) VALUES (
      NEW.id, NEW.employee_id, NEW.shift_id, 'cleaning', 'studio',
      NEW.studio_id, NEW.status::text, NEW.started_at, NEW.completed_at, NEW.duration_minutes,
      NEW.is_flagged, NEW.flag_reason,
      NEW.start_latitude, NEW.start_longitude, NEW.start_accuracy,
      NEW.end_latitude, NEW.end_longitude, NEW.end_accuracy,
      'synced', NEW.created_at, NEW.updated_at
    ) ON CONFLICT (id) DO UPDATE SET
      status = EXCLUDED.status,
      completed_at = EXCLUDED.completed_at,
      duration_minutes = EXCLUDED.duration_minutes,
      is_flagged = EXCLUDED.is_flagged,
      flag_reason = EXCLUDED.flag_reason,
      end_latitude = EXCLUDED.end_latitude,
      end_longitude = EXCLUDED.end_longitude,
      end_accuracy = EXCLUDED.end_accuracy,
      updated_at = EXCLUDED.updated_at;
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    UPDATE work_sessions SET
      status = NEW.status::text,
      completed_at = NEW.completed_at,
      duration_minutes = NEW.duration_minutes,
      is_flagged = NEW.is_flagged,
      flag_reason = NEW.flag_reason,
      end_latitude = NEW.end_latitude,
      end_longitude = NEW.end_longitude,
      end_accuracy = NEW.end_accuracy,
      updated_at = NEW.updated_at
    WHERE id = NEW.id;
    RETURN NEW;
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_sync_cleaning_to_work
  AFTER INSERT OR UPDATE ON cleaning_sessions
  FOR EACH ROW EXECUTE FUNCTION sync_cleaning_to_work_sessions();

-- B) maintenance_sessions -> work_sessions
CREATE OR REPLACE FUNCTION sync_maintenance_to_work_sessions()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO work_sessions (
      id, employee_id, shift_id, activity_type, location_type,
      building_id, apartment_id,
      status, started_at, completed_at, duration_minutes,
      notes,
      start_latitude, start_longitude, start_accuracy,
      end_latitude, end_longitude, end_accuracy,
      sync_status, created_at, updated_at
    ) VALUES (
      NEW.id, NEW.employee_id, NEW.shift_id, 'maintenance',
      CASE WHEN NEW.apartment_id IS NOT NULL THEN 'apartment' ELSE 'building' END,
      NEW.building_id, NEW.apartment_id,
      NEW.status::text, NEW.started_at, NEW.completed_at, NEW.duration_minutes,
      NEW.notes,
      NEW.start_latitude, NEW.start_longitude, NEW.start_accuracy,
      NEW.end_latitude, NEW.end_longitude, NEW.end_accuracy,
      COALESCE(NEW.sync_status, 'synced'), NEW.created_at, NEW.updated_at
    ) ON CONFLICT (id) DO UPDATE SET
      status = EXCLUDED.status,
      completed_at = EXCLUDED.completed_at,
      duration_minutes = EXCLUDED.duration_minutes,
      notes = EXCLUDED.notes,
      end_latitude = EXCLUDED.end_latitude,
      end_longitude = EXCLUDED.end_longitude,
      end_accuracy = EXCLUDED.end_accuracy,
      updated_at = EXCLUDED.updated_at;
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    UPDATE work_sessions SET
      status = NEW.status::text,
      completed_at = NEW.completed_at,
      duration_minutes = NEW.duration_minutes,
      notes = NEW.notes,
      end_latitude = NEW.end_latitude,
      end_longitude = NEW.end_longitude,
      end_accuracy = NEW.end_accuracy,
      updated_at = NEW.updated_at
    WHERE id = NEW.id;
    RETURN NEW;
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_sync_maintenance_to_work
  AFTER INSERT OR UPDATE ON maintenance_sessions
  FOR EACH ROW EXECUTE FUNCTION sync_maintenance_to_work_sessions();
