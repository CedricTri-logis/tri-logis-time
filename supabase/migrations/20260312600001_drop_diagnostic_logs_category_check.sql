-- Drop the restrictive event_category CHECK on diagnostic_logs.
-- The CHECK only allowed 9 categories but the app already uses 18+.
-- New categories (exitInfo, battery, crash, memory, service, satellite, doze, motion, metrickit)
-- were silently failing on insert.

ALTER TABLE diagnostic_logs DROP CONSTRAINT IF EXISTS diagnostic_logs_event_category_check;
