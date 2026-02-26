-- =============================================================================
-- Migration 043: Auto-match pending trips via pg_cron + pg_net
-- =============================================================================
-- Schedules a cron job every 5 minutes that calls the batch-match-trips
-- edge function for any trips with match_status = 'pending'.
-- Requires the service_role_key to be stored in vault (done separately).
-- =============================================================================

-- 1. Enable pg_net for async HTTP calls from PostgreSQL
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

-- 2. Function to check for pending trips and trigger OSRM matching
CREATE OR REPLACE FUNCTION process_pending_trip_matches()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_pending_count INTEGER;
    v_service_key TEXT;
    v_project_url TEXT := 'https://xdyzdclwvhkfwbkrdsiz.supabase.co';
BEGIN
    -- Only proceed if there are pending driving trips to match
    SELECT COUNT(*) INTO v_pending_count
    FROM trips
    WHERE match_status = 'pending'
      AND transport_mode != 'walking';

    IF v_pending_count = 0 THEN
        RETURN;
    END IF;

    -- Retrieve service role key from vault
    SELECT decrypted_secret INTO v_service_key
    FROM vault.decrypted_secrets
    WHERE name = 'service_role_key'
    LIMIT 1;

    IF v_service_key IS NULL THEN
        RAISE WARNING 'service_role_key not found in vault — cannot call batch-match-trips';
        RETURN;
    END IF;

    -- Call the batch-match-trips edge function via pg_net
    PERFORM net.http_post(
        url := v_project_url || '/functions/v1/batch-match-trips',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || v_service_key
        ),
        body := jsonb_build_object('reprocess_failed', true)
    );
END;
$$;

-- 3. Schedule: run every 5 minutes
SELECT cron.schedule(
    'match-pending-trips',
    '*/5 * * * *',
    $$SELECT process_pending_trip_matches()$$
);
