# Manual Time Corrections

## Problem

When an employee forgets to clock in/out, or when a supervisor needs to adjust time (remove part of a stop, correct hours), there is no mechanism to do so. The current system only allows approving/rejecting existing activities but cannot modify actual times or split activities.

## Scope

Two capabilities added to the supervisor dashboard:

1. **Edit shift clock-in/clock-out times** — modify the effective start/end of an existing shift
2. **Segment a stationary cluster** — split a stop into N parts, each independently approvable/rejectable

All changes are tied to an existing shift (work session). No "phantom" shifts are created.

## Approach: Two Tables + RPCs

Two new tables with clear responsibilities, integrated into the existing approval flow. Original data is never mutated — edits are layered on top, similar to how `activity_overrides` works.

A SQL helper function `effective_shift_times(p_shift_id)` centralizes the logic of reading the latest edit for each field, so all RPCs and queries that need shift boundaries go through one place.

---

## Data Model

### Table: `shift_time_edits`

Audit log of every clock-in/clock-out modification.

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID PK | |
| `shift_id` | UUID FK → shifts(id) ON DELETE CASCADE | |
| `field` | TEXT CHECK ('clocked_in_at', 'clocked_out_at') | Which timestamp was changed |
| `old_value` | TIMESTAMPTZ NOT NULL | Value before this edit |
| `new_value` | TIMESTAMPTZ NOT NULL | New effective value |
| `reason` | TEXT | Optional supervisor note |
| `changed_by` | UUID FK → employee_profiles(id) NOT NULL | Supervisor who made the change |
| `created_at` | TIMESTAMPTZ DEFAULT now() | |

- Each modification = a new row (append-only, never updated)
- Effective value for a shift = `new_value` of the latest edit (by `created_at`) for that field
- The `shifts` table is never modified — RPCs read the latest edit if one exists
- RLS: admin-only (read + write)

### Table: `cluster_segments`

Stores split points for a stationary cluster.

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID PK (deterministic: `md5(cluster_id \|\| segment_index)::UUID`) | Stable across re-segmentations with same cut points |
| `stationary_cluster_id` | UUID FK → stationary_clusters(id) ON DELETE CASCADE | |
| `segment_index` | INT NOT NULL | 0, 1, 2... |
| `starts_at` | TIMESTAMPTZ NOT NULL | |
| `ends_at` | TIMESTAMPTZ NOT NULL | |
| `created_by` | UUID FK → employee_profiles(id) NOT NULL | |
| `created_at` | TIMESTAMPTZ DEFAULT now() | |
| | UNIQUE(stationary_cluster_id, segment_index) | |

- Segment IDs are deterministic (`md5(cluster_id || '-' || segment_index)::UUID`) so that re-segmentation with the same cut points preserves IDs and their overrides
- When a cluster is segmented, N rows are created (2 for one cut, 3 for two cuts, etc.)
- Each segment is an independent activity in the approval system
- If no segments exist for a cluster → current behavior (cluster = 1 block)
- RLS: admin-only (read + write)

### Helper Function: `effective_shift_times(p_shift_id UUID)`

Returns `(effective_clocked_in_at TIMESTAMPTZ, effective_clocked_out_at TIMESTAMPTZ, clock_in_edited BOOLEAN, clock_out_edited BOOLEAN)`.

- For each field, selects the latest `shift_time_edit.new_value` (by `created_at`); falls back to the original `shifts` column if no edit exists.
- All RPCs and queries that need shift boundaries MUST call this function instead of reading `shifts.clocked_in_at` / `shifts.clocked_out_at` directly.

### Schema Changes to Existing Tables

**`activity_overrides`**: Update CHECK constraint to include `'stop_segment'`:
```sql
CHECK (activity_type IN ('trip', 'stop', 'clock_in', 'clock_out', 'gap', 'lunch_start', 'lunch_end', 'lunch', 'stop_segment'))
```

**`save_activity_override` RPC**: Update internal validation to accept `'stop_segment'` as a valid `activity_type`.

---

## RPCs

### New RPCs

#### `edit_shift_time(p_shift_id UUID, p_field TEXT, p_new_value TIMESTAMPTZ, p_reason TEXT DEFAULT NULL)`

- Auth: uses `is_admin_or_super_admin()` (consistent with all other approval RPCs)
- Derives `employee_id` and `date` from the shift record (using `to_business_date()` for date)
- Validates the day is not approved (checks `day_approvals.status != 'approved'`); returns error if locked
- Validates consistency: clock-in must be before clock-out (using `effective_shift_times` for the other field)
- Validates no overlap with another shift of the same employee (using `effective_shift_times` for neighboring shifts)
- **Date change guard for `clocked_in_at`**: if the edit would change the business date (via `to_business_date()`), reject with error "Edit would move shift to a different day. Adjust to stay within the same calendar date."
- **`clocked_out_at` crossing midnight is allowed**: date grouping is always by `clocked_in_at`, so a clock-out past midnight does not affect which day the shift belongs to
- Inserts a row into `shift_time_edits`
- Returns updated `get_day_approval_detail(employee_id, date)`

