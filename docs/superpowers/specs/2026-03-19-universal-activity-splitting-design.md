# Universal Activity Splitting

Split any approval activity (stop, trip, gap) into time-bounded segments for independent approval/rejection.

## Problem

Admins need to approve/reject portions of an activity, not just the whole thing. Key scenario: a 4-hour GPS gap where the employee was actually working for 3 hours and idle for 1 — the admin needs to approve the work portion and reject the rest. Currently, only stops can be split (via `cluster_segments`), and trips and gaps cannot be split at all.

## Design Decisions

- **Universal table** `activity_segments` replaces per-type tables (`cluster_segments`). Gaps have no source table, so a universal approach avoids treating them as a special case.
- **Split first, approve/reject later** — splitting creates segments with inherited auto-status. The admin then approves/rejects each segment independently using existing override buttons.
- **GPS points redistributed by timestamp** — when a trip is split, each segment gets the GPS points that fall within its time window. Distance is recalculated per segment.
- **Trip segments use `needs_review`** — intentionally simpler than parent trips which derive status from adjacent stops. Segments are explicitly created by admins who will review them, so auto-classification is unnecessary.
- **Kebab menu (⋮)** replaces inline scissors icon for a cleaner table UI. The menu contains "Diviser l'activité" and "Retirer la division" actions.

## Database

### New table: `activity_segments`

```sql
CREATE TABLE activity_segments (
    id              UUID PRIMARY KEY,
    activity_type   TEXT NOT NULL CHECK (activity_type IN ('stop', 'trip', 'gap')),
    activity_id     UUID NOT NULL,
    employee_id     UUID NOT NULL REFERENCES employee_profiles(id),
    segment_index   INT NOT NULL,
    starts_at       TIMESTAMPTZ NOT NULL,
    ends_at         TIMESTAMPTZ NOT NULL,
    created_by      UUID NOT NULL REFERENCES employee_profiles(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(activity_type, activity_id, segment_index),
    CHECK (ends_at > starts_at)
);

CREATE INDEX idx_activity_segments_lookup
    ON activity_segments (activity_type, activity_id);

CREATE INDEX idx_activity_segments_employee_date
    ON activity_segments (employee_id, starts_at);

ALTER TABLE activity_segments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage activity_segments"
    ON activity_segments FOR ALL
    USING (is_admin_or_super_admin(auth.uid()));

COMMENT ON TABLE activity_segments IS 'ROLE: Stores time-bounded segments when an admin splits an approval activity. STATUTS: Each segment gets independent approval via activity_overrides. REGLES: Max 2 cut points (3 segments). Segment minimum 1 minute. Parent activity disappears from approval timeline when segmented. RELATIONS: activity_type+activity_id references the parent (stationary_clusters, trips, or computed gap hash). employee_id denormalized for gap segments (no source table). TRIGGERS: None.';
```

The `id` is deterministic: `md5(activity_type || ':' || activity_id || ':' || segment_index)::UUID`.

Note on gap `activity_id`: for gaps, the `activity_id` is a computed hash `md5(employee_id || '/gap/' || gap_start || '/' || gap_end)::UUID` — the same hash used in `_get_day_approval_detail_base` to identify gaps. The frontend receives this hash in the activity's `activity_id` field and passes it to the RPC. This is a hash-of-hash for the deterministic segment ID, which is correct but fragile if the gap hash formula ever changes.

### Migration

- `DROP TABLE cluster_segments` (currently empty in production — 0 rows)
- `CREATE TABLE activity_segments` (with `employee_id`, FKs, RLS, COMMENT ON)
- Drop old RPCs: `segment_cluster`, `unsegment_cluster`
- Create new RPCs: `segment_activity`, `unsegment_activity`
- Update `_get_day_approval_detail_base` for universal segment support
- Update `get_weekly_approval_summary` — currently references `cluster_segments` in `live_segment_classification` CTE; must be updated to use `activity_segments` and handle `trip_segment` + `gap_segment`
- Update `approve_day` for new segment types (`trip_segment`, `gap_segment`)
- Update `save_activity_override` — add `trip_segment` and `gap_segment` to valid activity types
- Update `remove_activity_override` — add `trip_segment` and `gap_segment` to valid activity types
- Update `activity_overrides` CHECK constraint (if any) to accept `trip_segment` and `gap_segment`

## RPCs

### `segment_activity(p_activity_type, p_activity_id, p_cut_points[], p_employee_id, p_starts_at, p_ends_at)`

Unified RPC replacing `segment_cluster`.

