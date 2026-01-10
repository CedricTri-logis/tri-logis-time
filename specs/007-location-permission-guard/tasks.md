# Tasks: Location Permission Guard

**Input**: Design documents from `/specs/007-location-permission-guard/`
**Prerequisites**: plan.md ✓, spec.md ✓, research.md ✓, data-model.md ✓, contracts/ ✓

**Tests**: Not explicitly requested in feature specification. Tests are NOT included in this task list.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Flutter Mobile App**: `gps_tracker/lib/` for source, `gps_tracker/test/` for tests
- Paths follow existing feature-based structure per plan.md

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create new model files and directory structure for permission guard feature

- [X] T001 [P] Create `DeviceLocationStatus` enum in `gps_tracker/lib/features/tracking/models/device_location_status.dart`
- [X] T002 [P] Create `PermissionGuardStatus` enum in `gps_tracker/lib/features/tracking/models/permission_guard_status.dart`
- [X] T003 [P] Create `DismissibleWarningType` enum in `gps_tracker/lib/features/tracking/models/dismissible_warning_type.dart`
- [X] T004 [P] Create `PermissionChangeEvent` model in `gps_tracker/lib/features/tracking/models/permission_change_event.dart`
- [X] T005 Create `PermissionGuardState` model in `gps_tracker/lib/features/tracking/models/permission_guard_state.dart` (depends on T001-T003)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core provider and service infrastructure that ALL user stories depend on

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T006 Create `PermissionGuardNotifier` class with `checkStatus()`, `dismissWarning()`, `setActiveShift()`, `requestPermission()`, `openAppSettings()`, `openDeviceLocationSettings()`, `requestBatteryOptimization()` methods in `gps_tracker/lib/features/tracking/providers/permission_guard_provider.dart`
- [X] T007 Create derived providers (`permissionGuardStatusProvider`, `shouldShowPermissionBannerProvider`, `shouldBlockClockInProvider`, `shouldWarnOnClockInProvider`) in `gps_tracker/lib/features/tracking/providers/permission_guard_provider.dart`
- [X] T008 Create `PermissionMonitorService` class with `startMonitoring()`, `stopMonitoring()`, `isMonitoring` in `gps_tracker/lib/features/tracking/services/permission_monitor_service.dart`
- [X] T009 Create `permissionMonitorProvider` in `gps_tracker/lib/features/tracking/services/permission_monitor_service.dart`

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - Permission Status Awareness (Priority: P1) 🎯 MVP

**Goal**: Employee sees current location permission status on dashboard with actionable guidance

**Independent Test**: Open app with various permission states (denied, while-in-use, always) and verify appropriate status indicator appears

### Implementation for User Story 1

