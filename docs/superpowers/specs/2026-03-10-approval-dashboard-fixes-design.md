# Approval Dashboard Fixes — Design Spec

**Date:** 2026-03-10
**Context:** Celine Santerre March 9 2026 — clock-out icons missing, shift auto-closed prematurely, two duplicate Home clusters, gap detection lost

## Problem Statement

Migration 147 rewrote `get_day_approval_detail()` but lost gap detection logic from migration 144. Additionally, `flag_gpsless_shifts()` auto-closes shifts too aggressively (10 min no GPS), and clock events are hidden when GPS location is unavailable at clock-in/out time.

## Changes

### 1. `flag_gpsless_shifts()` → Non-destructive Flag + Midnight Close

- **Flag:** After 10 min with no GPS, set `gps_health = 'stale'` on the shift (new column `TEXT DEFAULT 'ok'` on `shifts` table). Do NOT close the shift.
- **Midnight close:** In the same cron, close any active shift when it's past midnight EST. Use `America/Toronto` timezone. Set `clock_out_reason = 'midnight_auto_close'`, `clocked_out_at = 23:59:59 EST of the clock-in day`.
- Call `detect_trips()` after midnight close as before.

### 2. Clock Events Without Location

- Remove `clock_in_location IS NOT NULL` and `clock_out_location IS NOT NULL` filters from `clock_data` CTE in `_get_day_approval_detail_base`.
- When location is NULL: `location_name = 'Lieu inconnu'`, `auto_status = 'needs_review'`, `auto_reason = 'Clock-in/out sans position GPS'`.
- Frontend `mergeClockEvents()` already merges these into adjacent stops.

### 3. Fix `detect_trips()` — Merge Same-Location Clusters

- After cluster creation in `detect_trips()`, add a fusion pass: if two consecutive clusters have the same `matched_location_id` (non-null) and no trip between them, merge into a single cluster.
- `gps_gap_seconds` of merged cluster = sum of original gaps + time between the two clusters.
- Rerun `detect_trips()` for Celine's March 9 shifts after the fix.

### 4. Restore Gap Detection in RPC

- Restore CTEs from migration 144: `shift_events`, `gap_pairs` (>300s threshold), `gap_activities`.
- Gaps inherit `start_location_id`/`end_location_id` from adjacent stops.
- `auto_status = 'needs_review'`, descriptive `auto_reason` based on gap type.

### 5. Dashboard — Show `gps_health = 'stale'`

- RPC returns `gps_health` info per shift.
- Approval detail view shows orange "GPS manquant" badge when a shift has `gps_health = 'stale'`.

## No Frontend Changes Required (except #5)

`mergeClockEvents()` and `mergeSameLocationGaps()` already handle the merge logic — only the data was missing.
