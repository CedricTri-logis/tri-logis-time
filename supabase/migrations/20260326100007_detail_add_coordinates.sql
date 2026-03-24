-- Add start/end coordinates to get_mileage_approval_detail for reverse geocoding
-- This migration was applied via MCP; this file is for version control only.
-- The full function definition is in 20260326100006_trip_status_from_day_approval.sql
-- with the addition of t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude
-- in the SELECT list.
SELECT 1; -- no-op: function already updated via MCP apply_migration