- [X] T010 [P] [US1] Create `PermissionStatusBanner` widget skeleton in `gps_tracker/lib/features/tracking/widgets/permission_status_banner.dart`
- [X] T011 [US1] Implement banner content configuration by `PermissionGuardStatus` (colors, icons, messages, actions) in `gps_tracker/lib/features/tracking/widgets/permission_status_banner.dart`
- [X] T012 [US1] Add `AnimatedSize` wrapper and show/hide logic based on `shouldShowBanner` in `gps_tracker/lib/features/tracking/widgets/permission_status_banner.dart`
- [X] T013 [US1] Wire banner action button to `permissionGuardProvider.notifier` methods in `gps_tracker/lib/features/tracking/widgets/permission_status_banner.dart`
- [X] T014 [US1] Wire dismiss button to `dismissWarning()` for dismissible warning types in `gps_tracker/lib/features/tracking/widgets/permission_status_banner.dart`
- [X] T015 [US1] Integrate `PermissionStatusBanner` at top of dashboard layout in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`
- [X] T016 [US1] Add `permissionGuardProvider.notifier.checkStatus()` to RefreshIndicator callback in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`
- [X] T017 [US1] Add `permissionGuardProvider.notifier.checkStatus()` to `didChangeAppLifecycleState` on resume in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`
- [X] T018 [US1] Add accessibility semantics (screen reader labels) to `PermissionStatusBanner` in `gps_tracker/lib/features/tracking/widgets/permission_status_banner.dart`

**Checkpoint**: User Story 1 complete - permission status banner displays correctly on dashboard

---

## Phase 4: User Story 2 - Guided Permission Request Flow (Priority: P1)

**Goal**: Employee is guided through educational flow explaining why permission is needed and how to grant it

**Independent Test**: Trigger permission flow from various states (first-time, previously denied, permanently denied) and verify appropriate guidance appears

### Implementation for User Story 2

- [X] T019 [P] [US2] Create `DeviceServicesDialog` widget in `gps_tracker/lib/features/tracking/widgets/device_services_dialog.dart`
- [X] T020 [US2] Implement platform-specific content (iOS vs Android steps) in `DeviceServicesDialog` using `Platform.isIOS` in `gps_tracker/lib/features/tracking/widgets/device_services_dialog.dart`
- [X] T021 [US2] Add "Open Settings" action that calls `Geolocator.openLocationSettings()` in `gps_tracker/lib/features/tracking/widgets/device_services_dialog.dart`
- [X] T022 [P] [US2] Create `BatteryOptimizationDialog` widget (Android-only) in `gps_tracker/lib/features/tracking/widgets/battery_optimization_dialog.dart`
- [X] T023 [US2] Implement battery optimization explanation content and action buttons in `gps_tracker/lib/features/tracking/widgets/battery_optimization_dialog.dart`
- [X] T024 [US2] Add "Allow" action that calls `permissionGuardProvider.notifier.requestBatteryOptimization()` in `gps_tracker/lib/features/tracking/widgets/battery_optimization_dialog.dart`
- [X] T025 [US2] Update `PermissionStatusBanner` to show `DeviceServicesDialog` when status is `deviceServicesDisabled` in `gps_tracker/lib/features/tracking/widgets/permission_status_banner.dart`
- [X] T026 [US2] Update `PermissionStatusBanner` to show existing `SettingsGuidanceDialog` when status is `permanentlyDenied` in `gps_tracker/lib/features/tracking/widgets/permission_status_banner.dart`
- [X] T027 [US2] Update `PermissionStatusBanner` to show existing `PermissionExplanationDialog` when status is `permissionRequired` in `gps_tracker/lib/features/tracking/widgets/permission_status_banner.dart`
- [X] T028 [US2] Update `PermissionStatusBanner` to show `BatteryOptimizationDialog` when status is `batteryOptimizationRequired` in `gps_tracker/lib/features/tracking/widgets/permission_status_banner.dart`

**Checkpoint**: User Story 2 complete - all permission states trigger appropriate educational guidance

---

## Phase 5: User Story 3 - Pre-Shift Permission Check (Priority: P2)

**Goal**: System checks permissions before clock-in and blocks/warns as appropriate

**Independent Test**: Attempt to clock in with various permission states and verify blocking or warning behavior

### Implementation for User Story 3

- [X] T029 [US3] Add pre-clock-in permission check in `_handleClockIn()` using `guardState.shouldBlockClockIn` in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`
- [X] T030 [US3] Show `DeviceServicesDialog` when blocked due to device services disabled in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`
- [X] T031 [US3] Show `SettingsGuidanceDialog` when blocked due to permanently denied permission in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`
- [X] T032 [US3] Show `PermissionExplanationDialog` and request permission when blocked due to no permission in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`
- [X] T033 [US3] Add warning check using `guardState.shouldWarnOnClockIn` in `_handleClockIn()` in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`
- [X] T034 [US3] Create `_showClockInWarningDialog()` helper for partial permission/battery optimization warnings in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`
- [X] T035 [US3] Allow user to proceed after acknowledging warning or return to fix issue in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`

**Checkpoint**: User Story 3 complete - clock-in properly blocked or warned based on permission state

---

## Phase 6: User Story 4 - Real-Time Permission Monitoring (Priority: P2)

**Goal**: System monitors permission changes during active shifts and notifies user

**Independent Test**: Start shift, revoke permission via device settings, verify app responds with notification and guidance

### Implementation for User Story 4

- [X] T036 [P] [US4] Create `PermissionChangeAlert` dialog widget in `gps_tracker/lib/features/tracking/widgets/permission_change_alert.dart`
- [X] T037 [US4] Implement alert content for permission revoked scenario (hadAny → !hasAny) in `gps_tracker/lib/features/tracking/widgets/permission_change_alert.dart`
- [X] T038 [US4] Implement alert content for permission downgraded scenario (always → whileInUse) in `gps_tracker/lib/features/tracking/widgets/permission_change_alert.dart`
- [X] T039 [US4] Add "OK" (acknowledge) and "Fix Now"/"Restore" action buttons in `gps_tracker/lib/features/tracking/widgets/permission_change_alert.dart`
- [X] T040 [US4] Integrate `PermissionMonitorService` with `shiftProvider` to start monitoring on shift start in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`
- [X] T041 [US4] Stop monitoring when shift ends via `PermissionMonitorService.stopMonitoring()` in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`
- [X] T042 [US4] Show `PermissionChangeAlert` when `PermissionChangeEvent.isDowngrade` detected during active shift in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`
- [X] T043 [US4] Call `permissionGuardProvider.notifier.checkStatus()` after permission change detected to update banner in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`
- [X] T044 [US4] Implement auto-resume tracking when permissions restored (detected by upgrade event) in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`

**Checkpoint**: User Story 4 complete - permission changes during shifts are detected and communicated

---

## Phase 7: User Story 5 - Permission Recovery Assistance (Priority: P3)

**Goal**: Users with permanently denied permissions get clear, platform-specific recovery instructions

**Independent Test**: Permanently deny permission and verify recovery flow provides accurate platform-specific instructions

### Implementation for User Story 5

- [X] T045 [US5] Verify existing `SettingsGuidanceDialog` has iOS-specific instructions (Settings > GPS Tracker > Location > Always) in `gps_tracker/lib/features/tracking/widgets/settings_guidance_dialog.dart`
- [X] T046 [US5] Verify existing `SettingsGuidanceDialog` has Android-specific instructions (Settings > Apps > GPS Tracker > Permissions > Location > Allow all the time) in `gps_tracker/lib/features/tracking/widgets/settings_guidance_dialog.dart`
- [X] T047 [US5] Verify "Open Settings" button calls `Geolocator.openAppSettings()` in `gps_tracker/lib/features/tracking/widgets/settings_guidance_dialog.dart`
- [X] T048 [US5] Ensure permission state is re-checked on app resume after returning from settings in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`

