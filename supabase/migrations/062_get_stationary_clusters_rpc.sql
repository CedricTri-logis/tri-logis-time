-- =============================================================================
-- 062: get_stationary_clusters RPC for dashboard visualization
-- =============================================================================
-- Returns stationary clusters with employee name and matched location name.
-- Supports filtering by employee, date range, and minimum duration.
-- =============================================================================

CREATE OR REPLACE FUNCTION get_stationary_clusters(
    p_employee_id UUID DEFAULT NULL,
    p_date_from DATE DEFAULT NULL,
    p_date_to DATE DEFAULT NULL,
    p_min_duration_seconds INTEGER DEFAULT 180
)
RETURNS TABLE (
    id UUID,
    shift_id UUID,
    employee_id UUID,
    employee_name TEXT,
    centroid_latitude DECIMAL(10, 8),
    centroid_longitude DECIMAL(11, 8),
    centroid_accuracy DECIMAL(6, 2),
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    duration_seconds INTEGER,
    gps_point_count INTEGER,
    matched_location_id UUID,
    matched_location_name TEXT,
    created_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        sc.id,
        sc.shift_id,
        sc.employee_id,
        ep.full_name::TEXT AS employee_name,
        sc.centroid_latitude,
        sc.centroid_longitude,
        sc.centroid_accuracy,
        sc.started_at,
        sc.ended_at,
        sc.duration_seconds,
        sc.gps_point_count,
        sc.matched_location_id,
        l.name::TEXT AS matched_location_name,
        sc.created_at
    FROM stationary_clusters sc
    JOIN employee_profiles ep ON ep.id = sc.employee_id
    LEFT JOIN locations l ON l.id = sc.matched_location_id
    WHERE (p_employee_id IS NULL OR sc.employee_id = p_employee_id)
      AND (p_date_from IS NULL OR sc.started_at >= p_date_from::TIMESTAMPTZ)
      AND (p_date_to IS NULL OR sc.started_at < (p_date_to + INTERVAL '1 day')::TIMESTAMPTZ)
      AND sc.duration_seconds >= p_min_duration_seconds
    ORDER BY sc.started_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