**Parameters:**
- `p_activity_type TEXT` — `'stop'`, `'trip'`, or `'gap'`
- `p_activity_id UUID` — cluster ID, trip ID, or gap hash
- `p_cut_points TIMESTAMPTZ[]` — timestamps where to split (max 2)
- `p_employee_id UUID DEFAULT NULL` — required for gaps (no source table)
- `p_starts_at TIMESTAMPTZ DEFAULT NULL` — required for gaps (no source table)
- `p_ends_at TIMESTAMPTZ DEFAULT NULL` — required for gaps (no source table)

**Logic:**
1. Auth: only admins/super_admins
2. Validate max 2 cut points: `IF array_length(p_cut_points, 1) > 2 THEN RAISE EXCEPTION`
3. Resolve activity time bounds and employee_id:
   - `stop` → `stationary_clusters.started_at / ended_at / employee_id`
   - `trip` → `trips.started_at / ended_at / employee_id`
   - `gap` → `p_starts_at / p_ends_at / p_employee_id` (all required, raise if NULL)
4. Determine business date: `to_business_date(v_started_at)`
5. Check day is not approved
6. Validate cut points: within bounds, each segment >= 1 minute, sorted
7. Delete existing segments + their activity_overrides for this activity (both parent type and segment type overrides: e.g., delete `'trip'` AND `'trip_segment'` overrides)
8. Delete parent activity override (if any)
9. Insert N+1 segments into `activity_segments` (with `employee_id` populated for all types)
10. Return `get_day_approval_detail()` with updated data

### `unsegment_activity(p_activity_type, p_activity_id)`

Unified RPC replacing `unsegment_cluster`.

**Logic:**
1. Auth: only admins/super_admins
2. Resolve employee_id and business date:
   - `stop` → from `stationary_clusters`
   - `trip` → from `trips`
   - `gap` → from `activity_segments.employee_id` (the segments themselves store the employee_id)
3. Check day is not approved
4. Delete activity_overrides for all segments of this activity (segment type overrides)
5. Delete segments from `activity_segments`
6. Return `get_day_approval_detail()` with updated data

## SQL: `_get_day_approval_detail_base` changes

### Current architecture (stops only)

```
stop_data → stop_classified → all_stops (exclude segmented + UNION stop segments)
trip_data (standalone)
gap_candidates (second CTE block, merged into v_activities)
```

### New architecture (universal)

First CTE block (inside `classified` UNION ALL):
```
stop_data → stop_classified ─┐
stop_segment_data ────────────┤
                              ├─ classified (UNION ALL)
trip_data (exclude segmented)─┤
trip_segment_data ────────────┤
clock_data ───────────────────┤
lunch_data ───────────────────┘
```

Second CTE block (gap detection — separate query into `v_gaps`):
```
gap_candidates (exclude segmented gaps) → v_gaps
```

Then gap_segment_data is added to `v_activities` alongside `v_gaps`:
```
v_activities = classified activities
             + v_gaps (non-segmented gaps only)
             + gap_segment_data (segmented gap pieces)
```

### CTE: `stop_segment_data`

Existing logic from current `segment_data` CTE, adapted to use `activity_segments` instead of `cluster_segments`:

```sql
stop_segment_data AS (
    SELECT
        'stop_segment'::TEXT AS activity_type,
        aseg.id AS activity_id,
        sc.shift_id,
        aseg.starts_at AS started_at,
        aseg.ends_at AS ended_at,
        EXTRACT(EPOCH FROM (aseg.ends_at - aseg.starts_at))::INTEGER / 60 AS duration_minutes,
        sc.matched_location_id,
        l.name AS location_name,
        l.location_type::TEXT,
        sc.centroid_latitude AS latitude,
        sc.centroid_longitude AS longitude,
        -- ... (auto_status, auto_reason same as current segment_data)
    FROM activity_segments aseg
    JOIN stationary_clusters sc ON sc.id = aseg.activity_id
    LEFT JOIN locations l ON l.id = sc.matched_location_id
    LEFT JOIN day_approvals da ON ...
    LEFT JOIN activity_overrides ao ON ... AND ao.activity_type = 'stop_segment'
    WHERE aseg.activity_type = 'stop'
      AND sc.employee_id = p_employee_id
      AND aseg.starts_at >= p_date::TIMESTAMPTZ
      AND aseg.starts_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
)
```

### CTE: `trip_segment_data`

New CTE for trip segments:

```sql
trip_segment_data AS (
    SELECT
        'trip_segment'::TEXT AS activity_type,
        aseg.id AS activity_id,
        t.shift_id,
        aseg.starts_at AS started_at,
        aseg.ends_at AS ended_at,
        EXTRACT(EPOCH FROM (aseg.ends_at - aseg.starts_at))::INTEGER / 60 AS duration_minutes,
        NULL::UUID AS matched_location_id,
        NULL::TEXT AS location_name,
        NULL::TEXT AS location_type,
        first_gp.latitude,
        first_gp.longitude,
        NULL::INTEGER AS gps_gap_seconds,
        NULL::INTEGER AS gps_gap_count,
        'needs_review'::TEXT AS auto_status,
        'Segment de trajet'::TEXT AS auto_reason,
        seg_distance.distance_km,
        t.transport_mode::TEXT,
        t.has_gps_gap,
        -- Start/end locations: nearest location to first/last GPS point in segment
        -- Uses ST_DWithin with location radius, same logic as clock event location matching
        seg_start_loc.id AS start_location_id,
        seg_start_loc.name AS start_location_name,
        seg_start_loc.location_type::TEXT AS start_location_type,
        seg_end_loc.id AS end_location_id,
        seg_end_loc.name AS end_location_name,
        seg_end_loc.location_type::TEXT AS end_location_type,
        ...
    FROM activity_segments aseg
    JOIN trips t ON t.id = aseg.activity_id
    -- First GPS point in segment window
    LEFT JOIN LATERAL (
        SELECT gp.latitude, gp.longitude
        FROM gps_points gp
        JOIN trip_gps_points tgp ON tgp.gps_point_id = gp.id
        WHERE tgp.trip_id = t.id
          AND gp.recorded_at >= aseg.starts_at
          AND gp.recorded_at < aseg.ends_at
        ORDER BY gp.recorded_at ASC LIMIT 1
    ) first_gp ON TRUE
    -- Distance: sum of haversine between consecutive GPS points within window
    LEFT JOIN LATERAL (
        SELECT COALESCE(SUM(pair_dist), 0)::DECIMAL AS distance_km
        FROM (
            SELECT ST_DistanceSphere(
                ST_MakePoint(gp1.longitude, gp1.latitude),
                ST_MakePoint(gp2.longitude, gp2.latitude)
            ) / 1000.0 AS pair_dist
            FROM (
                SELECT gp.latitude, gp.longitude, gp.recorded_at,
                       LEAD(gp.latitude) OVER (ORDER BY gp.recorded_at) AS next_lat,
                       LEAD(gp.longitude) OVER (ORDER BY gp.recorded_at) AS next_lng
                FROM gps_points gp
                JOIN trip_gps_points tgp ON tgp.gps_point_id = gp.id
                WHERE tgp.trip_id = t.id
                  AND gp.recorded_at >= aseg.starts_at
                  AND gp.recorded_at < aseg.ends_at
            ) gp1
            CROSS JOIN LATERAL (SELECT gp1.next_lat AS latitude, gp1.next_lng AS longitude) gp2
            WHERE gp1.next_lat IS NOT NULL
        ) sub
    ) seg_distance ON TRUE
    -- Start location: nearest location to first GPS point (ST_DWithin with radius)
    LEFT JOIN LATERAL (
        SELECT l.id, l.name, l.location_type
        FROM locations l, gps_points gp
        JOIN trip_gps_points tgp ON tgp.gps_point_id = gp.id
        WHERE tgp.trip_id = t.id
          AND gp.recorded_at >= aseg.starts_at AND gp.recorded_at < aseg.ends_at
          AND l.is_active = TRUE
          AND ST_DWithin(l.location::geography,
              ST_SetSRID(ST_MakePoint(gp.longitude, gp.latitude), 4326)::geography,
              l.radius_meters)
        ORDER BY gp.recorded_at ASC, ST_Distance(l.location::geography,
            ST_SetSRID(ST_MakePoint(gp.longitude, gp.latitude), 4326)::geography)
        LIMIT 1
    ) seg_start_loc ON TRUE
    -- End location: nearest location to last GPS point
    LEFT JOIN LATERAL (
        SELECT l.id, l.name, l.location_type
        FROM locations l, gps_points gp
        JOIN trip_gps_points tgp ON tgp.gps_point_id = gp.id
        WHERE tgp.trip_id = t.id
          AND gp.recorded_at >= aseg.starts_at AND gp.recorded_at < aseg.ends_at
          AND l.is_active = TRUE
          AND ST_DWithin(l.location::geography,
              ST_SetSRID(ST_MakePoint(gp.longitude, gp.latitude), 4326)::geography,
              l.radius_meters)
        ORDER BY gp.recorded_at DESC, ST_Distance(l.location::geography,
            ST_SetSRID(ST_MakePoint(gp.longitude, gp.latitude), 4326)::geography)
        LIMIT 1
    ) seg_end_loc ON TRUE
    LEFT JOIN day_approvals da ON ...
    LEFT JOIN activity_overrides ao ON ... AND ao.activity_type = 'trip_segment'
    WHERE aseg.activity_type = 'trip'
      AND t.employee_id = p_employee_id
      AND aseg.starts_at >= p_date::TIMESTAMPTZ
      AND aseg.starts_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
)
```

