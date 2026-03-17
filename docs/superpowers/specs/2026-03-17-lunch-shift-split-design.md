# Lunch Break → Shift Split Design

**Date:** 2026-03-17
**Status:** Draft
**Replaces:** `2026-03-16-lunch-break-shift-split-design (from GPS_Tracker).md` (brouillon précédent)

## Problem

When an employee stays in one place all day (e.g., working from home), `detect_trips` creates a single stationary cluster spanning the entire shift — including the lunch break. The dashboard shows one monolithic block with the lunch floating inside, making it impossible to distinguish work time from break time visually.

The current architecture stores lunch breaks in a separate `lunch_breaks` table, disconnected from the shift/cluster/trip data model. This creates a dual data source problem.

## Solution

Replace the `lunch_breaks` table with a **shift-split model** where lunch breaks physically split a shift into segments. Each segment is a regular shift record linked by a shared `work_body_id`. The lunch period itself becomes a dedicated segment marked `is_lunch = true`.

## Data Model

### New columns on `shifts`

| Column | Type | Default | Description |
|--------|------|---------|-------------|
| `work_body_id` | UUID, nullable | NULL | Groups shift segments from the same work day. NULL = simple shift without breaks. Only set when a lunch split occurs. |
| `is_lunch` | boolean, NOT NULL | false | Marks lunch segments. |

### Segment structure

A shift with one lunch break produces 3 segments:

```
Segment 1 (work)           Segment 2 (lunch)          Segment 3 (work)
08:18 → 12:55               12:55 → 14:31               14:31 → 19:07
work_body_id = ABC          work_body_id = ABC           work_body_id = ABC
is_lunch = false            is_lunch = true              is_lunch = false
clock_out_reason = 'lunch'  clock_out_reason = 'lunch_end'
```

A shift with N lunch breaks produces 2N+1 segments (N lunch + N+1 work).

### Lunch is a real segment

Unlike the previous draft (gap-derived model), lunch is a **physical shift record** with `is_lunch = true`. This allows `detect_trips` to run on the lunch segment and produce clusters/trips that are visible as expandable children in the dashboard.

Lunch duration = `clocked_out_at - clocked_in_at` on the lunch segment. The `lunch_breaks` table is kept temporarily as an inbox during transition (see Transition Strategy).

### New `clock_out_reason` values

| Value | Meaning |
|-------|---------|
| `'manual'` | Employee clocked out normally (existing) |
| `'midnight'` | Auto-closed by midnight cron (existing) |
| `'lunch'` | Segment closed because lunch started (new) |
| `'lunch_end'` | Lunch segment closed because lunch ended (new). Used by `midnight_auto_close` to distinguish lunch segments from work segments — if midnight closes a lunch segment, no post-lunch work segment is created. |

## GPS Tracking

**No change.** GPS tracking continues normally during lunch breaks, exactly as today. The tracking service does not pause, stop, or change behavior when a lunch segment is created. This preserves tracking resilience and avoids GPS restart issues.

### GPS point shift_id during live lunch (transition period)

During a live lunch break, the Flutter app continues writing GPS points to the **pre-lunch segment's shift_id** because it doesn't know the server created new segments. This is expected and harmless:

- The trigger redistributes GPS points by timestamp when the lunch INSERT occurs (steps 6-7).
- When the lunch ends (UPDATE trigger), GPS points captured after `ended_at` are redistributed to the post-lunch segment.
- The Flutter app learns about the new active shift_id via Supabase Realtime (the `shifts` table is in `supabase_realtime` publication). Once notified, it starts writing to the new segment's shift_id.
- Any GPS points that arrive between the trigger commit and the app learning the new shift_id are mis-assigned but will be corrected by the re-redistribution at lunch end.

### clock_in_location / clock_out_location on trigger-created segments

Trigger-created segments (lunch and post-lunch) have NULL `clock_in_location` and `clock_out_location` — the employee didn't physically "clock in." This is expected. The `clock_in_cluster_id` and `clock_in_location_id` are also NULL and will be populated by `detect_trips` when it runs on these segments.

## detect_trips

**No change to the algorithm.** `detect_trips` runs independently on each segment — including lunch segments. It produces clusters and trips for all three segments. It has no awareness of `is_lunch`; it simply processes GPS points within each shift's time window.

For the retroactive migration, existing clusters/trips on affected shifts are deleted and `detect_trips` is re-run on each new segment.

## Trigger: Inbox Conversion

The Flutter app continues writing to `lunch_breaks`. A server-side trigger automatically converts each entry into a shift split.

### INSERT with ended_at NOT NULL (lunch already ended)

