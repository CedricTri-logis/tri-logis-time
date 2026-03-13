-- Fix: Drop the old 4-param overload of start_maintenance.
-- The old version (from migration 018) BLOCKS when a cleaning session is active,
-- returning CLEANING_SESSION_ACTIVE error. The new version (from migration 148)
-- auto-closes cleaning sessions before creating the maintenance session.
-- Having both overloads causes PostgREST ambiguity when the app calls with
-- only the base params, potentially routing to the wrong (blocking) version.
-- This results in maintenance sessions being silently rejected and never created
-- on the server — they stay stuck as "pending" in local SQLCipher on the phone.

-- Drop the OLD 4-param overload (keeps the 7-param version with GPS support)
DROP FUNCTION IF EXISTS start_maintenance(UUID, UUID, UUID, UUID);