### CTE: `gap_segment_data`

New query for gap segments. Added to `v_activities` alongside `v_gaps` in the second phase (after gap detection), NOT inside the first CTE block:

```sql
-- After computing v_gaps, also fetch gap segments:
SELECT jsonb_agg(
    jsonb_build_object(
        'activity_type', 'gap_segment',
        'activity_id', aseg.id,
        'shift_id', (SELECT s.id FROM shifts s
            WHERE s.employee_id = p_employee_id
              AND s.clocked_in_at <= aseg.starts_at
              AND COALESCE(s.clocked_out_at, now()) >= aseg.ends_at
              AND NOT s.is_lunch
            LIMIT 1),
        'started_at', aseg.starts_at,
        'ended_at', aseg.ends_at,
        'duration_minutes', EXTRACT(EPOCH FROM (aseg.ends_at - aseg.starts_at))::INTEGER / 60,
        'auto_status', 'needs_review',
        'auto_reason', 'Temps non suivi (segment)',
        'override_status', ao.override_status,
        'override_reason', ao.reason,
        'final_status', COALESCE(ao.override_status, 'needs_review'),
        'matched_location_id', NULL,
        'location_name', NULL,
        'location_type', NULL,
        -- ... other NULL fields ...
        'has_gps_gap', TRUE,
        'gps_gap_seconds', EXTRACT(EPOCH FROM (aseg.ends_at - aseg.starts_at))::INTEGER,
        'gps_gap_count', 1
    )
)
INTO v_gap_segments
FROM activity_segments aseg
LEFT JOIN day_approvals da ON da.employee_id = p_employee_id AND da.date = p_date
LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
    AND ao.activity_type = 'gap_segment' AND ao.activity_id = aseg.id
WHERE aseg.activity_type = 'gap'
  AND aseg.employee_id = p_employee_id
  AND aseg.starts_at >= p_date::TIMESTAMPTZ
  AND aseg.starts_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ;

-- Merge into v_activities alongside gaps
IF v_gap_segments IS NOT NULL THEN
    v_activities := ... merge v_gap_segments ...
END IF;
```

### Exclusion of segmented parents

```sql
-- Stops: exclude segmented clusters from all_stops
WHERE sc.id NOT IN (
    SELECT activity_id FROM activity_segments WHERE activity_type = 'stop'
)

-- Trips: exclude segmented trips from trip_data
WHERE t.id NOT IN (
    SELECT activity_id FROM activity_segments WHERE activity_type = 'trip'
)

-- Gaps: exclude segmented gaps from gap output
-- In the v_gaps computation, filter out gaps that have been segmented:
WHERE md5(p_employee_id::TEXT || '/gap/' || gc.gap_start::TEXT || '/' || gc.gap_end::TEXT)::UUID
    NOT IN (SELECT activity_id FROM activity_segments WHERE activity_type = 'gap')
```

### Summary computation

Update needs_review_count to include all segment types:

```sql
-- Segments count toward needs_review (they are explicitly created for admin review)
-- Standalone trips still excluded (they derive status from adjacent stops)
WHERE a->>'final_status' = 'needs_review'
  AND a->>'activity_type' NOT IN ('trip')
  -- Note: trip_segment IS included (unlike trip, it has independent status)
```

## Frontend

### New component: `ActivitySegmentModal`

Replaces `ClusterSegmentModal`. Same popover UI (cut points, visual timeline bar, preview) but works for all activity types.

```typescript
interface ActivitySegmentModalProps {
  activityType: 'stop' | 'trip' | 'gap';
  activityId: string;
  startedAt: string;
  endedAt: string;
  isSegmented: boolean;
  employeeId?: string;  // required for gaps
  onUpdated: (newDetail: DayApprovalDetailType) => void;
}
```

Calls `segment_activity` RPC. For gaps, passes `p_starts_at`, `p_ends_at`, and `p_employee_id`.

### Kebab menu (⋮) on activity rows

Replace inline scissors icon with a kebab menu in the last column of each activity row (before the expand chevron).

**Menu items:**
- "Diviser l'activité" — opens `ActivitySegmentModal` popover (only if not already segmented and day not approved)
- "Retirer la division" — calls `unsegment_activity` with confirmation dialog (only if activity is segmented)

