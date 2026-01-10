# Implementation Plan: Location Permission Guard

**Branch**: `007-location-permission-guard` | **Date**: 2026-01-10 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/007-location-permission-guard/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command. See `.specify/templates/commands/plan.md` for the execution workflow.

## Summary

Implement a comprehensive location permission guard system that proactively displays permission status on the dashboard, guides employees through permission requests with educational flows, blocks/warns during clock-in based on permission level, monitors permission changes during active shifts, and provides platform-specific recovery guidance for permanently denied permissions.

## Technical Context

**Language/Version**: Dart >=3.0.0 <4.0.0 / Flutter >=3.0.0
**Primary Dependencies**: flutter_riverpod 2.5.0 (state), geolocator 12.0.0 (permissions/location), flutter_foreground_task 8.0.0 (background services)
**Storage**: N/A (uses existing local storage infrastructure; session-scoped acknowledgment state only)
**Testing**: flutter_test (unit/widget tests), integration_test (integration tests)
**Target Platform**: iOS 14.0+, Android API 24+ (Android 7.0+)
**Project Type**: Mobile (Flutter cross-platform)
**Performance Goals**: Permission status display <2 seconds from app launch; permission change detection <5 seconds
**Constraints**: Minimal battery impact (leverages existing permission polling); no additional network calls; session-scoped state only
**Scale/Scope**: Single feature module (~10-15 new files); integrates with existing tracking and shifts features

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Requirement | Compliance | Notes |
|-----------|-------------|------------|-------|
| I. Mobile-First Flutter | All features use Flutter cross-platform | ✅ PASS | Pure Flutter/Dart implementation, no native code required |
| II. Battery-Conscious Design | Minimize battery consumption | ✅ PASS | Leverages existing permission checking infrastructure; no new background processes |
| III. Privacy & Compliance | Location tracking only when clocked in | ✅ PASS | Feature manages permissions, does not add tracking; respects existing clock-in boundary |
| IV. Offline-First Architecture | Works without network | ✅ PASS | All permission checking is local; no network calls required |
| V. Simplicity & Maintainability | Directly serves core use case | ✅ PASS | Enables core GPS tracking by ensuring proper permissions |
| Platform: iOS | iOS 14.0+ minimum | ✅ PASS | Uses existing geolocator package which supports iOS 14+ |
| Platform: Android | API 24+ minimum | ✅ PASS | Uses existing geolocator package which supports Android 7.0+ |
| Backend: Supabase RLS | Row Level Security enabled | N/A | No database changes required for this feature |

**Gate Status**: ✅ PASSED - All applicable constitutional requirements satisfied

## Project Structure

### Documentation (this feature)

```text
specs/007-location-permission-guard/
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output (/speckit.plan command)
├── data-model.md        # Phase 1 output (/speckit.plan command)
├── quickstart.md        # Phase 1 output (/speckit.plan command)
├── contracts/           # Phase 1 output (/speckit.plan command)
└── tasks.md             # Phase 2 output (/speckit.tasks command - NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
gps_tracker/lib/
├── features/
│   ├── tracking/
│   │   ├── models/
│   │   │   └── location_permission_state.dart     # EXISTING - enhance with device services state
│   │   ├── providers/
│   │   │   ├── location_permission_provider.dart  # EXISTING - enhance with monitoring/session state
│   │   │   └── permission_guard_provider.dart     # NEW - UI state for banner and dismissals
│   │   ├── services/
│   │   │   └── permission_monitor_service.dart    # NEW - real-time monitoring during shifts
│   │   └── widgets/
│   │       ├── permission_explanation_dialog.dart # EXISTING - reuse
│   │       ├── settings_guidance_dialog.dart      # EXISTING - reuse
│   │       └── permission_status_banner.dart      # NEW - dashboard banner widget
│   └── shifts/
│       └── screens/
│           └── shift_dashboard_screen.dart        # EXISTING - integrate permission banner
├── shared/
│   └── widgets/
│       └── permission_guard_wrapper.dart          # NEW - optional wrapper for permission-gated screens

gps_tracker/test/
├── features/
│   └── tracking/
│       ├── providers/
│       │   └── permission_guard_provider_test.dart    # NEW
│       ├── services/
│       │   └── permission_monitor_service_test.dart   # NEW
│       └── widgets/
│           └── permission_status_banner_test.dart     # NEW

gps_tracker/integration_test/
└── permission_guard_test.dart                     # NEW - E2E permission flow tests
```

**Structure Decision**: Mobile Flutter project using existing feature-based architecture. New components integrate into existing `tracking/` feature module, with integration points in `shifts/` for the dashboard. No new features folder needed - permission guard is an enhancement to the existing tracking infrastructure.

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

No violations - all constitutional requirements satisfied.

---

## Post-Design Constitution Re-Check

*Completed after Phase 1 design artifacts generated.*

| Principle | Post-Design Assessment | Status |
|-----------|------------------------|--------|
| I. Mobile-First Flutter | All new widgets use Flutter Material/Cupertino widgets; no platform channels added | ✅ CONFIRMED |
| II. Battery-Conscious Design | 30-second monitoring interval (matches existing tracking heartbeat); no continuous polling | ✅ CONFIRMED |
| III. Privacy & Compliance | No new location data collection; only permission checking (metadata, not location data) | ✅ CONFIRMED |
| IV. Offline-First Architecture | All operations local; state resets on app restart (no persistence concerns) | ✅ CONFIRMED |
| V. Simplicity & Maintainability | ~10 new files; reuses existing dialogs; no new dependencies; YAGNI applied | ✅ CONFIRMED |
| Platform: iOS | Uses `Geolocator.openAppSettings()` and `openLocationSettings()` - verified API support | ✅ CONFIRMED |
| Platform: Android | Battery optimization via existing `flutter_foreground_task` APIs | ✅ CONFIRMED |
| Backend: Supabase RLS | No database operations added by this feature | N/A |

**Final Gate Status**: ✅ PASSED - Design artifacts comply with all constitutional principles.

---

## Generated Artifacts

| Artifact | Path | Description |
|----------|------|-------------|
| Research | `specs/007-location-permission-guard/research.md` | 9 research topics resolved; no unknowns remaining |
| Data Model | `specs/007-location-permission-guard/data-model.md` | 6 entities defined; all client-side state |
| Provider Contracts | `specs/007-location-permission-guard/contracts/provider-contracts.md` | Provider and service interfaces |
| Widget Contracts | `specs/007-location-permission-guard/contracts/widget-contracts.md` | UI component specifications |
| Quickstart | `specs/007-location-permission-guard/quickstart.md` | Implementation guide with code snippets |

---

## Next Steps

Run `/speckit.tasks` to generate the implementation task list (`tasks.md`).
