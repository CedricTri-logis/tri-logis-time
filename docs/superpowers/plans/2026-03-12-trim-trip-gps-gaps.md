# Trim Trip GPS Gaps — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a trip has a GPS gap > 5 min at its start or end, trim the trip boundaries so the gap period becomes a separate approvable "gap" line detected by the existing gap detector in `_get_day_approval_detail_base`.

**Architecture:** New post-processing function `trim_trip_gps_boundaries(p_shift_id)` runs after `compute_gps_gaps` in `detect_trips`. It trims trip `started_at`/`ended_at` to the first/last actual GPS point when a > 5 min gap exists at the trip edges. Zero-GPS-point trips with duration > 5 min are deleted entirely. The existing gap detection in the approval detail function automatically creates approvable "gap" activities for the uncovered time — no changes needed to `_get_day_approval_detail_base`, `get_weekly_approval_summary`, or the dashboard.

**Tech Stack:** PostgreSQL (Supabase), single migration file

---

## How It Works (Before/After)

**Before** (current behavior for Karo-Lyn, March 12):
```
Stop: 151-159 Principale   10:46 → 14:48  (4h02)
Trip: 14:48 → 16:02        (1h14, 2.5km, gps_gap=4136s)  ← includes 69 min of GPS lost
Stop: Lieu inconnu          16:02 → 16:18  (16 min)
```

**After** (proposed):
```
Stop: 151-159 Principale   10:46 → 14:48  (4h02)
Gap:  GPS perdu             14:48 → 15:57  (1h09, needs_review)  ← auto-detected, own approval
Trip: 15:57 → 16:02        (5 min, 2.5km, gps_gap=0)            ← trimmed to actual movement
Stop: Lieu inconnu          16:02 → 16:18  (16 min)
```

The "Gap" line is auto-created by the existing gap detector in `_get_day_approval_detail_base` (lines 700-860) which finds periods within shifts not covered by any stop, trip, or lunch.

---

## Chunk 1: Migration

### Task 1: Create `trim_trip_gps_boundaries` function + integrate + backfill

**Files:**
- Create: `supabase/migrations/20260312600000_trim_trip_gps_boundaries.sql`

- [ ] **Step 1: Write the function**