1. Find the active/completed shift for this employee that covers `started_at`
2. Generate `work_body_id` if not already set on the shift
3. Close current segment at `lunch.started_at` → `clock_out_reason = 'lunch'`
4. Create lunch segment: `started_at → ended_at`, `is_lunch = true`, `status = 'completed'`
5. Create new work segment: `clocked_in_at = ended_at`, same `employee_id`, `work_body_id`
   - `status = 'active'` if original shift was active, `'completed'` if original was completed
   - Inherits `shift_type` from first segment
6. Redistribute GPS points by timestamp to the 3 segments
7. Redistribute work_sessions by timestamp
8. Delete existing clusters/trips for the original shift
9. Queue `detect_trips` re-run on all 3 segments (see Async Redetection)

### INSERT with ended_at NULL (lunch starting)

1. Close current segment at `lunch.started_at` → `clock_out_reason = 'lunch'`
2. Create lunch segment: `started_at → NULL`, `is_lunch = true`, `status = 'active'`
3. Wait for UPDATE...

### UPDATE ended_at NULL → value (lunch ending)

1. Close lunch segment at `ended_at`
2. Create new work segment: `clocked_in_at = ended_at`, `status = 'active'`
3. Redistribute GPS points captured after `ended_at` to new segment

### Edge cases

| Case | Behavior |
|------|----------|
| Multiple lunches | Each lunch splits the current (last) work segment. All segments share the same `work_body_id`. |
| Shift already completed | Same logic, but all segments get `status = 'completed'`. |
| GPS points to redistribute | `UPDATE gps_points SET shift_id = X WHERE shift_id = old AND captured_at > threshold` |
| Clusters/trips | Deleted and re-detected via async `detect_trips` on each segment |
| Work sessions during lunch | Work sessions are NOT auto-closed when `clock_out_reason = 'lunch'`. The `auto_close_sessions_on_shift_complete` trigger skips lunch clock-outs. If a work session spans the lunch boundary, it stays linked to the pre-lunch segment (employee was working, then took a break). |
| Trigger security | Trigger runs as `SECURITY DEFINER` to bypass RLS when creating segments on behalf of the employee. |

## Async Redetection

`detect_trips` is too expensive to run inside a trigger (it processes all GPS points, runs DBSCAN, creates clusters, detects trips, matches locations, etc.). Running it 3 times synchronously would block the Flutter app's HTTP request for 15+ seconds.

**Solution:** The trigger only handles the structural split (close segment, create new segments, redistribute GPS points). Trip/cluster redetection is deferred:

- **For retroactive migration:** `detect_trips` is called in a migration script loop (acceptable — runs once, not on a user request).
- **For live lunch breaks:** After the trigger completes, `detect_trips` runs on the completed work segment only (the pre-lunch segment that just closed). The lunch segment and post-lunch segment get redetected later:
  - When the shift is finally completed (clock-out), `detect_trips` runs on all segments of the `work_body_id` — this is the existing behavior where `detect_trips` runs at shift completion.
  - The `backfill_location_matches` cron (every 5 min) also catches segments that need redetection.

## Interaction with Existing Crons

### `flag_gpsless_shifts` (migration 098)

This cron auto-closes active shifts with 0 GPS points after 10 minutes. When a lunch break creates a new post-lunch work segment, that segment starts with 0 GPS points (GPS points are still being written to the old segment until the app learns the new shift_id).

**Fix:** Update `flag_gpsless_shifts` to skip shifts where `work_body_id` is not null AND a sibling segment with `clock_out_reason = 'lunch'` was completed within the last 30 minutes.

### `midnight_auto_close` (migration 030)

