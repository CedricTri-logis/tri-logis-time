# Tasks: Shift Management

**Input**: Design documents from `/specs/003-shift-management/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure for shift management feature

- [X] T001 Create shifts feature directory structure at `gps_tracker/lib/features/shifts/`
- [X] T002 [P] Create models subdirectory at `gps_tracker/lib/features/shifts/models/`
- [X] T003 [P] Create providers subdirectory at `gps_tracker/lib/features/shifts/providers/`
- [X] T004 [P] Create screens subdirectory at `gps_tracker/lib/features/shifts/screens/`
- [X] T005 [P] Create services subdirectory at `gps_tracker/lib/features/shifts/services/`
- [X] T006 [P] Create widgets subdirectory at `gps_tracker/lib/features/shifts/widgets/`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T007 Create GeoPoint value object model in `gps_tracker/lib/features/shifts/models/geo_point.dart`
- [X] T008 Create ShiftStatus and SyncStatus enums in `gps_tracker/lib/features/shifts/models/shift_enums.dart`
- [X] T009 Create Shift model with fromJson/toJson in `gps_tracker/lib/features/shifts/models/shift.dart`
- [X] T010 Create LocalShift model for SQLite in `gps_tracker/lib/features/shifts/models/local_shift.dart`
- [X] T011 Create LocalGpsPoint model for SQLite in `gps_tracker/lib/features/shifts/models/local_gps_point.dart`
- [X] T012 Create LocalDatabaseException class in `gps_tracker/lib/shared/services/local_database_exception.dart`
- [X] T013 Implement LocalDatabase service with encrypted SQLite initialization in `gps_tracker/lib/shared/services/local_database.dart`
- [X] T014 Add LocalDatabase initialization to app startup in `gps_tracker/lib/main.dart`
- [X] T015 Create LocationService with permission handling and GPS capture in `gps_tracker/lib/features/shifts/services/location_service.dart`
- [X] T016 Create location_provider for LocationService in `gps_tracker/lib/features/shifts/providers/location_provider.dart`
- [X] T017 Create ConnectivityService wrapper in `gps_tracker/lib/features/shifts/services/connectivity_service.dart`
- [X] T018 Create connectivity_provider in `gps_tracker/lib/features/shifts/providers/connectivity_provider.dart`

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - Employee Clocks In (Priority: P1) 🎯 MVP

**Goal**: Authenticated employee can tap "Clock In" to start a shift with GPS location capture

**Independent Test**: Sign in, tap "Clock In", verify shift is created with correct timestamp and location data

### Implementation for User Story 1

- [X] T019 [US1] Implement ShiftService.clockIn() with local-first write in `gps_tracker/lib/features/shifts/services/shift_service.dart`
- [X] T020 [US1] Add clock_in RPC call logic to ShiftService in `gps_tracker/lib/features/shifts/services/shift_service.dart`
- [X] T021 [US1] Create shift_provider with active shift state in `gps_tracker/lib/features/shifts/providers/shift_provider.dart`
- [X] T022 [US1] Create ClockButton widget with clock-in state in `gps_tracker/lib/features/shifts/widgets/clock_button.dart`
- [X] T023 [US1] Create ShiftStatusCard widget showing active shift info in `gps_tracker/lib/features/shifts/widgets/shift_status_card.dart`
- [X] T024 [US1] Create SyncStatusIndicator widget in `gps_tracker/lib/features/shifts/widgets/sync_status_indicator.dart`
- [X] T025 [US1] Create ShiftDashboardScreen with clock-in UI in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`
- [X] T026 [US1] Add navigation from home to shift dashboard in `gps_tracker/lib/app.dart`
- [X] T027 [US1] Handle location permission prompt before clock-in in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`
- [X] T028 [US1] Add clock-in success snackbar feedback in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`

**Checkpoint**: User Story 1 complete - employees can clock in with location capture

---

## Phase 4: User Story 2 - Employee Clocks Out (Priority: P1)

**Goal**: Employee with active shift can tap "Clock Out" to complete the shift with end location

**Independent Test**: Have an active shift, tap "Clock Out", verify shift is completed with correct end timestamp and duration

### Implementation for User Story 2

