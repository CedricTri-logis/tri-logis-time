# Approval Simplification Design

## Problem

The day approval detail view shows every activity (stop, trip, clock) as equal-sized rows with individual approve/reject buttons. A typical day has 4 stops and 3 trips = 7 rows requiring 7 decisions. This is verbose and slow.

## Goal

Minimize the number of human decisions to approve a day. Stops are the primary unit of approval; trips derive their status from adjacent stops.

## Design Decisions

1. **Stops are the only activity with visible approve/reject buttons** (primary rows)
2. **Trips auto-derive status from endpoint stops** (compact connector rows, no buttons by default)
3. **Expanding a trip reveals the route map + manual override toggle** (for edge cases where the trip itself is suspicious between two approved locations)
4. **GPS anomalies (gaps, long duration) are visual warnings only** - they do not affect auto-classification or block day approval
5. **approve_day only checks stops and clocks for needs_review** - trips are excluded from the blocking check since they derive from stops

## Trip Auto-Classification Rule (simplified)

```
final_status = override_status ?? derived_status

derived_status:
  BOTH endpoints at approved location types -> 'approved'
  EITHER endpoint at rejected location type -> 'rejected'
  OTHERWISE (unmatched endpoints)           -> 'needs_review'
```

Removed from classification (become warning flags only):
- has_gps_gap no longer forces needs_review
- duration_minutes > 60 no longer forces needs_review

## Display Layout

Stops = full-height primary rows with approve/reject buttons visible:
```
[ok][x]  Office           45min   08:00-08:45
            -> 15min  12km                     (gps warning icon if applicable)
[ok][x]  Client A         2h00    09:00-11:00
            -> 20min  18km
[??]     Unmatched stop   1h30    11:20-12:50
            -> 15min  12km                     (gps warning icon)
[ok][x]  Office           1h00    13:05-14:05
```

Trip connector rows:
- ~50% row height, indented, lighter background
- Show: arrow icon, duration, distance, GPS warning if applicable
- Color follows derived status (green/red/amber matching endpoint logic)
- No approve/reject buttons in collapsed state
- Expandable: click reveals route map + manual override toggle

## Changes Required

### Database (Supabase migrations)

**1. Update get_day_approval_detail RPC**
- Trip auto_status: remove GPS gap and duration overrides, use endpoint-only logic
- Keep gps_gap_seconds, gps_gap_count, has_gps_gap as informational fields
- Keep duration_minutes > 60 as a returnable flag but not status-affecting

**2. Update approve_day RPC**
- Change needs_review check to exclude trips:
  `COUNT(*) FILTER (WHERE final_status = 'needs_review' AND activity_type NOT IN ('trip'))`

**3. Update get_weekly_approval_summary RPC**
- Adjust needs_review_count to exclude trip-only issues (flagged_trips no longer count)

### Frontend (Dashboard)

**4. day-approval-detail.tsx - ActivityRow split**
- Create `StopRow` component (full-size, with approve/reject buttons)
- Create `TripConnectorRow` component (compact, no buttons, expandable to show map + override)
- Remove manual cascade logic from handleOverride (trips now auto-derive on refetch)

**5. day-approval-detail.tsx - Expand behavior**
- Trip expanded state shows: route map + approve/reject override toggle
- Stop expanded state: unchanged (cluster map)

**6. Visual styling for trip connectors**
- Reduced padding (py-1.5 vs py-3)
- Indented left with arrow/connector icon
- Lighter background opacity
- Status color derived from endpoint logic

## Decision Flow After Changes

| Day scenario | Decisions needed |
|---|---|
| All stops at known locations | 0 - just click "Approve day" |
| 1 unmatched stop | 1 - approve/reject that stop, trips auto-follow |
| Suspicious trip between approved stops | 1 - expand trip, override manually |
| Admin disagrees with stop auto-classification | 1 - override that stop, trips auto-recalculate |

## What Does NOT Change

- activity_overrides table (trips can still be overridden when expanded)
- day_approvals table structure
- mergeClockEvents logic (clock events still merge into stops)
- Stop/clock auto-classification rules
- Expanded detail views (route maps, cluster maps)
