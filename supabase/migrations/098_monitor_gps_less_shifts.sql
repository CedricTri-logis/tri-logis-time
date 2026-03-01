-- Migration 098: Server-side GPS-less shift monitoring
--
-- Problem: Even with the client-side verification gate, edge cases can allow
-- shifts to run with 0 GPS points (stream crash after verification passes,
-- iOS killing the background task, old app builds). The server has no safety
-- net to detect these ghost shifts.
--
-- Fix: pg_cron job every 10 minutes that auto-closes active shifts with
-- 0 GPS points after 10 minutes of runtime. Uses last_heartbeat_at as
-- the best approximation of clock-out time.

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
    LOOP
        UPDATE shifts SET
            status = 'completed',
            clocked_out_at = COALESCE(v_shift.last_heartbeat_at, NOW()),
            clock_out_reason = 'no_gps_auto_close'
        WHERE id = v_shift.id;

        RAISE NOTICE 'Auto-closed GPS-less shift % for employee %',
            v_shift.id, v_shift.employee_id;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Schedule: every 10 minutes
SELECT cron.schedule(
    'flag-gpsless-shifts',
    '*/10 * * * *',
    $$SELECT flag_gpsless_shifts()$$
);