**Checkpoint**: User Story 5 complete - permanently denied recovery flow works on both platforms

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Final integration, edge cases, and quality improvements

- [X] T049 [P] Create optional `PermissionGuardWrapper` widget for gating screens in `gps_tracker/lib/shared/widgets/permission_guard_wrapper.dart`
- [X] T050 Add 500ms debounce to `checkStatus()` state updates to prevent UI flicker in `gps_tracker/lib/features/tracking/providers/permission_guard_provider.dart`
- [X] T051 Add `Platform.isAndroid` guard to battery optimization logic (no-op on iOS) in `gps_tracker/lib/features/tracking/providers/permission_guard_provider.dart`
- [X] T052 Add error handling for `Geolocator.checkPermission()` failures in `gps_tracker/lib/features/tracking/providers/permission_guard_provider.dart`
- [X] T053 Add error handling for `Geolocator.isLocationServiceEnabled()` failures in `gps_tracker/lib/features/tracking/providers/permission_guard_provider.dart`
- [X] T054 Ensure minimum 48x48dp touch targets on all interactive banner elements in `gps_tracker/lib/features/tracking/widgets/permission_status_banner.dart`
- [X] T055 Add barrel exports for new models in `gps_tracker/lib/features/tracking/models/models.dart` (or create if not exists)
- [X] T056 Run quickstart.md manual testing checklist to validate all scenarios

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 completion - BLOCKS all user stories
- **User Stories (Phase 3-7)**: All depend on Phase 2 completion
  - US1 (P1) and US2 (P1): Can proceed in parallel after Phase 2
  - US3 (P2): Can start after Phase 2; integrates with US1/US2 dialogs
  - US4 (P2): Can start after Phase 2; uses monitoring service
  - US5 (P3): Can start after Phase 2; verifies existing dialogs
- **Polish (Phase 8)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Phase 2 - No dependencies on other stories
- **User Story 2 (P1)**: Can start after Phase 2 - No dependencies; creates dialogs used by US1 banner
- **User Story 3 (P2)**: Can start after Phase 2 - Uses dialogs from US2
- **User Story 4 (P2)**: Can start after Phase 2 - Uses alert dialog, integrates with monitoring service
- **User Story 5 (P3)**: Can start after Phase 2 - Verifies/enhances existing dialogs

### Within Each User Story

- Widget skeleton before implementation details
- Provider integration before UI wiring
- Core functionality before accessibility/polish

### Parallel Opportunities

- All Phase 1 (Setup) tasks marked [P] can run in parallel
- Phase 2 tasks T006-T007 (provider) and T008-T009 (service) can run in parallel
- Within user stories, tasks marked [P] can run in parallel
- Different user stories can be worked on in parallel by different developers

---

## Parallel Example: Phase 1 (Setup)

```bash
# Launch all model files in parallel:
Task T001: "Create DeviceLocationStatus enum"
Task T002: "Create PermissionGuardStatus enum"
Task T003: "Create DismissibleWarningType enum"
Task T004: "Create PermissionChangeEvent model"
# Then T005 (depends on T001-T003)
```

## Parallel Example: User Story 1 & 2

```bash
# After Phase 2 completes, these can run in parallel:

# Developer A: User Story 1
Task T010: "Create PermissionStatusBanner widget skeleton"
Task T011-T018: "Implement banner..."

# Developer B: User Story 2
Task T019: "Create DeviceServicesDialog widget"
Task T022: "Create BatteryOptimizationDialog widget"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001-T005)
2. Complete Phase 2: Foundational (T006-T009) - CRITICAL
3. Complete Phase 3: User Story 1 (T010-T018)
4. **STOP and VALIDATE**: Dashboard shows permission banner correctly
5. Deploy/demo if ready

### Incremental Delivery

1. Setup + Foundational → Foundation ready
2. Add User Story 1 → Banner displays permission status (MVP!)
3. Add User Story 2 → Educational dialogs for all permission states
4. Add User Story 3 → Pre-clock-in checks work
5. Add User Story 4 → Real-time monitoring during shifts
6. Add User Story 5 → Recovery assistance polished
7. Polish phase → Edge cases and quality

### Parallel Team Strategy

With multiple developers after Phase 2:

- Developer A: User Story 1 (banner widget)
- Developer B: User Story 2 (dialogs)
- Developer C: User Story 3 + 4 (clock-in and monitoring integration)

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- All new widgets should use existing `PermissionExplanationDialog` and `SettingsGuidanceDialog` patterns
- Battery optimization is Android-only; guard with `Platform.isAndroid`
- Session-scoped state (dismissed warnings) resets on app restart as specified
