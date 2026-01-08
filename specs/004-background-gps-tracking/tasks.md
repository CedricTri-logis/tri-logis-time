# Tasks: Background GPS Tracking

**Input**: Design documents from `/specs/004-background-gps-tracking/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: Not explicitly requested in specification - test tasks omitted.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Flutter mobile app**: `gps_tracker/lib/` for source, `gps_tracker/test/` for tests
- **Feature structure**: `lib/features/tracking/` for new tracking module

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization, dependencies, and directory structure

- [X] T001 Add flutter_map and latlong2 dependencies in `gps_tracker/pubspec.yaml`
- [X] T002 Create tracking feature directory structure: `gps_tracker/lib/features/tracking/{models,providers,services,screens,widgets}`
- [X] T003 [P] Verify Android foreground service configuration in `gps_tracker/android/app/src/main/AndroidManifest.xml`
- [X] T004 [P] Verify iOS background modes and BGTaskScheduler configuration in `gps_tracker/ios/Runner/Info.plist`
- [X] T005 Update iOS AppDelegate for flutter_foreground_task in `gps_tracker/ios/Runner/AppDelegate.swift`
- [X] T006 Run `flutter pub get` and verify all dependencies resolve

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core models and service infrastructure that ALL user stories depend on

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T007 [P] Create TrackingConfig model in `gps_tracker/lib/features/tracking/models/tracking_config.dart`
- [X] T008 [P] Create TrackingStatus enum in `gps_tracker/lib/features/tracking/models/tracking_status.dart`
- [X] T009 [P] Create TrackingState model in `gps_tracker/lib/features/tracking/models/tracking_state.dart`
- [X] T010 [P] Create LocationPermissionState model in `gps_tracker/lib/features/tracking/models/location_permission_state.dart`
- [X] T011 [P] Create RoutePoint model in `gps_tracker/lib/features/tracking/models/route_point.dart`
- [X] T012 Create models barrel export in `gps_tracker/lib/features/tracking/models/models.dart`
- [X] T013 Create BackgroundTrackingService with initialize() and permission methods in `gps_tracker/lib/features/tracking/services/background_tracking_service.dart`
- [X] T014 Create GPSTrackingHandler (TaskHandler) for background isolate in `gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart`
- [X] T015 Initialize BackgroundTrackingService in app startup in `gps_tracker/lib/main.dart`

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - Continuous Location Tracking During Shift (Priority: P1) 🎯 MVP

**Goal**: Automatically start/stop GPS tracking tied to clock-in/out with background capture

**Independent Test**: Clock in, close app or lock phone, move to different locations, clock out, verify location points were captured throughout the shift

### Implementation for User Story 1

- [X] T016 [US1] Implement startTracking() method in BackgroundTrackingService in `gps_tracker/lib/features/tracking/services/background_tracking_service.dart`
- [X] T017 [US1] Implement stopTracking() method in BackgroundTrackingService in `gps_tracker/lib/features/tracking/services/background_tracking_service.dart`
- [X] T018 [US1] Implement position capture flow in GPSTrackingHandler.onStart() in `gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart`
- [X] T019 [US1] Implement _onPosition() handler for GPS point storage in `gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart`
- [X] T020 [US1] Create TrackingProvider with TrackingNotifier in `gps_tracker/lib/features/tracking/providers/tracking_provider.dart`
- [X] T021 [US1] Implement _handleTaskData() for background->main isolate communication in `gps_tracker/lib/features/tracking/providers/tracking_provider.dart`
- [X] T022 [US1] Implement _handlePositionUpdate() to store GPS points locally in `gps_tracker/lib/features/tracking/providers/tracking_provider.dart`
- [X] T023 [US1] Implement _handleShiftStateChange() for auto-start/stop on clock in/out in `gps_tracker/lib/features/tracking/providers/tracking_provider.dart`
- [X] T024 [US1] Add derived providers (isTrackingProvider, trackingStatusProvider) in `gps_tracker/lib/features/tracking/providers/tracking_provider.dart`
- [X] T025 [US1] Integrate TrackingProvider listener with ShiftProvider in `gps_tracker/lib/features/shifts/providers/shift_provider.dart`

**Checkpoint**: Background GPS tracking starts on clock-in and stops on clock-out. Points captured even when app is backgrounded.

---

## Phase 4: User Story 2 - View Shift Route and Location History (Priority: P1)

**Goal**: Display tracked GPS points as a visual route on a map for completed shifts

**Independent Test**: Complete a shift with background tracking, view shift details, verify tracked locations are displayed on a map in chronological route format

### Implementation for User Story 2

- [X] T026 [P] [US2] Create RouteStats model in `gps_tracker/lib/features/tracking/models/route_stats.dart`
- [X] T027 [US2] Create RouteProvider with shiftRoutePointsProvider in `gps_tracker/lib/features/tracking/providers/route_provider.dart`
- [X] T028 [US2] Implement routeStatsProvider for route statistics in `gps_tracker/lib/features/tracking/providers/route_provider.dart`
- [X] T029 [US2] Implement routeBoundsProvider for map auto-fit in `gps_tracker/lib/features/tracking/providers/route_provider.dart`
- [X] T030 [US2] Add getGpsPointsForShift() method to LocalDatabase in `gps_tracker/lib/shared/services/local_database.dart`
- [X] T031 [P] [US2] Create GpsPointMarker widget in `gps_tracker/lib/features/tracking/widgets/gps_point_marker.dart`
- [X] T032 [P] [US2] Create PointDetailSheet widget in `gps_tracker/lib/features/tracking/widgets/point_detail_sheet.dart`
- [X] T033 [US2] Create RouteMapWidget with flutter_map integration in `gps_tracker/lib/features/tracking/widgets/route_map_widget.dart`
- [X] T034 [US2] Create RouteStatsCard widget in `gps_tracker/lib/features/tracking/widgets/route_stats_card.dart`
- [X] T035 [US2] Integrate RouteMapWidget and RouteStatsCard into ShiftDetailScreen in `gps_tracker/lib/features/shifts/screens/shift_detail_screen.dart`

**Checkpoint**: Users can view their tracked route on a map for any completed shift with tappable points showing timestamps.

---

## Phase 5: User Story 3 - Battery-Conscious Tracking (Priority: P1)

**Goal**: Implement adaptive GPS polling that balances accuracy with battery consumption (<10%/hour)

**Independent Test**: Run background tracking for an extended period and verify battery consumption remains within acceptable limits

### Implementation for User Story 3

- [X] T036 [US3] Implement adaptive polling based on movement state in GPSTrackingHandler in `gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart`
- [X] T037 [US3] Add stationary detection logic (< 10m movement for 30s) in `gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart`
- [X] T038 [US3] Implement configurable intervals (activeIntervalSeconds, stationaryIntervalSeconds) in `gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart`
- [X] T039 [US3] Add isStationary flag to TrackingState updates in `gps_tracker/lib/features/tracking/providers/tracking_provider.dart`
- [X] T040 [US3] Configure platform-specific location settings (Android/iOS accuracy modes) in `gps_tracker/lib/features/tracking/services/background_tracking_service.dart`

**Checkpoint**: Tracking adapts polling frequency based on movement, reducing battery usage when stationary.

---

## Phase 6: User Story 4 - Offline Location Storage (Priority: P2)

**Goal**: Store GPS points locally when offline and sync when connectivity returns

**Independent Test**: Enable airplane mode during active shift, move to different locations, restore connectivity, verify all offline points sync correctly with original timestamps

### Implementation for User Story 4

- [X] T041 [US4] Implement local GPS point storage in GPSTrackingHandler (existing local_gps_points table) in `gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart`
- [X] T042 [US4] Integrate SyncProvider trigger on new GPS point capture in `gps_tracker/lib/features/tracking/providers/tracking_provider.dart`
- [X] T043 [US4] Implement 48-hour retention cleanup for old synced points in `gps_tracker/lib/shared/services/local_database.dart`
- [X] T044 [US4] Add connectivity check before sync attempt in `gps_tracker/lib/features/shifts/providers/sync_provider.dart`

**Checkpoint**: GPS points captured offline are stored locally and sync automatically when connectivity returns.

---

## Phase 7: User Story 5 - Location Tracking Permissions (Priority: P2)

**Goal**: Request and manage location permissions with clear user-facing explanations

**Independent Test**: Install app fresh, go through permission flow, verify all necessary location permissions are requested with clear explanations

### Implementation for User Story 5

- [X] T045 [US5] Implement checkPermissions() method in BackgroundTrackingService in `gps_tracker/lib/features/tracking/services/background_tracking_service.dart`
- [X] T046 [US5] Implement requestPermissions() with progressive flow (while-in-use -> always) in `gps_tracker/lib/features/tracking/services/background_tracking_service.dart`
- [X] T047 [US5] Implement battery optimization exemption request in `gps_tracker/lib/features/tracking/services/background_tracking_service.dart`
- [X] T048 [US5] Create LocationPermissionProvider for permission state management in `gps_tracker/lib/features/tracking/providers/location_permission_provider.dart`
- [X] T049 [US5] Create PermissionExplanationDialog widget with user-friendly explanations in `gps_tracker/lib/features/tracking/widgets/permission_explanation_dialog.dart`
- [X] T050 [US5] Add permission check before clock-in in ShiftProvider in `gps_tracker/lib/features/shifts/providers/shift_provider.dart`
- [X] T051 [US5] Create SettingsGuidanceDialog for denied-forever scenario in `gps_tracker/lib/features/tracking/widgets/settings_guidance_dialog.dart`

**Checkpoint**: Users are guided through permission requests with clear explanations; app handles all permission states gracefully.

---

## Phase 8: User Story 6 - Tracking Status Visibility (Priority: P3)

**Goal**: Provide clear visual indicators showing when tracking is active and when points are recorded

**Independent Test**: Clock in and observe tracking status indicators in app and system notification area

### Implementation for User Story 6

- [X] T052 [P] [US6] Create TrackingStatusIndicator widget (compact and full modes) in `gps_tracker/lib/features/tracking/widgets/tracking_status_indicator.dart`
- [X] T053 [US6] Configure Android foreground notification with tracking status in `gps_tracker/lib/features/tracking/services/background_tracking_service.dart`
- [X] T054 [US6] Implement notification text update on each position capture in `gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart`
- [X] T055 [US6] Integrate TrackingStatusIndicator into ShiftStatusCard in `gps_tracker/lib/features/shifts/widgets/shift_status_card.dart`
- [X] T056 [US6] Add tracking status to ShiftDashboardScreen header in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`
- [X] T057 [US6] Implement GPS signal loss indicator (paused state) in TrackingStatusIndicator in `gps_tracker/lib/features/tracking/widgets/tracking_status_indicator.dart`

