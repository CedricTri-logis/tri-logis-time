# Implementation Plan: Employee History

**Branch**: `006-employee-history` | **Date**: 2026-01-10 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/006-employee-history/spec.md`

## Summary

Enable managers to view, filter, search, and export shift history for employees under their supervision. Employees can also view their own enhanced history. The feature requires adding a role-based permission system (`role` field in `employee_profiles`), a supervision relationship table (`employee_supervisors`), and building a new history feature module with map integration, statistics, and PDF/CSV export capabilities.

## Technical Context

**Language/Version**: Dart 3.x / Flutter 3.x (>=3.0.0)
**Primary Dependencies**: flutter_riverpod 2.5.0 (state), supabase_flutter 2.12.0 (backend), google_maps_flutter (map display), pdf (client-side PDF generation), csv (CSV export)
**Storage**: PostgreSQL via Supabase (existing: employee_profiles, shifts, gps_points; new: employee_supervisors), SQLCipher local storage (existing)
**Testing**: flutter_test for unit/widget tests, integration_test for e2e
**Target Platform**: iOS 14.0+, Android API 24+ (matching existing requirements)
**Project Type**: Mobile application (Flutter)
**Performance Goals**: <3s shift history load, <2s filter updates, <10s CSV export (1000 shifts), <15s PDF export (100 shifts), map render with 100+ points <3s
**Constraints**: Offline-first (read-only for history), timezone-aware display (store UTC, display local), RLS for manager-employee data access
**Scale/Scope**: Manager views up to 50 supervised employees, employee history up to years of data, 4 new screens (employee list, history, detail, statistics)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Mobile-First Flutter | ✅ PASS | All UI in Flutter, cross-platform, using Material/Cupertino widgets |
| II. Battery-Conscious Design | ✅ PASS | No background operations; history is read-only viewing |
| III. Privacy & Compliance | ✅ PASS | Managers can only view supervised employees; RLS enforced; data already consented for work tracking |
| IV. Offline-First Architecture | ✅ PASS | History viewing works offline from local cache; export may require sync indicator |
| V. Simplicity & Maintainability | ✅ PASS | Directly serves core use case (oversight/verification of GPS tracking); minimal new dependencies |
| Backend: RLS Required | ✅ PASS | New RLS policies for manager access to supervised employee data |

**Gate Result**: PASS - All constitutional principles satisfied

## Project Structure

### Documentation (this feature)

```text
specs/006-employee-history/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output (API contracts)
└── tasks.md             # Phase 2 output (/speckit.tasks command)
```

### Source Code (repository root)

```text
gps_tracker/                           # Flutter project root
├── lib/
│   ├── features/
│   │   └── history/                   # NEW: Employee History feature
│   │       ├── models/
│   │       │   ├── employee_summary.dart
│   │       │   ├── shift_history_filter.dart
│   │       │   ├── history_statistics.dart
│   │       │   └── supervision_record.dart
│   │       ├── providers/
│   │       │   ├── supervised_employees_provider.dart
│   │       │   ├── employee_history_provider.dart
│   │       │   ├── history_filter_provider.dart
│   │       │   └── history_statistics_provider.dart
│   │       ├── screens/
│   │       │   ├── supervised_employees_screen.dart
│   │       │   ├── employee_history_screen.dart
│   │       │   ├── shift_detail_screen.dart
│   │       │   └── statistics_screen.dart
│   │       ├── services/
│   │       │   ├── history_service.dart
│   │       │   ├── export_service.dart
│   │       │   └── statistics_service.dart
│   │       ├── widgets/
│   │       │   ├── employee_list_tile.dart
│   │       │   ├── history_filter_bar.dart
│   │       │   ├── shift_history_card.dart
│   │       │   ├── statistics_card.dart
│   │       │   ├── gps_route_map.dart
│   │       │   └── export_dialog.dart
│   │       └── history.dart           # Feature barrel export
│   ├── features/auth/
│   │   └── models/
│   │       └── employee_profile.dart  # MODIFY: Add role field
│   └── shared/
│       └── models/
│           └── user_role.dart         # NEW: Role enum
├── test/
│   └── features/
│       └── history/                   # Unit and widget tests
└── integration_test/
    └── history_test.dart              # Integration tests

supabase/
└── migrations/
    └── 006_employee_history.sql       # NEW: Role field, employee_supervisors table, RLS policies
```

**Structure Decision**: Following established feature-based folder structure in `lib/features/`. New `history` feature module with models, providers, screens, services, and widgets subdirectories. Database changes via Supabase migration.

## Constitution Check (Post-Design Re-evaluation)

*Re-evaluated after Phase 1 design completion.*

| Principle | Status | Design Verification |
|-----------|--------|---------------------|
| I. Mobile-First Flutter | ✅ PASS | All 4 screens use Flutter widgets; `google_maps_flutter` is cross-platform; no platform-specific code required |
| II. Battery-Conscious Design | ✅ PASS | Feature is read-only history viewing with no background operations; map renders only when screen is active |
| III. Privacy & Compliance | ✅ PASS | RLS policies in `contracts/supabase-api.md` restrict managers to supervised employees only; all access controlled via `employee_supervisors` table |
| IV. Offline-First Architecture | ✅ PASS | Design includes offline reading from local cache; export works with cached data; clear sync status indicators |
| V. Simplicity & Maintainability | ✅ PASS | 5 new dependencies (all well-maintained); follows existing feature structure; no complex abstractions |
| Backend: RLS Required | ✅ PASS | All 4 RPC functions implement access checks; existing RLS policies updated for manager access |

**Post-Design Gate Result**: PASS - All constitutional principles verified in design artifacts

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

No violations - all constitutional principles satisfied.
