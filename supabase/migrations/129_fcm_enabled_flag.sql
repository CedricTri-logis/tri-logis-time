-- Add FCM kill switch to app_config
-- Set to 'false' initially — enable per-employee after verification
INSERT INTO app_config (key, value)
VALUES ('fcm_enabled', 'false')
ON CONFLICT (key) DO NOTHING;

-- Per-employee override for gradual rollout
-- When fcm_enabled = 'false' globally, only employees with fcm_opt_in = true get FCM
-- When fcm_enabled = 'true' globally, all employees get FCM
ALTER TABLE employee_profiles
  ADD COLUMN IF NOT EXISTS fcm_opt_in BOOLEAN NOT NULL DEFAULT false;
