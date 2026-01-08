# Implementation Plan: Employee Authentication

**Branch**: `002-employee-auth` | **Date**: 2026-01-08 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/002-employee-auth/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command. See `.specify/templates/commands/plan.md` for the execution workflow.

## Summary

Implement complete employee authentication for the GPS Clock-In Tracker app, including sign-in, account creation with email verification, password recovery, sign-out, and profile management. Uses Supabase Auth for backend authentication with Flutter frontend screens and Riverpod state management.

## Technical Context

**Language/Version**: Dart 3.x / Flutter 3.x (latest stable)
**Primary Dependencies**: flutter, supabase_flutter 2.12.0, flutter_riverpod 2.5.0, flutter_secure_storage 9.2.4
**Storage**: PostgreSQL via Supabase (employee_profiles table already exists), flutter_secure_storage for tokens
**Testing**: flutter_test (unit/widget), integration_test (integration tests)
**Target Platform**: iOS 14.0+, Android API 24+ (cross-platform Flutter app)
**Project Type**: mobile
**Performance Goals**: Sign-in completion within 30 seconds, 95% success rate on first attempt
**Constraints**: Offline-capable for session persistence (Constitution IV), network required for auth operations
**Scale/Scope**: Employee-facing app, ~5 auth screens (sign-in, sign-up, forgot password, profile, settings)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Mobile-First Flutter | ✅ PASS | Using Flutter with Material/Cupertino widgets |
| II. Battery-Conscious Design | ✅ PASS | Auth is network-based, no continuous background operations |
| III. Privacy & Compliance | ✅ PASS | Standard auth flow, no location data in auth screens |
| IV. Offline-First Architecture | ⚠️ PARTIAL | Session persistence works offline, but auth operations require network. App will clearly indicate when network is needed. |
| V. Simplicity & Maintainability | ✅ PASS | Using built-in Supabase Auth, minimal custom code |
| Backend: Supabase Auth | ✅ PASS | Using supabase_flutter with email/password as specified |
| Backend: RLS | ✅ PASS | employee_profiles table already has RLS enabled |

**Gate Result**: PASS - All principles satisfied. Offline-first partially applicable (auth inherently requires network for initial sign-in; session persistence handles subsequent offline access).

## Project Structure

### Documentation (this feature)

```text
specs/002-employee-auth/
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
│   ├── main.dart                          # App entry point with Supabase init
│   ├── app.dart                           # Root MaterialApp (add auth routing)
│   ├── core/
│   │   └── config/
│   │       ├── env_config.dart            # Existing - environment config
│   │       └── constants.dart             # Existing - add auth constants
│   ├── features/
│   │   ├── auth/                          # NEW: Authentication feature
│   │   │   ├── models/
│   │   │   │   └── employee_profile.dart  # Employee profile model
│   │   │   ├── providers/
│   │   │   │   ├── auth_provider.dart     # Auth state provider
│   │   │   │   └── profile_provider.dart  # Profile management provider
│   │   │   ├── screens/
│   │   │   │   ├── sign_in_screen.dart    # Email/password sign-in
│   │   │   │   ├── sign_up_screen.dart    # Account creation
│   │   │   │   ├── forgot_password_screen.dart
│   │   │   │   └── profile_screen.dart    # View/edit profile
│   │   │   ├── widgets/
│   │   │   │   ├── auth_form_field.dart   # Reusable form field
│   │   │   │   └── auth_button.dart       # Primary auth action button
│   │   │   └── services/
│   │   │       └── auth_service.dart      # Supabase auth wrapper
│   │   └── home/                          # Existing - update for auth
│   │       └── home_screen.dart           # Add sign-out option
│   └── shared/
│       ├── providers/
│       │   └── supabase_provider.dart     # Existing - auth providers defined
│       ├── widgets/
│       │   └── error_snackbar.dart        # Reusable error display
│       └── routing/
│           └── auth_guard.dart            # Route protection
├── test/
│   ├── features/
│   │   └── auth/
│   │       ├── auth_provider_test.dart
│   │       └── auth_service_test.dart
│   └── widget/
│       └── auth/
│           ├── sign_in_screen_test.dart
│           └── sign_up_screen_test.dart
└── integration_test/
    └── auth_flow_test.dart                # Full auth flow integration test

supabase/
└── migrations/
    └── 001_initial_schema.sql             # Existing - already has employee_profiles
```

**Structure Decision**: Mobile + API structure following existing Flutter project conventions. The auth feature will be added under `gps_tracker/lib/features/auth/` following the feature-based folder structure established in Spec 001. The database schema (employee_profiles) already exists from the initial migration.

## Complexity Tracking

> No violations requiring justification. Design adheres to all constitutional principles.

---

## Post-Design Constitution Re-Check

*Completed after Phase 1 design artifacts generated.*

| Principle | Post-Design Status | Design Validation |
|-----------|-------------------|-------------------|
| I. Mobile-First Flutter | ✅ CONFIRMED | All screens use Flutter Material widgets. No platform-specific code required. |
| II. Battery-Conscious Design | ✅ CONFIRMED | Auth operations are user-initiated only. No background polling or continuous network requests. |
| III. Privacy & Compliance | ✅ CONFIRMED | No location data collected during auth. Privacy consent checked before GPS features (existing in schema). |
| IV. Offline-First Architecture | ✅ CONFIRMED | Session persists locally via flutter_secure_storage. Graceful degradation: user stays "logged in" locally even when offline. Token refresh attempted on reconnect without forcing logout. |
| V. Simplicity & Maintainability | ✅ CONFIRMED | Using supabase_flutter built-in auth (no custom JWT). StreamProvider pattern for reactive auth state. Service class pattern keeps logic testable. No code generation dependencies. |
| Backend: Supabase Auth | ✅ CONFIRMED | email/password auth only. Email verification via Supabase. Password reset via Supabase magic links. |
| Backend: RLS | ✅ CONFIRMED | employee_profiles RLS policies already exist. Users can only read/update their own profile. |

**Final Gate Result**: PASS - All constitutional requirements satisfied. Design ready for task generation.

---

## Generated Artifacts

| Artifact | Path | Status |
|----------|------|--------|
| Research | `specs/002-employee-auth/research.md` | Complete |
| Data Model | `specs/002-employee-auth/data-model.md` | Complete |
| API Contracts | `specs/002-employee-auth/contracts/auth-api.md` | Complete |
| Quickstart | `specs/002-employee-auth/quickstart.md` | Complete |
| Agent Context | `CLAUDE.md` | Updated |

---

## Next Steps

Run `/speckit.tasks` to generate the implementation task list from this plan.