**Checkpoint**: Users see clear visual feedback that tracking is active, including notification (Android) and in-app indicators.

---

## Phase 9: Edge Cases & Device Restart (Post-MVP)

**Purpose**: Handle edge cases: device restart, GPS unavailable, long-running shifts

- [X] T058 Implement auto-resume tracking after device restart via autoRunOnBoot in `gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart`
- [X] T059 Add shift validity check on boot recovery in GPSTrackingHandler.onStart() in `gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart`
- [X] T060 Implement GPS signal loss handling with low-accuracy flagging in `gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart`
- [X] T061 Add health check timer (30s heartbeat) in GPSTrackingHandler.onRepeatEvent() in `gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart`
- [X] T062 Implement refreshState() for app resume state sync in `gps_tracker/lib/features/tracking/providers/tracking_provider.dart`

---

## Phase 10: Polish & Cross-Cutting Concerns

**Purpose**: Final integration, cleanup, and verification

- [X] T063 Create widgets barrel export in `gps_tracker/lib/features/tracking/widgets/widgets.dart`
- [X] T064 Create providers barrel export in `gps_tracker/lib/features/tracking/providers/providers.dart`
- [X] T065 Create tracking feature barrel export in `gps_tracker/lib/features/tracking/tracking.dart`
- [X] T066 Run `flutter analyze` and fix any linting issues
- [ ] T067 Run quickstart.md validation scenarios on physical device
- [ ] T068 Verify battery consumption meets SC-002 (<10% per hour) on physical device

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phases 3-8)**: All depend on Foundational phase completion
  - US1 (P1) → US2 (P1) → US3 (P1) can proceed sequentially
  - US4 (P2) and US5 (P2) can proceed after US3
  - US6 (P3) can proceed after US5
