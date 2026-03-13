# Untracked Time Visibility — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Show untracked shift time (periods with no detected GPS activity) as visible timeline entries in the day detail and as a GPS coverage indicator in the weekly approval grid.

**Architecture:** Add gap detection as a post-processing step in `get_day_approval_detail` that finds time periods between clock-in/out and detected activities, creates `untracked` entries with GPS point counts. Add `untracked_minutes` to `get_weekly_approval_summary` output. Update dashboard to render both.

**Tech Stack:** PostgreSQL (PL/pgSQL), TypeScript, React (shadcn/ui)

---

### Task 1: SQL Migration — Add untracked gaps to `get_day_approval_detail`

**Files:**
- Create: `supabase/migrations/129_untracked_time_visibility.sql`

**Step 1: Write the migration**

The migration redefines `get_day_approval_detail` with a gap detection block inserted between the activity building (line 349 current) and the summary computation (line 351 current). It also redefines `get_weekly_approval_summary` with `untracked_minutes`.

```sql
-- Migration 129: Untracked time visibility
-- Adds 'untracked' activity entries for time gaps between clock-in/out and
-- detected activities. Adds untracked_minutes to weekly summary.

CREATE OR REPLACE FUNCTION get_day_approval_detail(
    p_employee_id UUID,
    p_date DATE
)
RETURNS JSONB AS $$
DECLARE
    v_result JSONB;
    v_activities JSONB;
    v_day_approval RECORD;
    v_total_shift_minutes INTEGER;
    v_approved_minutes INTEGER := 0;
    v_rejected_minutes INTEGER := 0;
    v_needs_review_count INTEGER := 0;
    v_has_active_shift BOOLEAN := FALSE;
    v_untracked_minutes INTEGER := 0;
    -- Gap detection vars
    v_shift RECORD;
    v_act RECORD;
    v_prev_end TIMESTAMPTZ;
    v_gap_minutes INTEGER;
    v_gps_count INTEGER;
    v_gaps JSONB := '[]'::JSONB;
BEGIN
    -- Check for active shifts on this day
    SELECT EXISTS(
        SELECT 1 FROM shifts
        WHERE employee_id = p_employee_id
          AND clocked_in_at::DATE = p_date
          AND status = 'active'
    ) INTO v_has_active_shift;

    -- Get existing day_approval if any
    SELECT * INTO v_day_approval
    FROM day_approvals
    WHERE employee_id = p_employee_id AND date = p_date;

    -- Calculate total shift minutes for completed shifts on this day
    SELECT COALESCE(SUM(
        EXTRACT(EPOCH FROM (COALESCE(clocked_out_at, now()) - clocked_in_at)) / 60
    )::INTEGER, 0)
    INTO v_total_shift_minutes
    FROM shifts
    WHERE employee_id = p_employee_id
      AND clocked_in_at::DATE = p_date
      AND status = 'completed';

    -- Build classified activity list (IDENTICAL to migration 121)
    WITH activity_data AS (
        -- STOPS
        SELECT
            'stop'::TEXT AS activity_type,
            sc.id AS activity_id,
            sc.shift_id,
            sc.started_at,
            sc.ended_at,
            (sc.duration_seconds / 60)::INTEGER AS duration_minutes,
            sc.matched_location_id,
            l.name AS location_name,
            l.location_type::TEXT AS location_type,
            sc.centroid_latitude AS latitude,
            sc.centroid_longitude AS longitude,
            sc.gps_gap_seconds,
            sc.gps_gap_count,
            CASE
                WHEN l.location_type IN ('office', 'building') THEN 'approved'
                WHEN l.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                WHEN l.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN sc.matched_location_id IS NULL THEN 'needs_review'
                ELSE 'needs_review'
            END AS auto_status,
            CASE
                WHEN l.location_type = 'office' THEN 'Lieu de travail (bureau)'
                WHEN l.location_type = 'building' THEN 'Lieu de travail (immeuble)'
                WHEN l.location_type = 'vendor' THEN 'Fournisseur (à vérifier)'
                WHEN l.location_type = 'gaz' THEN 'Station-service (à vérifier)'
                WHEN l.location_type = 'home' THEN 'Domicile'
                WHEN l.location_type = 'cafe_restaurant' THEN 'Café / Restaurant'
                WHEN l.location_type = 'other' THEN 'Lieu non-professionnel'
                WHEN sc.matched_location_id IS NULL THEN 'Lieu inconnu'
                ELSE 'Lieu inconnu'
            END AS auto_reason,
            NULL::DECIMAL AS distance_km,
            NULL::TEXT AS transport_mode,
            NULL::BOOLEAN AS has_gps_gap,
            NULL::UUID AS start_location_id,
            NULL::TEXT AS start_location_name,
            NULL::TEXT AS start_location_type,
            NULL::UUID AS end_location_id,
            NULL::TEXT AS end_location_name,
            NULL::TEXT AS end_location_type
        FROM stationary_clusters sc
        LEFT JOIN locations l ON l.id = sc.matched_location_id
        WHERE sc.employee_id = p_employee_id
          AND sc.started_at >= p_date::TIMESTAMPTZ
          AND sc.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
          AND sc.duration_seconds >= 180

        UNION ALL

        -- TRIPS (with cluster-based location fallback)
        SELECT
            'trip'::TEXT,
            t.id,
            t.shift_id,
            t.started_at,
            t.ended_at,
            t.duration_minutes,
            NULL::UUID AS matched_location_id,
            NULL::TEXT AS location_name,
            NULL::TEXT AS location_type,
            t.start_latitude AS latitude,
            t.start_longitude AS longitude,
            NULL::INTEGER AS gps_gap_seconds,
            NULL::INTEGER AS gps_gap_count,
            CASE
                WHEN t.has_gps_gap = TRUE THEN 'needs_review'
                WHEN t.duration_minutes > 60 THEN 'needs_review'
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('office', 'building')
                 AND COALESCE(el.location_type, arr_loc.location_type) IN ('office', 'building') THEN 'approved'
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('home', 'cafe_restaurant', 'other')
                  OR COALESCE(el.location_type, arr_loc.location_type) IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IS NULL
                  OR COALESCE(el.location_type, arr_loc.location_type) IS NULL THEN 'needs_review'
                ELSE 'needs_review'
            END,
            CASE
                WHEN t.has_gps_gap = TRUE THEN 'Données GPS incomplètes'
                WHEN t.duration_minutes > 60 THEN 'Trajet anormalement long (>' || t.duration_minutes || ' min)'
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('office', 'building')
                 AND COALESCE(el.location_type, arr_loc.location_type) IN ('office', 'building') THEN 'Déplacement professionnel'
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('home', 'cafe_restaurant', 'other')
                  OR COALESCE(el.location_type, arr_loc.location_type) IN ('home', 'cafe_restaurant', 'other') THEN 'Trajet personnel'
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IS NULL
                  OR COALESCE(el.location_type, arr_loc.location_type) IS NULL THEN 'Destination inconnue'
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('vendor', 'gaz')
                  OR COALESCE(el.location_type, arr_loc.location_type) IN ('vendor', 'gaz') THEN 'Trajet fournisseur/station (à vérifier)'
                ELSE 'À vérifier'
            END,
            t.distance_km,
            t.transport_mode::TEXT,
            t.has_gps_gap,
            COALESCE(t.start_location_id, dep_cluster.matched_location_id),
            COALESCE(sl.name, dep_loc.name)::TEXT AS start_location_name,
            COALESCE(sl.location_type, dep_loc.location_type)::TEXT AS start_location_type,
            COALESCE(t.end_location_id, arr_cluster.matched_location_id),
            COALESCE(el.name, arr_loc.name)::TEXT AS end_location_name,
            COALESCE(el.location_type, arr_loc.location_type)::TEXT AS end_location_type
        FROM trips t
        LEFT JOIN locations sl ON sl.id = t.start_location_id
        LEFT JOIN locations el ON el.id = t.end_location_id
        LEFT JOIN LATERAL (
            SELECT sc2.matched_location_id
            FROM stationary_clusters sc2
            WHERE sc2.employee_id = p_employee_id
              AND sc2.ended_at = t.started_at
            LIMIT 1
        ) dep_cluster ON t.start_location_id IS NULL
        LEFT JOIN locations dep_loc ON dep_loc.id = dep_cluster.matched_location_id
        LEFT JOIN LATERAL (
            SELECT sc3.matched_location_id
            FROM stationary_clusters sc3
            WHERE sc3.employee_id = p_employee_id
              AND sc3.started_at = t.ended_at
            LIMIT 1
        ) arr_cluster ON t.end_location_id IS NULL
        LEFT JOIN locations arr_loc ON arr_loc.id = arr_cluster.matched_location_id
        WHERE t.employee_id = p_employee_id
          AND t.started_at >= p_date::TIMESTAMPTZ
          AND t.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ

        UNION ALL

        -- CLOCK IN
        SELECT
            'clock_in'::TEXT,
            s.id, s.id AS shift_id,
            s.clocked_in_at, s.clocked_in_at,
            0 AS duration_minutes,
            ci_loc.id AS matched_location_id,
            ci_loc.name AS location_name,
            ci_loc.location_type::TEXT AS location_type,
            (s.clock_in_location->>'latitude')::DECIMAL,
            (s.clock_in_location->>'longitude')::DECIMAL,
            NULL::INTEGER, NULL::INTEGER,
            CASE
                WHEN ci_loc.location_type IN ('office', 'building') THEN 'approved'
                WHEN ci_loc.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                WHEN ci_loc.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN ci_loc.id IS NULL THEN 'needs_review'
                ELSE 'needs_review'
            END,
            CASE
                WHEN ci_loc.location_type IN ('office', 'building') THEN 'Clock-in sur lieu de travail'
                WHEN ci_loc.location_type = 'vendor' THEN 'Clock-in chez fournisseur (à vérifier)'
                WHEN ci_loc.location_type = 'gaz' THEN 'Clock-in station-service (à vérifier)'
                WHEN ci_loc.location_type = 'home' THEN 'Clock-in depuis le domicile'
                WHEN ci_loc.location_type IN ('cafe_restaurant', 'other') THEN 'Clock-in hors lieu de travail'
                WHEN ci_loc.id IS NULL THEN 'Clock-in lieu inconnu'
                ELSE 'Clock-in lieu inconnu'
            END,
            NULL::DECIMAL, NULL::TEXT, NULL::BOOLEAN,
            NULL::UUID, NULL::TEXT, NULL::TEXT,
            NULL::UUID, NULL::TEXT, NULL::TEXT
        FROM shifts s
        LEFT JOIN LATERAL (
            SELECT l.id, l.name, l.location_type
            FROM locations l
            WHERE l.is_active = TRUE
              AND s.clock_in_location IS NOT NULL
              AND ST_DWithin(
                l.location::geography,
                ST_SetSRID(ST_MakePoint(
                    (s.clock_in_location->>'longitude')::DOUBLE PRECISION,
                    (s.clock_in_location->>'latitude')::DOUBLE PRECISION
                ), 4326)::geography,
                GREATEST(l.radius_meters, COALESCE(s.clock_in_accuracy, 0))
              )
            ORDER BY ST_Distance(
                l.location::geography,
                ST_SetSRID(ST_MakePoint(
                    (s.clock_in_location->>'longitude')::DOUBLE PRECISION,
                    (s.clock_in_location->>'latitude')::DOUBLE PRECISION
                ), 4326)::geography
            )
            LIMIT 1
        ) ci_loc ON TRUE
        WHERE s.employee_id = p_employee_id
          AND s.clocked_in_at::DATE = p_date
          AND s.status = 'completed'
          AND s.clock_in_location IS NOT NULL

        UNION ALL

        -- CLOCK OUT
        SELECT
            'clock_out'::TEXT,
            s.id, s.id AS shift_id,
            s.clocked_out_at, s.clocked_out_at,
            0 AS duration_minutes,
            co_loc.id AS matched_location_id,
            co_loc.name AS location_name,
            co_loc.location_type::TEXT AS location_type,
            (s.clock_out_location->>'latitude')::DECIMAL,
            (s.clock_out_location->>'longitude')::DECIMAL,
            NULL::INTEGER, NULL::INTEGER,
            CASE
                WHEN co_loc.location_type IN ('office', 'building') THEN 'approved'
                WHEN co_loc.location_type IN ('vendor', 'gaz') THEN 'needs_review'
                WHEN co_loc.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN co_loc.id IS NULL THEN 'needs_review'
                ELSE 'needs_review'
            END,
            CASE
                WHEN co_loc.location_type IN ('office', 'building') THEN 'Clock-out sur lieu de travail'
                WHEN co_loc.location_type = 'vendor' THEN 'Clock-out chez fournisseur (à vérifier)'
                WHEN co_loc.location_type = 'gaz' THEN 'Clock-out station-service (à vérifier)'
                WHEN co_loc.location_type = 'home' THEN 'Clock-out au domicile'
                WHEN co_loc.location_type IN ('cafe_restaurant', 'other') THEN 'Clock-out hors lieu de travail'
                WHEN co_loc.id IS NULL THEN 'Clock-out lieu inconnu'
                ELSE 'Clock-out lieu inconnu'
            END,
            NULL::DECIMAL, NULL::TEXT, NULL::BOOLEAN,
            NULL::UUID, NULL::TEXT, NULL::TEXT,
            NULL::UUID, NULL::TEXT, NULL::TEXT
        FROM shifts s
        LEFT JOIN LATERAL (
            SELECT l.id, l.name, l.location_type
            FROM locations l
            WHERE l.is_active = TRUE
              AND s.clock_out_location IS NOT NULL
              AND ST_DWithin(
                l.location::geography,
                ST_SetSRID(ST_MakePoint(
                    (s.clock_out_location->>'longitude')::DOUBLE PRECISION,
                    (s.clock_out_location->>'latitude')::DOUBLE PRECISION
                ), 4326)::geography,
                GREATEST(l.radius_meters, COALESCE(s.clock_out_accuracy, 0))
              )
            ORDER BY ST_Distance(
                l.location::geography,
                ST_SetSRID(ST_MakePoint(
                    (s.clock_out_location->>'longitude')::DOUBLE PRECISION,
                    (s.clock_out_location->>'latitude')::DOUBLE PRECISION
                ), 4326)::geography
            )
            LIMIT 1
        ) co_loc ON TRUE
        WHERE s.employee_id = p_employee_id
          AND s.clocked_out_at::DATE = p_date
          AND s.status = 'completed'
          AND s.clock_out_location IS NOT NULL
          AND s.clocked_out_at IS NOT NULL
    ),
    classified AS (
        SELECT
            ad.*,
            ao.override_status,
            ao.reason AS override_reason,
            COALESCE(ao.override_status, ad.auto_status) AS final_status
        FROM activity_data ad
        LEFT JOIN day_approvals da
            ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides ao
            ON ao.day_approval_id = da.id
           AND ao.activity_type = ad.activity_type
           AND ao.activity_id = ad.activity_id
        ORDER BY ad.started_at ASC
    )
    SELECT jsonb_agg(
        jsonb_build_object(
            'activity_type', c.activity_type,
            'activity_id', c.activity_id,
            'shift_id', c.shift_id,
            'started_at', c.started_at,
            'ended_at', c.ended_at,
            'duration_minutes', c.duration_minutes,
            'auto_status', c.auto_status,
            'auto_reason', c.auto_reason,
            'override_status', c.override_status,
            'override_reason', c.override_reason,
            'final_status', c.final_status,
            'matched_location_id', c.matched_location_id,
            'location_name', c.location_name,
            'location_type', c.location_type,
            'latitude', c.latitude,
            'longitude', c.longitude,
            'distance_km', c.distance_km,
            'transport_mode', c.transport_mode,
            'has_gps_gap', c.has_gps_gap,
            'start_location_id', c.start_location_id,
            'start_location_name', c.start_location_name,
            'start_location_type', c.start_location_type,
            'end_location_id', c.end_location_id,
            'end_location_name', c.end_location_name,
            'end_location_type', c.end_location_type,
            'gps_gap_seconds', c.gps_gap_seconds,
            'gps_gap_count', c.gps_gap_count
        )
        ORDER BY c.started_at ASC
    )
    INTO v_activities
    FROM classified c;

    -- ============================================================
    -- NEW: Detect untracked gaps per shift
    -- Walk through each completed shift, find time periods between
    -- clock-in/out and detected activities (stops/trips only).
    -- Create 'untracked' entries for gaps >= 3 minutes.
    -- ============================================================
    FOR v_shift IN
        SELECT id, clocked_in_at, clocked_out_at
        FROM shifts
        WHERE employee_id = p_employee_id
          AND clocked_in_at::DATE = p_date
          AND status = 'completed'
        ORDER BY clocked_in_at
    LOOP
        v_prev_end := v_shift.clocked_in_at;

        -- Walk through stops and trips for this shift, ordered by time
        FOR v_act IN
            SELECT
                (elem->>'started_at')::TIMESTAMPTZ AS started_at,
                (elem->>'ended_at')::TIMESTAMPTZ AS ended_at
            FROM jsonb_array_elements(COALESCE(v_activities, '[]'::JSONB)) elem
            WHERE (elem->>'shift_id')::UUID = v_shift.id
              AND elem->>'activity_type' IN ('stop', 'trip')
            ORDER BY (elem->>'started_at')::TIMESTAMPTZ
        LOOP
            v_gap_minutes := EXTRACT(EPOCH FROM (v_act.started_at - v_prev_end))::INTEGER / 60;

            IF v_gap_minutes >= 3 THEN
                -- Count GPS points in gap period
                SELECT COUNT(*) INTO v_gps_count
                FROM gps_points
                WHERE shift_id = v_shift.id
                  AND captured_at >= v_prev_end
                  AND captured_at < v_act.started_at;

                v_gaps := v_gaps || jsonb_build_array(jsonb_build_object(
                    'activity_type', 'untracked',
                    'activity_id', v_shift.id,
                    'shift_id', v_shift.id,
                    'started_at', v_prev_end,
                    'ended_at', v_act.started_at,
                    'duration_minutes', v_gap_minutes,
                    'auto_status', 'needs_review',
                    'auto_reason', CASE
                        WHEN v_gps_count = 0 THEN 'Aucune donnée GPS'
                        ELSE v_gps_count || ' points GPS — aucune activité détectée'
                    END,
                    'override_status', NULL,
                    'override_reason', NULL,
                    'final_status', 'needs_review',
                    'matched_location_id', NULL,
                    'location_name', NULL,
                    'location_type', NULL,
                    'latitude', NULL,
                    'longitude', NULL,
                    'distance_km', NULL,
                    'transport_mode', NULL,
                    'has_gps_gap', NULL,
                    'start_location_id', NULL,
                    'start_location_name', NULL,
                    'start_location_type', NULL,
                    'end_location_id', NULL,
                    'end_location_name', NULL,
                    'end_location_type', NULL,
                    'gps_gap_seconds', NULL,
                    'gps_gap_count', NULL,
                    'gps_point_count', v_gps_count
                ));
            END IF;

            v_prev_end := v_act.ended_at;
        END LOOP;

        -- Gap after last activity to clock-out
        IF v_shift.clocked_out_at IS NOT NULL THEN
            v_gap_minutes := EXTRACT(EPOCH FROM (v_shift.clocked_out_at - v_prev_end))::INTEGER / 60;

            IF v_gap_minutes >= 3 THEN
                SELECT COUNT(*) INTO v_gps_count
                FROM gps_points
                WHERE shift_id = v_shift.id
                  AND captured_at >= v_prev_end
                  AND captured_at < v_shift.clocked_out_at;

                v_gaps := v_gaps || jsonb_build_array(jsonb_build_object(
                    'activity_type', 'untracked',
                    'activity_id', v_shift.id,
                    'shift_id', v_shift.id,
                    'started_at', v_prev_end,
                    'ended_at', v_shift.clocked_out_at,
                    'duration_minutes', v_gap_minutes,
                    'auto_status', 'needs_review',
                    'auto_reason', CASE
                        WHEN v_gps_count = 0 THEN 'Aucune donnée GPS'
                        ELSE v_gps_count || ' points GPS — aucune activité détectée'
                    END,
                    'override_status', NULL,
                    'override_reason', NULL,
                    'final_status', 'needs_review',
                    'matched_location_id', NULL,
                    'location_name', NULL,
                    'location_type', NULL,
                    'latitude', NULL,
                    'longitude', NULL,
                    'distance_km', NULL,
                    'transport_mode', NULL,
                    'has_gps_gap', NULL,
                    'start_location_id', NULL,
                    'start_location_name', NULL,
                    'start_location_type', NULL,
                    'end_location_id', NULL,
                    'end_location_name', NULL,
                    'end_location_type', NULL,
                    'gps_gap_seconds', NULL,
                    'gps_gap_count', NULL,
                    'gps_point_count', v_gps_count
                ));
            END IF;
        END IF;
    END LOOP;

    -- Merge gaps into activities and re-sort
    IF jsonb_array_length(v_gaps) > 0 THEN
        SELECT jsonb_agg(elem ORDER BY (elem->>'started_at')::TIMESTAMPTZ ASC)
        INTO v_activities
        FROM (
            SELECT elem FROM jsonb_array_elements(COALESCE(v_activities, '[]'::JSONB)) elem
            UNION ALL
            SELECT elem FROM jsonb_array_elements(v_gaps) elem
        ) combined;
    END IF;

    -- Compute summary from activities JSONB
    -- Exclude 'untracked' and merged clock events from needs_review_count
    SELECT
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (WHERE a->>'final_status' = 'approved'), 0),
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (WHERE a->>'final_status' = 'rejected'), 0),
        COALESCE(COUNT(*) FILTER (WHERE
            a->>'final_status' = 'needs_review'
            AND a->>'activity_type' != 'untracked'
            AND NOT (
                a->>'activity_type' IN ('clock_in', 'clock_out')
                AND EXISTS (
                    SELECT 1 FROM jsonb_array_elements(COALESCE(v_activities, '[]'::JSONB)) s
                    WHERE s->>'activity_type' = 'stop'
                      AND (a->>'started_at')::TIMESTAMPTZ >= ((s->>'started_at')::TIMESTAMPTZ - INTERVAL '60 seconds')
                      AND (a->>'started_at')::TIMESTAMPTZ <= ((s->>'ended_at')::TIMESTAMPTZ + INTERVAL '60 seconds')
                )
            )
        ), 0),
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (WHERE a->>'activity_type' = 'untracked'), 0)
    INTO v_approved_minutes, v_rejected_minutes, v_needs_review_count, v_untracked_minutes
    FROM jsonb_array_elements(COALESCE(v_activities, '[]'::JSONB)) a;

    -- If day is already approved, use frozen values for summary
    IF v_day_approval.status = 'approved' THEN
        v_approved_minutes := v_day_approval.approved_minutes;
        v_rejected_minutes := v_day_approval.rejected_minutes;
        v_needs_review_count := 0;
        -- Recompute untracked from frozen values
        v_untracked_minutes := GREATEST(v_total_shift_minutes - v_approved_minutes - v_rejected_minutes, 0);
    END IF;

    -- Build result
    v_result := jsonb_build_object(
        'employee_id', p_employee_id,
        'date', p_date,
        'has_active_shift', v_has_active_shift,
        'approval_status', COALESCE(v_day_approval.status, 'pending'),
        'approved_by', v_day_approval.approved_by,
        'approved_at', v_day_approval.approved_at,
        'notes', v_day_approval.notes,
        'activities', COALESCE(v_activities, '[]'::JSONB),
        'summary', jsonb_build_object(
            'total_shift_minutes', v_total_shift_minutes,
            'approved_minutes', v_approved_minutes,
            'rejected_minutes', v_rejected_minutes,
            'needs_review_count', v_needs_review_count,
            'untracked_minutes', v_untracked_minutes
        )
    );

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

**Step 2: In the SAME migration file, redefine `get_weekly_approval_summary` to add `untracked_minutes`**

Key changes to migration 127 logic:
- Add `live_total_classified` to `live_day_totals` CTE (sum of ALL activity durations regardless of status)
- Output `untracked_minutes` per day = `total_shift_minutes - live_total_classified`
- For approved days: `total - frozen_approved - frozen_rejected`

```sql
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
            s.clocked_in_at::DATE AS shift_date,
            SUM(EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at)) / 60)::INTEGER AS total_shift_minutes,
            bool_or(s.status = 'active') AS has_active_shift
        FROM shifts s
        WHERE s.clocked_in_at::DATE BETWEEN p_week_start AND v_week_end
          AND s.employee_id IN (SELECT employee_id FROM employee_list)
        GROUP BY s.employee_id, s.clocked_in_at::DATE
    ),
    existing_approvals AS (
        SELECT da.employee_id, da.date, da.status, da.approved_minutes, da.rejected_minutes
        FROM day_approvals da
        WHERE da.date BETWEEN p_week_start AND v_week_end
          AND da.employee_id IN (SELECT employee_id FROM employee_list)
    ),
    live_activity_classification AS (
        -- Stops
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

        -- Trips
        SELECT
            t.employee_id,
            t.started_at::DATE,
            t.duration_minutes,
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
        LEFT JOIN day_approvals da ON da.employee_id = t.employee_id AND da.date = t.started_at::DATE
        LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
            AND ao.activity_type = 'trip' AND ao.activity_id = t.id
        WHERE t.started_at::DATE BETWEEN p_week_start AND v_week_end
          AND t.employee_id IN (SELECT employee_id FROM employee_list)
    ),
    live_day_totals AS (
        SELECT
            employee_id,
            activity_date,
            COALESCE(SUM(duration_minutes) FILTER (WHERE final_status = 'approved'), 0)::INTEGER AS live_approved,
            COALESCE(SUM(duration_minutes) FILTER (WHERE final_status = 'rejected'), 0)::INTEGER AS live_rejected,
            COALESCE(COUNT(*) FILTER (WHERE final_status = 'needs_review'), 0)::INTEGER AS live_needs_review_count,
            COALESCE(SUM(duration_minutes), 0)::INTEGER AS live_total_classified
        FROM live_activity_classification
        GROUP BY employee_id, activity_date
    ),
    pending_day_stats AS (
        SELECT
            ds.employee_id,
            ds.shift_date,
            ds.total_shift_minutes,
            ds.has_active_shift,
            ea.status AS approval_status,
            ea.approved_minutes AS frozen_approved,
            ea.rejected_minutes AS frozen_rejected,
            ldt.live_approved,
            ldt.live_rejected,
            ldt.live_needs_review_count,
            ldt.live_total_classified
        FROM day_shifts ds
        LEFT JOIN existing_approvals ea
            ON ea.employee_id = ds.employee_id AND ea.date = ds.shift_date
        LEFT JOIN live_day_totals ldt
            ON ldt.employee_id = ds.employee_id AND ldt.activity_date = ds.shift_date
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
                        'total_shift_minutes', COALESCE(pds.total_shift_minutes, 0),
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
                        'untracked_minutes', CASE
                            WHEN pds.total_shift_minutes IS NULL THEN 0
                            WHEN pds.approval_status = 'approved' THEN
                                GREATEST(COALESCE(pds.total_shift_minutes, 0) - COALESCE(pds.frozen_approved, 0) - COALESCE(pds.frozen_rejected, 0), 0)
                            ELSE
                                GREATEST(COALESCE(pds.total_shift_minutes, 0) - COALESCE(pds.live_total_classified, 0), 0)
                        END
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
```

**Step 3: Apply migration**

Run: `supabase db push` or apply via Supabase MCP tool.

**Step 4: Verify with Damien's data**

```sql
SELECT get_day_approval_detail('84e748e4-661d-49d0-8ae2-751ce2d02c00', '2026-03-03');
```

Expected: activities array now includes `untracked` entries for the 19-min gap in shift 1 and the ~4h28 gap after Home Irene in shift 2. Summary includes `untracked_minutes`.

**Step 5: Commit**

```bash
git add supabase/migrations/129_untracked_time_visibility.sql
git commit -m "feat: detect untracked shift gaps in approval RPCs (migration 129)"
```

---

### Task 2: Dashboard types — Add untracked support

**Files:**
- Modify: `dashboard/src/types/mileage.ts:229-292`

**Step 1: Update ApprovalActivity interface**

At line 230, add `'untracked'` to the activity_type union and add `gps_point_count`:

```typescript
export interface ApprovalActivity {
  activity_type: 'trip' | 'stop' | 'clock_in' | 'clock_out' | 'untracked';
  // ... all existing fields ...
  gps_point_count: number | null;  // NEW: GPS points in untracked period
}
```

**Step 2: Update DayApprovalDetail summary**

At line 269, add `untracked_minutes`:

```typescript
  summary: {
    total_shift_minutes: number;
    approved_minutes: number;
    rejected_minutes: number;
    needs_review_count: number;
    untracked_minutes: number;  // NEW
  };
```

**Step 3: Update WeeklyDayEntry**

At line 277, add `untracked_minutes`:

```typescript
export interface WeeklyDayEntry {
  date: string;
  has_shifts: boolean;
  has_active_shift: boolean;
  status: DayApprovalStatus;
  total_shift_minutes: number;
  approved_minutes: number | null;
  rejected_minutes: number | null;
  needs_review_count: number;
  untracked_minutes: number;  // NEW
}
```

**Step 4: Commit**

```bash
git add dashboard/src/types/mileage.ts
git commit -m "feat: add untracked activity type and untracked_minutes to approval types"
```

---

### Task 3: Dashboard — Render untracked rows in day detail

**Files:**
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx`

**Step 1: Add WifiOff import**

At line 8, add `WifiOff` to the lucide-react import:

```typescript
import {
  Loader2, CheckCircle2, XCircle, AlertTriangle,
  MapPin, MapPinOff, Car, Footprints, Clock,
  LogIn, LogOut, ChevronDown, ChevronUp, ArrowRight,
  Calendar, User, WifiOff,  // ADD WifiOff
} from 'lucide-react';
```

**Step 2: Handle 'untracked' in ApprovalActivityIcon**

At line 87, add untracked case at the top of the function:

```typescript
function ApprovalActivityIcon({ activity }: { activity: ApprovalActivity }) {
  if (activity.activity_type === 'untracked') {
    return <WifiOff className="h-4 w-4 text-gray-400" />;
  }
  if (activity.activity_type === 'trip') {
    // ... existing ...
```

**Step 3: Handle 'untracked' in ActivityRow rendering**

In the ActivityRow component (~line 854), add `isUntracked`:

```typescript
const isUntracked = activity.activity_type === 'untracked';
```

Update `isClock` check to include untracked for disable override buttons:

```typescript
const canOverride = !isClock && !isUntracked;
const canExpand = !isClock && !isUntracked;
```

In the action column (~line 904), change condition:

```typescript
{!isApproved && canOverride ? (
  // approve/reject buttons
) : !isApproved && isUntracked ? (
  <span className="text-[10px] text-gray-400 italic">info</span>
) : (
  // approved badge
)}
```

In the details column (~line 1007), add untracked rendering:

```typescript
) : isUntracked ? (
  <div className="space-y-1">
    <span className={`text-xs font-medium text-gray-600`}>
      Période non suivie
    </span>
    <div className="text-[10px] italic text-gray-500">
      {activity.auto_reason}
    </div>
  </div>
) : (
  // existing clock rendering
```

**Step 4: Add untracked-specific row styling**

In the `statusConfig` object, the 'needs_review' styles will apply by default. But for untracked we want a more muted gray style. Add a check in the row className:

```typescript
const rowStyle = isUntracked
  ? 'bg-gray-50 border-l-4 border-l-gray-300 hover:bg-gray-100/80 border-dashed'
  : statusConfig.row;
```

Use `rowStyle` instead of `statusConfig.row` in the `<tr>` className.

**Step 5: Exclude untracked from visibleNeedsReviewCount**

At line 389:

```typescript
const visibleNeedsReviewCount = useMemo(() => {
  return processedActivities.filter(
    pa => pa.item.final_status === 'needs_review' && pa.item.activity_type !== 'untracked'
  ).length;
}, [processedActivities]);
```

**Step 6: Add "Non suivi" summary card**

At line 639 (after the GPS perdu card), add a new card:

```typescript
{(detail.summary.untracked_minutes ?? 0) > 0 && (
  <div className="group relative overflow-hidden flex flex-col p-4 bg-gray-50 rounded-2xl border border-gray-200 border-dashed shadow-sm transition-all hover:shadow-md">
    <div className="absolute top-0 right-0 p-3 text-gray-200/50 group-hover:scale-110 transition-transform">
      <WifiOff className="h-12 w-12" />
    </div>
    <span className="text-[10px] uppercase tracking-[0.1em] text-gray-500 font-bold mb-1">Non suivi</span>
    <div className="flex items-baseline gap-1 mt-auto">
      <span className="text-2xl font-black text-gray-600 tracking-tight">
        {formatHours(detail.summary.untracked_minutes)}
      </span>
    </div>
  </div>
)}
```

Update the grid cols to handle 6 columns when both GPS gap and untracked exist:

```typescript
const summaryCardCount = 4
  + (gpsGapTotals.seconds > 0 ? 1 : 0)
  + ((detail.summary.untracked_minutes ?? 0) > 0 ? 1 : 0);

<div className={`grid grid-cols-2 sm:grid-cols-${Math.min(summaryCardCount, 6)} gap-4`}>
```

**Step 7: Commit**

```bash
git add dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "feat: render untracked time gaps in day approval detail"
```

---

### Task 4: Dashboard — Show untracked minutes in weekly grid

**Files:**
- Modify: `dashboard/src/components/approvals/approval-grid.tsx:155-183, 271-280`

**Step 1: Add WifiOff import**

Add `WifiOff` to the lucide-react import at the top of the file.

**Step 2: Show untracked indicator in cell**

In `renderCell` (~line 155), after the needs_review badge, add:

```typescript
{(day.untracked_minutes ?? 0) > 0 && (
  <span className="text-[10px] text-gray-400 flex items-center gap-0.5 justify-center">
    <WifiOff className="h-2.5 w-2.5" />
    {formatHours(day.untracked_minutes)} sans GPS
  </span>
)}
```

**Step 3: Show weekly total untracked**

Add helper function:

```typescript
const getWeekUntracked = (row: WeeklyEmployeeRow): number => {
  return row.days.reduce((sum, d) => sum + (d.untracked_minutes ?? 0), 0);
};
```

In the total column (~line 271), add after rejected:

```typescript
{getWeekUntracked(row) > 0 && (
  <span className="text-[10px] text-gray-400 flex items-center gap-0.5 justify-center">
    <WifiOff className="h-2.5 w-2.5" />
    {formatHours(getWeekUntracked(row))}
  </span>
)}
```

**Step 4: Commit**

```bash
git add dashboard/src/components/approvals/approval-grid.tsx
git commit -m "feat: show untracked minutes in weekly approval grid"
```

---

### Task 5: Verify end-to-end

**Step 1: Apply migration**

Use Supabase MCP or `supabase db push`.

**Step 2: Test with Damien's data**

```sql
SELECT get_day_approval_detail('84e748e4-661d-49d0-8ae2-751ce2d02c00', '2026-03-03');
```

Verify:
- Activities include 'untracked' entries with correct time ranges
- Summary has `untracked_minutes` ≈ 289
- `needs_review_count` is still 0 (untracked excluded)

**Step 3: Test weekly summary**

```sql
SELECT get_weekly_approval_summary('2026-03-02'); -- Monday of that week
```

Verify: Damien's entry for March 3 shows `untracked_minutes` ≈ 289.

**Step 4: Visual check**

Open dashboard, navigate to Damien's week, verify:
- Grid cell shows gray "4h49 sans GPS" indicator
- Day detail shows untracked rows in timeline with dashed gray style
- "Non suivi" summary card appears
- Approve button still works (untracked doesn't block)

**Step 5: Final commit**

```bash
git add -A
git commit -m "feat: untracked time visibility in approval dashboard"
```