- [X] T029 [US2] Implement ShiftService.clockOut() with local-first write in `gps_tracker/lib/features/shifts/services/shift_service.dart`
- [X] T030 [US2] Add clock_out RPC call logic to ShiftService in `gps_tracker/lib/features/shifts/services/shift_service.dart`
- [X] T031 [US2] Update ClockButton widget with clock-out state in `gps_tracker/lib/features/shifts/widgets/clock_button.dart`
- [X] T032 [US2] Create clock-out confirmation bottom sheet in `gps_tracker/lib/features/shifts/widgets/clock_out_confirmation_sheet.dart`
- [X] T033 [US2] Create shift summary widget showing duration after clock-out in `gps_tracker/lib/features/shifts/widgets/shift_summary_card.dart`
- [X] T034 [US2] Update ShiftDashboardScreen with clock-out flow in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`
- [X] T035 [US2] Add clock-out success confirmation with duration display in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`

**Checkpoint**: User Story 2 complete - employees can clock out and see shift duration

---

## Phase 5: User Story 3 - Employee Views Current Shift Status (Priority: P1)

**Goal**: Employee sees real-time elapsed time and shift information while clocked in

**Independent Test**: Clock in, verify dashboard shows accurate, updating shift timer

### Implementation for User Story 3

- [X] T036 [US3] Create ShiftTimerNotifier with 1Hz updates in `gps_tracker/lib/features/shifts/providers/shift_timer_provider.dart`
- [X] T037 [US3] Create ShiftTimer widget with HH:MM:SS display in `gps_tracker/lib/features/shifts/widgets/shift_timer.dart`
- [X] T038 [US3] Integrate ShiftTimer into ShiftStatusCard in `gps_tracker/lib/features/shifts/widgets/shift_status_card.dart`
- [X] T039 [US3] Add app lifecycle handling for timer recalculation in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`
- [X] T040 [US3] Update dashboard to show "ready to start" state when no active shift in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`

**Checkpoint**: User Story 3 complete - real-time shift status display works

---

## Phase 6: User Story 4 - Employee Views Shift History (Priority: P2)

**Goal**: Employee can view past shifts organized by date with pagination

**Independent Test**: Complete multiple shifts, navigate to history, verify all shifts appear with correct data

### Implementation for User Story 4

