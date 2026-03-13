# Approval Simplification Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make stops the primary approval unit with trips auto-deriving status, reducing admin decisions per day from ~7 to 0-2.

**Architecture:** Three SQL migrations update trip classification (endpoint-only), approve_day (exclude trips from blocking check), and weekly summary (remove flagged_trip_count). One major frontend refactor splits ActivityRow into StopRow (full buttons) and TripConnectorRow (compact, expand-to-override).

**Tech Stack:** PostgreSQL/Supabase (PL/pgSQL), Next.js 14, React, TypeScript, shadcn/ui, Tailwind CSS

---

### Task 1: SQL Migration — Simplify trip auto-classification

**Files:**
- Create: `supabase/migrations/134_approval_trip_derived_status.sql`

This migration replaces `get_day_approval_detail` to remove GPS gap and duration overrides from trip auto-classification. Trips now derive status purely from endpoint locations.

**Step 1: Create migration file**

The ONLY changes from migration 111 are in the trip CASE expressions (lines 119-143 in 111). Remove the first two WHEN clauses (`has_gps_gap` and `duration_minutes > 60`) from both the auto_status and auto_reason CASEs. Everything else stays identical.

```sql
-- Migration 134: Simplify trip auto-classification
-- Trips now derive status purely from endpoint stop locations.
-- GPS gaps and long duration become warning flags only, not status-affecting.

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

    -- If already approved, return frozen data
    IF v_day_approval.status = 'approved' THEN
        NULL; -- Fall through to activity building
    END IF;

    -- Calculate total shift minutes for completed shifts on this day
    SELECT COALESCE(SUM(
        EXTRACT(EPOCH FROM (COALESCE(clocked_out_at, now()) - clocked_in_at)) / 60
    )::INTEGER, 0)
    INTO v_total_shift_minutes
    FROM shifts
    WHERE employee_id = p_employee_id
      AND clocked_in_at::DATE = p_date
      AND status = 'completed';

    -- Build classified activity list
    WITH activity_data AS (
        -- STOPS (unchanged from migration 111)
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
                WHEN l.location_type IN ('office', 'building', 'vendor', 'gaz') THEN 'approved'
                WHEN l.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN sc.matched_location_id IS NULL THEN 'needs_review'
                ELSE 'needs_review'
            END AS auto_status,
            CASE
                WHEN l.location_type = 'office' THEN 'Lieu de travail (bureau)'
                WHEN l.location_type = 'building' THEN 'Lieu de travail (immeuble)'
                WHEN l.location_type = 'vendor' THEN 'Fournisseur'
                WHEN l.location_type = 'gaz' THEN 'Station-service'
                WHEN l.location_type = 'home' THEN 'Domicile'
                WHEN l.location_type = 'cafe_restaurant' THEN 'Café / Restaurant'
                WHEN l.location_type = 'other' THEN 'Lieu non-professionnel'
                WHEN sc.matched_location_id IS NULL THEN 'Lieu inconnu'
                ELSE 'Lieu inconnu'
            END AS auto_reason,
            NULL::DECIMAL AS distance_km,
            NULL::DECIMAL AS road_distance_km,
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

        -- TRIPS: status derived purely from endpoint locations
        -- GPS gaps and long duration are kept as fields but DO NOT affect auto_status
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
            -- CHANGED: endpoint-only classification (no GPS gap or duration override)
            CASE
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('office', 'building', 'vendor', 'gaz')
                 AND COALESCE(el.location_type, arr_loc.location_type) IN ('office', 'building', 'vendor', 'gaz') THEN 'approved'
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('home', 'cafe_restaurant', 'other')
                  OR COALESCE(el.location_type, arr_loc.location_type) IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IS NULL
                  OR COALESCE(el.location_type, arr_loc.location_type) IS NULL THEN 'needs_review'
                ELSE 'needs_review'
            END,
            -- CHANGED: auto_reason no longer references GPS gap or duration
            CASE
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('office', 'building', 'vendor', 'gaz')
                 AND COALESCE(el.location_type, arr_loc.location_type) IN ('office', 'building', 'vendor', 'gaz') THEN 'Déplacement professionnel'
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IN ('home', 'cafe_restaurant', 'other')
                  OR COALESCE(el.location_type, arr_loc.location_type) IN ('home', 'cafe_restaurant', 'other') THEN 'Trajet personnel'
                WHEN COALESCE(sl.location_type, dep_loc.location_type) IS NULL
                  OR COALESCE(el.location_type, arr_loc.location_type) IS NULL THEN 'Destination inconnue'
                ELSE 'À vérifier'
            END,
            t.distance_km,
            t.road_distance_km,
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

        -- CLOCK IN (unchanged from migration 111)
        SELECT
            'clock_in'::TEXT,
            s.id,
            s.id AS shift_id,
            s.clocked_in_at,
            s.clocked_in_at,
            0 AS duration_minutes,
            ci_loc.id AS matched_location_id,
            ci_loc.name AS location_name,
            ci_loc.location_type::TEXT AS location_type,
            (s.clock_in_location->>'latitude')::DECIMAL,
            (s.clock_in_location->>'longitude')::DECIMAL,
            NULL::INTEGER, NULL::INTEGER,
            CASE
                WHEN ci_loc.location_type IN ('office', 'building', 'vendor', 'gaz') THEN 'approved'
                WHEN ci_loc.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN ci_loc.id IS NULL THEN 'needs_review'
                ELSE 'needs_review'
            END,
            CASE
                WHEN ci_loc.location_type IN ('office', 'building', 'vendor', 'gaz') THEN 'Clock-in sur lieu de travail'
                WHEN ci_loc.location_type = 'home' THEN 'Clock-in depuis le domicile'
                WHEN ci_loc.location_type IN ('cafe_restaurant', 'other') THEN 'Clock-in hors lieu de travail'
                WHEN ci_loc.id IS NULL THEN 'Clock-in lieu inconnu'
                ELSE 'Clock-in lieu inconnu'
            END,
            NULL::DECIMAL, NULL::DECIMAL, NULL::TEXT, NULL::BOOLEAN,
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

        -- CLOCK OUT (unchanged from migration 111)
        SELECT
            'clock_out'::TEXT,
            s.id,
            s.id AS shift_id,
            s.clocked_out_at,
            s.clocked_out_at,
            0 AS duration_minutes,
            co_loc.id AS matched_location_id,
            co_loc.name AS location_name,
            co_loc.location_type::TEXT AS location_type,
            (s.clock_out_location->>'latitude')::DECIMAL,
            (s.clock_out_location->>'longitude')::DECIMAL,
            NULL::INTEGER, NULL::INTEGER,
            CASE
                WHEN co_loc.location_type IN ('office', 'building', 'vendor', 'gaz') THEN 'approved'
                WHEN co_loc.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                WHEN co_loc.id IS NULL THEN 'needs_review'
                ELSE 'needs_review'
            END,
            CASE
                WHEN co_loc.location_type IN ('office', 'building', 'vendor', 'gaz') THEN 'Clock-out sur lieu de travail'
                WHEN co_loc.location_type = 'home' THEN 'Clock-out au domicile'
                WHEN co_loc.location_type IN ('cafe_restaurant', 'other') THEN 'Clock-out hors lieu de travail'
                WHEN co_loc.id IS NULL THEN 'Clock-out lieu inconnu'
                ELSE 'Clock-out lieu inconnu'
            END,
            NULL::DECIMAL, NULL::DECIMAL, NULL::TEXT, NULL::BOOLEAN,
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
            'road_distance_km', c.road_distance_km,
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

    -- Compute summary from activities
    SELECT
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (WHERE a->>'final_status' = 'approved'), 0),
        COALESCE(SUM((a->>'duration_minutes')::INTEGER) FILTER (WHERE a->>'final_status' = 'rejected'), 0),
        -- CHANGED: only count stops and clocks as needs_review (trips derive from stops)
        COALESCE(COUNT(*) FILTER (WHERE a->>'final_status' = 'needs_review' AND a->>'activity_type' NOT IN ('trip')), 0)
    INTO v_approved_minutes, v_rejected_minutes, v_needs_review_count
    FROM jsonb_array_elements(COALESCE(v_activities, '[]'::JSONB)) a;

    -- If day is already approved, use frozen values for summary
    IF v_day_approval.status = 'approved' THEN
        v_approved_minutes := v_day_approval.approved_minutes;
        v_rejected_minutes := v_day_approval.rejected_minutes;
        v_needs_review_count := 0;
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
            'needs_review_count', v_needs_review_count
        )
    );

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

**Step 2: Apply migration**

Run: `cd supabase && supabase db push`

Or to apply to production directly:
```bash
supabase db push --linked
```

**Step 3: Verify trip classification changed**

Run against a known employee/date with GPS gap trips to confirm they no longer show as needs_review:
```sql
SELECT a->>'activity_type', a->>'auto_status', a->>'has_gps_gap', a->>'auto_reason'
FROM jsonb_array_elements(
  (SELECT get_day_approval_detail('EMPLOYEE_UUID', '2026-03-05'))->'activities'
) a
WHERE a->>'activity_type' = 'trip';
```

Expected: Trips with GPS gaps now show 'approved' or 'rejected' based on endpoints, not 'needs_review'.

**Step 4: Commit**

```bash
git add supabase/migrations/134_approval_trip_derived_status.sql
git commit -m "feat: simplify trip auto-classification to endpoint-only logic

