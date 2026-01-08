# Implementation Plan: Background GPS Tracking

**Branch**: `004-background-gps-tracking` | **Date**: 2026-01-08 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/004-background-gps-tracking/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command. See `.specify/templates/commands/plan.md` for the execution workflow.

## Summary

Implement continuous background GPS tracking during active shifts with battery-conscious design. The system automatically captures GPS location at configurable intervals (default: 5 minutes), stores points locally for offline scenarios, syncs when connectivity is available, and provides visual route display and tracking status indicators. Leverages existing `flutter_foreground_task` and `disable_battery_optimization` dependencies already in the project.

## Technical Context

**Language/Version**: Dart 3.x / Flutter 3.x (>=3.0.0)
**Primary Dependencies**: flutter_riverpod 2.5.0 (state), supabase_flutter 2.12.0 (backend), geolocator 12.0.0 (GPS), flutter_foreground_task 8.0.0 (background services), disable_battery_optimization 1.1.1, sqflite_sqlcipher 3.1.0 (local encrypted storage), connectivity_plus 6.0.0 (network status)
**Storage**: PostgreSQL via Supabase (gps_points table exists), SQLCipher for encrypted local storage (local_gps_points table exists)
**Testing**: flutter test (unit + widget tests), manual testing on physical devices for background behavior
**Target Platform**: iOS 14.0+ (Background Location Modes), Android API 24+ (Foreground Service)
**Project Type**: mobile (cross-platform Flutter)
**Performance Goals**: GPS capture within 30 seconds of interval, <10% battery per hour, route with 50+ points renders in <3 seconds, sync within 60 seconds of connectivity
**Constraints**: <10% battery/hour, 48+ hours offline storage capacity, works with app backgrounded/locked, auto-resume after device restart
**Scale/Scope**: Single employee app, GPS point every 5 minutes = ~12 points/hour = ~96 points/8-hour shift

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Pre-Design Validation

| Principle | Requirement | Compliance | Notes |
|-----------|-------------|------------|-------|
| **I. Mobile-First Flutter** | All features use Flutter for cross-platform | ✅ PASS | Single Flutter codebase, Material widgets, geolocator + flutter_foreground_task are cross-platform |
| **I. Mobile-First Flutter** | Platform-specific code isolated in channels | ✅ PASS | Platform code limited to AndroidManifest.xml and Info.plist configuration; no native code required |
| **I. Mobile-First Flutter** | Dependencies compatible with iOS + Android | ✅ PASS | flutter_foreground_task 8.0.0 supports both platforms |
| **II. Battery-Conscious Design** | GPS polling configurable (default 5 min) | ✅ PASS | Spec requires configurable intervals, default 5 minutes (FR-003) |
| **II. Battery-Conscious Design** | Platform-optimized background approach | ✅ PASS | Android: Foreground Service, iOS: Background Modes (already configured) |
| **II. Battery-Conscious Design** | Stop GPS tracking on clock-out | ✅ PASS | FR-002 requires automatic stop on clock-out |
| **II. Battery-Conscious Design** | Battery impact documented + tested | ⏳ PENDING | SC-002 requires <10% battery/hour; testing on physical devices required |
| **II. Battery-Conscious Design** | Users informed of battery usage | ✅ PASS | Permission explanations include battery context (FR-011) |
| **III. Privacy & Compliance** | Tracking only while clocked in | ✅ PASS | FR-001/FR-002 tie tracking to clock in/out only |
| **III. Privacy & Compliance** | Explicit consent before tracking | ✅ PASS | FR-011 requires permission with explanations; existing privacy consent flow |
| **III. Privacy & Compliance** | GPS data transmitted securely | ✅ PASS | Supabase client uses HTTPS/TLS; existing sync infrastructure |
| **III. Privacy & Compliance** | No tracking outside work hours | ✅ PASS | Tracking tied to active shift; stops automatically on clock-out |
| **IV. Offline-First Architecture** | GPS points stored locally when offline | ✅ PASS | FR-005, FR-006; existing local_gps_points table + SyncService |
| **IV. Offline-First Architecture** | Clear sync status indication | ✅ PASS | FR-013; existing SyncStatusIndicator pattern |
| **IV. Offline-First Architecture** | Local storage encrypted | ✅ PASS | Using existing SQLCipher encrypted database |
| **IV. Offline-First Architecture** | Conflict resolution defined | ✅ PASS | Using client_id for idempotent sync; existing pattern |
| **V. Simplicity & Maintainability** | Serves core clock-in + GPS use case | ✅ PASS | Direct implementation of core mission |
| **V. Simplicity & Maintainability** | Self-documenting code | ✅ PASS | Following existing naming conventions |
| **V. Simplicity & Maintainability** | Dependencies minimized | ✅ PASS | Reusing existing deps; flutter_foreground_task already in pubspec |