- [X] T041 [US4] Create ShiftSummary model for history display in `gps_tracker/lib/features/shifts/models/shift_summary.dart`
- [X] T042 [US4] Implement ShiftService.getShiftHistory() with pagination in `gps_tracker/lib/features/shifts/services/shift_service.dart`
- [X] T043 [US4] Create shift_history_provider with paginated loading in `gps_tracker/lib/features/shifts/providers/shift_history_provider.dart`
- [X] T044 [US4] Create ShiftCard widget for history list items in `gps_tracker/lib/features/shifts/widgets/shift_card.dart`
- [X] T045 [US4] Create ShiftHistoryScreen with paginated list in `gps_tracker/lib/features/shifts/screens/shift_history_screen.dart`
- [X] T046 [US4] Add empty state for no shift history in `gps_tracker/lib/features/shifts/screens/shift_history_screen.dart`
- [X] T047 [US4] Create ShiftDetailScreen showing full shift info in `gps_tracker/lib/features/shifts/screens/shift_detail_screen.dart`
- [X] T048 [US4] Add navigation from history list to shift detail in `gps_tracker/lib/features/shifts/screens/shift_history_screen.dart`
- [X] T049 [US4] Add navigation to history from dashboard in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`

**Checkpoint**: User Story 4 complete - shift history browsing works with pagination

---

## Phase 7: User Story 5 - Offline Sync (Priority: P1 - Core Requirement)

**Goal**: Clock-in/out works offline with automatic sync when connectivity returns

**Independent Test**: Enable airplane mode, clock in/out, disable airplane mode, verify data syncs within 30 seconds

### Implementation for User Story 5

- [X] T050 [US5] Create SyncService with pending record processing in `gps_tracker/lib/features/shifts/services/sync_service.dart`
- [X] T051 [US5] Create sync_provider with connectivity listener in `gps_tracker/lib/features/shifts/providers/sync_provider.dart`
- [X] T052 [US5] Implement sync queue processing with retry logic in `gps_tracker/lib/features/shifts/services/sync_service.dart`
- [X] T053 [US5] Add GPS points batch sync to SyncService in `gps_tracker/lib/features/shifts/services/sync_service.dart`
- [X] T054 [US5] Update SyncStatusIndicator to show pending/syncing/error states in `gps_tracker/lib/features/shifts/widgets/sync_status_indicator.dart`
- [X] T055 [US5] Add sync error toast notifications in `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`
- [X] T056 [US5] Initialize SyncService on app startup in `gps_tracker/lib/main.dart`

**Checkpoint**: User Story 5 complete - offline-first architecture fully functional

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Final improvements and integration

- [X] T057 Implement active shift recovery on app launch in `gps_tracker/lib/features/shifts/providers/shift_provider.dart`
- [X] T058 Add shift feature barrel export file in `gps_tracker/lib/features/shifts/shifts.dart`
- [X] T059 Update home screen to integrate shift dashboard in `gps_tracker/lib/features/home/screens/home_screen.dart`
- [X] T060 Run flutter analyze and fix any linting issues
- [X] T061 Run quickstart.md verification checklist
- [X] T062 Verify all acceptance scenarios from spec.md pass manual testing

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phase 3-7)**: All depend on Foundational phase completion
  - US1 (Clock In): Can start after Phase 2
  - US2 (Clock Out): Depends on US1 (needs active shift to exist)
  - US3 (Status Display): Depends on US1 (needs shift timer to show)
  - US4 (History): Depends on US2 (needs completed shifts to display)
  - US5 (Offline Sync): Can start after Phase 2, integrates with US1/US2
- **Polish (Phase 8)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Foundation only - can proceed independently
- **User Story 2 (P1)**: Requires US1 clock-in to exist for clock-out testing
- **User Story 3 (P1)**: Requires US1 for active shift state
- **User Story 4 (P2)**: Requires US2 for completed shifts to show in history
- **User Story 5 (P1)**: Foundation only - can run in parallel with US1-US4

### Within Each User Story

- Models before services
- Services before providers
- Providers before widgets
- Widgets before screens
- Core implementation before integration

### Parallel Opportunities

**Phase 1**: T002-T006 can all run in parallel (directory creation)

**Phase 2**: After T007-T012 models complete:
- T013 (LocalDatabase) can proceed
- T015 (LocationService) can proceed
- T017 (ConnectivityService) can proceed

**Phase 3-7**: Once foundational phase completes:
- US1 and US5 can start in parallel
- US2 starts after US1 clock-in implemented
- US3 starts after US1 shift state exists
- US4 can run parallel to US3

---

## Parallel Example: Phase 2 Models

```bash
# Launch all model tasks together:
Task: "Create GeoPoint value object model in gps_tracker/lib/features/shifts/models/geo_point.dart"
Task: "Create ShiftStatus and SyncStatus enums in gps_tracker/lib/features/shifts/models/shift_enums.dart"
Task: "Create Shift model with fromJson/toJson in gps_tracker/lib/features/shifts/models/shift.dart"
Task: "Create LocalShift model for SQLite in gps_tracker/lib/features/shifts/models/local_shift.dart"
```

---

## Implementation Strategy

### MVP First (User Stories 1-3 + 5)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL - blocks all stories)
3. Complete Phase 3: User Story 1 (Clock In)
4. Complete Phase 7: User Story 5 (Offline Sync) - in parallel
5. Complete Phase 4: User Story 2 (Clock Out)
6. Complete Phase 5: User Story 3 (Status Display)
7. **STOP and VALIDATE**: Test MVP independently (clock in, view timer, clock out, verify offline works)
8. Deploy/demo if ready

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add US1 (Clock In) → Test clock-in works → Demo
3. Add US5 (Offline Sync) → Test offline clock-in → Demo
4. Add US2 (Clock Out) → Test complete shift cycle → Demo
5. Add US3 (Status Display) → Test real-time timer → Demo
6. Add US4 (History) → Test history browsing → Deploy
7. Polish phase → Final QA → Release

### Single Developer Execution Order

For sequential implementation:
1. T001-T006 (Setup)
2. T007-T018 (Foundational)
3. T019-T028 (US1: Clock In)
4. T050-T056 (US5: Offline - can be interleaved)
5. T029-T035 (US2: Clock Out)
6. T036-T040 (US3: Status Display)
7. T041-T049 (US4: History)
8. T057-T062 (Polish)

---

## Notes

- All times stored in UTC, displayed in local timezone (FR-013)
- Local SQLite is source of truth per research.md decision
- GPS capture only at clock-in/out moments (battery conscious per Constitution II)
- Location permission required before clock-in (FR-011)
- Request ID (UUID) used for idempotent sync operations
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