```sql
-- =============================================================================
-- Trim trip GPS boundaries
-- =============================================================================
-- When a trip has a GPS gap > 5 min at the start or end, trim the trip
-- boundaries to the first/last actual GPS point. The uncovered time becomes
-- a "gap" activity auto-detected by _get_day_approval_detail_base.
--
-- Cases handled:
-- A. Zero-GPS-point trips with duration > 5 min → DELETE (entire trip is gap)
-- B. Start gap: (first_gps_point - trip.started_at) > 300s → trim started_at
-- C. End gap: (trip.ended_at - last_gps_point) > 300s → trim ended_at
-- =============================================================================

CREATE OR REPLACE FUNCTION trim_trip_gps_boundaries(p_shift_id UUID)
RETURNS VOID AS $$
DECLARE
    v_trip RECORD;
    v_first_point RECORD;
    v_last_point RECORD;
    v_gap_threshold_seconds CONSTANT INTEGER := 300; -- 5 minutes
    v_new_started_at TIMESTAMPTZ;
    v_new_ended_at TIMESTAMPTZ;
    v_changed BOOLEAN;
BEGIN
    FOR v_trip IN
        SELECT t.id, t.started_at, t.ended_at, t.gps_point_count,
               t.gps_gap_seconds, t.gps_gap_count,
               t.start_cluster_id, t.end_cluster_id
        FROM trips t
        WHERE t.shift_id = p_shift_id
          AND (t.gps_gap_seconds > 0 OR t.gps_point_count = 0)
    LOOP
        -- Case A: Zero GPS points and duration > 5 min → delete trip
        IF v_trip.gps_point_count = 0 THEN
            IF EXTRACT(EPOCH FROM (v_trip.ended_at - v_trip.started_at)) > v_gap_threshold_seconds THEN
                DELETE FROM trip_gps_points WHERE trip_id = v_trip.id;
                DELETE FROM trips WHERE id = v_trip.id;
            END IF;
            CONTINUE;
        END IF;

        -- Get first and last GPS points in the trip
        SELECT gp.captured_at, gp.latitude, gp.longitude
        INTO v_first_point
        FROM trip_gps_points tgp
        JOIN gps_points gp ON gp.id = tgp.gps_point_id
        WHERE tgp.trip_id = v_trip.id
        ORDER BY tgp.sequence_order ASC
        LIMIT 1;

        SELECT gp.captured_at, gp.latitude, gp.longitude
        INTO v_last_point
        FROM trip_gps_points tgp
        JOIN gps_points gp ON gp.id = tgp.gps_point_id
        WHERE tgp.trip_id = v_trip.id
        ORDER BY tgp.sequence_order DESC
        LIMIT 1;

        IF v_first_point IS NULL THEN
            CONTINUE; -- Safety check
        END IF;

        v_new_started_at := v_trip.started_at;
        v_new_ended_at := v_trip.ended_at;
        v_changed := FALSE;

        -- Case B: Start gap > 5 min → trim started_at to first GPS point
        IF EXTRACT(EPOCH FROM (v_first_point.captured_at - v_trip.started_at)) > v_gap_threshold_seconds THEN
            v_new_started_at := v_first_point.captured_at;
            v_changed := TRUE;
        END IF;

        -- Case C: End gap > 5 min → trim ended_at to last GPS point
        IF EXTRACT(EPOCH FROM (v_trip.ended_at - v_last_point.captured_at)) > v_gap_threshold_seconds THEN
            v_new_ended_at := v_last_point.captured_at;
            v_changed := TRUE;
        END IF;

        -- Apply changes
        IF v_changed THEN
            -- If trimming makes trip < 0 duration, delete it
            IF v_new_ended_at <= v_new_started_at THEN
                DELETE FROM trip_gps_points WHERE trip_id = v_trip.id;
                DELETE FROM trips WHERE id = v_trip.id;
                CONTINUE;
            END IF;

            UPDATE trips SET
                started_at = v_new_started_at,
                ended_at = v_new_ended_at,
                duration_minutes = GREATEST(1, EXTRACT(EPOCH FROM (v_new_ended_at - v_new_started_at)) / 60)::INTEGER,
                -- Update start coords if start was trimmed
                start_latitude = CASE
                    WHEN v_new_started_at <> v_trip.started_at THEN v_first_point.latitude
                    ELSE start_latitude
                END,
                start_longitude = CASE
                    WHEN v_new_started_at <> v_trip.started_at THEN v_first_point.longitude
                    ELSE start_longitude
                END,
                -- Update end coords if end was trimmed
                end_latitude = CASE
                    WHEN v_new_ended_at <> v_trip.ended_at THEN v_last_point.latitude
                    ELSE end_latitude
                END,
                end_longitude = CASE
                    WHEN v_new_ended_at <> v_trip.ended_at THEN v_last_point.longitude
                    ELSE end_longitude
                END,
                -- Recalculate distance
                distance_km = ROUND(
                    haversine_km(
                        CASE WHEN v_new_started_at <> v_trip.started_at THEN v_first_point.latitude ELSE start_latitude END,
                        CASE WHEN v_new_started_at <> v_trip.started_at THEN v_first_point.longitude ELSE start_longitude END,
                        CASE WHEN v_new_ended_at <> v_trip.ended_at THEN v_last_point.latitude ELSE end_latitude END,
                        CASE WHEN v_new_ended_at <> v_trip.ended_at THEN v_last_point.longitude ELSE end_longitude END
                    ) * 1.3,  -- correction factor
                    3
                )
            WHERE id = v_trip.id;
        END IF;
    END LOOP;

    -- Re-compute GPS gaps for all modified trips
    PERFORM compute_gps_gaps(p_shift_id);
END;
$$ LANGUAGE plpgsql
SET search_path TO public, extensions;
```

- [ ] **Step 2: Integrate into detect_trips**

