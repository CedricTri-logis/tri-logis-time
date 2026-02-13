# Implementation Plan: Cleaning Session Tracking via QR Code

**Branch**: `016-cleaning-qr-tracking` | **Date**: 2026-02-12 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/016-cleaning-qr-tracking/spec.md`

## Summary

Track housekeeping of short-term rental properties using QR code scanning. Cleaning employees scan a QR code when entering a room (start session) and scan again when leaving (end session). The system records session duration, links it to the employee's shift, and provides a supervisor dashboard for monitoring cleaning activity across 10 buildings and ~115 studios.

**Technical approach**:
- Supabase migration for `buildings`, `studios`, `cleaning_sessions` tables with seed data
- Flutter `mobile_scanner` package for QR code scanning with offline-first local storage
- Hook into existing shift clock-out to auto-close orphaned sessions
- Next.js dashboard page with cleaning activity overview and per-building/per-employee analytics

## Technical Context

**Language/Version**: Dart >=3.0.0 / Flutter >=3.29.0 (mobile), TypeScript 5.x / Node.js 18.x LTS (dashboard)
**Primary Dependencies**: flutter_riverpod 2.5.0, supabase_flutter 2.12.0, mobile_scanner 7.1.4 (NEW), sqflite_sqlcipher 3.1.0 (mobile); Next.js 14+, Refine, shadcn/ui, Zod (dashboard)
**Storage**: PostgreSQL via Supabase (buildings, studios, cleaning_sessions tables); SQLCipher local encrypted storage (local_studios, local_cleaning_sessions)
**Testing**: flutter test (mobile), Playwright (dashboard E2E)
**Target Platform**: iOS 14+, Android API 24+ (mobile); Chrome/Safari/Firefox (dashboard)
**Project Type**: Mobile + Web dashboard (existing monorepo)
**Performance Goals**: QR scan to session start in < 10 seconds; dashboard loads in < 3 seconds
**Constraints**: Offline-capable (local-first), encrypted local storage, camera required for QR scanning
**Scale/Scope**: 10 buildings, ~115 studios, ~50 employees, ~500 cleaning sessions/day

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Mobile App: Flutter Cross-Platform | PASS | Using Flutter with mobile_scanner (iOS + Android) |
| II. Desktop Dashboard: TypeScript Web Stack | PASS | Using Next.js 14+, shadcn/ui, Refine, Zod |
| III. Battery-Conscious Design | PASS | QR scanning is on-demand only (camera not running in background) |
| IV. Privacy & Compliance | PASS | Cleaning sessions only during active shifts; RLS enforced |
| V. Offline-First Architecture | PASS | Local-first with SQLCipher; sync when online |
| VI. Simplicity & Maintainability | PASS | Follows existing patterns (ShiftService → CleaningSessionService) |

**Post-Phase 1 Re-check**: All gates still pass. New dependency (mobile_scanner) is well-maintained and compatible with both platforms.

## Project Structure

### Documentation (this feature)

```text
specs/016-cleaning-qr-tracking/
├── spec.md              # Feature specification
├── plan.md              # This file
├── research.md          # Phase 0: Technology research
├── data-model.md        # Phase 1: Entity definitions and schema
├── quickstart.md        # Phase 1: Development setup guide
├── contracts/           # Phase 1: API and service contracts
│   ├── supabase-rpc.md  #   Supabase RPC function signatures
│   ├── flutter-services.md  # Flutter service contracts
│   └── dashboard-hooks.md   # Dashboard hook contracts
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── tasks.md             # Phase 2: Task list (via /speckit.tasks)
```

### Source Code (repository root)

```text
# Supabase (backend)
supabase/migrations/
└── 016_cleaning_qr_tracking.sql    # Schema + seed data + RPC functions

# Flutter (mobile app)
gps_tracker/lib/features/cleaning/
├── models/
│   ├── studio.dart                 # Studio model
│   ├── cleaning_session.dart       # CleaningSession model
│   └── scan_result.dart            # ScanResult model
├── providers/
│   ├── cleaning_session_provider.dart  # Riverpod state management
│   └── studio_cache_provider.dart      # Studio data cache
├── screens/
│   └── qr_scanner_screen.dart      # Camera QR scanner screen
├── services/
│   ├── cleaning_session_service.dart   # Business logic (local-first)
│   └── studio_cache_service.dart       # Studio data sync/lookup
└── widgets/
    ├── active_session_card.dart     # Current session display with timer
    ├── cleaning_history_list.dart   # Shift cleaning history
    ├── manual_entry_dialog.dart     # Fallback QR code text entry
    └── scan_result_dialog.dart      # Scan confirmation/error dialog

# Dashboard (web)
dashboard/src/
├── app/dashboard/cleaning/
│   └── page.tsx                    # Cleaning dashboard page
├── components/cleaning/
│   ├── cleaning-sessions-table.tsx # Session list with filters
│   ├── building-stats-cards.tsx    # Per-building summary cards
│   ├── cleaning-filters.tsx        # Date/building/employee filters
│   └── close-session-dialog.tsx    # Manual close confirmation
├── lib/hooks/
│   └── use-cleaning-sessions.ts    # Data fetching hooks
├── lib/validations/
│   └── cleaning.ts                 # Zod schemas
└── types/
    └── cleaning.ts                 # TypeScript types + transforms
```

**Structure Decision**: Extends the existing monorepo with a new `cleaning` feature module in Flutter (following the same pattern as `shifts`, `tracking`, `history`) and a new `cleaning` section in the dashboard (following the `locations` pattern from Spec 015).

## Complexity Tracking

> No constitution violations. All patterns follow existing conventions.
