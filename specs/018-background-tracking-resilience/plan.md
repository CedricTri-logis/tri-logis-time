# Implementation Plan: 018 - Background Tracking Resilience

**Branch**: `018-background-tracking-resilience` | **Date**: 2026-02-24 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/018-background-tracking-resilience/spec.md`

## Summary

Harden the background GPS tracking system against OS-level process suspension and termination on both iOS and Android. The current implementation is vulnerable to iOS suspending the app after ~5 minutes (dual CLLocationManager conflict since iOS 16.4, no `beginBackgroundTask` protection, no `CLBackgroundActivitySession`) and Android OEM-specific battery killers (Samsung, Xiaomi, Huawei) that bypass standard foreground service protections. This plan adds deferred SignificantLocationChanges activation, native iOS background execution APIs, OEM-specific battery guidance for Android, foreground service restart hardening, and cross-platform thermal state monitoring.

## Technical Context

**Language/Version**: Dart >=3.0.0 / Flutter >=3.29.0 (mobile), Swift 5.9+ (iOS native), Kotlin (Android native)
**Primary Dependencies**: flutter_foreground_task 8.0.0, geolocator 12.0.0, flutter_riverpod 2.5.0, supabase_flutter 2.12.0, device_info_plus (already in pubspec), sqflite_sqlcipher 3.1.0
**Storage**: N/A (no new database tables — uses existing Supabase + SQLCipher infrastructure)
**Testing**: Manual real-device testing (iOS background tracking survival, Android OEM validation), flutter test for unit tests
**Target Platform**: iOS 14.0+ (with iOS 17+ enhanced APIs), Android API 24+ (with OEM-specific handling)
**Project Type**: Mobile (Flutter cross-platform with native platform channels)
**Performance Goals**: GPS tracking survives >10 minutes in background without suspension; thermal adaptation reduces GPS frequency under thermal pressure
**Constraints**: Must not change distanceFilter: 0 (iOS stream survival requirement), must not replace flutter_foreground_task or geolocator plugins, must be fail-open (offline workers never locked out)
**Scale/Scope**: ~15 field employees using Samsung/iPhone devices; primary success metric is reduction in `auto_zombie_cleanup` invocations

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Mobile App: Flutter Cross-Platform | PASS | All changes are in the Flutter mobile app. Native Swift/Kotlin is isolated in clearly marked platform channels (method channels). |
| II. Desktop Dashboard: TypeScript Web Stack | N/A | No dashboard changes in this feature. |
| III. Battery-Conscious Design | PASS | Thermal monitoring explicitly reduces GPS frequency when device overheats. OEM guidance helps users configure their devices correctly rather than fighting the OS. |
| IV. Privacy & Compliance | PASS | No new data collection. GPS tracking still only occurs while clocked in. No location data outside work hours. |
| V. Offline-First Architecture | PASS | All changes are fail-open. No new network dependencies. |
| VI. Simplicity & Maintainability | PASS | Each improvement is isolated (iOS plugin, Android dialog, thermal service). No new abstractions — extends existing patterns. |
| iOS Requirements | PASS | Uses Background Modes capability (already configured), adds CLBackgroundActivitySession for iOS 17+ with graceful fallback. |
| Android Requirements | PASS | Extends existing foreground service with OEM-specific guidance. |

**Gate result: PASS** — No violations. All changes align with constitutional principles.

## Constitution Re-Check (Post Phase 1 Design)

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Mobile App: Flutter Cross-Platform | PASS | Native code is minimal and isolated: 1 new Swift plugin file (~80 lines), 1 Kotlin method channel extension (~60 lines). |
| III. Battery-Conscious Design | PASS | Thermal adaptation documented in contracts. GPS interval adapts from 60s → 120s → 300s based on thermal state. |
| VI. Simplicity & Maintainability | PASS | No new abstractions. `ThermalStateService` follows the same singleton + method channel pattern as `SignificantLocationService`. OEM dialog is a self-contained widget. |

**Post-design gate result: PASS**

## Project Structure

### Documentation (this feature)

```text
specs/018-background-tracking-resilience/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output (no new DB tables)
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output (method channel contracts)
│   ├── ios-background-execution.md
│   ├── android-oem-battery.md
│   └── thermal-state.md
└── tasks.md             # Phase 2 output (created by /speckit.tasks)
```

### Source Code (repository root)

```text
gps_tracker/
├── lib/features/tracking/
│   ├── providers/
│   │   └── tracking_provider.dart          # MODIFY: deferred SLC, thermal, FGS resume
│   ├── services/
│   │   ├── background_tracking_service.dart # MODIFY: lifecycle hooks for beginBackgroundTask
│   │   ├── gps_tracking_handler.dart        # MODIFY: signal main isolate on stream death
│   │   ├── significant_location_service.dart # MODIFY: start/stop from handler signal
│   │   └── thermal_state_service.dart       # NEW: cross-platform thermal monitoring
│   └── widgets/
│       ├── battery_optimization_dialog.dart  # MODIFY: delegate to OEM guide on supported OEMs
│       └── oem_battery_guide_dialog.dart     # NEW: OEM-specific setup instructions
├── ios/Runner/
│   ├── AppDelegate.swift                    # MODIFY: register BackgroundTaskPlugin
│   ├── SignificantLocationPlugin.swift      # MODIFY: add CLBackgroundActivitySession
│   └── BackgroundTaskPlugin.swift           # NEW: beginBackgroundTask + session management
├── android/app/src/main/
│   ├── AndroidManifest.xml                  # MODIFY: no new permissions needed
│   └── kotlin/.../MainActivity.kt           # MODIFY: add thermal + OEM method channels
└── test/
    └── features/tracking/
        ├── thermal_state_service_test.dart   # NEW
        └── oem_battery_guide_test.dart       # NEW
```

**Structure Decision**: Mobile-only feature. All changes are within the existing `gps_tracker/` Flutter project, extending the `features/tracking/` module. Native code is isolated in `ios/Runner/` (Swift) and `android/app/src/main/kotlin/` (Kotlin) with MethodChannel bridges.

## Complexity Tracking

No constitution violations — this section is not needed.
