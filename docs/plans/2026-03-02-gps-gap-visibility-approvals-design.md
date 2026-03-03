# GPS Gap Visibility in Approvals — Design

**Date:** 2026-03-02
**Status:** Approved

## Problem

When approving employee hours, GPS gaps (periods without GPS signal) are only visible when expanding individual activities. There's no day-level summary, and trips only have a boolean `has_gps_gap` with no duration/count detail. This makes it hard to assess data reliability when making approval decisions.

## Solution

### 1. Add `gps_gap_seconds` / `gps_gap_count` to trips table

**New columns on `trips`:**
- `gps_gap_seconds INTEGER NOT NULL DEFAULT 0` — total excess gap seconds (intervals > 5 min grace period)
- `gps_gap_count INTEGER NOT NULL DEFAULT 0` — number of individual gaps > 5 min

**detect_trips update:**
During trip construction (gap between two clusters), accumulate intervals between consecutive GPS points of the trip. Each interval > 300s (5 min) increments count and accumulates excess (interval - 300s) into seconds.

**get_day_approval_detail update:**
Return `gps_gap_seconds` and `gps_gap_count` for trips (currently only returned for stops).

**Backfill:** Re-run `detect_trips` for recent completed shifts.

### 2. Summary bar — day-level totalization

Add a 5th metric to the existing summary bar (alongside Approved / Rejected / Needs Review / Total):

- Format: `warning 23 min GPS perdu (4 gaps)`
- Color: amber (bg-amber-50, text-amber-700)
- Calculation: sum of `gps_gap_seconds` across all activities (stops + trips), sum of `gps_gap_count`
- Hidden when 0 gaps (no visual noise)
- Stronger styling (amber-100, border amber-300) when total >= 5 min

### 3. Per-line GPS gap detail under duration

For each activity row, below the existing duration:

- **gap >= 5 min (300s):** amber text `warning X min perdues (Y gaps)` — attention-grabbing
- **gap > 0 but < 5 min:** grey text `warning X min perdues (Y gaps)` — informational
- **gap = 0:** nothing shown

Existing pulsing amber triangle in Duration column remains for quick visual scan.

Legacy trips with `has_gps_gap = true` but `gps_gap_seconds = 0` (pre-backfill): keep current "Sans trace GPS" display.

### Threshold

5 minutes — gaps below 5 min are shown in grey (informational), gaps >= 5 min are shown in amber (attention-worthy).
