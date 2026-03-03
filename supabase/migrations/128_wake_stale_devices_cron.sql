-- =============================================================================
-- 128: pg_cron job to wake stale devices every 2 minutes
-- =============================================================================
-- Calls send-wake-push Edge Function via pg_net. The function finds active
-- shifts with heartbeat > 5 min and sends silent FCM push to wake killed apps.
-- =============================================================================

SELECT cron.schedule(
  'wake-stale-devices',
  '*/2 * * * *',
  $$
  SELECT net.http_post(
    url := 'https://xdyzdclwvhkfwbkrdsiz.supabase.co/functions/v1/send-wake-push',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'service_role_key' LIMIT 1),
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb
  );
  $$
);
