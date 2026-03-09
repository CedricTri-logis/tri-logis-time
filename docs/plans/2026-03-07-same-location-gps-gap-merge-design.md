# Design: Merge Same-Location GPS Gaps into Parent Row

**Date:** 2026-03-07
**Scope:** Dashboard approval detail panel (frontend-only)

## Problem

When an employee stays at the same location but loses GPS signal (e.g., 284-288_Dallaire from 08:22-09:30 then 13:43-15:55), the current UI splits it into:
- Row: Stop at 284-288_Dallaire (1h07)
- Row: "Deplacement non trace" 284-288_Dallaire -> 284-288_Dallaire (4h13, 0.0 km)
- Row: Stop at 284-288_Dallaire (2h12)

This is confusing because the "travel" row shows 0 km between the same location — it's not travel, it's a GPS signal loss.

## Solution

Merge consecutive same-location stops separated by GPS gaps into a single row with expandable nested gap sub-rows.

### Merged Row (collapsed)

- Single row for the location showing **full time span** (08:22-15:55)
- Duration: full span (7h33)
- **Yellow/amber left border + background tint** when unreviewed gaps exist
- GPS gap badge: "4h13 GPS perdu" (or "2 gaps - 4h13 GPS perdu" if multiple)
- Approve/reject buttons on main row = **stop time only**
- Expand chevron indicating nested items

### Merged Row (expanded)

- Only GPS gap sub-rows appear (indented)
- Each gap: duration, time range, individual approve/reject buttons
- "Tout approuver" bulk button at top of expanded section
- Once all gaps reviewed, yellow highlight disappears from parent row

### Merge Criteria

**Merge when:**
- A `gap` activity has `start_location_id === end_location_id` (same location both sides)
- Consecutive stop->gap->stop chains at the same location all fold together

**Do NOT merge:**
- Gap with different start/end locations -> "Deplacement non trace" (unchanged)
- Gap with no location data -> "Temps non suivi" (unchanged)
- Clock-in -> first cluster gaps (unchanged)
- Last cluster -> clock-out gaps (unchanged)

### Duration Calculation

- `started_at` = earliest stop's start time
- `ended_at` = latest stop's end time
- Total gap time = sum of all nested gap durations
- Display: full span duration + gap badge showing total lost time

### Approval Flow

1. Yellow highlight on row when unreviewed GPS gaps exist inside
2. Expand -> see individual gaps -> approve/reject each, or "Tout approuver" bulk
3. Main row approve/reject = stop time only
4. Yellow disappears once all nested gaps are handled

### Files to Modify

1. `dashboard/src/components/approvals/day-approval-detail.tsx`
   - Pre-process activities list: detect same-location gap sequences, build merged groups
   - New `MergedLocationRow` component: combined row with yellow tint, gap badge, expand/collapse
   - New `GapSubRow` component: individual gap approval (indented, approve/reject)
   - "Tout approuver" bulk button in expanded section
   - Existing `ActivityRow` unchanged for all non-merged activities

2. No backend/SQL changes
3. No new dependencies

### What Stays the Same

- All trip rows, clock-in/out rows, lunch rows
- Different-location gaps ("Deplacement non trace")
- No-data gaps ("Temps non suivi")
- Clock-in -> first cluster and last cluster -> clock-out gaps
- Approval API calls (same endpoints, called from nested sub-rows)
