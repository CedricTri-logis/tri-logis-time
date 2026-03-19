# Universal Activity Splitting

Split any approval activity (stop, trip, gap) into time-bounded segments for independent approval/rejection.

## Problem

Admins need to approve/reject portions of an activity, not just the whole thing. Key scenario: a 4-hour GPS gap where the employee was actually working for 3 hours and idle for 1 — the admin needs to approve the work portion and reject the rest. Currently, only stops can be split (via `cluster_segments`), and trips and gaps cannot be split at all.

## Design Decisions

- **Universal table** `activity_segments` replaces per-type tables (`cluster_segments`). Gaps have no source table, so a universal approach avoids treating them as a special case.
- **Split first, approve/reject later** — splitting creates segments with inherited auto-status. The admin then approves/rejects each segment independently using existing override buttons.
- **GPS points redistributed by timestamp** — when a trip is split, each segment gets the GPS points that fall within its time window. Distance is recalculated per segment.
- **Kebab menu (⋮)** replaces inline scissors icon for a cleaner table UI. The menu contains "Diviser l'activité" and "Retirer la division" actions.

## Database

### New table: `activity_segments`

```sql
CREATE TABLE activity_segments (
    id              UUID PRIMARY KEY,
    activity_type   TEXT NOT NULL CHECK (activity_type IN ('stop', 'trip', 'gap')),
    activity_id     UUID NOT NULL,
    segment_index   INT NOT NULL,
    starts_at       TIMESTAMPTZ NOT NULL,
    ends_at         TIMESTAMPTZ NOT NULL,
    created_by      UUID NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(activity_type, activity_id, segment_index),
    CHECK (ends_at > starts_at)
);

CREATE INDEX idx_activity_segments_lookup
    ON activity_segments (activity_type, activity_id);
```

The `id` is deterministic: `md5(activity_type || ':' || activity_id || ':' || segment_index)::UUID`.

### Migration

- `DROP TABLE cluster_segments` (currently empty in production — 0 rows)
- `CREATE TABLE activity_segments`
- Drop old RPCs: `segment_cluster`, `unsegment_cluster`
- Create new RPCs: `segment_activity`, `unsegment_activity`
- Update `_get_day_approval_detail_base` for universal segment support
- Update `approve_day` and `remove_activity_override` for new segment types

## RPCs

### `segment_activity(p_activity_type, p_activity_id, p_cut_points[], p_starts_at, p_ends_at)`

Unified RPC replacing `segment_cluster`.

**Parameters:**
- `p_activity_type TEXT` — `'stop'`, `'trip'`, or `'gap'`
- `p_activity_id UUID` — cluster ID, trip ID, or gap hash
- `p_cut_points TIMESTAMPTZ[]` — timestamps where to split
- `p_starts_at TIMESTAMPTZ DEFAULT NULL` — required for gaps (no source table)
- `p_ends_at TIMESTAMPTZ DEFAULT NULL` — required for gaps (no source table)

**Logic:**
1. Auth: only admins/super_admins
2. Resolve activity time bounds:
   - `stop` → `stationary_clusters.started_at / ended_at`
   - `trip` → `trips.started_at / ended_at`
   - `gap` → `p_starts_at / p_ends_at` (passed by frontend)
3. Determine employee_id and business date from the activity
4. Check day is not approved
5. Validate cut points: within bounds, each segment >= 1 minute, sorted
6. Delete existing segments + their activity_overrides for this activity
7. Delete parent activity override (if any)
8. Insert N+1 segments into `activity_segments`
9. Return `get_day_approval_detail()` with updated data

**Employee ID resolution:**
- `stop` → `stationary_clusters.employee_id`
- `trip` → `trips.employee_id`
- `gap` → passed as additional parameter `p_employee_id` (gaps have no table)

Updated signature includes `p_employee_id UUID DEFAULT NULL` for gap support.

### `unsegment_activity(p_activity_type, p_activity_id)`

Unified RPC replacing `unsegment_cluster`.

