-- Migration 027: Improve sync_gps_points error handling
-- Catches ALL per-point exceptions (not just unique_violation),
-- returns failed_ids array so client can mark only successful points as synced.

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
                captured_at, device_id
            )
            VALUES (
                (v_client_id)::UUID,
                (v_point->>'shift_id')::UUID,
                v_user_id,
                (v_point->>'latitude')::DECIMAL,
                (v_point->>'longitude')::DECIMAL,
                (v_point->>'accuracy')::DECIMAL,
                (v_point->>'captured_at')::TIMESTAMPTZ,
                v_point->>'device_id'
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
