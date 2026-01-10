# Implementation Plan: Employee & Shift Dashboard

**Branch**: `008-employee-shift-dashboard` | **Date**: 2026-01-10 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/008-employee-shift-dashboard/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command. See `.specify/templates/commands/plan.md` for the execution workflow.

## Summary

This feature implements personalized dashboards for employees and managers in the GPS Tracker app. Employees see their current shift status with a live timer, today's/monthly statistics, and recent shift history. Managers get a team dashboard showing all supervised employees with current status, search/filter capabilities, and aggregate team statistics with date range filtering. The feature integrates with existing shift management, offline sync infrastructure, and supervision relationships.

## Technical Context

**Language/Version**: Dart >=3.0.0 <4.0.0 / Flutter >=3.0.0
**Primary Dependencies**: flutter_riverpod 2.5.0 (state), supabase_flutter 2.12.0 (backend), fl_chart (bar charts for team statistics)
**Storage**: PostgreSQL via Supabase (existing: employee_profiles, shifts, gps_points, employee_supervisors); SQLCipher local storage (7-day cache)
**Testing**: flutter_test, integration_test
**Target Platform**: iOS 14.0+ / Android API 24+ (cross-platform Flutter)
**Project Type**: mobile
**Performance Goals**: Dashboard loads <2s, live timer 1-second updates, navigation <1s
**Constraints**: Offline-capable with 7-day cache, battery-conscious
**Scale/Scope**: Individual + team dashboards (up to ~100 supervised employees per manager)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Evidence |
|-----------|--------|----------|
| I. Mobile-First Flutter | PASS | Uses existing Flutter codebase, Material Design widgets, cross-platform from single codebase |
| II. Battery-Conscious Design | PASS | Live timer is UI-only (no GPS), uses existing GPS infrastructure, no new background operations |
| III. Privacy & Compliance | PASS | Dashboard displays only employee's own data or data from authorized supervision relationships; uses existing RLS policies |
| IV. Offline-First Architecture | PASS | Caches 7-day shift window locally, displays cached data with "last updated" timestamp when offline |
| V. Simplicity & Maintainability | PASS | Extends existing patterns (Riverpod providers, existing services), minimal new dependencies (only fl_chart for visualization) |

**Pre-Design Gate**: PASSED - No violations detected.

## Project Structure

### Documentation (this feature)

```text
specs/008-employee-shift-dashboard/
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output (/speckit.plan command)
├── data-model.md        # Phase 1 output (/speckit.plan command)
├── quickstart.md        # Phase 1 output (/speckit.plan command)
├── contracts/           # Phase 1 output (/speckit.plan command)
└── tasks.md             # Phase 2 output (/speckit.tasks command - NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
gps_tracker/
├── lib/
│   ├── features/
│   │   ├── dashboard/                    # NEW: Dashboard feature module
│   │   │   ├── dashboard.dart            # Barrel export
│   │   │   ├── models/
│   │   │   │   ├── dashboard_state.dart        # Employee dashboard state
│   │   │   │   ├── team_dashboard_state.dart   # Manager team dashboard state
│   │   │   │   └── employee_work_status.dart   # Active shift status for team list
│   │   │   ├── providers/
│   │   │   │   ├── dashboard_provider.dart     # Employee dashboard state
│   │   │   │   ├── team_dashboard_provider.dart # Manager team dashboard state
│   │   │   │   └── team_statistics_provider.dart # Team aggregate statistics
│   │   │   ├── services/
│   │   │   │   ├── dashboard_service.dart      # Dashboard data fetching
│   │   │   │   └── dashboard_cache_service.dart # Local cache management
│   │   │   ├── screens/
│   │   │   │   ├── employee_dashboard_screen.dart # Personal dashboard UI
│   │   │   │   ├── team_dashboard_screen.dart     # Manager team overview
│   │   │   │   └── team_statistics_screen.dart    # Team aggregate stats
│   │   │   └── widgets/
│   │   │       ├── shift_status_tile.dart      # Current shift status display
│   │   │       ├── live_shift_timer.dart       # 1-second updating timer
│   │   │       ├── daily_summary_card.dart     # Today's hours summary
│   │   │       ├── monthly_summary_card.dart   # Month's statistics
│   │   │       ├── recent_shifts_list.dart     # Last 7 days shifts
│   │   │       ├── sync_status_badge.dart      # Pending/synced/error indicator
│   │   │       ├── team_employee_tile.dart     # Employee row in team list
│   │   │       ├── team_search_bar.dart        # Search/filter for team
│   │   │       ├── date_range_picker.dart      # Statistics date filter
│   │   │       └── team_hours_chart.dart       # Bar chart per employee
│   │   ├── home/
│   │   │   └── home_screen.dart           # MODIFY: Route to dashboard
│   │   ├── shifts/                         # REUSE: Existing shift models/providers
│   │   └── history/                        # REUSE: Existing statistics models
│   └── shared/
│       └── services/
│           └── local_database.dart        # EXTEND: Dashboard cache tables
└── test/
    ├── features/
    │   └── dashboard/                     # Unit tests for dashboard
    └── integration_test/
        └── dashboard_flow_test.dart       # Integration tests
```

**Structure Decision**: Feature-based modular structure under `lib/features/dashboard/` following existing patterns. Reuses models and providers from `shifts/` and `history/` modules.

## Post-Design Constitution Check

*Re-evaluated after Phase 1 design completion.*

| Principle | Status | Post-Design Evidence |
|-----------|--------|---------------------|
| I. Mobile-First Flutter | PASS | All new widgets use Material Design; fl_chart is cross-platform; no platform-specific code required |
| II. Battery-Conscious Design | PASS | Live timer uses timestamp-based calculation (O(1)); no GPS polling added; 1-second UI updates only when screen visible |
| III. Privacy & Compliance | PASS | New RPC functions use existing SECURITY DEFINER pattern; RLS policies already cover supervision relationships; no new data collection |
| IV. Offline-First Architecture | PASS | Dashboard cache table with 7-day TTL; displays cached data with "last updated"; graceful degradation on offline |
| V. Simplicity & Maintainability | PASS | Reuses existing models (Shift, HistoryStatistics, TeamStatistics); extends proven StateNotifier pattern; only 1 new dependency (fl_chart) |

**Post-Design Gate**: PASSED - No new violations introduced.

## Complexity Tracking

> No Constitution violations detected. Table not applicable.
