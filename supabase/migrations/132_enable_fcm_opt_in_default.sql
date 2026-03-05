-- Enable FCM opt-in by default for all employees (existing + new)
-- The kill switch (app_config.fcm_enabled) remains the master control.

-- Change default for new employees
ALTER TABLE employee_profiles
  ALTER COLUMN fcm_opt_in SET DEFAULT true;

-- Opt-in all existing employees
UPDATE employee_profiles SET fcm_opt_in = true WHERE fcm_opt_in = false;
