-- Fix: Trip status considers adjacent stop overrides
-- If a stop adjacent to the trip was manually rejected/approved in day approval,
-- that override propagates to the trip status. Applied via MCP.
SELECT 1;