**Logic:**
1. Auth: only admins/super_admins
2. Resolve employee_id and business date from activity_type + activity_id
3. Check day is not approved
4. Delete activity_overrides for all segments of this activity
5. Delete segments from `activity_segments`
6. Return `get_day_approval_detail()` with updated data

## SQL: `_get_day_approval_detail_base` changes

### Current architecture (stops only)

```
stop_data → stop_classified → all_stops (exclude segmented + UNION stop segments)
trip_data (standalone)
gap_candidates (standalone)
```

### New architecture (universal)

```
stop_data → stop_classified ─┐
stop_segment_data ────────────┤
                              ├─ classified (UNION ALL)
trip_data (exclude segmented)─┤
trip_segment_data ────────────┤
                              │
gap_candidates (exclude segmented)─┤
gap_segment_data ─────────────┘
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
        -- First GPS point in segment window for lat/lng
        first_gp.latitude,
        first_gp.longitude,
        -- GPS gap detection within segment window
        ...,
        'needs_review'::TEXT AS auto_status,
        'Segment de trajet'::TEXT AS auto_reason,
        -- Distance: sum of consecutive point distances within segment window
        seg_distance.distance_km,
        t.transport_mode::TEXT,
        t.has_gps_gap,
        -- Start/end locations from first/last GPS points in segment
        seg_start_loc.id AS start_location_id,
        seg_start_loc.name AS start_location_name,
        seg_end_loc.id AS end_location_id,
        seg_end_loc.name AS end_location_name,
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
    -- Distance calculation within segment
    LEFT JOIN LATERAL (
        SELECT COALESCE(SUM(pair_dist), 0)::DECIMAL AS distance_km
        FROM ( ... point-to-point haversine within window ... ) sub
    ) seg_distance ON TRUE
    -- Location matching for start/end of segment
    LEFT JOIN LATERAL ( ... nearest location to first point ... ) seg_start_loc ON TRUE
    LEFT JOIN LATERAL ( ... nearest location to last point ... ) seg_end_loc ON TRUE
    LEFT JOIN day_approvals da ON ...
    LEFT JOIN activity_overrides ao ON ... AND ao.activity_type = 'trip_segment'
    WHERE aseg.activity_type = 'trip'
      AND t.employee_id = p_employee_id
      AND aseg.starts_at >= p_date::TIMESTAMPTZ
      AND aseg.starts_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
)
```

### CTE: `gap_segment_data`

New CTE for gap segments:

```sql
gap_segment_data AS (
    SELECT
        'gap_segment'::TEXT AS activity_type,
        aseg.id AS activity_id,
        -- shift_id: resolve from the parent gap's shift_id (stored during segment creation)
        -- or find the shift that contains this time window
        (SELECT s.id FROM shifts s
         WHERE s.employee_id = p_employee_id
           AND s.clocked_in_at <= aseg.starts_at
           AND COALESCE(s.clocked_out_at, now()) >= aseg.ends_at
         LIMIT 1) AS shift_id,
        aseg.starts_at AS started_at,
        aseg.ends_at AS ended_at,
        EXTRACT(EPOCH FROM (aseg.ends_at - aseg.starts_at))::INTEGER / 60 AS duration_minutes,
        NULL::UUID AS matched_location_id,
        NULL::TEXT AS location_name,
        NULL::TEXT AS location_type,
        NULL::DECIMAL AS latitude,
        NULL::DECIMAL AS longitude,
        NULL::INTEGER AS gps_gap_seconds,
        NULL::INTEGER AS gps_gap_count,
        'needs_review'::TEXT AS auto_status,
        'Temps non suivi (segment)'::TEXT AS auto_reason,
        ...
        ao.override_status,
        ao.reason AS override_reason,
        COALESCE(ao.override_status, 'needs_review') AS final_status,
        ...
    FROM activity_segments aseg
    LEFT JOIN day_approvals da ON da.employee_id = p_employee_id
        AND da.date = p_date
    LEFT JOIN activity_overrides ao ON ao.day_approval_id = da.id
        AND ao.activity_type = 'gap_segment'
        AND ao.activity_id = aseg.id
    WHERE aseg.activity_type = 'gap'
      AND aseg.starts_at >= p_date::TIMESTAMPTZ
      AND aseg.starts_at < (p_date + INTERVAL '1 day')::TIMESTAMPTZ
)
```

