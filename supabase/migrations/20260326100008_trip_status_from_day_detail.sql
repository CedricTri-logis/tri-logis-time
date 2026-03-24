-- Fix: Read trip final_status directly from get_day_approval_detail
-- instead of recalculating from location types (which misses adjacent cluster lookups).
-- This ensures mileage page shows the same approved/rejected status as the day approval page.
SELECT 1; -- Function already updated via MCP apply_migration
