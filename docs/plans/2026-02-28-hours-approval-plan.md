# Hours Approval System — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a shift hours approval workflow with automatic classification rules and a weekly grid dashboard for admins.

**Architecture:** On-the-fly classification via Supabase RPC — auto-classifies each activity line (trip/stop/clock event) based on matched location type. Admin overrides and final day approvals are stored in 2 new tables. Dashboard page shows a week×employee grid with drill-down to annotated activity timeline.

**Tech Stack:** PostgreSQL/Supabase (migrations, RPCs), Next.js 14 (App Router), shadcn/ui, Tailwind CSS, Zod, TypeScript

**Design Doc:** `docs/plans/2026-02-28-hours-approval-design.md`

---

## Classification Rules Reference

### Location Type → Auto Status
| Location Type | Auto Status |
|---|---|
| `office` | `approved` |
| `building` | `approved` |
| `vendor` | `approved` |
| `gaz` | `approved` |
| `home` | `rejected` |
| `cafe_restaurant` | `rejected` |
| `other` | `rejected` |
| No match (NULL) | `needs_review` |

### Trip Rules
- Both endpoints at approved locations → `approved`
- Either endpoint at rejected location → `rejected`
- Either endpoint unmatched → `needs_review`
- Duration > 60 min → `needs_review` (even if endpoints approved)
- `has_gps_gap = true` → `needs_review` (even if endpoints approved)

### Clock Event Rules
- Matched to approved location type → `approved`
- Matched to rejected location type → `rejected`
- No match → `needs_review`

---

## Task 1: Migration — Create tables

**Files:**
- Create: `supabase/migrations/092_hours_approval.sql`

**Step 1: Write the migration**

```sql
-- Migration 092: Hours approval system
-- Two tables: day_approvals (day-level status) + activity_overrides (line-level admin decisions)

-- ============================================================
-- Table: day_approvals
-- ============================================================
CREATE TABLE day_approvals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
    date DATE NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved')),
    total_shift_minutes INTEGER,
    approved_minutes INTEGER,
    rejected_minutes INTEGER,
    approved_by UUID REFERENCES employee_profiles(id),
    approved_at TIMESTAMPTZ,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(employee_id, date)
);

-- Indexes
CREATE INDEX idx_day_approvals_employee_date ON day_approvals(employee_id, date);
CREATE INDEX idx_day_approvals_status ON day_approvals(status);
CREATE INDEX idx_day_approvals_date ON day_approvals(date);

-- Updated_at trigger
CREATE TRIGGER set_day_approvals_updated_at
    BEFORE UPDATE ON day_approvals
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- Table: activity_overrides
-- ============================================================
CREATE TABLE activity_overrides (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    day_approval_id UUID NOT NULL REFERENCES day_approvals(id) ON DELETE CASCADE,
    activity_type TEXT NOT NULL CHECK (activity_type IN ('trip', 'stop', 'clock_in', 'clock_out')),
    activity_id UUID NOT NULL,
    override_status TEXT NOT NULL CHECK (override_status IN ('approved', 'rejected')),
    reason TEXT,
    created_by UUID NOT NULL REFERENCES employee_profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(day_approval_id, activity_type, activity_id)
);

CREATE INDEX idx_activity_overrides_day ON activity_overrides(day_approval_id);

-- ============================================================
-- RLS Policies
-- ============================================================

ALTER TABLE day_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE activity_overrides ENABLE ROW LEVEL SECURITY;

-- day_approvals: admin/super_admin full access
CREATE POLICY "admin_full_access_day_approvals"
    ON day_approvals
    FOR ALL
    USING (is_admin_or_super_admin(auth.uid()));

-- day_approvals: employees can view their own
CREATE POLICY "employee_view_own_day_approvals"
    ON day_approvals
    FOR SELECT
    USING (employee_id = auth.uid());

-- activity_overrides: admin/super_admin full access (via join check)
CREATE POLICY "admin_full_access_activity_overrides"
    ON activity_overrides
    FOR ALL
    USING (is_admin_or_super_admin(auth.uid()));
```

**Step 2: Apply the migration**

Run: `cd supabase && supabase db push`

Verify tables exist:
```sql
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public' AND table_name IN ('day_approvals', 'activity_overrides');
```
Expected: 2 rows returned.

**Step 3: Commit**

```bash
git add supabase/migrations/092_hours_approval.sql
git commit -m "feat: add day_approvals + activity_overrides tables (migration 092)"
```

---

## Task 2: RPC — `get_day_approval_detail`

