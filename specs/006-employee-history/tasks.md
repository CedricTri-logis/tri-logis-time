# Tasks: Employee History

**Input**: Design documents from `/specs/006-employee-history/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: Not explicitly requested in the feature specification.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Flutter project**: `gps_tracker/lib/` for source, `gps_tracker/test/` for tests
- **Supabase**: `supabase/migrations/` for database migrations

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization, dependencies, and database schema

- [X] T001 Create database migration file at supabase/migrations/006_employee_history.sql with role column, employee_supervisors table, indexes, and RLS policies
- [X] T002 Add new dependencies to gps_tracker/pubspec.yaml (google_maps_flutter, pdf, printing, csv, share_plus)
- [X] T003 [P] Configure Google Maps API key in android/app/src/main/AndroidManifest.xml
- [X] T004 [P] Configure Google Maps API key in ios/Runner/AppDelegate.swift
- [X] T005 Create history feature directory structure at gps_tracker/lib/features/history/

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core models and infrastructure that MUST be complete before ANY user story can be implemented

**CRITICAL**: No user story work can begin until this phase is complete

- [X] T006 Create UserRole enum in gps_tracker/lib/shared/models/user_role.dart
- [X] T007 Update EmployeeProfile model to add role field in gps_tracker/lib/features/auth/models/employee_profile.dart
- [X] T008 [P] Create SupervisionRecord model in gps_tracker/lib/features/history/models/supervision_record.dart
- [X] T009 [P] Create EmployeeSummary model in gps_tracker/lib/features/history/models/employee_summary.dart
- [X] T010 [P] Create ShiftHistoryFilter model in gps_tracker/lib/features/history/models/shift_history_filter.dart
- [X] T011 [P] Create HistoryStatistics model in gps_tracker/lib/features/history/models/history_statistics.dart
- [X] T012 Create HistoryService for Supabase RPC calls in gps_tracker/lib/features/history/services/history_service.dart
- [X] T013 Create barrel export file in gps_tracker/lib/features/history/history.dart

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - Manager Views Employee Shift History (Priority: P1)

**Goal**: Enable managers to view a list of supervised employees and access their complete shift history with clock-in/out times, durations, and locations.

**Independent Test**: Log in as a manager, select an employee, verify complete shift history displays with accurate timestamps and locations.

### Implementation for User Story 1

- [X] T014 [US1] Create SupervisedEmployeesProvider in gps_tracker/lib/features/history/providers/supervised_employees_provider.dart
- [X] T015 [US1] Create EmployeeHistoryProvider in gps_tracker/lib/features/history/providers/employee_history_provider.dart
- [X] T016 [P] [US1] Create EmployeeListTile widget in gps_tracker/lib/features/history/widgets/employee_list_tile.dart
- [X] T017 [P] [US1] Create ShiftHistoryCard widget in gps_tracker/lib/features/history/widgets/shift_history_card.dart
- [X] T018 [US1] Create SupervisedEmployeesScreen in gps_tracker/lib/features/history/screens/supervised_employees_screen.dart
- [X] T019 [US1] Create EmployeeHistoryScreen with shift list in gps_tracker/lib/features/history/screens/employee_history_screen.dart
- [X] T020 [US1] Create ShiftDetailScreen with clock times and locations in gps_tracker/lib/features/history/screens/shift_detail_screen.dart
- [X] T021 [US1] Add navigation to Employee History from manager home screen (update existing home screen)
- [X] T022 [US1] Add history feature routes to app navigation in gps_tracker/lib/app.dart

**Checkpoint**: At this point, User Story 1 should be fully functional and testable independently

---

## Phase 4: User Story 2 - Manager Filters and Searches History (Priority: P1)

**Goal**: Allow managers to filter shift history by date range and search employees by name for efficient data retrieval.

**Independent Test**: Apply various filters (date range, employee name) and verify results accurately reflect the filter criteria.

### Implementation for User Story 2

- [X] T023 [US2] Create HistoryFilterProvider for filter state in gps_tracker/lib/features/history/providers/history_filter_provider.dart
- [X] T024 [US2] Create HistoryFilterBar widget with date range picker and search in gps_tracker/lib/features/history/widgets/history_filter_bar.dart
- [X] T025 [US2] Integrate HistoryFilterBar into SupervisedEmployeesScreen for employee search
- [X] T026 [US2] Integrate HistoryFilterBar into EmployeeHistoryScreen for date range filtering
- [X] T027 [US2] Add filter clear functionality to HistoryFilterBar widget

**Checkpoint**: At this point, User Stories 1 AND 2 should both work independently

---

## Phase 5: User Story 3 - Manager Exports History Data (Priority: P2)

**Goal**: Enable managers to export shift history data in CSV or PDF format for payroll processing and compliance documentation.

**Independent Test**: Select employees and date ranges, export data, verify the exported file contains accurate and complete information.

### Implementation for User Story 3

- [X] T028 [US3] Create ExportService for CSV generation in gps_tracker/lib/features/history/services/export_service.dart
- [X] T029 [US3] Add PDF generation to ExportService using pdf package
- [X] T030 [P] [US3] Create ExportDialog widget for format selection in gps_tracker/lib/features/history/widgets/export_dialog.dart
- [X] T031 [US3] Integrate export functionality into EmployeeHistoryScreen with export button
- [X] T032 [US3] Add file sharing capability using share_plus for exported files

**Checkpoint**: At this point, User Stories 1, 2, AND 3 should all work independently

---

## Phase 6: User Story 4 - Manager Views Shift Summary Statistics (Priority: P2)

**Goal**: Provide managers with aggregate statistics including total hours, shift count, and average duration for individuals or their team.

**Independent Test**: Select a time period and employees, verify calculated statistics accurately reflect underlying shift data.

### Implementation for User Story 4

- [X] T033 [US4] Create StatisticsService for calculating and fetching stats in gps_tracker/lib/features/history/services/statistics_service.dart
- [X] T034 [US4] Create HistoryStatisticsProvider in gps_tracker/lib/features/history/providers/history_statistics_provider.dart
- [X] T035 [P] [US4] Create StatisticsCard widget for displaying metrics in gps_tracker/lib/features/history/widgets/statistics_card.dart
- [X] T036 [US4] Create StatisticsScreen for individual and team stats in gps_tracker/lib/features/history/screens/statistics_screen.dart
- [X] T037 [US4] Add navigation to StatisticsScreen from EmployeeHistoryScreen
- [X] T038 [US4] Add drill-down capability from statistics to specific shifts

**Checkpoint**: At this point, User Stories 1-4 should all work independently

---

## Phase 7: User Story 5 - Manager Views Shift Location Details (Priority: P3)

**Goal**: Allow managers to view clock-in/out locations and GPS routes on a map for shift verification.

**Independent Test**: View a shift with GPS data and verify the map accurately shows locations recorded during that shift.

### Implementation for User Story 5

- [X] T039 [US5] Create GpsRouteMap widget using google_maps_flutter in gps_tracker/lib/features/history/widgets/gps_route_map.dart
- [X] T040 [US5] Add GPS point fetching to HistoryService for shift routes
- [X] T041 [US5] Integrate GpsRouteMap into ShiftDetailScreen
- [X] T042 [US5] Add marker tap handling to show timestamp for each GPS point
- [X] T043 [US5] Handle shifts with no GPS data (display message with clock-in/out locations only)

**Checkpoint**: At this point, User Stories 1-5 should all work independently

---

## Phase 8: User Story 6 - Employee Views Own Enhanced History (Priority: P3)

**Goal**: Allow employees to access their own enhanced history with filtering, statistics, and export capabilities.

**Independent Test**: Log in as an employee, access enhanced history, verify all self-service features work correctly with data limited to their own shifts.

### Implementation for User Story 6

- [X] T044 [US6] Add employee self-history access to HistoryService (reuse existing RPC with auth.uid())
- [X] T045 [US6] Create employee history entry point (adapt SupervisedEmployeesScreen or skip to own history)
- [X] T046 [US6] Add enhanced history access to employee home/profile screen
- [X] T047 [US6] Verify all filtering, statistics, and export features work for employee self-service

**Checkpoint**: All user stories should now be independently functional

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

- [X] T048 [P] Add loading states and error handling across all history screens
- [X] T049 [P] Add offline support indicators for history viewing (synced data only)
- [X] T050 [P] Implement pagination with infinite scroll for shift lists
- [X] T051 Add timezone display indicator to all timestamp displays
- [X] T052 Verify RLS policies work correctly for all access patterns
- [X] T053 Run quickstart.md verification checklist

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phase 3-8)**: All depend on Foundational phase completion
  - User stories can proceed in priority order (P1 first)
  - US1 and US2 are both P1 but can be parallelized after US1 core screens exist
- **Polish (Phase 9)**: Depends on all desired user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational (Phase 2) - No dependencies on other stories
- **User Story 2 (P1)**: Depends on US1 screens existing (adds filter functionality to them)
- **User Story 3 (P2)**: Depends on US1 (exports from history screen) - independent of US2
- **User Story 4 (P2)**: Depends on US1 (statistics for viewed employees) - independent of US2/US3
- **User Story 5 (P3)**: Depends on US1 (adds map to shift detail screen) - independent of US2/US3/US4
- **User Story 6 (P3)**: Depends on US1-US4 infrastructure (reuses all components for self-service)

### Within Each User Story

- Providers before screens
- Widgets before screens that use them
- Services before providers that call them
- Core implementation before integration

### Parallel Opportunities

**Phase 1 (Setup)**:
- T003 and T004 (Google Maps config for Android/iOS) can run in parallel

**Phase 2 (Foundational)**:
- T008, T009, T010, T011 (model files) can run in parallel after T006/T007

**Phase 3 (US1)**:
- T016 and T017 (widgets) can run in parallel

**Phase 5 (US3)**:
- T030 (ExportDialog) can run in parallel with T028/T029 (ExportService)

**Phase 9 (Polish)**:
- T048, T049, T050 can run in parallel

---

## Parallel Example: User Story 1 Widgets

```bash
# Launch all widgets for User Story 1 together:
Task: "Create EmployeeListTile widget in gps_tracker/lib/features/history/widgets/employee_list_tile.dart"
Task: "Create ShiftHistoryCard widget in gps_tracker/lib/features/history/widgets/shift_history_card.dart"
```

---

## Parallel Example: Foundational Models

```bash
# Launch all models in parallel (after T006/T007):
Task: "Create SupervisionRecord model in gps_tracker/lib/features/history/models/supervision_record.dart"
Task: "Create EmployeeSummary model in gps_tracker/lib/features/history/models/employee_summary.dart"
Task: "Create ShiftHistoryFilter model in gps_tracker/lib/features/history/models/shift_history_filter.dart"
Task: "Create HistoryStatistics model in gps_tracker/lib/features/history/models/history_statistics.dart"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (database, dependencies, structure)
2. Complete Phase 2: Foundational (models, core service)
3. Complete Phase 3: User Story 1 (manager views history)
4. **STOP and VALIDATE**: Test User Story 1 independently
5. Deploy/demo if ready - managers can view employee shift history!

### Recommended Delivery Sequence

1. **MVP**: Setup + Foundational + US1 = Core history viewing
2. **Iteration 1**: Add US2 = Filtering and search capability
3. **Iteration 2**: Add US3 = Export functionality (CSV/PDF)
4. **Iteration 3**: Add US4 = Statistics dashboard
5. **Iteration 4**: Add US5 = GPS route visualization
6. **Iteration 5**: Add US6 = Employee self-service
7. **Final**: Polish phase for cross-cutting improvements

---

## Notes

- [P] tasks = different files, no dependencies within the phase
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- Database migration (T001) contains all RPC functions defined in contracts/supabase-api.md
- Google Maps API key must be obtained from Google Cloud Console before T003/T004
