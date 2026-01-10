# Implementation Plan: Offline Resilience

**Branch**: `005-offline-resilience` | **Date**: 2026-01-10 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/005-offline-resilience/spec.md`

## Summary

This feature enhances the GPS Tracker app with comprehensive offline resilience capabilities. The primary goal is to ensure seamless operation regardless of network connectivity, with automatic data synchronization when connectivity returns. Building on the existing local-first architecture (SQLCipher encrypted storage, connectivity detection, batch sync), this implementation adds exponential backoff retry logic, storage capacity monitoring with warnings, structured sync logging, sync progress UI, conflict resolution, and persistent sync status across app restarts.

## Technical Context

**Language/Version**: Dart 3.x / Flutter 3.x (>=3.0.0)
**Primary Dependencies**: flutter_riverpod 2.5.0 (state), supabase_flutter 2.12.0 (backend), sqflite_sqlcipher 3.1.0 (local encrypted storage), connectivity_plus 6.0.0 (network status)
**Storage**: SQLCipher-encrypted SQLite (local_shifts, local_gps_points tables exist); PostgreSQL via Supabase (shifts, gps_points tables)
**Testing**: flutter test, integration_test/ directory
**Target Platform**: iOS 14.0+, Android API 24+
**Project Type**: Mobile (Flutter cross-platform)
**Performance Goals**: Clock in/out within 3 seconds; sync begins within 30 seconds of connectivity; batch sync ≤60 seconds per 100 GPS points
**Constraints**: Offline-capable for 7+ days; <1MB storage for 7-day offline operation; exponential backoff max 15 minutes
**Scale/Scope**: Single user focus; ~1000+ GPS points may accumulate during extended offline

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Evidence |
|-----------|--------|----------|
| **I. Mobile-First Flutter** | ✅ PASS | All implementation uses Flutter; no platform-specific code beyond existing platform channels |
| **II. Battery-Conscious Design** | ✅ PASS | Sync uses exponential backoff to reduce battery drain; no additional GPS polling (uses existing intervals) |
| **III. Privacy & Compliance** | ✅ PASS | No new location collection; sync only operates on already-collected shift data; encrypted storage maintained |
| **IV. Offline-First Architecture** | ✅ PASS | Core feature directly implements this principle (local-first, sync on reconnect, conflict resolution) |
| **V. Simplicity & Maintainability** | ✅ PASS | Extends existing services; no new frameworks; clear separation of concerns |
| **Platform Requirements** | ✅ PASS | iOS 14.0+ and Android API 24+ compatible; uses existing foreground service infrastructure |
| **Backend Requirements** | ✅ PASS | Uses Supabase REST/PostgREST batch upsert; RLS policies already in place |

**Gate Status**: ✅ PASSED - No violations. Proceed to Phase 0.

## Project Structure

### Documentation (this feature)

```text
specs/005-offline-resilience/
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
│   ├── main.dart                                    # App initialization (existing)
│   ├── features/
│   │   ├── shifts/
│   │   │   ├── models/
│   │   │   │   ├── local_shift.dart                # Existing - add sync metadata fields
│   │   │   │   ├── local_gps_point.dart            # Existing - no changes needed
│   │   │   │   └── sync_status.dart                # NEW - Sync status model for persistence
│   │   │   ├── providers/
│   │   │   │   ├── sync_provider.dart              # Existing - enhance with persistence, progress
│   │   │   │   └── connectivity_provider.dart      # Existing - no changes needed
│   │   │   ├── services/
│   │   │   │   ├── sync_service.dart               # Existing - add backoff, resumable sync
│   │   │   │   ├── shift_service.dart              # Existing - minor updates for sync status
│   │   │   │   └── sync_logger.dart                # NEW - Structured sync logging
│   │   │   └── widgets/
│   │   │       ├── sync_status_indicator.dart      # Existing - enhance with progress
│   │   │       └── sync_detail_sheet.dart          # NEW - Detailed sync status view
│   │   └── tracking/
│   │       └── ...                                  # No changes needed
│   └── shared/
│       └── services/
│           └── local_database.dart                 # Existing - add sync metadata tables
├── test/
│   └── features/shifts/
│       ├── services/
│       │   ├── sync_service_test.dart              # NEW - Backoff, batch, retry tests
│       │   └── sync_logger_test.dart               # NEW - Logging tests
│       └── providers/
│           └── sync_provider_test.dart             # NEW - State persistence tests
└── integration_test/
    └── offline_sync_test.dart                      # NEW - End-to-end offline scenarios
```

**Structure Decision**: Mobile (Flutter) single-project structure. Extends existing feature modules (`shifts`, `tracking`) rather than creating new top-level features. New files are added within existing service/model/widget directories to maintain consistency.

## Constitution Re-Check (Post-Phase 1 Design)

| Principle | Status | Post-Design Evidence |
|-----------|--------|----------------------|
| **I. Mobile-First Flutter** | ✅ PASS | All new code is Dart/Flutter; 4 new database tables, 3 new services, 2 new widgets - all Flutter |
| **II. Battery-Conscious Design** | ✅ PASS | Exponential backoff (30s→15min) reduces retry frequency; no new background operations |
| **III. Privacy & Compliance** | ✅ PASS | Sync logging stores only operation metadata, not location data; quarantine preserves data integrity |
| **IV. Offline-First Architecture** | ✅ PASS | Sync metadata persistence ensures state survives restart; 7-day capacity validated (~302KB) |
| **V. Simplicity & Maintainability** | ✅ PASS | No new dependencies; extends existing patterns; well-separated concerns |
| **Platform Requirements** | ✅ PASS | SQLCipher works on both platforms; UI components use standard Flutter widgets |
| **Backend Requirements** | ✅ PASS | Uses existing Supabase RPC endpoints; no backend changes required |

**Post-Design Gate Status**: ✅ PASSED - Design aligns with constitution principles.

## Complexity Tracking

> No constitution violations requiring justification. Implementation extends existing patterns.