The core RPC that returns the activity timeline annotated with auto-classification and overrides.

**Files:**
- Create: `supabase/migrations/093_get_day_approval_detail.sql`

**Step 1: Write the RPC**

This RPC reuses the same data sources as `get_employee_activity` (trips, stationary_clusters, shifts) but adds:
- `location_type` for matched locations (needed for classification rules)
- `auto_status` computed from location_type rules
- `auto_reason` explaining the classification
- `override_status` from activity_overrides table
- `final_status` = COALESCE(override_status, auto_status)
- Summary totals

```sql
-- Migration 093: get_day_approval_detail RPC
-- Returns activity timeline for one employee's day, annotated with approval statuses

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
        -- Still build the activity list for display, but use frozen totals
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
            -- Auto classification for stops
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
            -- Extra fields for display
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

        -- TRIPS
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
            -- Auto classification for trips
            CASE
                -- GPS gap or very long → needs_review regardless
                WHEN t.has_gps_gap = TRUE THEN 'needs_review'
                WHEN t.duration_minutes > 60 THEN 'needs_review'
                -- Both endpoints at approved locations
                WHEN sl.location_type IN ('office', 'building', 'vendor', 'gaz')
                 AND el.location_type IN ('office', 'building', 'vendor', 'gaz') THEN 'approved'
                -- Either endpoint at rejected location
                WHEN sl.location_type IN ('home', 'cafe_restaurant', 'other')
                  OR el.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'rejected'
                -- Either endpoint unmatched
                WHEN t.start_location_id IS NULL OR t.end_location_id IS NULL THEN 'needs_review'
                ELSE 'needs_review'
            END,
            CASE
                WHEN t.has_gps_gap = TRUE THEN 'Données GPS incomplètes'
                WHEN t.duration_minutes > 60 THEN 'Trajet anormalement long (>' || t.duration_minutes || ' min)'
                WHEN sl.location_type IN ('office', 'building', 'vendor', 'gaz')
                 AND el.location_type IN ('office', 'building', 'vendor', 'gaz') THEN 'Déplacement professionnel'
                WHEN sl.location_type IN ('home', 'cafe_restaurant', 'other')
                  OR el.location_type IN ('home', 'cafe_restaurant', 'other') THEN 'Trajet personnel'
                WHEN t.start_location_id IS NULL OR t.end_location_id IS NULL THEN 'Destination inconnue'
                ELSE 'À vérifier'
            END,
            t.distance_km,
            t.transport_mode::TEXT,
            t.has_gps_gap,
            t.start_location_id,
            sl.name::TEXT AS start_location_name,
            sl.location_type::TEXT AS start_location_type,
            t.end_location_id,
            el.name::TEXT AS end_location_name,
            el.location_type::TEXT AS end_location_type
        FROM trips t
        LEFT JOIN locations sl ON sl.id = t.start_location_id
        LEFT JOIN locations el ON el.id = t.end_location_id
        WHERE t.employee_id = p_employee_id
          AND t.started_at >= p_date::TIMESTAMPTZ
          AND t.started_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ

        UNION ALL

        -- CLOCK IN
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

    -- Compute summary from classified activities
    SELECT
        COALESCE(SUM(CASE WHEN final_status = 'approved' THEN duration_minutes ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN final_status = 'rejected' THEN duration_minutes ELSE 0 END), 0),
        COALESCE(COUNT(*) FILTER (WHERE final_status = 'needs_review'), 0)
    INTO v_approved_minutes, v_rejected_minutes, v_needs_review_count
    FROM (
        SELECT
            COALESCE(ao.override_status, ad.auto_status) AS final_status,
            ad.duration_minutes
        FROM activity_data ad
        LEFT JOIN day_approvals da
            ON da.employee_id = p_employee_id AND da.date = p_date
        LEFT JOIN activity_overrides ao
            ON ao.day_approval_id = da.id
           AND ao.activity_type = ad.activity_type
           AND ao.activity_id = ad.activity_id
    ) sub;

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

**Step 2: Apply the migration**

Run: `cd supabase && supabase db push`

**Step 3: Test the RPC with a known employee**

```sql
SELECT get_day_approval_detail(
    'EMPLOYEE_UUID_HERE'::UUID,
    '2026-02-27'::DATE
);
```

Verify output has `activities` array with `auto_status`, `auto_reason`, `final_status` fields.

**Step 4: Commit**

```bash
git add supabase/migrations/093_get_day_approval_detail.sql
git commit -m "feat: add get_day_approval_detail RPC with auto-classification (migration 093)"
```

---

## Task 3: RPC — `get_weekly_approval_summary`

Returns the grid data: one row per employee, with 7 day entries.

**Files:**
- Create: `supabase/migrations/094_get_weekly_approval_summary.sql`

**Step 1: Write the RPC**

```sql
-- Migration 094: get_weekly_approval_summary RPC
-- Returns weekly grid data for the approvals dashboard

