# Implementation Plan: Shift Management

**Branch**: `003-shift-management` | **Date**: 2026-01-08 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/003-shift-management/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command. See `.specify/templates/commands/plan.md` for the execution workflow.

## Summary

Implement employee shift clock-in/clock-out functionality with GPS location capture, real-time shift status display, and offline support. This feature enables employees to start/stop work sessions while capturing location data, with all data syncing to Supabase when connectivity returns.

## Technical Context

**Language/Version**: Dart 3.x / Flutter 3.x (>=3.0.0)
**Primary Dependencies**: flutter_riverpod 2.5.0 (state), supabase_flutter 2.12.0 (backend), geolocator 12.0.0 (GPS), sqflite_sqlcipher 3.1.0 (local encrypted storage), connectivity_plus 6.0.0 (network status)
**Storage**: PostgreSQL via Supabase (shifts, gps_points tables exist), SQLCipher for encrypted local storage
**Testing**: flutter_test (unit/widget), integration_test (integration)
**Target Platform**: iOS 14.0+, Android API 24+ (Android 7.0+)
**Project Type**: Mobile application
**Performance Goals**: Clock-in/out actions complete within 5 seconds, elapsed time updates at 1Hz, history loads 50 shifts in <3 seconds
**Constraints**: Offline-capable for clock-in/out, sync within 30 seconds of connectivity, encrypted local storage
**Scale/Scope**: Single employee view, ~5 screens (dashboard, clock confirmation, history list, shift detail, settings)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Principle I: Mobile-First Flutter ✅
- [x] Using Flutter for cross-platform iOS/Android from single codebase
- [x] Using Material Design widgets (existing pattern in auth screens)
- [x] No platform-specific code required for this feature

### Principle II: Battery-Conscious Design ✅
- [x] GPS polling only during active shifts (Constitution compliance)
- [x] GPS stops when employee clocks out
- [x] Background tracking handled by flutter_foreground_task (already in dependencies)

### Principle III: Privacy & Compliance ✅
- [x] Location tracking only when clocked in (spec requirement)
- [x] Privacy consent required before clock-in (enforced by `clock_in()` DB function)
- [x] Data transmitted via Supabase HTTPS
- [x] No tracking outside work hours

### Principle IV: Offline-First Architecture ✅
- [x] Clock in/out must work offline with local storage (FR-009)
- [x] GPS data stored locally when offline, batch-uploaded when online
- [x] Sync status displayed to users (spec requirement)
- [x] Local storage encrypted via sqflite_sqlcipher

### Principle V: Simplicity & Maintainability ✅
- [x] Feature directly serves core use case (clock-in with GPS)
- [x] No feature creep - scoped to employee view only
- [x] Using established patterns from auth feature

**Pre-Design Gate Status**: PASSED

## Project Structure

### Documentation (this feature)

```text
specs/003-shift-management/
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
│   ├── main.dart
│   ├── app.dart
│   ├── core/
│   │   └── config/
│   ├── features/
│   │   ├── auth/                    # Existing - authentication
│   │   ├── home/                    # Existing - to be enhanced with shift status
│   │   └── shifts/                  # NEW - shift management feature
│   │       ├── models/
│   │       │   ├── shift.dart       # Shift data model
│   │       │   └── clock_event.dart # Clock event model
│   │       ├── providers/
│   │       │   ├── shift_provider.dart       # Active shift state
│   │       │   ├── shift_history_provider.dart # History state
│   │       │   └── sync_provider.dart        # Sync status
│   │       ├── screens/
│   │       │   ├── shift_dashboard_screen.dart # Main clock-in/out UI
│   │       │   ├── shift_history_screen.dart   # History list
│   │       │   └── shift_detail_screen.dart    # Individual shift view
│   │       ├── services/
│   │       │   ├── shift_service.dart    # Shift operations
│   │       │   ├── location_service.dart # GPS capture
│   │       │   └── sync_service.dart     # Offline sync
│   │       └── widgets/
│   │           ├── clock_button.dart     # Clock in/out button
│   │           ├── shift_timer.dart      # Elapsed time display
│   │           └── shift_card.dart       # Shift list item
│   └── shared/
│       ├── models/
│       ├── providers/
│       │   └── supabase_provider.dart   # Existing
│       ├── services/
│       │   └── local_database.dart      # NEW - SQLite operations
│       └── widgets/
├── test/
│   └── features/
│       └── shifts/                       # NEW - shift tests
└── integration_test/
    └── shifts_test.dart                  # NEW - shift integration tests

supabase/
└── migrations/
    └── 001_initial_schema.sql           # Existing - shifts & gps_points tables
```

**Structure Decision**: Using established Flutter feature-based structure. The `shifts` feature module follows the same pattern as the existing `auth` feature (models, providers, screens, services, widgets). Shared services like `local_database.dart` go in `shared/services/` since they're used by both shifts and future features.

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

*No violations - all Constitution principles satisfied.*

---

## Post-Design Constitution Re-Check

*Verified after Phase 1 design completion.*

### Principle I: Mobile-First Flutter ✅
- Design uses Flutter exclusively with Material Design patterns
- No platform channels required - geolocator abstracts location APIs
- All UI follows existing auth feature patterns

### Principle II: Battery-Conscious Design ✅
- GPS capture only at clock-in/out moments (high accuracy, 15s timeout)
- No continuous location streaming during shifts (per research decision)
- Timer uses device clock, not GPS polling
- Background service (flutter_foreground_task) available if periodic capture added later

### Principle III: Privacy & Compliance ✅
- `clock_in()` RPC enforces privacy consent check (existing DB function)
- Location data only captured at explicit user actions (clock-in/out)
- All data encrypted locally (sqflite_sqlcipher)
- HTTPS transport via Supabase client

### Principle IV: Offline-First Architecture ✅
- Local SQLite is source of truth (per research decision)
- All clock operations write locally first, sync later
- Sync status indicator in UI (per data model)
- Idempotency via request_id prevents duplicates on retry

### Principle V: Simplicity & Maintainability ✅
- Feature module follows existing `auth` pattern exactly
- No new dependencies required (all in pubspec.yaml)
- No premature abstractions - direct service calls
- ~13 new files organized in clear structure

**Post-Design Gate Status**: PASSED

---

## Generated Artifacts

| Artifact | Path | Status |
|----------|------|--------|
| Research | `specs/003-shift-management/research.md` | Complete |
| Data Model | `specs/003-shift-management/data-model.md` | Complete |
| Supabase Contracts | `specs/003-shift-management/contracts/supabase-rpc.md` | Complete |
| Local DB Contracts | `specs/003-shift-management/contracts/local-database.md` | Complete |
| Quickstart | `specs/003-shift-management/quickstart.md` | Complete |

## Next Steps

Run `/speckit.tasks` to generate the implementation task list.