### Platform Requirements Check

| Platform | Requirement | Compliance | Notes |
|----------|-------------|------------|-------|
| **iOS** | "Always" location permission | ✅ PASS | NSLocationAlwaysAndWhenInUseUsageDescription configured |
| **iOS** | Background Modes capability | ✅ PASS | UIBackgroundModes: location, fetch already configured |
| **iOS** | Background location indicator | ✅ PASS | iOS shows system indicator automatically |
| **Android** | Foreground Service | ✅ PASS | FOREGROUND_SERVICE + FOREGROUND_SERVICE_LOCATION permissions exist |
| **Android** | Persistent notification | ✅ PASS | FR-012 requires this; flutter_foreground_task provides it |
| **Android** | Battery optimization handling | ✅ PASS | disable_battery_optimization dependency already in project |
| **Backend** | Supabase Auth | ✅ PASS | Existing auth infrastructure |
| **Backend** | RLS enabled | ✅ PASS | gps_points table has RLS policies |
| **Backend** | supabase_flutter client | ✅ PASS | Existing sync_gps_points RPC |

**Gate Status**: ✅ **PASS** - All mandatory requirements satisfied. Battery testing (SC-002) will be validated during implementation phase.

## Project Structure

### Documentation (this feature)

```text
specs/004-background-gps-tracking/
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output (/speckit.plan command)
├── data-model.md        # Phase 1 output (/speckit.plan command)
├── quickstart.md        # Phase 1 output (/speckit.plan command)
├── contracts/           # Phase 1 output (/speckit.plan command)
└── tasks.md             # Phase 2 output (/speckit.tasks command - NOT created by /speckit.plan)
```

### Source Code (Flutter Mobile Project)

```text
gps_tracker/
├── lib/
│   ├── main.dart                           # App entry with background task init
│   ├── features/
│   │   ├── shifts/
│   │   │   ├── models/
│   │   │   │   └── local_gps_point.dart    # EXISTING - GPS point model
│   │   │   ├── providers/
│   │   │   │   ├── shift_provider.dart     # MODIFY - integrate tracking start/stop
│   │   │   │   └── sync_provider.dart      # EXISTING - handles GPS point sync
│   │   │   ├── services/
│   │   │   │   ├── location_service.dart   # EXISTING - geolocator wrapper
│   │   │   │   └── sync_service.dart       # EXISTING - sync_gps_points RPC
│   │   │   ├── screens/
│   │   │   │   ├── shift_dashboard_screen.dart  # MODIFY - add tracking indicator
│   │   │   │   └── shift_detail_screen.dart     # MODIFY - add route map view
│   │   │   └── widgets/
│   │   │       └── shift_status_card.dart  # MODIFY - add tracking status
│   │   └── tracking/                       # NEW - background tracking feature
│   │       ├── models/
│   │       │   ├── tracking_config.dart    # Interval, accuracy, battery mode
│   │       │   └── tracking_state.dart     # Running, paused, stopped states
│   │       ├── providers/
│   │       │   ├── tracking_provider.dart  # Background tracking state
│   │       │   └── route_provider.dart     # GPS points for route display
│   │       ├── services/
│   │       │   └── background_tracking_service.dart  # Core service
│   │       ├── screens/
│   │       │   └── route_map_screen.dart   # Full route visualization
│   │       └── widgets/
│   │           ├── tracking_status_indicator.dart
│   │           ├── route_map_widget.dart
│   │           └── gps_point_marker.dart
│   └── shared/
│       └── services/
│           └── local_database.dart         # EXISTING - local_gps_points table
├── test/
│   ├── features/
│   │   └── tracking/
│   │       ├── services/
│   │       │   └── background_tracking_service_test.dart
│   │       └── providers/
│   │           └── tracking_provider_test.dart
│   └── integration/
│       └── background_tracking_integration_test.dart
├── ios/
│   └── Runner/
│       └── Info.plist                      # EXISTING - background modes configured
└── android/
    └── app/src/main/
        └── AndroidManifest.xml             # EXISTING - permissions configured

supabase/
└── migrations/
    └── [existing]                          # gps_points table already exists
```

