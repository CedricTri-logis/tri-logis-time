-- ============================================================
-- Update weekly RPCs for time corrections
-- Changes:
-- 1. get_weekly_approval_summary: effective times + segments
-- 2. get_weekly_breakdown_totals: segment override support
-- ============================================================

-- 1. get_weekly_approval_summary
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
    -- [CHANGE A] Use effective times for shift duration
    day_shifts AS (
        SELECT
            s.employee_id,
            s.clocked_in_at::DATE AS shift_date,
            SUM(EXTRACT(EPOCH FROM (COALESCE(est.effective_clocked_out_at, s.clocked_out_at) - est.effective_clocked_in_at)) / 60)::INTEGER AS total_shift_minutes,
            bool_or(s.status = 'active') AS has_active_shift
        FROM shifts s
        CROSS JOIN LATERAL effective_shift_times(s.id) est
        WHERE s.clocked_in_at::DATE BETWEEN p_week_start AND v_week_end
          AND s.employee_id IN (SELECT employee_id FROM employee_list)
        GROUP BY s.employee_id, s.clocked_in_at::DATE
    ),
    day_lunch AS (
        SELECT
            lb.employee_id,
            lb.started_at::DATE AS lunch_date,
            COALESCE(SUM(EXTRACT(EPOCH FROM (lb.ended_at - lb.started_at))::INTEGER / 60), 0) AS lunch_minutes
        FROM lunch_breaks lb
        WHERE lb.ended_at IS NOT NULL
          AND lb.started_at::DATE BETWEEN p_week_start AND v_week_end
          AND lb.employee_id IN (SELECT employee_id FROM employee_list)
        GROUP BY lb.employee_id, lb.started_at::DATE
    ),
    day_calls_lagged AS (
        SELECT
            employee_id,
            clocked_in_at::DATE AS call_date,
            clocked_in_at,
            clocked_out_at,
            LAG(clocked_in_at) OVER w AS prev_clocked_in_at,
            LAG(clocked_out_at) OVER w AS prev_clocked_out_at
        FROM shifts
        WHERE shift_type = 'call'
          AND status = 'completed'
          AND clocked_in_at::DATE BETWEEN p_week_start AND v_week_end
          AND employee_id IN (SELECT employee_id FROM employee_list)
        WINDOW w AS (PARTITION BY employee_id, clocked_in_at::DATE ORDER BY clocked_in_at)
    ),
    day_calls AS (
        SELECT
            employee_id, call_date, clocked_in_at, clocked_out_at,
            SUM(CASE
                WHEN prev_clocked_in_at IS NULL THEN 1
                WHEN clocked_in_at >= GREATEST(prev_clocked_in_at + INTERVAL '3 hours', prev_clocked_out_at) THEN 1
                ELSE 0
            END) OVER (PARTITION BY employee_id, call_date ORDER BY clocked_in_at) AS group_id
        FROM day_calls_lagged
    ),
    day_call_groups AS (
        SELECT
            employee_id, call_date, group_id,
            COUNT(*) AS shifts_in_group,
            GREATEST(EXTRACT(EPOCH FROM (MAX(clocked_out_at) - MIN(clocked_in_at))) / 60, 180)::INTEGER AS group_billed_minutes,
            GREATEST(0, 180 - EXTRACT(EPOCH FROM (MAX(clocked_out_at) - MIN(clocked_in_at))) / 60)::INTEGER AS group_bonus_minutes
        FROM day_calls
        GROUP BY employee_id, call_date, group_id
    ),
    day_call_totals AS (
        SELECT
            employee_id, call_date,
            SUM(shifts_in_group)::INTEGER AS call_count,
            SUM(group_billed_minutes)::INTEGER AS call_billed_minutes,
            SUM(group_bonus_minutes)::INTEGER AS call_bonus_minutes
        FROM day_call_groups
        GROUP BY employee_id, call_date
    ),
    existing_approvals AS (
        SELECT da.employee_id, da.date, da.status, da.approved_minutes, da.rejected_minutes
        FROM day_approvals da
        WHERE da.date BETWEEN p_week_start AND v_week_end
          AND da.employee_id IN (SELECT employee_id FROM employee_list)
    ),
    live_stop_classification AS (
        SELECT
            sc.employee_id,
            sc.started_at::DATE AS activity_date,
            sc.id AS activity_id,
            sc.started_at,
            sc.ended_at,
            (sc.duration_seconds / 60)::INTEGER AS duration_minutes,
            COALESCE(ao.override_status,
                CASE
                    WHEN l.location_type IN ('office', 'building') THEN 'approved'
                    WHEN l.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                    WHEN l.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                    ELSE 'rejected'
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
    ),
    -- [CHANGE C] Segment classification
    live_segment_classification AS (
        SELECT
            sc.employee_id,
            cs.starts_at::DATE AS activity_date,
            cs.id AS activity_id,
            cs.starts_at AS started_at,
            cs.ends_at AS ended_at,
            EXTRACT(EPOCH FROM (cs.ends_at - cs.starts_at))::INTEGER / 60 AS duration_minutes,
            COALESCE(ao.override_status,
                CASE
                    WHEN l.location_type IN ('office', 'building') THEN 'approved'
                    WHEN l.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                    WHEN l.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                    ELSE 'rejected'
                END
            ) AS final_status
        FROM cluster_segments cs
        JOIN stationary_clusters sc ON sc.id = cs.stationary_cluster_id
        LEFT JOIN locations l ON l.id = sc.matched_location_id
        LEFT JOIN day_approvals da ON da.employee_id = sc.employee_id AND da.date = cs.starts_at::DATE
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'stop_segment' AND ao.activity_id = cs.id
        WHERE cs.starts_at::DATE BETWEEN p_week_start AND v_week_end
          AND sc.employee_id IN (SELECT employee_id FROM employee_list)
    ),
    -- Union: non-segmented stops + segments
    live_all_stops AS (
        SELECT * FROM live_stop_classification
        WHERE activity_id NOT IN (SELECT DISTINCT stationary_cluster_id FROM cluster_segments)
        UNION ALL
        SELECT * FROM live_segment_classification
    ),
    live_trip_classification AS (
        SELECT
            t.employee_id,
            t.started_at::DATE AS activity_date,
            t.started_at,
            t.ended_at,
            t.duration_minutes,
            COALESCE(ao.override_status,
                CASE
                    WHEN lunch_adj.id IS NOT NULL THEN 'rejected'
                    WHEN t.has_gps_gap = TRUE THEN
                        CASE
                            WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'rejected'
                            WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'approved'
                            WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL
                                 AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.started_at > t.started_at) THEN 'rejected'
                            WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL
                                 AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.ended_at < t.ended_at) THEN 'rejected'
                            WHEN dep_stop.final_status IS NULL OR arr_stop.final_status IS NULL THEN 'needs_review'
                            ELSE 'needs_review'
                        END
                    WHEN t.duration_minutes > 60 THEN 'needs_review'
                    WHEN dep_stop.final_status = 'rejected' OR arr_stop.final_status = 'rejected' THEN 'rejected'
                    WHEN dep_stop.final_status = 'approved' AND arr_stop.final_status = 'approved' THEN 'approved'
                    WHEN dep_stop.final_status IS NOT NULL AND arr_stop.final_status IS NULL
                         AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.started_at > t.started_at) THEN 'rejected'
                    WHEN arr_stop.final_status IS NOT NULL AND dep_stop.final_status IS NULL
                         AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.shift_id = t.shift_id AND t2.ended_at < t.ended_at) THEN 'rejected'
                    WHEN dep_stop.final_status IS NULL OR arr_stop.final_status IS NULL THEN 'needs_review'
                    ELSE 'needs_review'
                END
            ) AS final_status
        FROM trips t
        -- [CHANGE C] Use live_all_stops for trip adjacency
        LEFT JOIN LATERAL (
            SELECT ls.final_status
            FROM live_all_stops ls
            WHERE ls.employee_id = t.employee_id
              AND ls.ended_at BETWEEN t.started_at - INTERVAL '2 minutes' AND t.started_at + INTERVAL '2 minutes'
            ORDER BY ABS(EXTRACT(EPOCH FROM (ls.ended_at - t.started_at)))
            LIMIT 1
        ) dep_stop ON TRUE
        LEFT JOIN LATERAL (
            SELECT ls.final_status
            FROM live_all_stops ls
            WHERE ls.employee_id = t.employee_id
              AND ls.started_at BETWEEN t.ended_at - INTERVAL '2 minutes' AND t.ended_at + INTERVAL '2 minutes'
            ORDER BY ABS(EXTRACT(EPOCH FROM (ls.started_at - t.ended_at)))
            LIMIT 1
        ) arr_stop ON TRUE
        LEFT JOIN LATERAL (
            SELECT lb.id
            FROM lunch_breaks lb
            WHERE lb.employee_id = t.employee_id
              AND lb.ended_at IS NOT NULL
              AND t.started_at < lb.ended_at + INTERVAL '2 minutes'
              AND t.ended_at > lb.started_at - INTERVAL '2 minutes'
            LIMIT 1
        ) lunch_adj ON TRUE
        LEFT JOIN day_approvals da ON da.employee_id = t.employee_id AND da.date = t.started_at::DATE
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'trip' AND ao.activity_id = t.id
        WHERE t.started_at::DATE BETWEEN p_week_start AND v_week_end
          AND t.employee_id IN (SELECT employee_id FROM employee_list)
    ),
    live_activity_classification AS (
        -- [CHANGE C] Use live_all_stops instead of live_stop_classification
        SELECT employee_id, activity_date, duration_minutes, final_status
        FROM live_all_stops
        UNION ALL
        SELECT employee_id, activity_date, duration_minutes, final_status
        FROM live_trip_classification
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
    -- [CHANGE D] Gap detection with effective times
    shift_boundaries AS (
        SELECT
            s.id AS shift_id,
            s.employee_id,
            s.clocked_in_at::DATE AS shift_date,
            est.effective_clocked_in_at AS clocked_in_at,
            est.effective_clocked_out_at AS clocked_out_at
        FROM shifts s
        CROSS JOIN LATERAL effective_shift_times(s.id) est
        WHERE s.status = 'completed'
          AND s.clocked_in_at::DATE BETWEEN p_week_start AND v_week_end
          AND s.employee_id IN (SELECT employee_id FROM employee_list)
          AND est.effective_clocked_out_at IS NOT NULL
    ),
    activity_events AS (
        SELECT sb.shift_id, sb.employee_id, sb.shift_date,
            GREATEST(sc.started_at, sb.clocked_in_at) AS evt_start,
            LEAST(sc.ended_at, sb.clocked_out_at) AS evt_end
        FROM shift_boundaries sb
        JOIN stationary_clusters sc ON sc.employee_id = sb.employee_id
           AND sc.started_at >= sb.clocked_in_at - INTERVAL '1 minute'
           AND sc.started_at < sb.clocked_out_at AND sc.ended_at > sb.clocked_in_at
           AND sc.duration_seconds >= 180
        UNION ALL
        SELECT sb.shift_id, sb.employee_id, sb.shift_date,
            GREATEST(t.started_at, sb.clocked_in_at) AS evt_start,
            LEAST(t.ended_at, sb.clocked_out_at) AS evt_end
        FROM shift_boundaries sb
        JOIN trips t ON t.employee_id = sb.employee_id
           AND t.started_at >= sb.clocked_in_at - INTERVAL '1 minute'
           AND t.started_at < sb.clocked_out_at AND t.ended_at > sb.clocked_in_at
        UNION ALL
        SELECT sb.shift_id, sb.employee_id, sb.shift_date,
            GREATEST(lb.started_at, sb.clocked_in_at) AS evt_start,
            LEAST(lb.ended_at, sb.clocked_out_at) AS evt_end
        FROM shift_boundaries sb
        JOIN lunch_breaks lb ON lb.employee_id = sb.employee_id
           AND lb.shift_id = sb.shift_id AND lb.ended_at IS NOT NULL
    ),
    coverage_sorted AS (
        SELECT shift_id, employee_id, shift_date, evt_start, evt_end,
               ROW_NUMBER() OVER (PARTITION BY shift_id ORDER BY evt_start, evt_end DESC) AS rn
        FROM activity_events
    ),
    coverage_with_max AS (
        SELECT cs.*,
               MAX(evt_end) OVER (PARTITION BY shift_id ORDER BY rn ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_max_end
        FROM coverage_sorted cs
    ),
    coverage_islands AS (
        SELECT shift_id, employee_id, shift_date, evt_start, evt_end,
               SUM(CASE WHEN rn = 1 OR evt_start > prev_max_end THEN 1 ELSE 0 END)
                   OVER (PARTITION BY shift_id ORDER BY rn) AS island_id
        FROM coverage_with_max
    ),
    coverage_spans AS (
        SELECT shift_id, employee_id, shift_date, island_id,
               MIN(evt_start) AS span_start, MAX(evt_end) AS span_end
        FROM coverage_islands
        GROUP BY shift_id, employee_id, shift_date, island_id
    ),
    spans_numbered AS (
        SELECT shift_id, employee_id, shift_date, span_start, span_end,
               ROW_NUMBER() OVER (PARTITION BY shift_id ORDER BY span_start) AS span_rn,
               COUNT(*) OVER (PARTITION BY shift_id) AS span_count
        FROM coverage_spans
    ),
    gap_candidates AS (
        SELECT sb.employee_id, sb.shift_date, sb.clocked_in_at AS gap_start, sn.span_start AS gap_end
        FROM shift_boundaries sb JOIN spans_numbered sn ON sn.shift_id = sb.shift_id AND sn.span_rn = 1
        UNION ALL
        SELECT sn1.employee_id, sn1.shift_date, sn1.span_end AS gap_start, sn2.span_start AS gap_end
        FROM spans_numbered sn1 JOIN spans_numbered sn2 ON sn2.shift_id = sn1.shift_id AND sn2.span_rn = sn1.span_rn + 1
        UNION ALL
        SELECT sb.employee_id, sb.shift_date, sn.span_end AS gap_start, sb.clocked_out_at AS gap_end
        FROM shift_boundaries sb JOIN spans_numbered sn ON sn.shift_id = sb.shift_id AND sn.span_rn = sn.span_count
        UNION ALL
        SELECT sb.employee_id, sb.shift_date, sb.clocked_in_at AS gap_start, sb.clocked_out_at AS gap_end
        FROM shift_boundaries sb WHERE NOT EXISTS (SELECT 1 FROM activity_events ae WHERE ae.shift_id = sb.shift_id)
    ),
    day_coverage_gap_totals AS (
        SELECT employee_id, shift_date,
            COALESCE(SUM(EXTRACT(EPOCH FROM (gap_end - gap_start)) / 60)::INTEGER, 0) AS coverage_gap_minutes
        FROM gap_candidates
        WHERE EXTRACT(EPOCH FROM (gap_end - gap_start)) > 300
        GROUP BY employee_id, shift_date
    ),
    activity_quality_gaps AS (
        SELECT sb.employee_id, sb.shift_date,
            COALESCE(SUM(sc.gps_gap_seconds), 0) AS stop_gap_seconds
        FROM shift_boundaries sb
        JOIN stationary_clusters sc ON sc.employee_id = sb.employee_id
           AND sc.started_at >= sb.clocked_in_at - INTERVAL '1 minute'
           AND sc.started_at < sb.clocked_out_at AND sc.ended_at > sb.clocked_in_at
           AND sc.duration_seconds >= 180 AND sc.gps_gap_seconds > 0
        GROUP BY sb.employee_id, sb.shift_date
    ),
    trip_quality_gaps AS (
        SELECT sb.employee_id, sb.shift_date,
            COALESCE(SUM(t.gps_gap_seconds), 0) AS trip_gap_seconds
        FROM shift_boundaries sb
        JOIN trips t ON t.employee_id = sb.employee_id
           AND t.started_at >= sb.clocked_in_at - INTERVAL '1 minute'
           AND t.started_at < sb.clocked_out_at AND t.ended_at > sb.clocked_in_at
           AND t.gps_gap_seconds > 0
        GROUP BY sb.employee_id, sb.shift_date
    ),
    day_gap_totals AS (
        SELECT
            COALESCE(cg.employee_id, aq.employee_id, tq.employee_id) AS employee_id,
            COALESCE(cg.shift_date, aq.shift_date, tq.shift_date) AS shift_date,
            COALESCE(cg.coverage_gap_minutes, 0) + (COALESCE(aq.stop_gap_seconds, 0) / 60) + (COALESCE(tq.trip_gap_seconds, 0) / 60) AS gap_minutes
        FROM day_coverage_gap_totals cg
        FULL OUTER JOIN activity_quality_gaps aq ON aq.employee_id = cg.employee_id AND aq.shift_date = cg.shift_date
        FULL OUTER JOIN trip_quality_gaps tq ON tq.employee_id = COALESCE(cg.employee_id, aq.employee_id)
           AND tq.shift_date = COALESCE(cg.shift_date, aq.shift_date)
    ),
    pending_day_stats AS (
        SELECT
            ds.employee_id, ds.shift_date, ds.total_shift_minutes, ds.has_active_shift,
            ea.status AS approval_status, ea.approved_minutes AS frozen_approved, ea.rejected_minutes AS frozen_rejected,
            ldt.live_approved, ldt.live_rejected, ldt.live_needs_review_count,
            COALESCE(dl.lunch_minutes, 0) AS lunch_minutes,
            COALESCE(dct.call_count, 0) AS call_count,
            COALESCE(dct.call_billed_minutes, 0) AS call_billed_minutes,
            COALESCE(dct.call_bonus_minutes, 0) AS call_bonus_minutes,
            COALESCE(dgt.gap_minutes, 0) AS gap_minutes
        FROM day_shifts ds
        LEFT JOIN existing_approvals ea ON ea.employee_id = ds.employee_id AND ea.date = ds.shift_date
        LEFT JOIN live_day_totals ldt ON ldt.employee_id = ds.employee_id AND ldt.activity_date = ds.shift_date
        LEFT JOIN day_lunch dl ON dl.employee_id = ds.employee_id AND dl.lunch_date = ds.shift_date
        LEFT JOIN day_call_totals dct ON dct.employee_id = ds.employee_id AND dct.call_date = ds.shift_date
        LEFT JOIN day_gap_totals dgt ON dgt.employee_id = ds.employee_id AND dgt.shift_date = ds.shift_date
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
                        'lunch_minutes', COALESCE(pds.lunch_minutes, 0),
                        'call_count', COALESCE(pds.call_count, 0),
                        'call_billed_minutes', COALESCE(pds.call_billed_minutes, 0),
                        'call_bonus_minutes', COALESCE(pds.call_bonus_minutes, 0),
                        'gap_minutes', COALESCE(pds.gap_minutes, 0)
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


-- =====================================================================
-- 2. get_weekly_breakdown_totals — segment support in classified_stops
-- =====================================================================
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
    -- Classified stops (non-segmented only)
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
          -- Exclude segmented clusters
          AND sc.id NOT IN (SELECT DISTINCT stationary_cluster_id FROM cluster_segments)
    ),
    -- [CHANGE] Classified segments
    classified_segments AS (
        SELECT
            COALESCE(l.location_type::TEXT, '_unmatched') AS location_type,
            EXTRACT(EPOCH FROM (cs.ends_at - cs.starts_at))::INTEGER AS duration_seconds,
            COALESCE(ao.override_status,
                CASE
                    WHEN l.location_type IN ('office', 'building') THEN 'approved'
                    WHEN l.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                    ELSE 'needs_review'
                END
            ) AS final_status
        FROM cluster_segments cs
        JOIN stationary_clusters sc ON sc.id = cs.stationary_cluster_id
        LEFT JOIN locations l ON l.id = sc.matched_location_id
        LEFT JOIN day_approvals da ON da.employee_id = sc.employee_id AND da.date = to_business_date(cs.starts_at)
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'stop_segment' AND ao.activity_id = cs.id
        WHERE to_business_date(cs.starts_at) BETWEEN p_week_start AND v_week_end
          AND sc.employee_id IN (SELECT employee_id FROM employee_list)
    ),
    all_classified_stops AS (
        SELECT * FROM classified_stops
        UNION ALL
        SELECT * FROM classified_segments
    ),
    -- Classified trips (with lunch adjacency + commute detection)
    classified_trips AS (
        SELECT
            t.duration_minutes * 60 AS duration_seconds,
            COALESCE(ao.override_status,
                CASE
                    WHEN lunch_adj.id IS NOT NULL THEN 'rejected'
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
            SELECT sc2.matched_location_id FROM stationary_clusters sc2
            WHERE sc2.employee_id = t.employee_id AND sc2.ended_at = t.started_at LIMIT 1
        ) dep_cluster ON t.start_location_id IS NULL
        LEFT JOIN locations dep_loc ON dep_loc.id = dep_cluster.matched_location_id
        LEFT JOIN LATERAL (
            SELECT sc3.matched_location_id FROM stationary_clusters sc3
            WHERE sc3.employee_id = t.employee_id AND sc3.started_at = t.ended_at LIMIT 1
        ) arr_cluster ON t.end_location_id IS NULL
        LEFT JOIN locations arr_loc ON arr_loc.id = arr_cluster.matched_location_id
        LEFT JOIN LATERAL (
            SELECT lb.id FROM lunch_breaks lb
            WHERE lb.employee_id = t.employee_id AND lb.ended_at IS NOT NULL
              AND t.started_at < lb.ended_at + INTERVAL '2 minutes'
              AND t.ended_at > lb.started_at - INTERVAL '2 minutes'
            LIMIT 1
        ) lunch_adj ON TRUE
        LEFT JOIN day_approvals da ON da.employee_id = t.employee_id AND da.date = to_business_date(t.started_at)
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'trip' AND ao.activity_id = t.id
        WHERE to_business_date(t.started_at) BETWEEN p_week_start AND v_week_end
          AND t.employee_id IN (SELECT employee_id FROM employee_list)
    ),
    -- [CHANGE] Use all_classified_stops
    stop_totals AS (
        SELECT location_type, SUM(duration_seconds)::INTEGER AS total_seconds
        FROM all_classified_stops
        WHERE final_status = 'approved'
        GROUP BY location_type
    ),
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