CREATE OR REPLACE FUNCTION get_weekly_approval_summary(
    p_week_start DATE
)
RETURNS JSONB AS $$
DECLARE
    v_week_end DATE := p_week_start + INTERVAL '6 days';
    v_result JSONB;
BEGIN
    -- Validate p_week_start is a Monday
    IF EXTRACT(ISODOW FROM p_week_start) != 1 THEN
        RAISE EXCEPTION 'p_week_start must be a Monday, got %', p_week_start;
    END IF;

    WITH employee_list AS (
        -- Get all active employees visible to the caller
        SELECT ep.id AS employee_id, ep.full_name AS employee_name
        FROM employee_profiles ep
        WHERE ep.status = 'active'
        ORDER BY ep.full_name
    ),
    day_shifts AS (
        -- Get completed shifts grouped by employee + day
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
    -- For non-approved days, compute needs_review count
    -- We do a lightweight check: count activities that would be needs_review
    pending_day_stats AS (
        SELECT
            ds.employee_id,
            ds.shift_date,
            ds.total_shift_minutes,
            ds.has_active_shift,
            ea.status AS approval_status,
            ea.approved_minutes AS frozen_approved,
            ea.rejected_minutes AS frozen_rejected,
            -- Count stops at unknown locations (needs_review proxy)
            (
                SELECT COUNT(*)
                FROM stationary_clusters sc
                LEFT JOIN locations l ON l.id = sc.matched_location_id
                WHERE sc.employee_id = ds.employee_id
                  AND sc.started_at::DATE = ds.shift_date
                  AND sc.duration_seconds >= 180
                  AND sc.matched_location_id IS NULL
            ) AS unmatched_stop_count,
            -- Count trips with GPS gaps or long duration
            (
                SELECT COUNT(*)
                FROM trips t
                WHERE t.employee_id = ds.employee_id
                  AND t.started_at::DATE = ds.shift_date
                  AND (t.has_gps_gap = TRUE OR t.duration_minutes > 60)
            ) AS flagged_trip_count
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
                            WHEN (pds.unmatched_stop_count + pds.flagged_trip_count) > 0 THEN 'needs_review'
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
                            ELSE COALESCE(pds.unmatched_stop_count + pds.flagged_trip_count, 0)
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

**Step 2: Apply and test**

Run: `cd supabase && supabase db push`

Test:
```sql
-- Get the Monday of the current week
SELECT get_weekly_approval_summary(
    date_trunc('week', CURRENT_DATE)::DATE
);
```

Verify: returns JSON array with employee names and 7 day entries.

**Step 3: Commit**

```bash
git add supabase/migrations/094_get_weekly_approval_summary.sql
git commit -m "feat: add get_weekly_approval_summary RPC (migration 094)"
```

---

## Task 4: RPC — `save_activity_override` + `approve_day`

**Files:**
- Create: `supabase/migrations/095_approval_actions.sql`

**Step 1: Write the RPCs**

```sql
-- Migration 095: Approval action RPCs
-- save_activity_override: admin overrides a single activity line
-- approve_day: freezes a day's approval

-- ============================================================
-- save_activity_override
-- ============================================================
CREATE OR REPLACE FUNCTION save_activity_override(
    p_employee_id UUID,
    p_date DATE,
    p_activity_type TEXT,
    p_activity_id UUID,
    p_status TEXT,
    p_reason TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_day_approval_id UUID;
    v_caller UUID := auth.uid();
BEGIN
    -- Verify caller is admin
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can save overrides';
    END IF;

    -- Verify valid status
    IF p_status NOT IN ('approved', 'rejected') THEN
        RAISE EXCEPTION 'Invalid override status: %. Must be approved or rejected', p_status;
    END IF;

    -- Verify valid activity type
    IF p_activity_type NOT IN ('trip', 'stop', 'clock_in', 'clock_out') THEN
        RAISE EXCEPTION 'Invalid activity type: %', p_activity_type;
    END IF;

    -- Check day is not already approved
    IF EXISTS(
        SELECT 1 FROM day_approvals
        WHERE employee_id = p_employee_id AND date = p_date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Cannot override activities on an already approved day';
    END IF;

    -- Find or create day_approval row
    INSERT INTO day_approvals (employee_id, date, status)
    VALUES (p_employee_id, p_date, 'pending')
    ON CONFLICT (employee_id, date) DO NOTHING
    RETURNING id INTO v_day_approval_id;

    IF v_day_approval_id IS NULL THEN
        SELECT id INTO v_day_approval_id
        FROM day_approvals
        WHERE employee_id = p_employee_id AND date = p_date;
    END IF;

    -- Upsert override
    INSERT INTO activity_overrides (day_approval_id, activity_type, activity_id, override_status, reason, created_by)
    VALUES (v_day_approval_id, p_activity_type, p_activity_id, p_status, p_reason, v_caller)
    ON CONFLICT (day_approval_id, activity_type, activity_id)
    DO UPDATE SET
        override_status = EXCLUDED.override_status,
        reason = EXCLUDED.reason,
        created_by = EXCLUDED.created_by,
        created_at = now();

    -- Return updated detail
    RETURN get_day_approval_detail(p_employee_id, p_date);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- remove_activity_override
-- ============================================================
CREATE OR REPLACE FUNCTION remove_activity_override(
    p_employee_id UUID,
    p_date DATE,
    p_activity_type TEXT,
    p_activity_id UUID
)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
BEGIN
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can remove overrides';
    END IF;

    -- Check day is not already approved
    IF EXISTS(
        SELECT 1 FROM day_approvals
        WHERE employee_id = p_employee_id AND date = p_date AND status = 'approved'
    ) THEN
        RAISE EXCEPTION 'Cannot modify overrides on an already approved day';
    END IF;

    DELETE FROM activity_overrides ao
    USING day_approvals da
    WHERE ao.day_approval_id = da.id
      AND da.employee_id = p_employee_id
      AND da.date = p_date
      AND ao.activity_type = p_activity_type
      AND ao.activity_id = p_activity_id;

    RETURN get_day_approval_detail(p_employee_id, p_date);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- approve_day
-- ============================================================
CREATE OR REPLACE FUNCTION approve_day(
    p_employee_id UUID,
    p_date DATE,
    p_notes TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_caller UUID := auth.uid();
    v_detail JSONB;
    v_needs_review INTEGER;
    v_approved_minutes INTEGER;
    v_rejected_minutes INTEGER;
    v_total_shift_minutes INTEGER;
BEGIN
    IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION 'Only admins can approve days';
    END IF;

    -- Get current detail to check needs_review
    v_detail := get_day_approval_detail(p_employee_id, p_date);
    v_needs_review := (v_detail->'summary'->>'needs_review_count')::INTEGER;

    IF v_needs_review > 0 THEN
        RAISE EXCEPTION 'Cannot approve day: % activities still need review', v_needs_review;
    END IF;

    v_approved_minutes := (v_detail->'summary'->>'approved_minutes')::INTEGER;
    v_rejected_minutes := (v_detail->'summary'->>'rejected_minutes')::INTEGER;
    v_total_shift_minutes := (v_detail->'summary'->>'total_shift_minutes')::INTEGER;

    -- Upsert day_approvals with frozen values
    INSERT INTO day_approvals (
        employee_id, date, status,
        total_shift_minutes, approved_minutes, rejected_minutes,
        approved_by, approved_at, notes
    )
    VALUES (
        p_employee_id, p_date, 'approved',
        v_total_shift_minutes, v_approved_minutes, v_rejected_minutes,
        v_caller, now(), p_notes
    )
    ON CONFLICT (employee_id, date)
    DO UPDATE SET
        status = 'approved',
        total_shift_minutes = EXCLUDED.total_shift_minutes,
        approved_minutes = EXCLUDED.approved_minutes,
        rejected_minutes = EXCLUDED.rejected_minutes,
        approved_by = EXCLUDED.approved_by,
        approved_at = EXCLUDED.approved_at,
        notes = EXCLUDED.notes;

    RETURN get_day_approval_detail(p_employee_id, p_date);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

**Step 2: Apply and test**

Run: `cd supabase && supabase db push`

**Step 3: Commit**

```bash
git add supabase/migrations/095_approval_actions.sql
git commit -m "feat: add save_activity_override, remove_activity_override, approve_day RPCs (migration 095)"
```

---

## Task 5: Dashboard — Types and validation schemas

**Files:**
- Modify: `dashboard/src/types/mileage.ts` (add new types at end)
- Create: `dashboard/src/lib/validations/approval.ts`

**Step 1: Add TypeScript types**

Append to `dashboard/src/types/mileage.ts`:

```typescript
// ============================================================
// Hours Approval types
// ============================================================

export type ApprovalAutoStatus = 'approved' | 'rejected' | 'needs_review';
export type DayApprovalStatus = 'no_shift' | 'active' | 'pending' | 'needs_review' | 'approved';

export interface ApprovalActivity {
  activity_type: 'trip' | 'stop' | 'clock_in' | 'clock_out';
  activity_id: string;
  shift_id: string;
  started_at: string;
  ended_at: string;
  duration_minutes: number;
  auto_status: ApprovalAutoStatus;
  auto_reason: string;
  override_status: 'approved' | 'rejected' | null;
  override_reason: string | null;
  final_status: ApprovalAutoStatus;
  matched_location_id: string | null;
  location_name: string | null;
  location_type: string | null;
  latitude: number | null;
  longitude: number | null;
  distance_km: number | null;
  transport_mode: string | null;
  has_gps_gap: boolean | null;
  start_location_id: string | null;
  start_location_name: string | null;
  start_location_type: string | null;
  end_location_id: string | null;
  end_location_name: string | null;
  end_location_type: string | null;
  gps_gap_seconds: number | null;
  gps_gap_count: number | null;
}

export interface DayApprovalDetail {
  employee_id: string;
  date: string;
  has_active_shift: boolean;
  approval_status: 'pending' | 'approved';
  approved_by: string | null;
  approved_at: string | null;
  notes: string | null;
  activities: ApprovalActivity[];
  summary: {
    total_shift_minutes: number;
    approved_minutes: number;
    rejected_minutes: number;
    needs_review_count: number;
  };
}

export interface WeeklyDayEntry {
  date: string;
  has_shifts: boolean;
  has_active_shift: boolean;
  status: DayApprovalStatus;
  total_shift_minutes: number;
  approved_minutes: number | null;
  rejected_minutes: number | null;
  needs_review_count: number;
}

export interface WeeklyEmployeeRow {
  employee_id: string;
  employee_name: string;
  days: WeeklyDayEntry[];
}
```

**Step 2: Create validation schema**

Create `dashboard/src/lib/validations/approval.ts`:

```typescript
import { z } from 'zod';

export const approvalFilterSchema = z.object({
  status: z.enum(['all', 'pending', 'needs_review', 'approved']).default('all'),
  employee_search: z.string().optional(),
});

export type ApprovalFilterInput = z.infer<typeof approvalFilterSchema>;

export const overrideSchema = z.object({
  employee_id: z.string().uuid(),
  date: z.string(),
  activity_type: z.enum(['trip', 'stop', 'clock_in', 'clock_out']),
  activity_id: z.string().uuid(),
  status: z.enum(['approved', 'rejected']),
  reason: z.string().max(500).optional(),
});

export type OverrideInput = z.infer<typeof overrideSchema>;
```

**Step 3: Commit**

```bash
git add dashboard/src/types/mileage.ts dashboard/src/lib/validations/approval.ts
git commit -m "feat: add hours approval TypeScript types and Zod schemas"
```

---

## Task 6: Dashboard — Approval page with weekly grid

**Files:**
- Create: `dashboard/src/app/dashboard/approvals/page.tsx`
- Create: `dashboard/src/components/approvals/approval-grid.tsx`
- Modify: `dashboard/src/components/layout/sidebar.tsx` (add nav item)

**Step 1: Create the ApprovalGrid component**

Create `dashboard/src/components/approvals/approval-grid.tsx`:

This component renders the week×employee table. Key features:
- Week navigation (◀ ▶ arrows)
- Status filter dropdown
- Employee search
- Color-coded cells with hours and status badges
- Click handler on cells to open detail

The component should:
- Call `get_weekly_approval_summary` RPC on mount and when week changes
- Format hours as `Xh` or `XhYY`
- Use Badge component for status indicators
- Use Skeleton for loading state

Patterns to follow:
- Employee loading pattern from `activity-tab.tsx:193-202`
- RPC call pattern from `activity-tab.tsx:213-222`
- Badge colors from `activity/page.tsx:295-312`

**Step 2: Create the approvals page**

Create `dashboard/src/app/dashboard/approvals/page.tsx`:

Simple page wrapper that renders `<ApprovalGrid />` with a header. Include a slot/state for the detail panel.

**Step 3: Add sidebar entry**

In `dashboard/src/components/layout/sidebar.tsx`, add between "Activités" and "Rapports":

```typescript
import { ..., ClipboardCheck } from 'lucide-react';

// In navigation array, between Activités and Rapports:
{
  name: 'Approbation',
  href: '/dashboard/approvals',
  icon: ClipboardCheck,
},
```

**Step 4: Commit**

```bash
git add dashboard/src/components/approvals/approval-grid.tsx \
      dashboard/src/app/dashboard/approvals/page.tsx \
      dashboard/src/components/layout/sidebar.tsx
git commit -m "feat: add approvals page with weekly employee×day grid"
```

---

## Task 7: Dashboard — Day approval detail panel

**Files:**
- Create: `dashboard/src/components/approvals/day-approval-detail.tsx`

**Step 1: Create the DayApprovalDetail component**

This is the side panel / sheet that opens when clicking a cell in the grid.

Key features:
- Header: employee name, date, shift times
- Summary bar: approved/rejected/needs_review minutes
- Activity timeline (chronological list):
  - Each line shows: time range, type icon, location name, duration, status badge
  - Status badge: green check (approved), red X (rejected), yellow warning (needs_review)
  - Override toggle: click a line's status to flip approved↔rejected
  - For needs_review lines: explicit approve/reject buttons
- "Approuver la journée" button at bottom (disabled if needs_review_count > 0)
- Optional notes textarea before approving

Component should:
- Call `get_day_approval_detail` RPC when opened
- Call `save_activity_override` RPC when toggling a line
- Call `approve_day` RPC when confirming
- Use Sheet component (from shadcn/ui) for the side panel
- Show toast notifications on success/error (sonner)

Patterns to follow:
- Badge styling from `activity/page.tsx:295-312`
- Dialog pattern from `activity/page.tsx:249-344`
- Icons: use lucide `CheckCircle2`, `XCircle`, `AlertTriangle`, `Clock`, `Car`, `MapPin`

Note: Sheet component is not yet installed. Need to add it:
```bash
cd dashboard && npx shadcn@latest add sheet
```

**Step 2: Wire detail panel into ApprovalGrid**

In `approval-grid.tsx`, add state for selected cell (employee_id + date). When set, render `<DayApprovalDetail>` as a Sheet. On close/approve, refresh the grid data.

**Step 3: Commit**

```bash
git add dashboard/src/components/approvals/day-approval-detail.tsx \
      dashboard/src/components/approvals/approval-grid.tsx \
      dashboard/src/components/ui/sheet.tsx
git commit -m "feat: add day approval detail panel with override and approve actions"
```

---

## Task 8: Integration testing and polish

**Step 1: Test the full flow**

1. Open `/dashboard/approvals`
2. Verify the weekly grid loads with employee rows and day columns
3. Click a cell with shifts → verify detail panel opens
4. Verify auto-classification:
   - Stops at offices/buildings show green
   - Stops at home show red
   - Unmatched stops show yellow
   - Trips between work locations show green
   - Trips touching home show red
5. Override a needs_review line → verify it toggles and count updates
6. Resolve all needs_review → verify "Approuver" button enables
7. Click "Approuver la journée" → verify cell turns green in grid
8. Navigate to previous/next week → verify data refreshes
9. Filter by status → verify grid filters correctly

**Step 2: Test edge cases**

1. Day with no shifts → cell shows "—" (grey)
2. Day with active shift → cell shows "En cours" (not clickable)
3. Day already approved → detail panel shows frozen state, no edit
4. Employee with no shifts all week → row may be hidden or all grey

**Step 3: Final commit**

```bash
git add -A
git commit -m "feat: hours approval system - polish and integration"
```

---

## Summary

| Task | Migration/File | Description |
|------|----------------|-------------|
| 1 | `092_hours_approval.sql` | `day_approvals` + `activity_overrides` tables |
| 2 | `093_get_day_approval_detail.sql` | Core RPC with auto-classification logic |
| 3 | `094_get_weekly_approval_summary.sql` | Weekly grid summary RPC |
| 4 | `095_approval_actions.sql` | `save/remove_activity_override` + `approve_day` RPCs |
| 5 | Types + validations | TypeScript interfaces + Zod schemas |
| 6 | Approvals page + grid | `/dashboard/approvals` page + `ApprovalGrid` component |
| 7 | Detail panel | `DayApprovalDetail` sheet with override/approve actions |
| 8 | Integration testing | Full flow testing + edge cases |