#### `segment_cluster(p_cluster_id UUID, p_cut_points TIMESTAMPTZ[])`

- Auth: `is_admin_or_super_admin()`
- Derives `employee_id` from `stationary_clusters.employee_id` and `date` from `to_business_date(started_at)`
- Validates the day is not approved
- Validates all cut points are within cluster bounds (`started_at` → `ended_at`)
- Validates each resulting segment is at least 1 minute
- Deletes existing segments for this cluster (for re-segmentation), along with their `activity_overrides` (see deletion logic below)
- If a `stop`-level override exists on the parent cluster, deletes it (supervisor must re-approve at segment level)
- Creates N segment rows with deterministic IDs
- Returns updated `get_day_approval_detail(employee_id, date)`

#### `unsegment_cluster(p_cluster_id UUID)`

- Auth: `is_admin_or_super_admin()`
- Derives `employee_id` and `date` from the cluster
- Validates the day is not approved
- Deletes all `activity_overrides` where `activity_type = 'stop_segment'` AND `activity_id IN (SELECT id FROM cluster_segments WHERE stationary_cluster_id = p_cluster_id)` — requires joining through `day_approvals` to find the correct `day_approval_id`
- Deletes all `cluster_segments` for this cluster
- Cluster reverts to its original `auto_status`
- Returns updated `get_day_approval_detail(employee_id, date)`

### Modified RPCs

#### Architecture Note: Two Independent Functions

**IMPORTANT:** `get_day_approval_detail` (migration 147) and `_get_day_approval_detail_base` (migration 20260312300000) are **completely separate, independent implementations** — they do NOT share code. `get_day_approval_detail` has its own inline activity pipeline and project sessions CTE. Both must be independently modified with identical segment/clock-edit logic.

Callers:
- `get_day_approval_detail` is called by: `approve_day`, `save_activity_override`, `remove_activity_override`, and the dashboard directly
- `_get_day_approval_detail_base` is called by: `get_weekly_approval_summary` (for live classification)

#### Changes to Both Functions

- **Clock data CTE**: LEFT JOIN to `shift_time_edits` to get latest edits. Uses `effective_shift_times()` for the displayed time. Adds output fields: `is_edited BOOLEAN`, `original_value TIMESTAMPTZ` on `clock_in`/`clock_out` activities when edited.
- **Clock-in/out location**: the location fields (`clock_in_location`, `clock_out_location`) remain tied to the original event. The `auto_status` of the clock activity is NOT recalculated — the time edit affects duration calculation only. Location-based status stays as-is.
- **Stationary clusters CTE**: when `cluster_segments` exist for a cluster, emit each segment as a separate activity row with `activity_type = 'stop_segment'`. The parent cluster row is suppressed. Each segment inherits the parent cluster's `auto_status` (same `matched_location_id` = same classification).
- **`stop_classified` CTE**: must UNION segments into `stop_classified` so that trip derivation (which joins `stop_classified` via LATERAL to find adjacent stops) continues to work. Without this, trips adjacent to segmented clusters would lose their auto-status derivation.
- **`needs_review_count` filter**: the clock-event deduplication filter that suppresses `needs_review` on clock events overlapping with a `stop` must be updated to also match `'stop_segment'`: `WHERE activity_type IN ('stop', 'stop_segment')`.
- **Gap detection (`shift_boundaries` CTE)**: uses `effective_shift_times()` for shift boundary timestamps. Note: editing shift times may cause gap UUIDs to change (they are deterministic based on timestamps). Existing gap overrides that no longer match are effectively orphaned and ignored — acceptable since time edits are manual corrections.

#### `get_weekly_approval_summary`

- Uses `effective_shift_times()` everywhere it currently reads `shifts.clocked_in_at` / `shifts.clocked_out_at`:
  - `day_shifts` CTE (date grouping key)
  - `day_lunch` CTE
  - `day_calls_lagged` / `day_call_groups` CTEs
  - `shift_boundaries` CTE (gap detection)
  - Live classification CTE
  - `total_shift_minutes` calculation
- Segment overrides affect `approved_minutes` / `rejected_minutes`

#### `get_weekly_breakdown_totals`

- Uses `effective_shift_times()` for shift duration calculations
- Must be segment-aware when joining `activity_overrides`: check both `activity_type = 'stop'` and `activity_type = 'stop_segment'` for override lookups on stationary clusters

---

## Dashboard UI

### Clock-in/Clock-out Edit

On `clock_in` and `clock_out` activity rows in `day-approval-detail`:

- **Edit button** (pencil icon) next to the displayed time
- **Popover on click:**
  - Time picker (hour:minute)
  - Optional text field for reason
  - Cancel / Save buttons
- **After edit:** original time shown struck-through next to new time, with "Modified" badge
- **History link:** click to see all edits (who, when, old → new value)

### Cluster Segmentation

On `stop` activity rows in `day-approval-detail`:

- **Split button** (scissors icon) next to the duration
- **Popover/modal on click:**
  - Visual bar representing the stop duration (e.g., 10:00 ——— 12:00)
  - Supervisor clicks the bar or enters a time to place a cut point
  - Can add multiple cut points
  - Preview of resulting segments with durations
  - Cancel / Apply buttons
- **After segmentation:** each segment appears as a distinct row in the timeline with its own approve/reject buttons
- Segments labeled with sub-index (Stop 1/2, Stop 2/2)
- **Unsegment button** to revert to original cluster

### Visual Indicators

- Edited times: distinct style (badge + struck-through original)
- Segments: sub-indexed labels
- Summary at top reflects corrected hours and segment statuses

---

## Business Rules & Edge Cases

### Clock-in/Clock-out Edits

- **Active shift:** only clock-in can be modified (no clock-out yet)
- **Approved day:** must `reopen_day` before editing times — the RPC enforces this
- **Temporal consistency:** clock-in must remain < clock-out; each edit validated against the latest effective value of the other field
- **Overlap prevention:** new clock-in/out must not overlap another shift of the same employee (using effective times)
- **Date change prevention (`clocked_in_at` only):** an edit that would move the shift to a different business date (via `to_business_date()`) is rejected. The supervisor must adjust within the same day.
- **`clocked_out_at` crossing midnight:** allowed — date grouping is always by `clocked_in_at`, so this has no effect on day assignment
- **Location auto-status unchanged:** editing a clock time does not recalculate location-based auto_status. The GPS location was recorded at the original time and remains associated with the clock event.

### Cluster Segmentation

- **Approved day:** must reopen before segmenting — the RPC enforces this
- **Minimum duration:** each segment must be at least 1 minute
- **Auto-status inheritance:** all segments inherit the parent cluster's `auto_status` (same `matched_location_id` = same classification)
- **Deterministic IDs:** segment IDs are `md5(cluster_id || '-' || segment_index)::UUID` — re-segmentation with the same cuts preserves IDs
- **Re-segmentation:** replaces previous segments; existing overrides on old segments AND the parent cluster override (if any) are deleted. Supervisor must re-approve at segment level.
- **Unsegment:** deletes segment overrides → cluster reverts to its original auto-status
- **`approve_day` interaction:** each segment counts as its own activity — all must have `final_status != 'needs_review'` before the day can be approved
- **Trip adjacency:** segments are unioned into `stop_classified` so trip auto-status derivation (which joins adjacent stops) continues to work with segmented clusters

### Gap Detection After Edits

- Gap boundaries use `effective_shift_times()` (in `shift_boundaries` CTE of both `_get_day_approval_detail_base` and `get_weekly_approval_summary`), so they shift when clock times are edited
- Existing gap overrides may become orphaned if gap UUIDs change — this is acceptable since the time edit is itself a manual correction that resets review context
- New gaps may appear; they will have `auto_status = 'needs_review'` as usual

### Interactions with Existing Systems

- **Call billing:** uses `effective_shift_times()` to determine callback period (17h-5h)
- **Lunch breaks:** not affected by clock edits (lunches have their own timestamps)
- **GPS points:** never modified — only shift boundary times change
- **`activity_overrides`:** segments use `activity_type = 'stop_segment'` and `activity_id = segment UUID`. The CHECK constraint and `save_activity_override` validation are updated to accept this type.

### Functions That Must Use `effective_shift_times()`

All SQL functions/CTEs that currently read `shifts.clocked_in_at` or `shifts.clocked_out_at` must be updated:

- `_get_day_approval_detail_base`:
  - `clock_data` CTE (clock-in/out display times)
  - `shift_boundaries` CTE (gap detection boundaries)
- `get_day_approval_detail`:
  - Inline `clock_data` CTE
  - Inline `shift_boundaries` CTE (if present)
- `get_weekly_approval_summary`:
  - `day_shifts` CTE (date grouping + shift minutes)
  - `day_lunch` CTE
  - `day_calls_lagged` / `day_call_groups` CTEs
  - `shift_boundaries` CTE (gap minutes)
  - Live classification CTE
- `get_weekly_breakdown_totals`:
  - Shift duration calculations
  - Override lookups (must check both `'stop'` and `'stop_segment'`)
- Call billing: `set_shift_type_on_insert` trigger only fires on INSERT, so it uses original times (correct). Manual `update_shift_type` does not depend on times.
