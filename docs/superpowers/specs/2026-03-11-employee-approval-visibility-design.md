# Employee Approval Visibility — Design Spec

**Date:** 2026-03-11
**Feature:** Employees see their approval status, activity breakdown by location, and OSRM trip routes in the Flutter app.

## Goal

Enrich the existing ShiftHistoryScreen → ShiftDetailScreen flow so employees can see their hours approval data (approved/rejected/pending) in read-only mode, with per-location breakdown and interactive OSRM trip maps.

## ShiftHistoryScreen (Day List)

- Each day row shows a **status badge**:
  - Green "Approuvé" — day approved by supervisor
  - Red "Rejeté" — day has rejected activities (not yet fully approved)
  - Grey "En attente" — not yet reviewed by supervisor
  - No badge — no shift that day
- **Quick summary** per row: approved hours / rejected hours (e.g., "7h12 ✓ · 0h30 ✗")

## ShiftDetailScreen (Tap on a Day)

### Header Summary

- Total shift time, approved hours, rejected hours, day status
- Grouped by location (e.g., "Chantier A — 3h ✓", "Bureau — 1h ✓", "Inconnu — 30min ✗")

### Activity Timeline

- Same data as `get_day_approval_detail` RPC — trips, stops, clock in/out, GPS gaps, lunch breaks
- Each row: type icon, detail (location, distance), duration, time range, **status badge** (approved/rejected/pending)
- Read-only — no action buttons

### OSRM Trip Map

- flutter_map with OSRM routes drawn as polylines (from `trips.route_geometry`)
- Start/end markers for each trip
- Tap on a trip → popup showing distance and duration
- Interactive zoom/pan

## Data Sources

- **`get_day_approval_detail(p_employee_id, p_date)`** — full activity timeline with statuses (existing RPC)
- **`get_weekly_approval_summary(p_week_start)`** — day-level statuses for list badges (existing RPC)
- **`trips.route_geometry`** — OSRM polylines (existing column)
- No new RPCs needed. RLS policies must allow employees to read their own approval data.

## Technical Decisions

- **No local cache** — always fetched live from Supabase
- **Pull-to-refresh** on both screens
- **No new dependencies** — uses existing flutter_map, supabase_flutter, flutter_riverpod

## Out of Scope

- Rejection reasons display
- Push notifications on approval/rejection
- Weekly view (keep day list)
- Employee ability to contest decisions
