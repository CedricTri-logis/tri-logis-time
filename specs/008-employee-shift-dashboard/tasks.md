# Tasks: Employee & Shift Dashboard

**Input**: Design documents from `/specs/008-employee-shift-dashboard/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: Not explicitly requested in the feature specification. Tests are omitted.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3, US4)
- Include exact file paths in descriptions

## Path Conventions

- **Flutter project**: `gps_tracker/lib/` for source, `gps_tracker/test/` for tests
- **Supabase**: `supabase/migrations/` for database migrations
- Paths are relative to repository root

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization, dependency setup, and dashboard feature structure

- [X] T001 Add fl_chart dependency (^1.1.1) in gps_tracker/pubspec.yaml
- [X] T002 Run flutter pub get to install dependencies
- [X] T003 Create dashboard feature directory structure under gps_tracker/lib/features/dashboard/ (models/, providers/, services/, screens/, widgets/)
- [X] T004 Create barrel export file gps_tracker/lib/features/dashboard/dashboard.dart

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Database migrations, cache infrastructure, and shared models that ALL user stories depend on

**CRITICAL**: No user story work can begin until this phase is complete

- [X] T005 Create Supabase migration for get_dashboard_summary RPC function in supabase/migrations/008_employee_dashboard.sql
- [X] T006 Create Supabase migration for get_team_employee_hours RPC function in supabase/migrations/008_employee_dashboard.sql
- [X] T007 Apply database migration with supabase db push
- [X] T008 [P] Create ShiftStatusInfo model in gps_tracker/lib/features/dashboard/models/dashboard_state.dart
- [X] T009 [P] Create DailyStatistics model in gps_tracker/lib/features/dashboard/models/dashboard_state.dart
- [X] T010 [P] Create EmployeeDashboardState model in gps_tracker/lib/features/dashboard/models/dashboard_state.dart
- [X] T011 [P] Create TeamDashboardState model in gps_tracker/lib/features/dashboard/models/team_dashboard_state.dart
- [X] T012 [P] Create TeamEmployeeStatus model in gps_tracker/lib/features/dashboard/models/employee_work_status.dart
- [X] T013 [P] Create DateRangePreset enum in gps_tracker/lib/features/dashboard/models/team_dashboard_state.dart
- [X] T014 [P] Create TeamStatisticsState model in gps_tracker/lib/features/dashboard/models/team_dashboard_state.dart
- [X] T015 [P] Create EmployeeHoursData model in gps_tracker/lib/features/dashboard/models/team_dashboard_state.dart
- [X] T016 Extend local database with dashboard_cache table in gps_tracker/lib/shared/services/local_database.dart
- [X] T017 [P] Create DashboardCacheService for cache CRUD operations in gps_tracker/lib/features/dashboard/services/dashboard_cache_service.dart
- [X] T018 [P] Create DashboardService for Supabase RPC calls in gps_tracker/lib/features/dashboard/services/dashboard_service.dart

**Checkpoint**: Foundation ready - user story implementation can now begin in parallel

---

## Phase 3: User Story 1 - Employee Views Personal Dashboard (Priority: P1) MVP

**Goal**: Display personalized dashboard with current shift status, live timer, today's/monthly stats, and recent shift history

**Independent Test**: Log in as employee, verify dashboard shows shift status, today's summary, monthly stats, and recent shifts

### Implementation for User Story 1

- [X] T019 [P] [US1] Create LiveShiftTimer widget (1-second updates using Timer) in gps_tracker/lib/features/dashboard/widgets/live_shift_timer.dart
- [X] T020 [P] [US1] Create ShiftStatusTile widget (active/inactive display with clock-in prompt) in gps_tracker/lib/features/dashboard/widgets/shift_status_tile.dart
- [X] T021 [P] [US1] Create DailySummaryCard widget (today's hours and shift count) in gps_tracker/lib/features/dashboard/widgets/daily_summary_card.dart
- [X] T022 [P] [US1] Create MonthlySummaryCard widget (this month's totals) in gps_tracker/lib/features/dashboard/widgets/monthly_summary_card.dart
- [X] T023 [P] [US1] Create RecentShiftsList widget (last 7 days, tappable items) in gps_tracker/lib/features/dashboard/widgets/recent_shifts_list.dart
- [X] T024 [US1] Create DashboardProvider with StateNotifier, WidgetsBindingObserver for foreground refresh in gps_tracker/lib/features/dashboard/providers/dashboard_provider.dart
- [X] T025 [US1] Create EmployeeDashboardScreen with pull-to-refresh, composed widgets in gps_tracker/lib/features/dashboard/screens/employee_dashboard_screen.dart
- [X] T026 [US1] Add navigation from dashboard shift items to detailed shift view in gps_tracker/lib/features/dashboard/screens/employee_dashboard_screen.dart
- [X] T027 [US1] Update home_screen.dart to route employees to EmployeeDashboardScreen in gps_tracker/lib/features/home/home_screen.dart
- [X] T028 [US1] Update barrel export with US1 components in gps_tracker/lib/features/dashboard/dashboard.dart

**Checkpoint**: User Story 1 fully functional - employee can view personal dashboard with all statistics

---

## Phase 4: User Story 2 - Manager Views Team Dashboard (Priority: P2)

**Goal**: Display team overview with all supervised employees, their status, search/filter, and navigation to employee details

**Independent Test**: Log in as manager, verify team dashboard shows all supervised employees with status indicators, search works, and employee tap navigates to history

### Implementation for User Story 2

- [X] T029 [P] [US2] Create TeamEmployeeTile widget (employee row with status badge, today/monthly hours) in gps_tracker/lib/features/dashboard/widgets/team_employee_tile.dart
- [X] T030 [P] [US2] Create TeamSearchBar widget (search/filter by name or ID) in gps_tracker/lib/features/dashboard/widgets/team_search_bar.dart
- [X] T031 [US2] Create TeamDashboardProvider with StateNotifier, client-side filtering in gps_tracker/lib/features/dashboard/providers/team_dashboard_provider.dart
- [X] T032 [US2] Create TeamDashboardScreen with employee list, search bar, active count in gps_tracker/lib/features/dashboard/screens/team_dashboard_screen.dart
- [X] T033 [US2] Add navigation from employee tile to their detailed history screen in gps_tracker/lib/features/dashboard/screens/team_dashboard_screen.dart
- [X] T034 [US2] Update home_screen.dart to show TabBar for manager role (Team/Personal dashboards) in gps_tracker/lib/features/home/home_screen.dart
- [X] T035 [US2] Update barrel export with US2 components in gps_tracker/lib/features/dashboard/dashboard.dart

**Checkpoint**: User Story 2 fully functional - manager can view team, search employees, navigate to details

---

## Phase 5: User Story 3 - Manager Views Team Statistics (Priority: P3)

**Goal**: Display aggregate team statistics with date range filtering and bar chart visualization

**Independent Test**: Log in as manager, navigate to team statistics, verify aggregate metrics and bar chart display correctly for different date ranges

### Implementation for User Story 3

- [X] T036 [P] [US3] Create DateRangePicker widget with presets (Today, This Week, This Month, Custom) in gps_tracker/lib/features/dashboard/widgets/date_range_picker.dart
- [X] T037 [P] [US3] Create TeamHoursChart widget using fl_chart (horizontal bar chart per employee) in gps_tracker/lib/features/dashboard/widgets/team_hours_chart.dart
- [X] T038 [US3] Create TeamStatisticsProvider with StateNotifier, date range state management in gps_tracker/lib/features/dashboard/providers/team_statistics_provider.dart
- [X] T039 [US3] Create TeamStatisticsScreen with aggregate metrics, date picker, bar chart in gps_tracker/lib/features/dashboard/screens/team_statistics_screen.dart
- [X] T040 [US3] Add navigation from team dashboard to statistics screen in gps_tracker/lib/features/dashboard/screens/team_dashboard_screen.dart
- [X] T041 [US3] Update barrel export with US3 components in gps_tracker/lib/features/dashboard/dashboard.dart

**Checkpoint**: User Story 3 fully functional - manager can view and filter team statistics with visualization

---

## Phase 6: User Story 4 - Employee Sees Sync Status (Priority: P4)

**Goal**: Display sync status indicator showing pending, synced, or error states for data synchronization

**Independent Test**: Create local shifts while offline, verify sync indicator shows pending; go online and verify indicator updates to synced; simulate error and verify error state displays

### Implementation for User Story 4

- [X] T042 [P] [US4] Create SyncStatusBadge widget (pending/synced/error display with counts) in gps_tracker/lib/features/dashboard/widgets/sync_status_badge.dart
- [X] T043 [US4] Integrate SyncStatusBadge into EmployeeDashboardScreen in gps_tracker/lib/features/dashboard/screens/employee_dashboard_screen.dart
- [X] T044 [US4] Add sync status to DashboardProvider state (reuse existing SyncState from shifts) in gps_tracker/lib/features/dashboard/providers/dashboard_provider.dart
- [X] T045 [US4] Add retry action for sync errors on SyncStatusBadge in gps_tracker/lib/features/dashboard/widgets/sync_status_badge.dart
- [X] T046 [US4] Update barrel export with US4 components in gps_tracker/lib/features/dashboard/dashboard.dart

**Checkpoint**: User Story 4 fully functional - employee sees sync status with pending count and error handling

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Empty states, error handling, offline caching, and performance optimization

- [X] T047 [P] Add empty state for new employees with no shift history in gps_tracker/lib/features/dashboard/screens/employee_dashboard_screen.dart
- [X] T048 [P] Add empty state for managers with no supervised employees in gps_tracker/lib/features/dashboard/screens/team_dashboard_screen.dart
- [X] T049 [P] Add error state with retry option for failed data loads in gps_tracker/lib/features/dashboard/screens/employee_dashboard_screen.dart
- [X] T050 [P] Add "last updated" timestamp display when showing cached data offline in gps_tracker/lib/features/dashboard/widgets/shift_status_tile.dart
- [X] T051 Implement dashboard cache loading on DashboardService initialization in gps_tracker/lib/features/dashboard/providers/dashboard_provider.dart
- [X] T052 Implement dashboard cache writing after successful API fetch in gps_tracker/lib/features/dashboard/providers/dashboard_provider.dart
- [X] T053 Implement expired cache cleanup (7-day TTL) in DashboardCacheService in gps_tracker/lib/features/dashboard/services/dashboard_cache_service.dart
- [X] T054 Run quickstart.md verification checklist to validate all success criteria

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phase 3-6)**: All depend on Foundational phase completion
  - User stories can proceed in parallel (if staffed)
  - Or sequentially in priority order (P1 → P2 → P3 → P4)
- **Polish (Phase 7)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational (Phase 2) - No dependencies on other stories
- **User Story 2 (P2)**: Can start after Foundational (Phase 2) - No dependencies on US1, independently testable
- **User Story 3 (P3)**: Can start after Foundational (Phase 2) - Shares team_dashboard_state.dart models but is independently testable
- **User Story 4 (P4)**: Can start after Foundational (Phase 2) - Integrates with US1's DashboardProvider but adds new widget

### Within Each User Story

- Widgets marked [P] before providers (providers compose widgets)
- Providers before screens
- Screens before navigation integration
- Story complete before moving to next priority

### Parallel Opportunities

- T008-T018 (Foundational models/services) can all run in parallel
- T019-T023 (US1 widgets) can all run in parallel
- T029-T030 (US2 widgets) can run in parallel
- T036-T037 (US3 widgets) can run in parallel
- T042 (US4 widget) can run in parallel with other US4 prep
- T047-T050 (Polish) can all run in parallel

---

## Parallel Example: Foundational Phase

```bash
# Launch all models in parallel:
Task: "Create ShiftStatusInfo model in gps_tracker/lib/features/dashboard/models/dashboard_state.dart"
Task: "Create DailyStatistics model in gps_tracker/lib/features/dashboard/models/dashboard_state.dart"
Task: "Create EmployeeDashboardState model in gps_tracker/lib/features/dashboard/models/dashboard_state.dart"
Task: "Create TeamDashboardState model in gps_tracker/lib/features/dashboard/models/team_dashboard_state.dart"
Task: "Create TeamEmployeeStatus model in gps_tracker/lib/features/dashboard/models/employee_work_status.dart"
Task: "Create DateRangePreset enum in gps_tracker/lib/features/dashboard/models/team_dashboard_state.dart"
Task: "Create TeamStatisticsState model in gps_tracker/lib/features/dashboard/models/team_dashboard_state.dart"
Task: "Create EmployeeHoursData model in gps_tracker/lib/features/dashboard/models/team_dashboard_state.dart"
```

## Parallel Example: User Story 1 Widgets

```bash
# Launch all US1 widgets in parallel:
Task: "Create LiveShiftTimer widget in gps_tracker/lib/features/dashboard/widgets/live_shift_timer.dart"
Task: "Create ShiftStatusTile widget in gps_tracker/lib/features/dashboard/widgets/shift_status_tile.dart"
Task: "Create DailySummaryCard widget in gps_tracker/lib/features/dashboard/widgets/daily_summary_card.dart"
Task: "Create MonthlySummaryCard widget in gps_tracker/lib/features/dashboard/widgets/monthly_summary_card.dart"
Task: "Create RecentShiftsList widget in gps_tracker/lib/features/dashboard/widgets/recent_shifts_list.dart"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL - blocks all stories)
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: Test employee dashboard independently
5. Deploy/demo if ready

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add User Story 1 → Test independently → Deploy/Demo (MVP!)
3. Add User Story 2 → Test independently → Deploy/Demo
4. Add User Story 3 → Test independently → Deploy/Demo
5. Add User Story 4 → Test independently → Deploy/Demo
6. Complete Polish phase → Final validation

### Parallel Team Strategy

With multiple developers:

1. Team completes Setup + Foundational together
2. Once Foundational is done:
   - Developer A: User Story 1 (Employee Dashboard)
   - Developer B: User Story 2 (Team Dashboard)
   - Developer C: User Story 3 (Team Statistics)
3. User Story 4 can be added to any story after US1 base is done
4. Stories complete and integrate independently

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- Models in same file (T008-T010) should be in one task or split by class
- Live timer uses Timer pattern from existing shift_timer.dart (see research.md)
- fl_chart 1.1.1 for bar charts (see research.md)
- Cache TTL is 7 days (matches display window per spec)