If an employee has an active lunch segment at midnight, the midnight cron would close it. This is acceptable — the lunch segment gets closed, and no post-lunch work segment is created (the employee presumably didn't return from lunch). Same behavior as today where midnight closes any active shift.

## Retroactive Migration

One-shot migration for existing 57 lunch breaks:

1. For each `lunch_break` (ordered by `shift_id`, `started_at`):
   a. Assign `work_body_id` to parent shift
   b. Split into 3 segments (work → lunch → work)
   c. Redistribute GPS points and work_sessions by timestamp
   d. Delete existing clusters, trips, trip_gps_points for the original shift
   e. Re-run `detect_trips()` on each new segment
2. Delete existing `day_approvals` and `activity_overrides` for affected shifts (supervisors re-approve)
3. Structural split (steps 1a-1d, step 2) in a single transaction per shift — not all 57 in one giant transaction, to avoid long lock holds
4. `detect_trips` re-runs (step 1e) in a separate loop after each structural commit — if one fails, the split is already done and can be retried
5. Log counts: shifts split, GPS points redistributed, detect_trips runs

**Volume:** ~57 shifts, ~114+ new segments, proportional GPS point redistribution.

## RPCs Modified

### `get_day_approval_detail`

- Work segments (`is_lunch = false`): return stops, trips, clock events as normal activities
- Lunch segments (`is_lunch = true`): return a single `lunch` activity at the top level, with `children: ApprovalActivity[]` containing the stops/trips detected during the break
- Lunch activity: `auto_status = 'rejected'`, `auto_reason = 'Pause dîner (non payée)'`
- Summary: `lunch_minutes = SUM(duration of is_lunch segments)`, `total_shift_minutes` excludes lunch

Example output for a shift with one lunch:

| # | Type | Time | Duration | Detail |
|---|------|------|----------|--------|
| 1 | stop | 08:18→12:55 | 277 min | Home Zahra |
| 2 | clock_in | 08:18 | — | Home Zahra |
| 3 | **lunch** | 12:55→14:31 | 95 min | Pause dîner (children: [...]) |
| 4 | stop | 14:31→19:07 | 276 min | Home Zahra |
| 5 | clock_out | 19:07 | — | Home Zahra |

### `get_weekly_approval_summary`

Add `lunch_minutes` per day in return payload.

### `get_monitored_team`

Employee on an active `is_lunch = true` segment → display label "en pause" in the monitoring UI (not a new enum value — the shift_status stays as computed, but the UI shows "en pause" when `is_lunch = true`). Segments with same `work_body_id` treated as one continuous presence.

### `clock_in` / `clock_out` RPCs

No change. Split is handled by the trigger on `lunch_breaks`.

## Dashboard Changes

### TypeScript types

```typescript
// Add to ApprovalActivity.activity_type union
activity_type: 'trip' | 'stop' | 'clock_in' | 'clock_out' | 'gap' | 'lunch'

// Add children field for lunch activities
children?: ApprovalActivity[]

// Add to summary
lunch_minutes: number
```

### Timeline rendering (day-approval-detail)

Lunch renders as a distinct expandable row:

- **Background:** neutral slate/gray (not green or red)
- **Icon:** utensils (fork/knife)
- **No approve/reject buttons** — non-approvable, always rejected
- **Expandable:** click to see child stops/trips during lunch
- **Children:** rendered as sub-rows, all auto-rejected, no approve/reject buttons
- **Does not merge** into adjacent stops via `merge-clock-events`

### Summary cards

Add a 6th card: "Dîner" with utensils icon, showing total lunch minutes.

### Weekly approval grid

Show lunch minutes in day cell tooltip: "9h13 travaillé · 1h35 dîner".

## Approval Rules

- Lunch activities are **non-approvable** — always `auto_status = 'rejected'`
- Children (stops/trips during lunch) are also non-approvable
- Supervisors cannot override lunch status
- Lunch duration is automatically deducted from paid time
- The `save_activity_override` RPC must reject overrides where `activity_type = 'lunch'`

## Draft Migrations (to be rewritten)

The draft migrations `20260316000001` through `20260316000005` implement the **gap-derived model** from the previous spec (lunch = implicit gap between 2 segments, no `is_lunch` column, no lunch segment record). This spec uses the **physical-segment model** (lunch = real shift record with `is_lunch = true`, 3 segments per lunch).

**These draft migrations must be rewritten from scratch.** Do not attempt to adapt them — the data model is fundamentally different.

## Transition Strategy

### Phase 1: Database migration
- Add `work_body_id`, `is_lunch` columns to `shifts`
- Create conversion trigger on `lunch_breaks`
- Run retroactive migration (split existing 57 shifts, re-run detect_trips)
- Update RPCs

### Phase 2: Dashboard
- Add `'lunch'` type to TypeScript types
- Implement lunch row rendering with expandable children
- Add lunch summary card
- Update weekly grid tooltip

### Phase 3: Flutter app update
- Modify lunch break logic to use new shift-split model natively (stop writing to `lunch_breaks`, instead use clock-out/clock-in with lunch reason)
- Deploy and bump `minimum_app_version`

### Phase 4: Cleanup
- Drop `lunch_breaks` table (only after all users on new app version)
- Remove conversion trigger
- Remove inbox compatibility code

**During transition:** Old app writes to `lunch_breaks` → trigger converts to shift-split automatically. No user disruption.

## Out of Scope

- Changing GPS behavior during lunch (tracking continues as-is)
- Supervisor override of lunch duration
- Configurable lunch duration rules (e.g., max 30 min paid)
- Multiple lunch types (just one type: "Pause dîner")
