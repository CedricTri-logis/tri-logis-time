# Implementation Plan: Diagnostic Logging

**Branch**: `019-diagnostic-logging` | **Date**: 2026-02-24 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/019-diagnostic-logging/spec.md`

## Summary

Replace all 36+ scattered `debugPrint` calls across the Flutter app with a centralized `DiagnosticLogger` service that persists structured events locally (SQLCipher) and syncs them to a new Supabase `diagnostic_logs` table. This gives administrators remote visibility into GPS tracking failures, shift lifecycle issues, sync problems, and device-level diagnostics — information that is currently invisible in production because it only exists in the device console.

**Technical approach**: New `DiagnosticLogger` singleton → local `diagnostic_events` SQLCipher table → batch sync via `sync_diagnostic_logs` RPC (migration 036) → piggybacks on existing `SyncService.syncAll()` cycle as lowest-priority step.

## Technical Context

**Language/Version**: Dart >=3.0.0 / Flutter >=3.29.0 (mobile app only — no dashboard changes)
**Primary Dependencies**: supabase_flutter 2.12.0, sqflite_sqlcipher 3.1.0, flutter_riverpod 2.5.0, package_info_plus, device_info_plus, flutter_secure_storage (all existing — no new dependencies)
**Storage**: SQLCipher local (`diagnostic_events` table) + Supabase PostgreSQL (`diagnostic_logs` table, migration 036)
**Testing**: `flutter test` (unit tests for DiagnosticLogger, sync service)
**Target Platform**: iOS 14.0+ / Android API 24+
**Project Type**: Mobile (Flutter)
**Performance Goals**: Zero battery impact (async fire-and-forget inserts, no new timers); <2s added to sync cycle
**Constraints**: Offline-capable (local-first with server sync); <2MB local storage (5000 events max)
**Scale/Scope**: ~50 events/hour during active shift; ~200 events per sync batch; 90-day server retention

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Mobile App: Flutter Cross-Platform | PASS | Pure Flutter/Dart implementation, no platform-specific code changes |
| II. Desktop Dashboard: TypeScript Web Stack | N/A | No dashboard changes in this feature |
| III. Battery-Conscious Design | PASS | Async fire-and-forget inserts; no new timers/wake-ups; sync piggybacks on existing cycle |
| IV. Privacy & Compliance | PASS | Logs contain device telemetry, not personal data; same encryption (SQLCipher) and RLS as existing data; admin-only server access |
| V. Offline-First Architecture | PASS | Local-first storage with batch sync; events persist across restarts |
| VI. Simplicity & Maintainability | PASS | Single new service (DiagnosticLogger) + one migration; replaces scattered debugPrints with structured logging; no new dependencies |

**Post-Phase 1 Re-check**: All gates still PASS. No new dependencies, no new background tasks, no battery impact.

## Project Structure

### Documentation (this feature)

```text
specs/019-diagnostic-logging/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 research findings
├── data-model.md        # Entity schemas and event catalog
├── quickstart.md        # Developer setup guide
├── contracts/
│   └── sync_diagnostic_logs.md  # RPC contract
└── tasks.md             # Phase 2 output (via /speckit.tasks)
```

### Source Code (repository root)

```text
supabase/
└── migrations/
    └── 036_diagnostic_logs.sql          # NEW: Table + RPC + pg_cron retention

gps_tracker/lib/
├── shared/
│   └── services/
│       ├── local_database.dart          # MODIFY: Add diagnostic_events table (schema v4)
│       └── diagnostic_logger.dart       # NEW: Central logging service
├── features/
│   ├── tracking/
│   │   ├── providers/
│   │   │   └── tracking_provider.dart   # MODIFY: Replace 17+ debugPrints
│   │   └── services/
│   │       ├── background_tracking_service.dart   # MODIFY: Replace 2 debugPrints
│   │       ├── gps_tracking_handler.dart          # MODIFY: Add diagnostic messages
│   │       ├── significant_location_service.dart  # MODIFY: Replace 3 debugPrints
│   │       ├── background_execution_service.dart  # MODIFY: Replace 6 debugPrints
│   │       └── thermal_state_service.dart         # MODIFY: Replace 2 debugPrints
│   ├── shifts/
│   │   ├── services/
│   │   │   ├── sync_service.dart                  # MODIFY: Replace 6 debugPrints + add diagnostic sync step
│   │   │   └── diagnostic_sync_service.dart       # NEW: Server sync for diagnostic events
│   │   └── providers/
│   │       └── shift_provider.dart                # MODIFY: Replace 1 debugPrint
│   ├── auth/
│   │   └── providers/
│   │       └── device_session_provider.dart       # MODIFY: Add force_logout event
│   └── mileage/
│       └── services/
│           └── trip_service.dart                   # MODIFY: Replace 6 debugPrints
├── main.dart                                       # MODIFY: Add app_started event
└── shared/services/
    └── realtime_service.dart                       # MODIFY: Replace 4 debugPrints

gps_tracker/test/
└── shared/services/
    └── diagnostic_logger_test.dart      # NEW: Unit tests
```

**Structure Decision**: Pure modification of existing mobile app structure. Two new files (`diagnostic_logger.dart`, `diagnostic_sync_service.dart`) follow the established service pattern. One new migration. No new directories needed.

## Complexity Tracking

No constitutional violations. No complexity justification needed.

---

## Implementation Summary

### New Files (3)
1. **`supabase/migrations/036_diagnostic_logs.sql`** — Server table, RPC, indexes, RLS, pg_cron retention
2. **`gps_tracker/lib/shared/services/diagnostic_logger.dart`** — Central logger service (singleton, async inserts, debug-mode console output)
3. **`gps_tracker/lib/features/shifts/services/diagnostic_sync_service.dart`** — Batch sync of diagnostic events to server via RPC

### Modified Files (14)
1. **`local_database.dart`** — Add `diagnostic_events` table (schema v4 migration), insert/query/prune methods
2. **`tracking_provider.dart`** — Replace 17+ debugPrints with DiagnosticLogger calls
3. **`background_tracking_service.dart`** — Replace 2 debugPrints
4. **`gps_tracking_handler.dart`** — Add `diagnostic` message type to background→main channel
5. **`significant_location_service.dart`** — Replace 3 debugPrints
6. **`background_execution_service.dart`** — Replace 6 debugPrints
7. **`thermal_state_service.dart`** — Replace 2 debugPrints
8. **`sync_service.dart`** — Replace 6 debugPrints + add diagnostic sync as step 5 in syncAll()
9. **`shift_provider.dart`** — Replace 1 debugPrint + add clock-in/out events
10. **`device_session_provider.dart`** — Add force_logout critical event
11. **`trip_service.dart`** — Replace 6 debugPrints
12. **`realtime_service.dart`** — Replace 4 debugPrints
13. **`main.dart`** — Add app_started/app_startup_failed events
14. **`version_check_service.dart`** — Replace 1 debugPrint

### Key Design Decisions
- **No new dependencies**: Everything built on existing packages
- **Background isolate**: Logs sent via existing `sendDataToMain()` channel as `{type: 'diagnostic', ...}` messages
- **Sync priority**: Diagnostic logs sync AFTER GPS points (step 5 in syncAll) — never delays critical data
- **Debug filtering**: `debug` severity = local only, never synced (saves ~60% bandwidth)
- **Deduplication**: Client UUID per event; server catches unique_violation gracefully
- **Retention**: 5000 events local (auto-prune), 90 days server (pg_cron)
