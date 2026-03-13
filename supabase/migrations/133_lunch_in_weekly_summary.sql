-- =============================================================================
-- 133: Add lunch_minutes to get_weekly_approval_summary
-- =============================================================================
-- Adds lunch_minutes to each day entry and subtracts from total_shift_minutes.
-- Also includes lunch breaks in gap detection covered periods.
-- =============================================================================

CREATE OR REPLACE FUNCTION get_weekly_approval_summary(
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
        SELECT ep.id AS employee_id, ep.full_name AS employee_name
        FROM employee_profiles ep
        WHERE ep.status = 'active'
        ORDER BY ep.full_name
    ),
    day_shifts AS (
        SELECT
            s.employee_id,
            (s.clocked_in_at AT TIME ZONE 'America/Toronto')::DATE AS shift_date,
            SUM(EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at)) / 60)::INTEGER AS total_shift_minutes,
            bool_or(s.status = 'active') AS has_active_shift
        FROM shifts s
        WHERE (s.clocked_in_at AT TIME ZONE 'America/Toronto')::DATE BETWEEN p_week_start AND v_week_end
          AND s.employee_id IN (SELECT employee_id FROM employee_list)
        GROUP BY s.employee_id, (s.clocked_in_at AT TIME ZONE 'America/Toronto')::DATE
    ),
    -- Lunch minutes per employee per day
    day_lunch AS (
        SELECT
            lb.employee_id,
            (lb.started_at AT TIME ZONE 'America/Toronto')::DATE AS lunch_date,
            COALESCE(SUM(EXTRACT(EPOCH FROM (lb.ended_at - lb.started_at))::INTEGER / 60), 0) AS lunch_minutes
        FROM lunch_breaks lb
        WHERE lb.ended_at IS NOT NULL
          AND (lb.started_at AT TIME ZONE 'America/Toronto')::DATE BETWEEN p_week_start AND v_week_end
          AND lb.employee_id IN (SELECT employee_id FROM employee_list)
        GROUP BY lb.employee_id, (lb.started_at AT TIME ZONE 'America/Toronto')::DATE
    ),
    existing_approvals AS (
        SELECT da.employee_id, da.date, da.status, da.approved_minutes, da.rejected_minutes
        FROM day_approvals da
        WHERE da.date BETWEEN p_week_start AND v_week_end
          AND da.employee_id IN (SELECT employee_id FROM employee_list)
    ),
    completed_shifts AS (
        SELECT s.id AS shift_id, s.employee_id, s.clocked_in_at, s.clocked_out_at
        FROM shifts s
        WHERE (s.clocked_in_at AT TIME ZONE 'America/Toronto')::DATE BETWEEN p_week_start AND v_week_end
          AND s.employee_id IN (SELECT employee_id FROM employee_list)
          AND s.status = 'completed'
          AND s.clocked_out_at IS NOT NULL
    ),
    shift_real_activities AS (
        SELECT sc.shift_id, sc.started_at, sc.ended_at
        FROM stationary_clusters sc
        WHERE sc.started_at::DATE BETWEEN p_week_start AND v_week_end
          AND sc.employee_id IN (SELECT employee_id FROM employee_list)
          AND sc.duration_seconds >= 180
        UNION ALL
        SELECT t.shift_id, t.started_at, t.ended_at
        FROM trips t
        WHERE t.started_at::DATE BETWEEN p_week_start AND v_week_end
          AND t.employee_id IN (SELECT employee_id FROM employee_list)
        UNION ALL
        -- Include lunch breaks as covered periods for gap detection
        SELECT lb.shift_id, lb.started_at, lb.ended_at
        FROM lunch_breaks lb
        WHERE lb.ended_at IS NOT NULL
          AND (lb.started_at AT TIME ZONE 'America/Toronto')::DATE BETWEEN p_week_start AND v_week_end
          AND lb.employee_id IN (SELECT employee_id FROM employee_list)
    ),
    gap_shift_events AS (
        SELECT cs.shift_id, cs.employee_id, cs.clocked_in_at AS event_time, 0 AS event_order
        FROM completed_shifts cs
        UNION ALL
        SELECT ra.shift_id, cs.employee_id, ra.started_at, 2
        FROM shift_real_activities ra
        JOIN completed_shifts cs ON cs.shift_id = ra.shift_id
        UNION ALL
        SELECT ra.shift_id, cs.employee_id, ra.ended_at, 1
        FROM shift_real_activities ra
        JOIN completed_shifts cs ON cs.shift_id = ra.shift_id
        UNION ALL
        SELECT cs.shift_id, cs.employee_id, cs.clocked_out_at, 3
        FROM completed_shifts cs
    ),
    gap_ordered_events AS (
        SELECT
            shift_id, employee_id, event_time, event_order,
            ROW_NUMBER() OVER (PARTITION BY shift_id ORDER BY event_time, event_order) AS rn
        FROM gap_shift_events
    ),
    gap_pairs AS (
        SELECT
            e1.shift_id, e1.employee_id,
            e1.event_time AS gap_started_at, e2.event_time AS gap_ended_at,
            EXTRACT(EPOCH FROM (e2.event_time - e1.event_time))::INTEGER AS gap_seconds
        FROM gap_ordered_events e1
        JOIN gap_ordered_events e2 ON e1.shift_id = e2.shift_id AND e2.rn = e1.rn + 1
        WHERE e1.event_order IN (0, 1) AND e2.event_order IN (2, 3)
          AND EXTRACT(EPOCH FROM (e2.event_time - e1.event_time)) > 300
    ),
    empty_shift_gaps AS (
        SELECT cs.shift_id, cs.employee_id,
            cs.clocked_in_at AS gap_started_at, cs.clocked_out_at AS gap_ended_at,
            EXTRACT(EPOCH FROM (cs.clocked_out_at - cs.clocked_in_at))::INTEGER AS gap_seconds
        FROM completed_shifts cs
        WHERE NOT EXISTS (SELECT 1 FROM shift_real_activities ra WHERE ra.shift_id = cs.shift_id)
          AND NOT EXISTS (SELECT 1 FROM gap_pairs gp WHERE gp.shift_id = cs.shift_id)
          AND EXTRACT(EPOCH FROM (cs.clocked_out_at - cs.clocked_in_at)) > 300
    ),
    all_weekly_gaps AS (
        SELECT * FROM gap_pairs UNION ALL SELECT * FROM empty_shift_gaps
    ),
    live_activity_classification AS (
        SELECT
            sc.employee_id,
            sc.started_at::DATE AS activity_date,
            (sc.duration_seconds / 60)::INTEGER AS duration_minutes,
            COALESCE(ao.override_status,
                CASE
                    WHEN l.location_type IN ('office', 'building') THEN 'approved'
                    WHEN l.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                    ELSE 'needs_review'
                END
            ) AS final_status
        FROM stationary_clusters sc
        LEFT JOIN locations l ON l.id = sc.matched_location_id
        LEFT JOIN day_approvals da ON da.employee_id = sc.employee_id AND da.date = sc.started_at::DATE
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'stop' AND ao.activity_id = sc.id
        WHERE sc.started_at::DATE BETWEEN p_week_start AND v_week_end
          AND sc.employee_id IN (SELECT employee_id FROM employee_list)
          AND sc.duration_seconds >= 180

        UNION ALL

        SELECT
            t.employee_id, t.started_at::DATE, t.duration_minutes,
            COALESCE(ao.override_status,
                CASE
                    WHEN t.has_gps_gap = TRUE THEN 'needs_review'
                    WHEN t.duration_minutes > 60 THEN 'needs_review'
                    WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('office', 'building')
                     AND COALESCE(el.location_type, arr_loc.location_type) IN ('office', 'building') THEN 'approved'
                    WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('home', 'cafe_restaurant', 'other')
                      OR COALESCE(el.location_type, arr_loc.location_type) IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                    ELSE 'needs_review'
                END
            ) AS final_status
        FROM trips t
        LEFT JOIN locations sl ON sl.id = t.start_location_id
        LEFT JOIN locations el ON el.id = t.end_location_id
        LEFT JOIN LATERAL (
            SELECT sc2.matched_location_id FROM stationary_clusters sc2
            WHERE sc2.employee_id = t.employee_id AND sc2.ended_at = t.started_at LIMIT 1
        ) dep_cluster ON t.start_location_id IS NULL
        LEFT JOIN locations dep_loc ON dep_loc.id = dep_cluster.matched_location_id
        LEFT JOIN LATERAL (
            SELECT sc3.matched_location_id FROM stationary_clusters sc3
            WHERE sc3.employee_id = t.employee_id AND sc3.started_at = t.ended_at LIMIT 1
        ) arr_cluster ON t.end_location_id IS NULL
        LEFT JOIN locations arr_loc ON arr_loc.id = arr_cluster.matched_location_id
        LEFT JOIN day_approvals da ON da.employee_id = t.employee_id AND da.date = t.started_at::DATE
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'trip' AND ao.activity_id = t.id
        WHERE t.started_at::DATE BETWEEN p_week_start AND v_week_end
          AND t.employee_id IN (SELECT employee_id FROM employee_list)

        UNION ALL

        SELECT
            g.employee_id, g.gap_started_at::DATE AS activity_date,
            (g.gap_seconds / 60)::INTEGER AS duration_minutes,
            COALESCE(ao.override_status, 'needs_review') AS final_status
        FROM all_weekly_gaps g
        LEFT JOIN day_approvals da ON da.employee_id = g.employee_id AND da.date = g.gap_started_at::DATE
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'gap'
            AND ao.activity_id = md5(g.employee_id::TEXT || '/gap/' || g.gap_started_at::TEXT || '/' || g.gap_ended_at::TEXT)::UUID
    ),
    live_day_totals AS (
        SELECT
            employee_id, activity_date,
            COALESCE(SUM(duration_minutes) FILTER (WHERE final_status = 'approved'), 0)::INTEGER AS live_approved,
            COALESCE(SUM(duration_minutes) FILTER (WHERE final_status = 'rejected'), 0)::INTEGER AS live_rejected,
            COALESCE(COUNT(*) FILTER (WHERE final_status = 'needs_review'), 0)::INTEGER AS live_needs_review_count
        FROM live_activity_classification
        GROUP BY employee_id, activity_date
    ),
    pending_day_stats AS (
        SELECT
            ds.employee_id, ds.shift_date,
            ds.total_shift_minutes,
            ds.has_active_shift,
            ea.status AS approval_status,
            ea.approved_minutes AS frozen_approved,
            ea.rejected_minutes AS frozen_rejected,
            ldt.live_approved, ldt.live_rejected, ldt.live_needs_review_count,
            COALESCE(dl.lunch_minutes, 0) AS lunch_minutes
        FROM day_shifts ds
        LEFT JOIN existing_approvals ea ON ea.employee_id = ds.employee_id AND ea.date = ds.shift_date
        LEFT JOIN live_day_totals ldt ON ldt.employee_id = ds.employee_id AND ldt.activity_date = ds.shift_date
        LEFT JOIN day_lunch dl ON dl.employee_id = ds.employee_id AND dl.lunch_date = ds.shift_date
    )
    SELECT jsonb_agg(
        jsonb_build_object(
            'employee_id', el.employee_id,
            'employee_name', el.employee_name,
            'days', (
                SELECT COALESCE(jsonb_agg(
                    jsonb_build_object(
                        'date', d::DATE,
                        'has_shifts', (pds.total_shift_minutes IS NOT NULL),
                        'has_active_shift', COALESCE(pds.has_active_shift, FALSE),
                        'status', CASE
                            WHEN pds.total_shift_minutes IS NULL THEN 'no_shift'
                            WHEN pds.has_active_shift THEN 'active'
                            WHEN pds.approval_status = 'approved' THEN 'approved'
                            WHEN COALESCE(pds.live_needs_review_count, 0) > 0 THEN 'needs_review'
                            ELSE 'pending'
                        END,
                        'total_shift_minutes', GREATEST(COALESCE(pds.total_shift_minutes, 0) - COALESCE(pds.lunch_minutes, 0), 0),
                        'approved_minutes', CASE
                            WHEN pds.approval_status = 'approved' THEN pds.frozen_approved
                            ELSE COALESCE(pds.live_approved, 0)
                        END,
                        'rejected_minutes', CASE
                            WHEN pds.approval_status = 'approved' THEN pds.frozen_rejected
                            ELSE COALESCE(pds.live_rejected, 0)
                        END,
                        'needs_review_count', CASE
                            WHEN pds.approval_status = 'approved' THEN 0
                            ELSE COALESCE(pds.live_needs_review_count, 0)
                        END,
                        'lunch_minutes', COALESCE(pds.lunch_minutes, 0)
                    )
                    ORDER BY d::DATE
                ), '[]'::JSONB)
                FROM generate_series(p_week_start, v_week_end, INTERVAL '1 day') d
                LEFT JOIN pending_day_stats pds
                    ON pds.employee_id = el.employee_id AND pds.shift_date = d::DATE
            )
        )
        ORDER BY el.employee_name
    )
    INTO v_result
    FROM employee_list el;

    RETURN COALESCE(v_result, '[]'::JSONB);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
