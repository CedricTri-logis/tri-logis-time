# Lunch Break Distinct Approval Lines

**Date**: 2026-03-07
**Scope**: Dashboard only (no Flutter or DB schema changes)

## Problem

Currently, lunch_start and lunch_end events are emitted as separate events by the RPC and get merged into nearby stops via `mergeClockEvents`. Lunch breaks don't appear as their own distinct lines in the approval timeline.

## Solution

Each lunch break appears as its own row in the approval timeline with start time, end time, duration, and a lunch icon. Always auto-approved (no approve/reject buttons).

## Changes

### 1. RPC `get_day_approval_detail` (new migration)

Replace the two separate `lunch_start` + `lunch_end` UNION blocks with a single `lunch` activity type per break:
- `activity_type = 'lunch'`
- `started_at` = break start, `ended_at` = break end
- `duration_minutes` = calculated from the break
- `auto_status = 'approved'`
- Keep lunch breaks as covered periods in gap detection (unchanged)

### 2. `merge-clock-events.ts`

- Add `'lunch'` to `MergeableActivity.activity_type` union
- Stop merging lunch events into stops (exclude `lunch` from the merge loop)
- Remove `hasLunchStart` / `hasLunchEnd` flags (no longer needed)

### 3. `day-approval-detail.tsx`

- New timeline row for `activity_type = 'lunch'`:
  - Icon: `UtensilsCrossed`
  - Shows: start time -> end time, duration
  - Green "Approuve" badge (auto, no override buttons)
- Remove lunch_start/lunch_end rendering logic

### 4. Summary breakdown (top of detail panel)

- Add a line with `UtensilsCrossed` icon + total lunch minutes (e.g., "45 min diner")

### 5. Types (`mileage.ts`)

- Add `'lunch'` to activity_type unions
- Remove `'lunch_start'` and `'lunch_end'` from types

## What stays the same

- `lunch_breaks` table schema
- Flutter app (no changes)
- `get_weekly_approval_summary` (already shows lunch_minutes)
- Approval grid (already shows lunch minutes per day)
- `activity_overrides` constraint (keep lunch_start/lunch_end for backwards compat)