- **Edge Cases (Phase 9)**: Depends on US1 completion
- **Polish (Phase 10)**: Depends on all desired user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational (Phase 2) - Core tracking functionality
- **User Story 2 (P1)**: Can start after US1 - Needs GPS points to exist for visualization
- **User Story 3 (P1)**: Can start after US1 - Enhances existing tracking service
- **User Story 4 (P2)**: Can start after Foundational - Uses existing sync infrastructure
- **User Story 5 (P2)**: Can start after Foundational - Permission flow independent
- **User Story 6 (P3)**: Can start after US1 - Needs tracking state to display

### Within Each User Story

- Models before providers
- Services before providers that depend on them
- Providers before widgets that consume them
- Core implementation before UI integration

### Parallel Opportunities

- All Setup tasks marked [P] can run in parallel
- All Foundational model tasks (T007-T011) can run in parallel
- US2: T026, T031, T032 can run in parallel
- US6: T052 can start while US6 service work progresses

---

## Parallel Example: Foundational Models

```bash
# Launch all foundational models together:
Task: "Create TrackingConfig model in gps_tracker/lib/features/tracking/models/tracking_config.dart"
Task: "Create TrackingStatus enum in gps_tracker/lib/features/tracking/models/tracking_status.dart"
Task: "Create TrackingState model in gps_tracker/lib/features/tracking/models/tracking_state.dart"
Task: "Create LocationPermissionState model in gps_tracker/lib/features/tracking/models/location_permission_state.dart"
Task: "Create RoutePoint model in gps_tracker/lib/features/tracking/models/route_point.dart"
```

---

## Parallel Example: User Story 2 (Route Display)

```bash
# Launch parallel widget tasks:
Task: "Create GpsPointMarker widget in gps_tracker/lib/features/tracking/widgets/gps_point_marker.dart"
Task: "Create PointDetailSheet widget in gps_tracker/lib/features/tracking/widgets/point_detail_sheet.dart"
```

---

## Implementation Strategy

### MVP First (User Stories 1-3)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL - blocks all stories)
3. Complete Phase 3: User Story 1 - Core background tracking
4. Complete Phase 4: User Story 2 - Route visualization
5. Complete Phase 5: User Story 3 - Battery optimization
6. **STOP and VALIDATE**: Test on physical device, verify core flow works

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add User Story 1 → Test tracking start/stop → Functional MVP
3. Add User Story 2 → Test route display → Visual MVP
4. Add User Story 3 → Test battery usage → Optimized MVP
5. Add User Story 4 → Test offline sync → Robust offline support
6. Add User Story 5 → Test permission flow → Production-ready permissions
7. Add User Story 6 → Test status indicators → Complete feature
8. Complete Edge Cases + Polish → Production release

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Physical device testing required for background behavior verification
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- Battery testing (SC-002) requires extended runtime on physical device
