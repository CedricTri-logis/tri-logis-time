-- Include standalone manual_time_entries (shift_id IS NULL) in get_weekly_approval_summary.
-- Previously employees with only manual time on a day showed as "no_shift" with 0 minutes.

CREATE OR REPLACE FUNCTION public.get_weekly_approval_summary(p_week_start date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
    v_week_end DATE := p_week_start + INTERVAL '6 days';
    v_result JSONB;
BEGIN
    IF EXTRACT(DOW FROM p_week_start) != 0 THEN
        RAISE EXCEPTION 'p_week_start must be a Sunday, got %', p_week_start;
    END IF;

    WITH employee_list AS (
        SELECT ep.id AS employee_id, ep.full_name AS employee_name
        FROM employee_profiles ep
        WHERE ep.status = 'active'
        ORDER BY ep.full_name
    ),
    -- Shift duration excludes lunch segments
    day_shifts AS (
        SELECT
            s.employee_id,
            s.clocked_in_at::DATE AS shift_date,
            SUM(EXTRACT(EPOCH FROM (COALESCE(est.effective_clocked_out_at, s.clocked_out_at) - est.effective_clocked_in_at)) / 60)::INTEGER AS total_shift_minutes,
            bool_or(s.status = 'active') AS has_active_shift
        FROM shifts s
        CROSS JOIN LATERAL effective_shift_times(s.id) est
        WHERE s.clocked_in_at::DATE BETWEEN p_week_start AND v_week_end
          AND NOT s.is_lunch
          AND s.employee_id IN (SELECT employee_id FROM employee_list)
        GROUP BY s.employee_id, s.clocked_in_at::DATE
    ),
    -- Standalone manual time entries (shift_id IS NULL)
    day_manual_time AS (
        SELECT
            mte.employee_id,
            mte.date AS shift_date,
            SUM(EXTRACT(EPOCH FROM (mte.ends_at - mte.starts_at)) / 60)::INTEGER AS manual_minutes
        FROM manual_time_entries mte
        WHERE mte.date BETWEEN p_week_start AND v_week_end
          AND mte.employee_id IN (SELECT employee_id FROM employee_list)
          AND mte.shift_id IS NULL
        GROUP BY mte.employee_id, mte.date
    ),
    -- Lunch minutes from lunch shift segments (override-aware)
    day_lunch AS (
        SELECT
            s.employee_id,
            (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date AS lunch_date,
            COALESCE(SUM(
                CASE
                    WHEN EXISTS (SELECT 1 FROM activity_segments aseg WHERE aseg.activity_type = 'lunch' AND aseg.activity_id = s.id)
                        THEN 0
                    WHEN COALESCE(ao.override_status, 'rejected') = 'approved'
                        THEN 0
                    ELSE EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at))::INTEGER / 60
                END
            ), 0)
            + COALESCE(MAX((
                SELECT SUM(EXTRACT(EPOCH FROM (aseg2.ends_at - aseg2.starts_at))::INTEGER / 60)
                FROM activity_segments aseg2
                JOIN shifts s2 ON s2.id = aseg2.activity_id AND s2.is_lunch = true AND s2.employee_id = s.employee_id
                LEFT JOIN day_approvals da2 ON da2.employee_id = aseg2.employee_id
                    AND da2.date = (aseg2.starts_at AT TIME ZONE 'America/Montreal')::date
                LEFT JOIN activity_overrides ao2 ON ao2.day_approval_id = da2.id
                    AND ao2.activity_type = 'lunch_segment' AND ao2.activity_id = aseg2.id
                WHERE aseg2.activity_type = 'lunch'
                  AND (aseg2.starts_at AT TIME ZONE 'America/Montreal')::date = (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date
                  AND COALESCE(ao2.override_status, 'rejected') != 'approved'
            )), 0) AS lunch_minutes
        FROM shifts s
        LEFT JOIN day_approvals da ON da.employee_id = s.employee_id
            AND da.date = (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'lunch' AND ao.activity_id = s.id
        WHERE s.is_lunch = true AND s.clocked_out_at IS NOT NULL
          AND (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date BETWEEN p_week_start AND v_week_end
          AND s.employee_id IN (SELECT employee_id FROM employee_list)
        GROUP BY s.employee_id, (s.clocked_in_at AT TIME ZONE 'America/Montreal')::date
    ),
    day_calls_lagged AS (
        SELECT
            s.employee_id,
            s.clocked_in_at::DATE AS call_date,
            est.effective_clocked_in_at AS clocked_in_at,
            est.effective_clocked_out_at AS clocked_out_at,
            LAG(est.effective_clocked_in_at) OVER w AS prev_clocked_in_at,
            LAG(est.effective_clocked_out_at) OVER w AS prev_clocked_out_at
        FROM shifts s, effective_shift_times(s.id) est
        WHERE s.shift_type = 'call'
          AND s.status = 'completed'
          AND s.clocked_in_at::DATE BETWEEN p_week_start AND v_week_end
          AND s.employee_id IN (SELECT employee_id FROM employee_list)
          AND s.is_lunch = false
        WINDOW w AS (PARTITION BY s.employee_id, s.clocked_in_at::DATE ORDER BY est.effective_clocked_in_at)
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
          -- Exclude stops from lunch segments
          AND NOT EXISTS (SELECT 1 FROM shifts sl WHERE sl.id = sc.shift_id AND sl.is_lunch = true)
    ),
    live_segment_classification AS (
        SELECT
            sc.employee_id,
            aseg.starts_at::DATE AS activity_date,
            aseg.id AS activity_id,
            aseg.starts_at AS started_at,
            aseg.ends_at AS ended_at,
            EXTRACT(EPOCH FROM (aseg.ends_at - aseg.starts_at))::INTEGER / 60 AS duration_minutes,
            COALESCE(ao.override_status,
                CASE
                    WHEN l.location_type IN ('office', 'building') THEN 'approved'
                    WHEN l.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                    WHEN l.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                    ELSE 'rejected'
                END
            ) AS final_status
        FROM activity_segments aseg
        JOIN stationary_clusters sc ON sc.id = aseg.activity_id
        LEFT JOIN locations l ON l.id = sc.matched_location_id
        LEFT JOIN day_approvals da ON da.employee_id = sc.employee_id AND da.date = aseg.starts_at::DATE
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'stop_segment' AND ao.activity_id = aseg.id
        WHERE aseg.activity_type = 'stop'
          AND aseg.starts_at::DATE BETWEEN p_week_start AND v_week_end
          AND sc.employee_id IN (SELECT employee_id FROM employee_list)
          -- Exclude segments from lunch segments
          AND NOT EXISTS (SELECT 1 FROM shifts sl WHERE sl.id = sc.shift_id AND sl.is_lunch = true)
    ),
    -- New CTE for trip segments
    live_trip_segment_classification AS (
        SELECT
            t.employee_id,
            aseg.starts_at::DATE AS activity_date,
            aseg.id AS activity_id,
            aseg.starts_at AS started_at,
            aseg.ends_at AS ended_at,
            EXTRACT(EPOCH FROM (aseg.ends_at - aseg.starts_at))::INTEGER / 60 AS duration_minutes,
            COALESCE(ao.override_status, 'needs_review') AS final_status
        FROM activity_segments aseg
        JOIN trips t ON t.id = aseg.activity_id
        LEFT JOIN day_approvals da ON da.employee_id = t.employee_id AND da.date = aseg.starts_at::DATE
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'trip_segment' AND ao.activity_id = aseg.id
        WHERE aseg.activity_type = 'trip'
          AND aseg.starts_at::DATE BETWEEN p_week_start AND v_week_end
          AND t.employee_id IN (SELECT employee_id FROM employee_list)
          AND NOT EXISTS (SELECT 1 FROM shifts sl WHERE sl.id = t.shift_id AND sl.is_lunch = true)
    ),
    -- Union: non-segmented stops + segments
    live_all_stops AS (
        SELECT * FROM live_stop_classification
        WHERE activity_id NOT IN (SELECT activity_id FROM activity_segments WHERE activity_type = 'stop')
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
                    -- Trip on a lunch segment -> rejected
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
        -- Check if trip is on a lunch segment
        LEFT JOIN LATERAL (
            SELECT sl.id
            FROM shifts sl
            WHERE sl.id = t.shift_id AND sl.is_lunch = true
            LIMIT 1
        ) lunch_adj ON TRUE
        LEFT JOIN day_approvals da ON da.employee_id = t.employee_id AND da.date = t.started_at::DATE
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'trip' AND ao.activity_id = t.id
        WHERE t.started_at::DATE BETWEEN p_week_start AND v_week_end
          AND t.employee_id IN (SELECT employee_id FROM employee_list)
          AND t.id NOT IN (SELECT activity_id FROM activity_segments WHERE activity_type = 'trip')
    ),
    live_activity_classification AS (
        SELECT employee_id, activity_date, duration_minutes, final_status
        FROM live_all_stops
        UNION ALL
        SELECT employee_id, activity_date, duration_minutes, final_status
        FROM live_trip_classification
        UNION ALL
        SELECT employee_id, activity_date, duration_minutes, final_status
        FROM live_trip_segment_classification
        UNION ALL
        -- Manual time entries (standalone only)
        SELECT
            mte.employee_id,
            mte.date AS activity_date,
            EXTRACT(EPOCH FROM (mte.ends_at - mte.starts_at))::INTEGER / 60 AS duration_minutes,
            COALESCE(ao.override_status, 'needs_review') AS final_status
        FROM manual_time_entries mte
        LEFT JOIN day_approvals da ON da.employee_id = mte.employee_id AND da.date = mte.date
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'manual_time' AND ao.activity_id = mte.id
        WHERE mte.date BETWEEN p_week_start AND v_week_end
          AND mte.employee_id IN (SELECT employee_id FROM employee_list)
          AND mte.shift_id IS NULL
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
    -- Gap detection with effective times (exclude lunch segments from shift_boundaries)
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
          AND NOT s.is_lunch
    ),
    activity_events AS (
        SELECT sb.shift_id, sb.employee_id, sb.shift_date,
            GREATEST(sc.started_at, sb.clocked_in_at) AS evt_start,
            LEAST(sc.ended_at, sb.clocked_out_at) AS evt_end
        FROM shift_boundaries sb
        JOIN stationary_clusters sc ON sc.employee_id = sb.employee_id
           AND sc.started_at < sb.clocked_out_at AND sc.ended_at > sb.clocked_in_at
           AND sc.duration_seconds >= 180
        UNION ALL
        SELECT sb.shift_id, sb.employee_id, sb.shift_date,
            GREATEST(t.started_at, sb.clocked_in_at) AS evt_start,
            LEAST(t.ended_at, sb.clocked_out_at) AS evt_end
        FROM shift_boundaries sb
        JOIN trips t ON t.employee_id = sb.employee_id
           AND t.started_at < sb.clocked_out_at AND t.ended_at > sb.clocked_in_at
        UNION ALL
        -- Lunch segments as coverage events (use shifts with is_lunch via work_body_id)
        SELECT sb.shift_id, sb.employee_id, sb.shift_date,
            GREATEST(s_lunch.clocked_in_at, sb.clocked_in_at) AS evt_start,
            LEAST(s_lunch.clocked_out_at, sb.clocked_out_at) AS evt_end
        FROM shift_boundaries sb
        JOIN shifts s_lunch ON s_lunch.employee_id = sb.employee_id
           AND s_lunch.work_body_id = (SELECT work_body_id FROM shifts WHERE id = sb.shift_id)
           AND s_lunch.is_lunch = true AND s_lunch.clocked_out_at IS NOT NULL
           AND s_lunch.clocked_in_at < sb.clocked_out_at
           AND s_lunch.clocked_out_at > sb.clocked_in_at
        UNION ALL
        -- Manual time entries as coverage events
        SELECT sb.shift_id, sb.employee_id, sb.shift_date,
            GREATEST(mte.starts_at, sb.clocked_in_at) AS evt_start,
            LEAST(mte.ends_at, sb.clocked_out_at) AS evt_end
        FROM shift_boundaries sb
        JOIN manual_time_entries mte ON mte.employee_id = sb.employee_id
           AND mte.starts_at < sb.clocked_out_at AND mte.ends_at > sb.clocked_in_at
           AND mte.shift_id = sb.shift_id
    ),
    coverage_sorted AS (
        SELECT shift_id, employee_id, shift_date, evt_start, evt_end,
               ROW_NUMBER() OVER (PARTITION BY shift_id ORDER BY evt_start, evt_end DESC) AS rn
        FROM activity_events
        WHERE evt_start < evt_end
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
           AND sc.started_at < sb.clocked_out_at AND sc.ended_at > sb.clocked_in_at
           AND sc.duration_seconds >= 180 AND sc.gps_gap_seconds > 0
        GROUP BY sb.employee_id, sb.shift_date
    ),
    trip_quality_gaps AS (
        SELECT sb.employee_id, sb.shift_date,
            COALESCE(SUM(t.gps_gap_seconds), 0) AS trip_gap_seconds
        FROM shift_boundaries sb
        JOIN trips t ON t.employee_id = sb.employee_id
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
            COALESCE(ds.employee_id, dmt.employee_id) AS employee_id,
            COALESCE(ds.shift_date, dmt.shift_date) AS shift_date,
            COALESCE(ds.total_shift_minutes, 0) + COALESCE(dmt.manual_minutes, 0) AS total_shift_minutes,
            COALESCE(ds.has_active_shift, FALSE) AS has_active_shift,
            ea.status AS approval_status, ea.approved_minutes AS frozen_approved, ea.rejected_minutes AS frozen_rejected,
            ldt.live_approved, ldt.live_rejected, ldt.live_needs_review_count,
            COALESCE(dl.lunch_minutes, 0) AS lunch_minutes,
            COALESCE(dct.call_count, 0) AS call_count,
            COALESCE(dct.call_billed_minutes, 0) AS call_billed_minutes,
            CASE WHEN COALESCE(
                CASE WHEN ea.status = 'approved' THEN ea.approved_minutes
                     ELSE ldt.live_approved END,
                0) > 0
            THEN COALESCE(dct.call_bonus_minutes, 0) ELSE 0 END AS call_bonus_minutes,
            COALESCE(dgt.gap_minutes, 0) AS gap_minutes
        FROM day_shifts ds
        FULL OUTER JOIN day_manual_time dmt
            ON dmt.employee_id = ds.employee_id AND dmt.shift_date = ds.shift_date
        LEFT JOIN existing_approvals ea
            ON ea.employee_id = COALESCE(ds.employee_id, dmt.employee_id)
            AND ea.date = COALESCE(ds.shift_date, dmt.shift_date)
        LEFT JOIN live_day_totals ldt
            ON ldt.employee_id = COALESCE(ds.employee_id, dmt.employee_id)
            AND ldt.activity_date = COALESCE(ds.shift_date, dmt.shift_date)
        LEFT JOIN day_lunch dl
            ON dl.employee_id = COALESCE(ds.employee_id, dmt.employee_id)
            AND dl.lunch_date = COALESCE(ds.shift_date, dmt.shift_date)
        LEFT JOIN day_call_totals dct
            ON dct.employee_id = COALESCE(ds.employee_id, dmt.employee_id)
            AND dct.call_date = COALESCE(ds.shift_date, dmt.shift_date)
        LEFT JOIN day_gap_totals dgt
            ON dgt.employee_id = COALESCE(ds.employee_id, dmt.employee_id)
            AND dgt.shift_date = COALESCE(ds.shift_date, dmt.shift_date)
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
                        -- Lunch already excluded from total_shift_minutes (day_shifts filters NOT is_lunch)
                        'total_shift_minutes', COALESCE(pds.total_shift_minutes, 0),
                        'approved_minutes', LEAST(
                            CASE
                                WHEN pds.approval_status = 'approved' THEN pds.frozen_approved
                                ELSE COALESCE(pds.live_approved, 0)
                            END,
                            COALESCE(pds.total_shift_minutes, 0)
                        ),
                        'rejected_minutes', LEAST(
                            CASE
                                WHEN pds.approval_status = 'approved' THEN pds.frozen_rejected
                                ELSE COALESCE(pds.live_rejected, 0)
                            END,
                            GREATEST(
                                COALESCE(pds.total_shift_minutes, 0)
                                - CASE
                                    WHEN pds.approval_status = 'approved' THEN COALESCE(pds.frozen_approved, 0)
                                    ELSE COALESCE(pds.live_approved, 0)
                                  END,
                                0
                            )
                        ),
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
$function$;
