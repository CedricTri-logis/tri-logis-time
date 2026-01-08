# Implementation Plan: Project Foundation

**Branch**: `001-project-foundation` | **Date**: 2026-01-08 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-project-foundation/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command. See `.specify/templates/commands/plan.md` for the execution workflow.

## Summary

Infrastructure and scaffolding setup for GPS Clock-In Tracker mobile application. This establishes the Flutter project structure, Supabase backend schema with RLS policies, and platform-specific configurations for iOS/Android location permissions. Technical approach uses Flutter 3.x with Riverpod for state management, Supabase for backend, and platform-specific foreground services for background location tracking.

## Technical Context

**Language/Version**: Dart 3.x / Flutter 3.x (latest stable)
**Primary Dependencies**: flutter, supabase_flutter, flutter_riverpod, geolocator, sqflite (local storage)
**Storage**: Supabase PostgreSQL (remote), SQLite via sqflite (local offline cache)
**Testing**: flutter_test (unit), integration_test (integration), patrol (optional for E2E)
**Target Platform**: iOS 14.0+, Android 7.0+ (API 24)
**Project Type**: Mobile (Flutter cross-platform)
**Performance Goals**: 60 fps UI, GPS capture every 5 minutes during active shift, battery-efficient background tracking
**Constraints**: Offline-capable, encrypted local storage, <5% battery impact during tracking, HTTPS/TLS required
**Scale/Scope**: Single app with ~10-15 screens planned, targeting 10k+ beta testers via TestFlight/Play Internal Testing

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Pre-Design Gates (Phase 0)

| Principle | Requirement | Status | Notes |
|-----------|-------------|--------|-------|
| I. Mobile-First Flutter | Flutter ONLY framework | ✅ PASS | Flutter 3.x selected |
| I. Mobile-First Flutter | Dependencies iOS+Android compatible | ✅ PASS | All deps cross-platform |
| II. Battery-Conscious | GPS interval configurable | ✅ PASS | Default 5min specified |
| II. Battery-Conscious | Platform-optimized background tracking | ✅ PASS | iOS Background Modes + Android Foreground Service planned |
| III. Privacy & Compliance | RLS on all tables | ✅ PASS | Required in FR-004 |
| III. Privacy & Compliance | HTTPS/TLS for data transmission | ✅ PASS | Supabase enforces TLS |
| IV. Offline-First | Local storage for offline | ✅ PASS | sqflite for local cache |
| IV. Offline-First | Encrypted local storage | ✅ PASS | sqflite_sqlcipher + flutter_secure_storage (see research.md) |
| V. Simplicity | Minimized dependencies | ✅ PASS | Core deps only |
| V. Simplicity | YAGNI applied | ✅ PASS | Foundation only, no extras |
| Platform: iOS | Min target iOS 14.0 | ✅ PASS | Specified in Technical Context |
| Platform: Android | Min SDK API 24 | ✅ PASS | Specified in Technical Context |
| Backend: Supabase | supabase_flutter client | ✅ PASS | In primary dependencies |

### Post-Design Gates (Phase 1) - Verified

| Requirement | Status | Evidence |
|-------------|--------|----------|
| Data model includes explicit consent tracking | ✅ PASS | `employee_profiles.privacy_consent_at` in data-model.md |
| RLS policies defined for all tables | ✅ PASS | All 3 tables have RLS in contracts/database-schema.sql |
| Background location approach documented | ✅ PASS | geolocator + flutter_foreground_task in research.md |
| Sync conflict resolution strategy defined | ✅ PASS | Client UUID + LWW pattern in research.md |
| Privacy consent enforced before tracking | ✅ PASS | `clock_in()` function validates consent |

## Project Structure

### Documentation (this feature)

```text
specs/001-project-foundation/
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output (/speckit.plan command)
├── data-model.md        # Phase 1 output (/speckit.plan command)
├── quickstart.md        # Phase 1 output (/speckit.plan command)
├── contracts/           # Phase 1 output (/speckit.plan command)
└── tasks.md             # Phase 2 output (/speckit.tasks command - NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
gps_tracker/                    # Flutter project root (created by flutter create)
├── lib/
│   ├── main.dart               # App entry point
│   ├── app.dart                # App widget with routing/theming
│   ├── core/
│   │   ├── config/             # Environment config, constants
│   │   ├── services/           # Platform services (location, storage)
│   │   └── utils/              # Shared utilities
│   ├── features/
│   │   ├── auth/               # Authentication feature
│   │   ├── shifts/             # Shift management feature
│   │   └── tracking/           # GPS tracking feature
│   └── shared/
│       ├── models/             # Shared data models
│       ├── providers/          # Riverpod providers
│       └── widgets/            # Reusable UI components
├── test/
│   ├── unit/                   # Unit tests
│   └── widget/                 # Widget tests
├── integration_test/           # Integration tests
├── ios/                        # iOS platform-specific code
│   └── Runner/
│       └── Info.plist          # Permission strings, background modes
├── android/                    # Android platform-specific code
│   └── app/
│       └── src/main/
│           └── AndroidManifest.xml  # Permissions, services
├── pubspec.yaml                # Dependencies
└── analysis_options.yaml       # Linting rules

supabase/                       # Supabase configuration (outside Flutter project)
├── migrations/                 # SQL migration files
│   └── 001_initial_schema.sql
└── config.toml                 # Local development config
```

**Structure Decision**: Flutter project with feature-based architecture. Features are self-contained modules (auth, shifts, tracking) with shared core services and models. Supabase configuration kept separate from Flutter project for clear separation of concerns.

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

*No violations. All gates pass or have research items identified.*