Note: `gap_segment_data` needs the employee filter. Since gaps have no source table, the `activity_segments` table should include an `employee_id` column for gap segments. Updated table schema:

```sql
ALTER TABLE activity_segments ADD COLUMN employee_id UUID;
-- Required for gaps (no source table to JOIN), optional for stops/trips
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
-- After computing gap_candidates, filter out those with segments:
WHERE md5(p_employee_id::TEXT || '/gap/' || gc.gap_start::TEXT || '/' || gc.gap_end::TEXT)::UUID
    NOT IN (SELECT activity_id FROM activity_segments WHERE activity_type = 'gap')
```

### Summary computation

Update needs_review_count to include all segment types:

```sql
WHERE a->>'activity_type' IN ('stop', 'stop_segment', 'gap', 'gap_segment', 'trip_segment')
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
  onUpdated: (newDetail: DayApprovalDetailType) => void;
}
```

Calls `segment_activity` RPC. For gaps, passes `p_starts_at` and `p_ends_at`.

### Kebab menu (⋮) on activity rows

Replace inline scissors icon with a kebab menu in the last column of each activity row.

**Menu items:**
- "Diviser l'activité" — opens `ActivitySegmentModal` popover (only if not already segmented and day not approved)
- "Retirer la division" — calls `unsegment_activity` with confirmation dialog (only if activity is segmented)

The menu appears on:
- `ActivityRow` (stops, gaps, clock events)
- `TripConnectorRow` (trips)
- `MergedLocationRow` (merged stop groups)

For segment rows (`stop_segment`, `trip_segment`, `gap_segment`), the menu shows only "Retirer la division" which unsegments the parent activity (removes ALL segments, not just one).

### Segment row rendering

| Segment type | Icon | Badge | Default status |
|---|---|---|---|
| `stop_segment` | Location icon (from parent) | "Segment" | Inherits from location type |
| `trip_segment` | Car / Walking | "Segment" | `needs_review` |
| `gap_segment` | WifiOff | "Segment" | `needs_review` |

### Bug fixes included

1. **`durationStats`** (`day-approval-detail.tsx:157`): filter includes `stop_segment` alongside `stop`
2. **`mergeSameLocationGaps`**: already handles `stop_segment`, add `trip_segment` and `gap_segment` to type checks
3. **`nestLunchActivities`**: already protects `stop_segment` from absorption, add protection for `trip_segment` and `gap_segment`
4. **`visibleNeedsReviewCount`**: ensure `trip_segment` and `gap_segment` count toward the review count (exclude `trip` as before, but include `trip_segment`)
5. **`MergeableActivity` type** (`merge-clock-events.ts`): add `trip_segment`, `gap_segment` to the `activity_type` union
6. **`ApprovalActivity` type** (`mileage.ts`): add `trip_segment`, `gap_segment` to the `activity_type` union

### Files changed

```
dashboard/src/
├── components/approvals/
│   ├── cluster-segment-modal.tsx → renamed to activity-segment-modal.tsx
│   ├── approval-rows.tsx         (kebab menu, segment rendering, unsegment)
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
- **Maximum cut points**: 2 (creates 3 segments max) — keeps UI simple
- **Gap ID instability**: If shift times are edited after a gap is segmented, the gap hash changes. The segments remain in `activity_segments` but won't match any gap. Handle by: detecting orphaned gap segments and surfacing them as standalone rows, or cleaning them up when shift times are edited.
- **Trip with no GPS points in a segment window**: Segment shows "Aucun point GPS" with 0 km distance. Still approvable.
- **Approved day**: Cannot segment/unsegment. Must reopen day first (enforced by RPC).
- **Overlapping segments**: Prevented by deterministic IDs and the UNIQUE constraint on (activity_type, activity_id, segment_index).