The menu appears on:
- `ActivityRow` (stops, gaps) — for non-segmented activities
- `TripConnectorRow` (trips) — for non-segmented trips
- `MergedLocationRow` — on the primary stop of the group. Note: segmenting a stop within a merged group may cause the group to break apart on re-render (since the segmented stop is replaced by segments, the merge condition may no longer chain). This is expected behavior — the admin explicitly wants to treat parts of that time differently.

For segment rows (`stop_segment`, `trip_segment`, `gap_segment`), the menu shows only "Retirer la division" which unsegments the parent activity (removes ALL segments, not just one).

### `ApprovalActivityIcon` updates

The `ApprovalActivityIcon` component in `approval-rows.tsx` must handle new segment types:
- `trip_segment` → same icon as `trip` (Car for driving, Footprints for walking)
- `gap_segment` → same icon as `gap` (WifiOff)
- `stop_segment` → already handled (inherits from parent location type)

### Segment row rendering

| Segment type | Icon | Badge | Default status |
|---|---|---|---|
| `stop_segment` | Location icon (from parent) | "Segment" | Inherits from location type |
| `trip_segment` | Car / Walking (from parent) | "Segment" | `needs_review` |
| `gap_segment` | WifiOff | "Segment" | `needs_review` |

### Bug fixes included

1. **`durationStats`** (`day-approval-detail.tsx:157`): filter includes `stop_segment` alongside `stop`
2. **`mergeSameLocationGaps`**: already handles `stop_segment`, add `trip_segment` and `gap_segment` to type checks
3. **`nestLunchActivities`**: already protects `stop_segment` from absorption, add protection for `trip_segment` and `gap_segment`
4. **`visibleNeedsReviewCount`**: ensure `trip_segment` and `gap_segment` count toward the review count. Filter: exclude `trip` (derives from stops) but include `trip_segment` (has independent status)
5. **`MergeableActivity` type** (`merge-clock-events.ts`): add `trip_segment`, `gap_segment` to the `activity_type` union
6. **`ApprovalActivity` type** (`mileage.ts`): add `trip_segment`, `gap_segment` to the `activity_type` union
7. **`ApprovalActivityIcon`** (`approval-rows.tsx`): add rendering for `trip_segment` and `gap_segment`

### Files changed

```
dashboard/src/
├── components/approvals/
│   ├── cluster-segment-modal.tsx → renamed to activity-segment-modal.tsx
│   ├── approval-rows.tsx         (kebab menu, ApprovalActivityIcon, segment rendering, unsegment)
│   ├── approval-utils.ts         (mergeSameLocationGaps, nestLunchActivities)
│   └── day-approval-detail.tsx   (durationStats, visibleNeedsReviewCount)
├── lib/utils/
│   └── merge-clock-events.ts     (MergeableActivity type union)
└── types/
    └── mileage.ts                (ApprovalActivity type union)
```

### Not changed

Flutter mobile app — reads approval data via RPC only, no segmentation logic.

## Edge cases

- **Segment minimum duration**: 1 minute (enforced by RPC)
- **Maximum cut points**: 2 (creates 3 segments max) — enforced by RPC with explicit validation
- **Gap ID instability**: If shift times are edited after a gap is segmented, the gap hash changes. The segments remain in `activity_segments` but won't match any gap. **Resolution**: when `_get_day_approval_detail_base` detects gap segments whose `activity_id` doesn't match any current `gap_candidates` row, include them as standalone `gap_segment` rows with `auto_reason = 'Segment orphelin (horaire modifié)'`. The admin can then unsegment to clean up. Additionally, consider adding cleanup logic in `edit_shift_time` RPC to delete orphaned gap segments.
- **Trip with no GPS points in a segment window**: Segment shows "Aucun point GPS" with 0 km distance. Still approvable. Note: parent trip's `distance_km` will NOT equal the sum of segment distances (GPS points at segment boundaries may not be consecutive).
- **Approved day**: Cannot segment/unsegment. Must reopen day first (enforced by RPC).
- **Overlapping segments**: Prevented by deterministic IDs and the UNIQUE constraint on (activity_type, activity_id, segment_index).
- **Merged location group + segmentation**: Segmenting a stop within a merged group causes the group to break apart on re-render. This is expected — the merge logic in `mergeSameLocationGaps` requires consecutive same-location stops, and segments replace the parent stop.
- **Midnight-crossing activities**: Date filter uses `aseg.starts_at` only, consistent with existing approach. Gap hash uses both `gap_start` and `gap_end` which may be on different UTC dates, but `to_business_date` normalizes to Montreal timezone.
