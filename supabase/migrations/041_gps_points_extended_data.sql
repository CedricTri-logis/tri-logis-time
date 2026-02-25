-- Migration 041: Add extended GPS data columns to gps_points
-- Captures speed, heading, altitude, and mock detection for richer tracking data.

-- Add new columns (all nullable — older app versions won't send them)
ALTER TABLE gps_points ADD COLUMN IF NOT EXISTS speed DECIMAL;
ALTER TABLE gps_points ADD COLUMN IF NOT EXISTS speed_accuracy DECIMAL;
ALTER TABLE gps_points ADD COLUMN IF NOT EXISTS heading DECIMAL;
ALTER TABLE gps_points ADD COLUMN IF NOT EXISTS heading_accuracy DECIMAL;
ALTER TABLE gps_points ADD COLUMN IF NOT EXISTS altitude DECIMAL;
ALTER TABLE gps_points ADD COLUMN IF NOT EXISTS altitude_accuracy DECIMAL;
ALTER TABLE gps_points ADD COLUMN IF NOT EXISTS is_mocked BOOLEAN;

COMMENT ON COLUMN gps_points.speed IS 'Speed in m/s from device GPS';
COMMENT ON COLUMN gps_points.speed_accuracy IS 'Speed accuracy in m/s';
COMMENT ON COLUMN gps_points.heading IS 'Heading/bearing in degrees (0-360)';
COMMENT ON COLUMN gps_points.heading_accuracy IS 'Heading accuracy in degrees';
COMMENT ON COLUMN gps_points.altitude IS 'Altitude in meters above sea level';
COMMENT ON COLUMN gps_points.altitude_accuracy IS 'Altitude accuracy in meters';
COMMENT ON COLUMN gps_points.is_mocked IS 'Whether location was mocked/faked (Android only)';

-- Update sync_gps_points RPC to accept the new fields
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
                is_mocked
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
                (v_point->>'is_mocked')::BOOLEAN
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
