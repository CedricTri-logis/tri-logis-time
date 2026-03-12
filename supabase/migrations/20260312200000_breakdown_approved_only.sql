-- Fix: Répartition breakdown should show only APPROVED activities, not all non-rejected ones.
-- Previously used "final_status != 'rejected'" which included needs_review/pending.

CREATE OR REPLACE FUNCTION get_weekly_breakdown_totals(
    p_week_start DATE
)
RETURNS JSONB AS $$
DECLARE
    v_week_end DATE := p_week_start + INTERVAL '6 days';
    v_result JSONB;
BEGIN
    IF EXTRACT(ISODOW FROM p_week_start) != 1 THEN
        RAISE EXCEPTION 'p_week_start must be a Monday, got %', p_week_start;
    END IF;

    WITH employee_list AS (
        SELECT ep.id AS employee_id
        FROM employee_profiles ep
        WHERE ep.status = 'active'
    ),
    -- Classified stops with location_type
    classified_stops AS (
        SELECT
            COALESCE(l.location_type::TEXT, '_unmatched') AS location_type,
            sc.duration_seconds,
            COALESCE(ao.override_status,
                CASE
                    WHEN l.location_type IN ('office', 'building') THEN 'approved'
                    WHEN l.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                    ELSE 'needs_review'
                END
            ) AS final_status
        FROM stationary_clusters sc
        LEFT JOIN locations l ON l.id = sc.matched_location_id
        LEFT JOIN day_approvals da ON da.employee_id = sc.employee_id AND da.date = to_business_date(sc.started_at)
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'stop' AND ao.activity_id = sc.id
        WHERE to_business_date(sc.started_at) BETWEEN p_week_start AND v_week_end
          AND sc.employee_id IN (SELECT employee_id FROM employee_list)
          AND sc.duration_seconds >= 180
    ),
    -- Classified trips
    classified_trips AS (
        SELECT
            t.duration_minutes * 60 AS duration_seconds,
            COALESCE(ao.override_status,
                CASE
                    WHEN t.has_gps_gap = TRUE THEN 'needs_review'
                    WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('office', 'building', 'vendor', 'gaz')
                     AND COALESCE(el.location_type, arr_loc.location_type) IN ('office', 'building', 'vendor', 'gaz') THEN
                        CASE
                            WHEN t.expected_distance_km IS NOT NULL AND t.distance_km > 2.0 * t.expected_distance_km THEN 'needs_review'
                            WHEN t.expected_duration_seconds IS NOT NULL AND t.duration_minutes > 2.0 * (t.expected_duration_seconds / 60.0) THEN 'needs_review'
                            ELSE 'approved'
                        END
                    WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('home', 'cafe_restaurant', 'other')
                      OR COALESCE(el.location_type, arr_loc.location_type) IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                    WHEN (
                        COALESCE(sl.location_type, dep_loc.location_type) IN ('office', 'building', 'vendor', 'gaz')
                        AND COALESCE(el.location_type, arr_loc.location_type) IS NULL
                        AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.started_at > t.started_at)
                    ) OR (
                        COALESCE(sl.location_type, dep_loc.location_type) IS NULL
                        AND COALESCE(el.location_type, arr_loc.location_type) IN ('office', 'building', 'vendor', 'gaz')
                        AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.ended_at < t.ended_at)
                    ) THEN 'rejected'
                    WHEN t.duration_minutes > 30 THEN 'needs_review'
                    WHEN t.distance_km > 10 THEN 'needs_review'
                    WHEN haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) > 0.1
                     AND t.distance_km / GREATEST(haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude), 0.01) > 2.0
                        THEN 'needs_review'
                    WHEN haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) > 2.0
                     AND haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude)
                         / GREATEST(t.duration_minutes / 60.0, 0.01) > 130 THEN 'needs_review'
                    WHEN haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude) > 2.0
                     AND haversine_km(t.start_latitude, t.start_longitude, t.end_latitude, t.end_longitude)
                         / GREATEST(t.duration_minutes / 60.0, 0.01) < 5 THEN 'needs_review'
                    ELSE 'needs_review'
                END
            ) AS final_status
        FROM trips t
        LEFT JOIN locations sl ON sl.id = t.start_location_id
        LEFT JOIN locations el ON el.id = t.end_location_id
        LEFT JOIN LATERAL (
            SELECT sc2.matched_location_id
            FROM stationary_clusters sc2
            WHERE sc2.employee_id = t.employee_id
              AND sc2.ended_at = t.started_at
            LIMIT 1
        ) dep_cluster ON t.start_location_id IS NULL
        LEFT JOIN locations dep_loc ON dep_loc.id = dep_cluster.matched_location_id
        LEFT JOIN LATERAL (
            SELECT sc3.matched_location_id
            FROM stationary_clusters sc3
            WHERE sc3.employee_id = t.employee_id
              AND sc3.started_at = t.ended_at
            LIMIT 1
        ) arr_cluster ON t.end_location_id IS NULL
        LEFT JOIN locations arr_loc ON arr_loc.id = arr_cluster.matched_location_id
        LEFT JOIN day_approvals da ON da.employee_id = t.employee_id AND da.date = to_business_date(t.started_at)
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'trip' AND ao.activity_id = t.id
        WHERE to_business_date(t.started_at) BETWEEN p_week_start AND v_week_end
          AND t.employee_id IN (SELECT employee_id FROM employee_list)
    ),
    -- Aggregate stop breakdown by type (APPROVED only)
    stop_totals AS (
        SELECT
            location_type,
            SUM(duration_seconds)::INTEGER AS total_seconds
        FROM classified_stops
        WHERE final_status = 'approved'
        GROUP BY location_type
    ),
    -- Aggregate travel total (APPROVED only)
    trip_total AS (
        SELECT COALESCE(SUM(duration_seconds), 0)::INTEGER AS total_seconds
        FROM classified_trips
        WHERE final_status = 'approved'
    )
    SELECT jsonb_build_object(
        'travel_seconds', (SELECT total_seconds FROM trip_total),
        'stop_by_type', COALESCE(
            (SELECT jsonb_object_agg(location_type, total_seconds) FROM stop_totals),
            '{}'::JSONB
        )
    )
    INTO v_result;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
