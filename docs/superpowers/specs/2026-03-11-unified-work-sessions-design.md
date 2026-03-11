# Unified Work Sessions — Design Spec

**Date:** 2026-03-11
**Status:** Approved
**Scope:** Merge cleaning_sessions + maintenance_sessions into unified work_sessions, add mandatory activity type selection at clock-in

## Problem

1. Two separate systems (cleaning/maintenance) with duplicate code, duplicate tables, duplicate RPCs — hard to maintain
2. No activity tracking for admin/office work — employees show 0% utilization
3. No mandatory project/activity selection at clock-in — shifts start without context
4. Employees doing ménage on non-studio locations (apartments after renovation) can only track via the entretien flow, which miscategorizes the work

## Solution

Unify into a single `work_sessions` table with `activity_type` field. Add mandatory activity type selection at clock-in. Simplify mobile UI from tabbed to single view.

## Activity Types

| Type | Code | Color | Location selection | Description |
|------|------|-------|-------------------|-------------|
| Ménage | `cleaning` | Green (#4CAF50) | QR scan OR building/apartment picker | Nettoyage — studios, aires communes, appartements |
| Entretien | `maintenance` | Orange (#FF9800) | Building/apartment picker | Maintenance, réparations, rénovations |
| Administration | `admin` | Blue (#2196F3) | None (shift starts immediately) | Bureau, gestion, planification |

Future: `ticket` type for maintenance tickets (employees clock-in on a ticket).

## Data Model

### New table: `work_sessions`

```sql
CREATE TABLE work_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
  shift_id UUID NOT NULL REFERENCES shifts(id),
  activity_type TEXT NOT NULL CHECK (activity_type IN ('cleaning','maintenance','admin')),
  location_type TEXT CHECK (location_type IN ('studio','apartment','office')),
  studio_id UUID REFERENCES studios(id) ON DELETE CASCADE,
  apartment_id UUID REFERENCES apartments(id),
  building_id UUID REFERENCES property_buildings(id),
  status TEXT NOT NULL DEFAULT 'in_progress',
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  duration_minutes NUMERIC,
  notes TEXT,
  is_flagged BOOLEAN DEFAULT false,
  flag_reason TEXT,
  sync_status TEXT DEFAULT 'synced',
  start_latitude DOUBLE PRECISION,
  start_longitude DOUBLE PRECISION,
  start_accuracy DOUBLE PRECISION,
  end_latitude DOUBLE PRECISION,
  end_longitude DOUBLE PRECISION,
  end_accuracy DOUBLE PRECISION,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
```

- `activity_type` = what the employee is DOING (cleaning vs maintenance vs admin)
- `location_type` = WHERE they are doing it (studio, apartment, office)
- `studio_id` and `apartment_id` are mutually exclusive — one filled depending on location selection method
- For admin: no location, `location_type = 'office'`, no studio/apartment_id

### Shift table changes

Add/update `shift_type` to store the activity type chosen at clock-in. This becomes the primary activity type of the shift. Changeable via "Changer d'activité" button.

### Tables dropped (Phase 3)

- `cleaning_sessions` — data migrated to `work_sessions` with `activity_type='cleaning'`
- `maintenance_sessions` — data migrated to `work_sessions` with `activity_type='maintenance'`

## Mobile UX

### Clock-in flow (new)

```
Tap "DÉBUTER UN QUART"
  → GPS validation (unchanged)
  → Activity Type Picker (full screen)
      ├── 🧹 Ménage → Location picker: "Scanner QR" or "Choisir bâtiment/appart"
      ├── 🔧 Entretien → Building/apartment picker
      └── 💼 Administration → Shift starts immediately (no location)
  → clockIn() + first WorkSession created
```

Shift does NOT start until activity type + location (if applicable) are selected.

### Active shift screen (redesigned)

- **No more tabs** — single unified view colored by activity type
- Shift header: shows activity type badge + timer + GPS point count
- Active session card: location label + live timer + complete button
- Session history: all completed sessions listed below
- Bottom buttons:
  - "TERMINER LE QUART" (red, prominent)
  - "Pause dîner" (left)
  - "Changer d'activité" (right, small/discrete) — closes current session, reopens type picker, stays in same shift

### Session interactions by type

| Action | Ménage (QR) | Ménage (appart) | Entretien | Admin |
|--------|-------------|-----------------|-----------|-------|
| Start session | QR scan | Building picker | Building picker | Auto (1 session = whole shift) |
| End session | QR scan or manual | "Terminer" button | "Terminer" button | Clock-out ends it |
| New session | QR scan (auto-closes previous) | FAB → picker | FAB → picker | N/A |
| Location label | "Studio 823 — Le Convivial" | "286-A Dallaire — Appart." | "154-3 Charlebois — Unité 3" | "Bureau" |

## Database Dependencies to Migrate

### 19 RPC functions → ~10 unified

| Old function(s) | New function | Notes |
|----------------|-------------|-------|
| `scan_in` (2 overloads) | `start_work_session` | Handles all types, QR lookup for cleaning |
| `scan_out` (2 overloads) | `complete_work_session` | Unified completion |
| `start_maintenance` | `start_work_session` | Same function handles all types |
| `complete_maintenance` | `complete_work_session` | Same function |
| `auto_close_shift_sessions` + `auto_close_maintenance_sessions` | `auto_close_work_sessions` | Single UPDATE |
| `auto_close_sessions_on_shift_complete` | `auto_close_sessions_on_shift_complete` | Rewritten: 1 UPDATE instead of 2 |
| `get_active_session` | `get_active_work_session` | Single query |
| `manually_close_session` + `manual_close_cleaning_session` + `manually_close_maintenance_session` | `manually_close_work_session` | Single function |
| `get_cleaning_dashboard` | `get_work_sessions_dashboard` | Filterable by activity_type |
| `get_cleaning_stats_by_building` + `get_employee_cleaning_stats` | `get_work_session_stats` | Unified with groupBy parameter |
| `_get_project_sessions` | `_get_project_sessions` | Simplified: SELECT instead of UNION ALL |
| `get_team_active_status` + `get_monitored_team` | Rewritten | 1 LEFT JOIN instead of 2 |
| `compute_cluster_effective_types` | Rewritten | 1 JOIN instead of 2 |
| `server_close_all_sessions` | Rewritten | 1 UPDATE instead of 2 |

### Other database objects

- 14 RLS policies (7+7) → 7 on `work_sessions` (same pattern: own/admin/supervised)
- 2 triggers → 1 (`updated_at`)
- 10 indexes → ~7 consolidated + new index on `activity_type`
- 7 foreign keys → consolidated

## Flutter Architecture

### File structure

```
lib/features/
  work_sessions/              ← NEW (replaces cleaning/ + maintenance/)
    models/
      work_session.dart       ← unified model
      activity_type.dart      ← enum + display helpers
    services/
      work_session_service.dart
      work_session_local_db.dart
      studio_cache_service.dart       ← kept from cleaning
      property_cache_service.dart     ← kept from maintenance
    providers/
      work_session_provider.dart      ← single provider
    widgets/
      active_work_session_card.dart   ← unified (color by type)
      work_session_history_list.dart  ← unified
      activity_type_picker.dart       ← NEW (clock-in screen)
    screens/
      qr_scanner_screen.dart          ← moved from cleaning
```

### Provider

```dart
workSessionProvider (StateNotifier)
  state: WorkSessionState { activeSession, isLoading, error }
  methods: startSession(), scanIn(), scanOut(), completeSession(),
           manualClose(), changeActivityType(), syncPending()

Derived:
  activeWorkSessionProvider → WorkSession?
  hasActiveWorkSessionProvider → bool
  shiftWorkSessionsProvider(shiftId) → List<WorkSession>
```

### Local SQLite migration

On app update, `WorkSessionLocalDb.ensureTables()`:
1. Creates `local_work_sessions` table
2. Migrates data from `local_cleaning_sessions` (if exists) with `activity_type='cleaning'`
3. Migrates data from `local_maintenance_sessions` (if exists) with `activity_type='maintenance'`
4. Drops old tables

## Dashboard Changes

### Page: `/dashboard/work-sessions` (replaces `/dashboard/cleaning`)

- Filter tabs: All / 🧹 Ménage / 🔧 Entretien / 💼 Admin (with live counts)
- Stats cards: Sessions today, Total hours, Utilization rate, Flagged sessions
- View toggle: By session / By employee / By building
- Table with color-coded type badges (green/orange/blue), consistent with mobile
- Supervisor can manually close active sessions
- Flagged sessions highlighted in red

### Monitoring (team-list.tsx)

Reads `activity_type` from `work_sessions` directly. Badge shows type icon + location.

### Approvals (`_get_project_sessions`)

Simplified from UNION ALL to single SELECT. Activity type badge added to approval detail view.

### Navigation

Sidebar: "Ménages" → "Sessions de travail"

## Deployment Strategy

### Phase 1 — Preparation (no breaking changes)

1. Create `work_sessions` table + indexes + RLS + trigger
2. Migrate historical data from both old tables
3. Create new RPCs (start_work_session, complete_work_session, etc.)
4. Keep old RPCs functional (old app versions still work)
5. Add bidirectional sync triggers: writes to old tables copy to work_sessions and vice versa
6. Deploy updated dashboard (reads from work_sessions)

### Phase 2 — Deploy Flutter app

1. Push new app using WorkSessionService + new RPCs
2. New app writes to work_sessions directly
3. Old phones not yet updated continue writing to old tables → trigger syncs to work_sessions
4. Force update via existing version check (minimum version)

### Phase 3 — Cleanup (all phones updated)

1. Verify no phones use old RPCs (via logs)
2. Remove sync triggers
3. DROP old tables and old RPCs
4. Clean migration

### Rollback plan

- Phase 2 issues: old RPCs still work, revert Flutter app to previous version
- Phase 1 issues: drop work_sessions table, no impact on existing system
- Bidirectional sync triggers keep both systems consistent during transition

## Success Criteria

1. All employees must select an activity type before shift starts
2. Single unified view on mobile (no more tabs)
3. Utilization rate visible for ALL employees (including admin)
4. Ménage on apartments shows as "cleaning" type (not maintenance)
5. Zero data loss during migration
6. Dashboard shows all session types with color-coded badges
7. No downtime during rollout (phased deployment)
