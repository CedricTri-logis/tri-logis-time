-- Migration 142: Telemetry Phase 1
-- Adds battery_level to gps_points and expands diagnostic_logs categories.

-- 1. Battery level on GPS points
ALTER TABLE gps_points ADD COLUMN IF NOT EXISTS battery_level SMALLINT;
COMMENT ON COLUMN gps_points.battery_level IS 'Battery percentage (0-100) at time of GPS capture';

-- 2. Expand diagnostic_logs event categories
ALTER TABLE diagnostic_logs
  DROP CONSTRAINT IF EXISTS diagnostic_logs_event_category_check;

ALTER TABLE diagnostic_logs
  ADD CONSTRAINT diagnostic_logs_event_category_check
    CHECK (event_category IN (
      'gps', 'shift', 'sync', 'auth', 'permission',
      'lifecycle', 'thermal', 'error', 'network',
      'battery', 'memory', 'crash', 'service',
      'satellite', 'doze', 'motion', 'metrickit'
    ));

-- 3. Update sync_gps_points to accept battery_level
CREATE OR REPLACE FUNCTION sync_gps_points(p_points JSONB)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID;
    v_point JSONB;
    v_inserted INTEGER := 0;
    v_duplicates INTEGER := 0;
    v_errors INTEGER := 0;
    v_failed_ids JSONB := '[]'::JSONB;
    v_client_id TEXT;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Not authenticated');
    END IF;

    FOR v_point IN SELECT * FROM jsonb_array_elements(p_points)
    LOOP
        v_client_id := v_point->>'client_id';
        BEGIN
            INSERT INTO gps_points (
                client_id, shift_id, employee_id,
                latitude, longitude, accuracy,
                captured_at, device_id,
                speed, speed_accuracy,
                heading, heading_accuracy,
                altitude, altitude_accuracy,
                is_mocked, battery_level
            )
            VALUES (
                (v_client_id)::UUID,
                (v_point->>'shift_id')::UUID,
                v_user_id,
                (v_point->>'latitude')::DECIMAL,
                (v_point->>'longitude')::DECIMAL,
                (v_point->>'accuracy')::DECIMAL,
                (v_point->>'captured_at')::TIMESTAMPTZ,
                v_point->>'device_id',
                (v_point->>'speed')::DECIMAL,
                (v_point->>'speed_accuracy')::DECIMAL,
                (v_point->>'heading')::DECIMAL,
                (v_point->>'heading_accuracy')::DECIMAL,
                (v_point->>'altitude')::DECIMAL,
                (v_point->>'altitude_accuracy')::DECIMAL,
                (v_point->>'is_mocked')::BOOLEAN,
                (v_point->>'battery_level')::SMALLINT
            );
            v_inserted := v_inserted + 1;
        EXCEPTION WHEN unique_violation THEN
            v_duplicates := v_duplicates + 1;
        WHEN OTHERS THEN
            v_errors := v_errors + 1;
            v_failed_ids := v_failed_ids || to_jsonb(v_client_id);
        END;
    END LOOP;

    RETURN jsonb_build_object(
        'status', 'success',
        'inserted', v_inserted,
        'duplicates', v_duplicates,
        'errors', v_errors,
        'failed_ids', v_failed_ids
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
