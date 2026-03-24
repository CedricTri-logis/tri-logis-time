-- Cron safety net: detect_trips on completed shifts that were never processed.
--
-- Finds shifts completed in the last 25 hours with GPS points but no
-- stationary_clusters, and runs detect_trips on each one.
-- Scheduled every 30 minutes via pg_cron.

CREATE OR REPLACE FUNCTION backfill_missing_trip_detection()
RETURNS TABLE(shift_id uuid, employee_name text, status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT s.id AS shift_id, ep.full_name
        FROM shifts s
        JOIN employee_profiles ep ON ep.id = s.employee_id
        WHERE s.status = 'completed'
          AND s.clocked_out_at >= NOW() - INTERVAL '25 hours'
          -- Has GPS points
          AND EXISTS (
              SELECT 1 FROM gps_points gp WHERE gp.shift_id = s.id LIMIT 1
          )
          -- But no stationary clusters at all
          AND NOT EXISTS (
              SELECT 1 FROM stationary_clusters sc WHERE sc.shift_id = s.id LIMIT 1
          )
        ORDER BY s.clocked_out_at DESC
    LOOP
        BEGIN
            PERFORM detect_trips(r.shift_id);
            shift_id := r.shift_id;
            employee_name := r.full_name;
            status := 'ok';
            RETURN NEXT;
        EXCEPTION WHEN OTHERS THEN
            shift_id := r.shift_id;
            employee_name := r.full_name;
            status := 'error: ' || SQLERRM;
            RETURN NEXT;
        END;
    END LOOP;
END;
$$;

-- Schedule every 30 minutes
SELECT cron.schedule(
    'backfill-missing-trip-detection',
    '*/30 * * * *',
    'SELECT * FROM backfill_missing_trip_detection()'
);
