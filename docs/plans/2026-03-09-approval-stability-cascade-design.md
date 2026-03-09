# Approval Stability & Cascade Design

**Date:** 2026-03-09
**Status:** Approved

## Problem Summary

Three interrelated bugs in the approval system:

1. **Lost overrides**: When trip detection re-runs (sync, manual trigger), it deletes all trips/clusters and recreates them with new UUIDs. Manual approvals/rejections reference the old UUIDs and become orphaned — items revert to yellow.

2. **No trip cascade**: Trips between rejected stops stay yellow. The system classifies trips by endpoint location types only, ignoring the override status of adjacent stops.

3. **Unknown = yellow**: Stops at unmatched locations default to "needs review" instead of "rejected." Company policy: if it's not in the approved locations list, it's rejected.

## Design

### Fix 1: Deterministic Activity IDs

**Current behavior:** `detect_trips()` does `DELETE FROM trips WHERE shift_id = ?` then `INSERT` with `gen_random_uuid()`. Same for `stationary_clusters`.

**New behavior:** Use `uuid_generate_v5(namespace_uuid, shift_id::text || '|' || start_time::text)` to generate deterministic IDs. Same shift + same start time = same UUID every time.

- Re-running detection on a completed shift produces the same IDs if boundaries didn't change
- Existing overrides stay attached automatically
- If boundaries shift (new GPS data changes a stop's start time), that's a genuinely new activity with a new ID, requiring fresh review
- Requires `uuid-ossp` extension (or use `gen_random_uuid()` as namespace with a fixed namespace constant)

### Fix 2: Bidirectional Trip Cascade from Neighbors

**Current behavior:** Trip auto_status is derived from its start/end location types (`office` → approved, `home` → rejected, unmatched → needs_review).

**New behavior:** In `get_day_approval_detail()`, after computing all stop statuses (auto-classification + overrides merged), derive each trip's status from its neighboring stops:

| Left stop | Right stop | Trip status |
|-----------|------------|-------------|
| approved  | approved   | **approved** |
| rejected  | anything   | **rejected** |
| anything  | rejected   | **rejected** |
| needs_review | approved | **needs_review** |
| approved | needs_review | **needs_review** |
| needs_review | needs_review | **needs_review** |

**Rule:** If either neighbor is rejected → trip is rejected. Only approved if both neighbors are approved. Rationale: "we don't pay transportation to or from a rejected place."

This replaces the current endpoint-location-based trip classification. Stops drive everything.

Manual trip overrides still take precedence: `COALESCE(trip_override, cascade_status)`.

### Fix 3: Unknown Locations Default to Rejected

**Current behavior:** In `get_day_approval_detail()`, stops with `matched_location_id IS NULL` get `auto_status = 'needs_review'`.

**New behavior:** Change to `auto_status = 'rejected'`. Since trips now cascade from stops (Fix 2), an unknown stop automatically rejects its adjacent trips too.

Admins manually approve the rare exceptions via override.

### One-time Cleanup Migration

Match orphaned `activity_overrides` to current trips/clusters by time proximity:

1. Find all overrides where `activity_id` doesn't match any current trip/cluster
2. For each orphaned override, find the current trip/cluster in the same shift with the closest start time (within a tolerance window, e.g., 5 minutes)
3. Update the override's `activity_id` to the current row's ID
4. Log any overrides that couldn't be matched (for manual review)

## Scope

- **Backend only**: All changes are in Supabase migrations (SQL)
- **No Flutter changes**: The mobile app doesn't need updating
- **No dashboard changes**: The dashboard reads from `get_day_approval_detail()` which will return corrected data
- **Migration count**: 1 migration with all fixes + cleanup