Trips now derive status purely from endpoint stop locations.
GPS gaps and long duration become warning flags only."
```

---

### Task 2: SQL Migration — Update approve_day to exclude trips from blocking check

**Files:**
- Create: `supabase/migrations/135_approve_day_exclude_trips.sql`

The `approve_day` RPC calls `get_day_approval_detail` and checks `needs_review_count`. Since Task 1 already changed the needs_review_count computation in `get_day_approval_detail` to exclude trips, the `approve_day` function itself does NOT need changes — it reads from the summary which is already correct.

However, `get_weekly_approval_summary` still uses `flagged_trip_count` as a proxy. This needs updating.

```sql
-- Migration 135: Update weekly approval summary to exclude trip flags from needs_review
-- Trips derive status from endpoint stops, so flagged_trip_count is no longer relevant.

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
    pending_day_stats AS (
        SELECT
            ds.employee_id,
            ds.shift_date,
            ds.total_shift_minutes,
            ds.has_active_shift,
            ea.status AS approval_status,
            ea.approved_minutes AS frozen_approved,
            ea.rejected_minutes AS frozen_rejected,
            -- Only count unmatched stops (trips no longer count)
            (
                SELECT COUNT(*)
                FROM stationary_clusters sc
                LEFT JOIN locations l ON l.id = sc.matched_location_id
                WHERE sc.employee_id = ds.employee_id
                  AND sc.started_at::DATE = ds.shift_date
                  AND sc.duration_seconds >= 180
                  AND sc.matched_location_id IS NULL
            ) AS unmatched_stop_count
            -- REMOVED: flagged_trip_count subquery
        FROM day_shifts ds
        LEFT JOIN existing_approvals ea
            ON ea.employee_id = ds.employee_id AND ea.date = ds.shift_date
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
                            -- CHANGED: only unmatched stops trigger needs_review
                            WHEN pds.unmatched_stop_count > 0 THEN 'needs_review'
                            ELSE 'pending'
                        END,
                        'total_shift_minutes', COALESCE(pds.total_shift_minutes, 0),
                        'approved_minutes', CASE
                            WHEN pds.approval_status = 'approved' THEN pds.frozen_approved
                            ELSE NULL
                        END,
                        'rejected_minutes', CASE
                            WHEN pds.approval_status = 'approved' THEN pds.frozen_rejected
                            ELSE NULL
                        END,
                        'needs_review_count', CASE
                            WHEN pds.approval_status = 'approved' THEN 0
                            -- CHANGED: only unmatched stops
                            ELSE COALESCE(pds.unmatched_stop_count, 0)
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

**Step 2: Apply migration**

```bash
cd supabase && supabase db push --linked
```

**Step 3: Commit**

```bash
git add supabase/migrations/135_approve_day_exclude_trips.sql
git commit -m "feat: weekly summary excludes trip flags from needs_review count

Only unmatched stops now trigger needs_review status on the weekly grid."
```

---

### Task 3: Frontend — Remove cascade logic from handleOverride

**Files:**
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx`

Since trips auto-derive status from endpoint stops in SQL, the frontend cascade logic is now unnecessary. When a stop is overridden, the returned `get_day_approval_detail` result already has the correct trip statuses.

**Step 1: Simplify handleOverride**

Remove the cascade blocks (lines 451-463 and 489-501). The function becomes a simple toggle:

In `handleOverride`, remove:
- Lines 451-463: The "Cascade: un-rejecting a stop also un-rejects adjacent trips" block
- Lines 489-501: The "Cascade: rejecting a stop also rejects adjacent trips" block

Also remove the `findAdjacentTrips` callback (lines 424-431) since it's no longer used.

The simplified handleOverride:

```typescript
const handleOverride = async (activity: ApprovalActivity, newStatus: 'approved' | 'rejected') => {
  if (activity.override_status === newStatus) {
    setIsSaving(true);
    try {
      const { data, error } = await supabaseClient.rpc('remove_activity_override', {
        p_employee_id: employeeId,
        p_date: date,
        p_activity_type: activity.activity_type,
        p_activity_id: activity.activity_id,
      });
      if (error) {
        toast.error('Erreur: ' + error.message);
        return;
      }
      setDetail(data as DayApprovalDetailType);
    } finally {
      setIsSaving(false);
    }
    return;
  }

  setIsSaving(true);
  try {
    const { data, error } = await supabaseClient.rpc('save_activity_override', {
      p_employee_id: employeeId,
      p_date: date,
      p_activity_type: activity.activity_type,
      p_activity_id: activity.activity_id,
      p_status: newStatus,
    });
    if (error) {
      toast.error('Erreur: ' + error.message);
      return;
    }
    setDetail(data as DayApprovalDetailType);
  } finally {
    setIsSaving(false);
  }
};
```

**Step 2: Update visibleNeedsReviewCount to exclude trips**

Change the filter to exclude trips (matches the SQL change):

```typescript
const visibleNeedsReviewCount = useMemo(() =>
  processedActivities.filter(pa =>
    pa.item.final_status === 'needs_review' &&
    pa.item.activity_type !== 'trip'
  ).length
, [processedActivities]);
```

**Step 3: Verify the dashboard compiles**

```bash
cd dashboard && npm run build
```

**Step 4: Commit**

```bash
git add dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "refactor: remove trip cascade logic, trips auto-derive from SQL"
```

---

### Task 4: Frontend — Split ActivityRow into StopRow and TripConnectorRow

**Files:**
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx`

This is the main visual change. Replace the single `ActivityRow` component with two separate components and update the rendering loop.

**Step 1: Create TripConnectorRow component**

Add this new component after the existing `ActivityRow` (which will become StopRow). TripConnectorRow is a compact row with no approve/reject buttons by default. When expanded, it shows the route map plus override buttons.

```typescript
function TripConnectorRow({
  pa,
  isApproved,
  isSaving,
  isExpanded,
  onToggle,
  onOverride,
}: {
  pa: ProcessedActivity<ApprovalActivity>;
  isApproved: boolean;
  isSaving: boolean;
  isExpanded: boolean;
  onToggle: () => void;
  onOverride: (activity: ApprovalActivity, status: 'approved' | 'rejected') => void;
}) {
  const { item: activity } = pa;
  const hasOverride = activity.override_status !== null;

  const statusColor = {
    approved: {
      bg: 'bg-green-50/40',
      text: 'text-green-700',
      subtext: 'text-green-600/60',
      border: 'border-l-green-400',
    },
    rejected: {
      bg: 'bg-red-50/40',
      text: 'text-red-700',
      subtext: 'text-red-600/60',
      border: 'border-l-red-400',
    },
    needs_review: {
      bg: 'bg-amber-50/30',
      text: 'text-amber-700',
      subtext: 'text-amber-600/60',
      border: 'border-l-amber-400',
    },
  }[activity.final_status];

  return (
    <>
      <tr
        className={`${statusColor.bg} border-l-2 ${statusColor.border} cursor-pointer transition-all hover:brightness-95 group`}
        onClick={onToggle}
      >
        {/* Empty action column — no buttons */}
        <td className="px-3 py-1.5">
          {hasOverride && (
            <div className="flex justify-center">
              <div className="h-2 w-2 rounded-full bg-blue-500" title="Override manuel" />
            </div>
          )}
        </td>

        {/* Empty clock column */}
        <td className="py-1.5" />

        {/* Arrow connector icon */}
        <td className="px-2 py-1.5 text-center">
          <div className="flex justify-center">
            {activity.transport_mode === 'walking'
              ? <Footprints className="h-3 w-3 text-orange-400" />
              : <Car className="h-3 w-3 text-blue-400" />
            }
          </div>
        </td>

        {/* Duration + distance inline */}
        <td colSpan={3} className="px-3 py-1.5">
          <div className="flex items-center gap-2 ml-2">
            <ArrowRight className="h-3 w-3 text-muted-foreground/40 flex-shrink-0" />
            <span className={`text-[11px] font-medium tabular-nums ${statusColor.text}`}>
              {formatDurationMinutes(activity.duration_minutes)}
            </span>
            {(activity.road_distance_km ?? activity.distance_km) ? (
              <span className={`text-[11px] tabular-nums ${statusColor.subtext}`}>
                {formatDistance(activity.road_distance_km ?? activity.distance_km)}
              </span>
            ) : null}
            <span className={`text-[11px] truncate ${statusColor.subtext}`}>
              {activity.start_location_name || '?'} → {activity.end_location_name || '?'}
            </span>
            {activity.has_gps_gap && (
              <AlertTriangle className="h-3 w-3 text-amber-500 flex-shrink-0" title="Données GPS incomplètes" />
            )}
            {activity.duration_minutes > 60 && (
              <Clock className="h-3 w-3 text-amber-500 flex-shrink-0" title={`Trajet long: ${activity.duration_minutes} min`} />
            )}
          </div>
        </td>

        {/* Distance column */}
        <td className="py-1.5" />

        {/* Expand chevron */}
        <td className="px-3 py-1.5 text-center">
          <div className={`rounded-full p-0.5 transition-colors ${isExpanded ? 'bg-muted' : 'group-hover:bg-muted'}`}>
            {isExpanded
              ? <ChevronUp className="h-3 w-3 text-primary" />
              : <ChevronDown className="h-3 w-3 text-muted-foreground" />
            }
          </div>
        </td>
      </tr>

      {/* Expanded: route map + override toggle */}
      {isExpanded && (
        <tr>
          <td colSpan={8} className="p-0 border-b">
            <div className="px-4 py-4 bg-muted/10 border-t border-b space-y-4">
              {/* Override controls (only when day not approved) */}
              {!isApproved && (
                <div className="flex items-center gap-3 px-2 py-2 bg-background rounded-lg border">
                  <span className="text-xs font-medium text-muted-foreground">Forcer le statut:</span>
                  <div className="flex items-center gap-2" onClick={(e) => e.stopPropagation()}>
                    <Button
                      variant="outline"
                      size="sm"
                      className={`h-7 text-xs rounded-full ${
                        activity.override_status === 'approved'
                          ? 'border-green-500 bg-green-50 text-green-700'
                          : 'text-muted-foreground hover:text-green-600 hover:bg-green-50'
                      }`}
                      onClick={() => onOverride(activity, 'approved')}
                      disabled={isSaving}
                    >
                      <CheckCircle2 className="h-3 w-3 mr-1" />
                      Approuver
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      className={`h-7 text-xs rounded-full ${
                        activity.override_status === 'rejected'
                          ? 'border-red-500 bg-red-50 text-red-700'
                          : 'text-muted-foreground hover:text-red-600 hover:bg-red-50'
                      }`}
                      onClick={() => onOverride(activity, 'rejected')}
                      disabled={isSaving}
                    >
                      <XCircle className="h-3 w-3 mr-1" />
                      Rejeter
                    </Button>
                  </div>
                  {hasOverride && (
                    <Badge variant="outline" className="text-[10px] border-blue-300 text-blue-600">
                      Override actif
                    </Badge>
                  )}
                </div>
              )}

              {/* Route map */}
              <TripExpandDetail activity={activity} />
            </div>
          </td>
        </tr>
      )}
    </>
  );
}
```

**Step 2: Update the rendering loop in the table body**

Replace the current `processedActivities.map()` (around line 768) to use different components for trips vs stops/clocks:

```typescript
{processedActivities.map((pa) => {
  const key = `${pa.item.activity_type}-${pa.item.activity_id}`;
  const isTrip = pa.item.activity_type === 'trip';

  return isTrip ? (
    <TripConnectorRow
      key={key}
      pa={pa}
      isApproved={isApproved}
      isSaving={isSaving}
      isExpanded={expandedId === key}
      onToggle={() => setExpandedId(expandedId === key ? null : key)}
      onOverride={handleOverride}
    />
  ) : (
    <ActivityRow
      key={key}
      pa={pa}
      isApproved={isApproved}
      isSaving={isSaving}
      isExpanded={expandedId === key}
      onToggle={() => setExpandedId(expandedId === key ? null : key)}
      onOverride={handleOverride}
    />
  );
})}
```

**Step 3: Remove trip-specific rendering from ActivityRow**

In the existing `ActivityRow` component, remove the trip-related conditional branches since trips are now handled by `TripConnectorRow`. Specifically:
- Remove `const isTrip = activity.activity_type === 'trip';` (no longer needed)
- In the Details `<td>`, remove the `isTrip ? (...)` branch — only keep stop and clock rendering
- In the Distance `<td>`, always show `—` (trips have their own row now)
- In the expanded section, remove the `isTrip ? (<TripExpandDetail>)` branch

**Step 4: Verify build**

```bash
cd dashboard && npm run build
```

**Step 5: Commit**

```bash
git add dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "feat: compact trip connector rows with expand-to-override

Stops are primary rows with approve/reject buttons.
Trips are compact connector rows, expandable to see route map
and manual override controls."
```

---

### Task 5: Manual verification on production data

**Step 1: Open the approvals page**

Navigate to `https://time.trilogis.ca/dashboard/approvals`, pick an employee day with multiple stops and trips.

**Step 2: Verify the layout**

Confirm:
- Stops show as full-height rows with approve/reject buttons
- Trips show as compact connector rows between stops (no buttons visible)
- Trip rows show: arrow icon, duration, distance, start → end location names
- GPS gap warning icons appear on relevant trip rows
- Long duration (>60 min) warning icons appear on relevant trip rows

**Step 3: Verify trip auto-classification**

- Trips between two approved locations show green (approved)
- Trips to/from home show red (rejected)
- Trips with GPS gaps between two approved locations still show green (not needs_review)

**Step 4: Verify expand-to-override on trips**

- Click a trip connector row to expand
- Confirm route map appears
- Confirm "Forcer le statut" controls appear (Approuver / Rejeter buttons)
- Override a trip, confirm it saves and shows the blue dot indicator

**Step 5: Verify day approval flow**

- Resolve any unmatched stops
- Confirm "Approve day" button is enabled even if trips have GPS gaps
- Approve the day, confirm it freezes correctly

**Step 6: Commit if any fixes needed**

```bash
git add -A
git commit -m "fix: address issues found during manual verification"
```