Add `PERFORM trim_trip_gps_boundaries(p_shift_id);` right after the existing `PERFORM compute_gps_gaps(p_shift_id);` call at the end of `detect_trips`.

The current end of `detect_trips` (in migration 122) has:
```sql
    -- Step 8: Compute GPS gaps
    PERFORM compute_gps_gaps(p_shift_id);
END;
```

We need to rewrite `detect_trips` to add one line after compute_gps_gaps:
```sql
    -- Step 8: Compute GPS gaps
    PERFORM compute_gps_gaps(p_shift_id);

    -- Step 9: Trim trip boundaries at GPS gaps
    PERFORM trim_trip_gps_boundaries(p_shift_id);
END;
```

**IMPORTANT:** This requires re-declaring the full `detect_trips` function (CREATE OR REPLACE). Copy the latest version from migration 122 and add the single PERFORM line.

- [ ] **Step 3: Backfill all completed shifts**

```sql
-- Backfill: re-run trim for all completed shifts that have trips with GPS gaps
DO $$
DECLARE
    v_shift_id UUID;
    v_count INTEGER := 0;
BEGIN
    FOR v_shift_id IN
        SELECT DISTINCT t.shift_id
        FROM trips t
        JOIN shifts s ON s.id = t.shift_id
        WHERE s.status = 'completed'
          AND (t.gps_gap_seconds > 0 OR t.gps_point_count = 0)
    LOOP
        PERFORM trim_trip_gps_boundaries(v_shift_id);
        v_count := v_count + 1;
    END LOOP;
    RAISE NOTICE 'Backfilled % shifts', v_count;
END $$;
```

- [ ] **Step 4: Apply migration**

```bash
cd supabase && supabase db push
```

Or via MCP: `apply_migration`

- [ ] **Step 5: Verify with Karo-Lyn's data**

```sql
-- Check trip was trimmed
SELECT id, started_at AT TIME ZONE 'America/Toronto', ended_at AT TIME ZONE 'America/Toronto',
       duration_minutes, distance_km, gps_gap_seconds
FROM trips
WHERE id = '40083aed-7593-4c01-89b8-1d4a05a7f1a8';
-- Expected: started_at ≈ 15:57:25, duration ≈ 5 min, gps_gap_seconds ≈ 0

-- Check gap is auto-detected in approval detail
SELECT a->>'activity_type', a->>'started_at', a->>'ended_at',
       a->>'duration_minutes', a->>'auto_reason', a->>'final_status'
FROM get_day_approval_detail('edf9e035-2b0b-47d6-bb53-8c037138faff', '2026-03-12') d,
     jsonb_array_elements(d->'activities') a
WHERE a->>'activity_type' IN ('gap', 'trip')
ORDER BY a->>'started_at';
-- Expected: gap 14:48→15:57 (needs_review) + trip 15:57→16:02 (5 min)
```

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/20260312600000_trim_trip_gps_boundaries.sql
git commit -m "feat: trim trip boundaries at GPS gaps for separate approval lines"
```

---

## What Does NOT Change

- **`_get_day_approval_detail_base`**: No changes. Its existing gap detection (lines 700-860) already finds uncovered periods within shifts and creates approvable "gap" activities.
- **`get_weekly_approval_summary`**: No changes. Its live classification reads from the trips table which will have corrected boundaries.
- **Dashboard**: No changes. Gap activities are already rendered with approve/reject buttons (approval-rows.tsx `GapSubRow` component).
- **Flutter app**: No changes.

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Zero-GPS-point trip, duration > 5 min | Delete trip; gap detector creates "GPS perdu" line |
| Zero-GPS-point trip, duration ≤ 5 min | Keep trip as-is (within grace period) |
| Gap at start only | Trim started_at, keep end |
| Gap at end only | Trim ended_at, keep start |
| Gaps at both start and end | Trim both |
| Gap in middle of trip | NOT handled (future enhancement — would need trip splitting) |
| Same cluster before/after gap | No trip exists (distance < 0.2km filter), gap already detected |
| Trip already has correct boundaries | No change (gaps < 5 min at edges) |
