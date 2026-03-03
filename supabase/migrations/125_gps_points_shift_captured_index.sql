-- =============================================================================
-- 125: Add composite index on gps_points (shift_id, captured_at DESC)
-- =============================================================================
-- The get_team_active_status RPC was timing out (25s) because the lateral join
-- for "latest GPS point per shift" used idx_gps_points_captured_at and filtered
-- by shift_id, scanning ~3000 rows per shift. The composite index enables an
-- Index Only Scan, reducing execution from 25s to 68ms.
-- =============================================================================

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_gps_points_shift_captured
ON gps_points (shift_id, captured_at DESC);