**Structure Decision**: Mobile Flutter project structure, extending existing `shifts` feature with background tracking integration, and creating new `tracking` feature module for dedicated tracking UI components.

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

No constitution violations. All requirements satisfied with existing architecture and dependencies.

---

## Post-Design Constitution Check

*Re-evaluation after Phase 1 design completion.*

### Design Artifacts Review

| Artifact | Constitution Alignment | Notes |
|----------|----------------------|-------|
| **research.md** | ✅ Aligned | Decisions favor existing dependencies, platform-optimized approaches |
| **data-model.md** | ✅ Aligned | Minimal new models; reuses existing LocalGpsPoint; encrypted storage |
| **contracts/background-tracking-service.md** | ✅ Aligned | Uses flutter_foreground_task (cross-platform), respects privacy boundaries |
| **contracts/tracking-provider.md** | ✅ Aligned | Follows Riverpod patterns established in project |
| **contracts/route-provider.md** | ✅ Aligned | Reuses existing database infrastructure |
| **contracts/ui-widgets.md** | ✅ Aligned | Material widgets, theme integration |
| **quickstart.md** | ✅ Aligned | Documents platform-specific setup clearly |

### New Dependencies Introduced

| Dependency | Justification | Constitution Check |
|------------|---------------|-------------------|
| `flutter_map: ^6.0.0` | Route visualization | ✅ Cross-platform, no API key required, minimal |
| `latlong2: ^0.9.0` | Map coordinate helpers | ✅ Lightweight utility, required by flutter_map |

### Key Design Decisions Verification

| Decision | Constitution Principle | Verification |
|----------|----------------------|--------------|
| Use flutter_foreground_task (existing) | V. Simplicity | ✅ No new major dependency |
| Use geolocator position stream | II. Battery-Conscious | ✅ Distance-filtered, adaptive polling |
| Auto-stop on clock-out | III. Privacy | ✅ No tracking outside work hours |
| SQLCipher for local storage | IV. Offline-First | ✅ Encrypted at rest |
| Client-ID for idempotent sync | IV. Offline-First | ✅ Conflict resolution defined |
| OpenStreetMap tiles | V. Simplicity | ✅ Free, no vendor lock-in |

### Final Gate Status

✅ **PASS** - All design artifacts comply with Constitution principles.

| Principle | Status |
|-----------|--------|
| I. Mobile-First Flutter | ✅ Single codebase, minimal platform code |
| II. Battery-Conscious Design | ✅ Adaptive polling, distance filter, configurable intervals |
| III. Privacy & Compliance | ✅ Tracking tied to shifts, explicit permissions, encrypted |
| IV. Offline-First Architecture | ✅ Local storage, batch sync, clear status |
| V. Simplicity & Maintainability | ✅ Extends existing patterns, minimal new abstractions |

---

## Generated Artifacts

| Artifact | Path | Status |
|----------|------|--------|
| Implementation Plan | `specs/004-background-gps-tracking/plan.md` | ✅ Complete |
| Research Document | `specs/004-background-gps-tracking/research.md` | ✅ Complete |
| Data Model | `specs/004-background-gps-tracking/data-model.md` | ✅ Complete |
| Service Contract | `specs/004-background-gps-tracking/contracts/background-tracking-service.md` | ✅ Complete |
| Provider Contract | `specs/004-background-gps-tracking/contracts/tracking-provider.md` | ✅ Complete |
| Route Provider Contract | `specs/004-background-gps-tracking/contracts/route-provider.md` | ✅ Complete |
| UI Widgets Contract | `specs/004-background-gps-tracking/contracts/ui-widgets.md` | ✅ Complete |
| Quickstart Guide | `specs/004-background-gps-tracking/quickstart.md` | ✅ Complete |

---

## Next Steps

Run `/speckit.tasks` to generate `tasks.md` with implementation task breakdown.
