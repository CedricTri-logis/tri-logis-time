# Tasks: Offline Resilience

**Input**: Design documents from `/specs/005-offline-resilience/`
**Prerequisites**: plan.md ✓, spec.md ✓, research.md ✓, data-model.md ✓, contracts/sync-api.md ✓, quickstart.md ✓

**Tests**: Not explicitly requested in specification - test tasks omitted.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Database Infrastructure)

**Purpose**: Create database tables and models required for offline resilience

- [X] T001 Add sync_metadata table migration to gps_tracker/lib/shared/services/local_database.dart
- [X] T002 Add quarantined_records table migration to gps_tracker/lib/shared/services/local_database.dart
- [X] T003 Add sync_log_entries table migration to gps_tracker/lib/shared/services/local_database.dart
- [X] T004 Add storage_metrics table migration to gps_tracker/lib/shared/services/local_database.dart

---

## Phase 2: Foundational (Core Models & Services)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T005 [P] Create SyncMetadata model in gps_tracker/lib/features/shifts/models/sync_metadata.dart
- [X] T006 [P] Create QuarantinedRecord model in gps_tracker/lib/features/shifts/models/quarantined_record.dart
- [X] T007 [P] Create SyncLogEntry model in gps_tracker/lib/features/shifts/models/sync_log_entry.dart
- [X] T008 [P] Create StorageMetrics model in gps_tracker/lib/features/shifts/models/storage_metrics.dart
- [X] T009 [P] Create SyncProgress model in gps_tracker/lib/features/shifts/models/sync_progress.dart
- [X] T010 [P] Create SyncResult model in gps_tracker/lib/features/shifts/models/sync_result.dart
- [X] T011 [P] Create SyncException and SyncErrorCode in gps_tracker/lib/features/shifts/models/sync_exception.dart
- [X] T012 Add SyncMetadata CRUD operations to gps_tracker/lib/shared/services/local_database.dart
- [X] T013 Add QuarantinedRecord CRUD operations to gps_tracker/lib/shared/services/local_database.dart
- [X] T014 Add SyncLogEntry CRUD operations with rotation to gps_tracker/lib/shared/services/local_database.dart
- [X] T015 Add StorageMetrics CRUD operations to gps_tracker/lib/shared/services/local_database.dart
- [X] T016 Create SyncLogger service in gps_tracker/lib/features/shifts/services/sync_logger.dart
- [X] T017 Create ExponentialBackoff strategy in gps_tracker/lib/features/shifts/services/backoff_strategy.dart

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - Seamless Work During Network Outages (Priority: P1) 🎯 MVP

**Goal**: Employees can clock in, track GPS, and clock out without interruption regardless of network connectivity

**Independent Test**: Enable airplane mode, perform complete shift (clock in, let tracking run, clock out), verify all data captured correctly before restoring connectivity

### Implementation for User Story 1

- [X] T018 [US1] Enhance SyncState with persistence fields (progress, consecutiveFailures, nextRetryIn) in gps_tracker/lib/features/shifts/providers/sync_provider.dart
- [X] T019 [US1] Add SyncState.fromMetadata and toMetadata methods for persistence in gps_tracker/lib/features/shifts/providers/sync_provider.dart
- [X] T020 [US1] Implement sync state load on app startup in gps_tracker/lib/features/shifts/providers/sync_provider.dart
- [X] T021 [US1] Implement sync state persist on state changes in gps_tracker/lib/features/shifts/providers/sync_provider.dart
- [X] T022 [US1] Ensure ShiftService clock-in works offline with local UUID v4 assignment in gps_tracker/lib/features/shifts/services/shift_service.dart
- [X] T023 [US1] Ensure ShiftService clock-out works offline with local storage in gps_tracker/lib/features/shifts/services/shift_service.dart
- [X] T024 [US1] Verify GPS tracking continues during offline mode (no changes needed - audit only) in gps_tracker/lib/features/tracking/services/gps_tracking_handler.dart

**Checkpoint**: User Story 1 complete - offline shift operations work seamlessly

---

## Phase 4: User Story 2 - Automatic Data Synchronization (Priority: P1)

**Goal**: When connectivity is restored, all accumulated shifts and GPS points upload automatically

**Independent Test**: Accumulate offline data, restore connectivity, verify all data syncs automatically within 30 seconds

### Implementation for User Story 2

- [X] T025 [US2] Add exponential backoff with jitter to sync retry logic in gps_tracker/lib/features/shifts/services/sync_service.dart
- [X] T026 [US2] Add sync progress tracking with SyncProgress emission in gps_tracker/lib/features/shifts/services/sync_service.dart
- [X] T027 [US2] Add progressStream getter to SyncService in gps_tracker/lib/features/shifts/services/sync_service.dart
- [X] T028 [US2] Implement resumable batch sync (track last synced batch) in gps_tracker/lib/features/shifts/services/sync_service.dart
- [X] T029 [US2] Add connectivity listener to trigger sync within 30 seconds of reconnect in gps_tracker/lib/features/shifts/providers/sync_provider.dart
- [X] T030 [US2] Add sync-on-app-launch when connectivity available in gps_tracker/lib/main.dart
- [X] T031 [US2] Integrate SyncLogger calls for sync operations in gps_tracker/lib/features/shifts/services/sync_service.dart
- [X] T032 [US2] Add backoff state persistence across app restarts in gps_tracker/lib/features/shifts/services/sync_service.dart

**Checkpoint**: User Story 2 complete - automatic sync works reliably

---

## Phase 5: User Story 3 - Extended Offline Operation (Priority: P1)

**Goal**: System can operate offline for 7+ days, with storage monitoring and warnings

**Independent Test**: Simulate extended offline operation with high data volumes, verify storage capacity and data integrity

### Implementation for User Story 3

- [X] T033 [P] [US3] Create StorageMonitor service in gps_tracker/lib/features/shifts/services/storage_monitor.dart
- [X] T034 [US3] Implement calculateMetrics method with table size calculation in gps_tracker/lib/features/shifts/services/storage_monitor.dart
- [X] T035 [US3] Implement storage warning detection at 80% threshold in gps_tracker/lib/features/shifts/services/storage_monitor.dart
- [X] T036 [US3] Implement storage critical detection at 95% threshold in gps_tracker/lib/features/shifts/services/storage_monitor.dart
- [X] T037 [US3] Implement freeStorage method with pruning of old synced data in gps_tracker/lib/features/shifts/services/storage_monitor.dart
- [X] T038 [P] [US3] Create storageMonitorProvider in gps_tracker/lib/features/shifts/providers/storage_provider.dart
- [X] T039 [US3] Add storage warning check on data write operations in gps_tracker/lib/shared/services/local_database.dart
- [X] T040 [US3] Integrate storage monitoring with sync operations in gps_tracker/lib/features/shifts/services/sync_service.dart

**Checkpoint**: User Story 3 complete - extended offline operation with storage monitoring works

---

## Phase 6: User Story 4 - Sync Status Visibility (Priority: P2)

**Goal**: Users can see sync status including pending counts, last sync time, and any issues

**Independent Test**: Accumulate offline data, verify sync status display shows accurate counts and timestamps

### Implementation for User Story 4

- [X] T041 [P] [US4] Enhance SyncStatusIndicator with progress display and badge in gps_tracker/lib/features/shifts/widgets/sync_status_indicator.dart
- [X] T042 [P] [US4] Create SyncDetailSheet widget in gps_tracker/lib/features/shifts/widgets/sync_detail_sheet.dart
- [X] T043 [US4] Add last sync timestamp display to SyncDetailSheet in gps_tracker/lib/features/shifts/widgets/sync_detail_sheet.dart
- [X] T044 [US4] Add pending counts display to SyncDetailSheet in gps_tracker/lib/features/shifts/widgets/sync_detail_sheet.dart
- [X] T045 [US4] Add progress bar during active sync to SyncDetailSheet in gps_tracker/lib/features/shifts/widgets/sync_detail_sheet.dart
- [X] T046 [US4] Add error message display with remediation hints to SyncDetailSheet in gps_tracker/lib/features/shifts/widgets/sync_detail_sheet.dart
- [X] T047 [US4] Add manual "Sync Now" button to SyncDetailSheet in gps_tracker/lib/features/shifts/widgets/sync_detail_sheet.dart
- [X] T048 [US4] Add tap-to-open detail sheet gesture to SyncStatusIndicator in gps_tracker/lib/features/shifts/widgets/sync_status_indicator.dart
- [X] T049 [P] [US4] Create StorageWarningBanner widget in gps_tracker/lib/features/shifts/widgets/storage_warning_banner.dart
- [X] T050 [US4] Integrate StorageWarningBanner into shift dashboard in gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart

**Checkpoint**: User Story 4 complete - sync status visibility works

---

## Phase 7: User Story 5 - Conflict Resolution (Priority: P2)

**Goal**: System handles data conflicts gracefully using timestamp-based resolution and idempotency keys

**Independent Test**: Create intentional conflicts (same shift ID on local and server with different data), verify resolution behavior

### Implementation for User Story 5

- [X] T051 [P] [US5] Create QuarantineService in gps_tracker/lib/features/shifts/services/quarantine_service.dart
- [X] T052 [US5] Implement quarantineShift method in gps_tracker/lib/features/shifts/services/quarantine_service.dart
- [X] T053 [US5] Implement quarantineGpsPoint method in gps_tracker/lib/features/shifts/services/quarantine_service.dart
- [X] T054 [US5] Implement getPendingRecords method in gps_tracker/lib/features/shifts/services/quarantine_service.dart
- [X] T055 [US5] Implement resolveRecord and discardRecord methods in gps_tracker/lib/features/shifts/services/quarantine_service.dart
- [X] T056 [US5] Add timestamp-based conflict resolution to shift sync in gps_tracker/lib/features/shifts/services/sync_service.dart
- [X] T057 [US5] Add idempotency key (request_id/client_id) validation to prevent duplicates in gps_tracker/lib/features/shifts/services/sync_service.dart
- [X] T058 [US5] Integrate quarantine service for validation errors during sync in gps_tracker/lib/features/shifts/services/sync_service.dart
- [X] T059 [US5] Add quarantine stats to SyncDetailSheet in gps_tracker/lib/features/shifts/widgets/sync_detail_sheet.dart

**Checkpoint**: User Story 5 complete - conflict resolution and quarantine work

---

## Phase 8: User Story 6 - Network-Aware Battery Optimization (Priority: P3)

**Goal**: Intelligent sync behavior that considers network quality to optimize battery usage

**Independent Test**: Monitor sync behavior and battery usage under various network conditions

### Implementation for User Story 6

- [X] T060 [US6] Add HTTP response code handling for quality assessment in gps_tracker/lib/features/shifts/services/sync_service.dart
- [X] T061 [US6] Implement extended backoff for HTTP 429 (rate limit) responses in gps_tracker/lib/features/shifts/services/sync_service.dart
- [X] T062 [US6] Add retry decision logic based on error type and attempt count in gps_tracker/lib/features/shifts/services/sync_service.dart
- [X] T063 [US6] Add battery level check before large sync operations (optional defer) in gps_tracker/lib/features/shifts/services/sync_service.dart

**Checkpoint**: User Story 6 complete - network-aware battery optimization works

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

- [X] T064 [P] Add log rotation trigger on app startup in gps_tracker/lib/main.dart
- [X] T065 [P] Add export logs functionality for support purposes in gps_tracker/lib/features/shifts/services/sync_logger.dart
- [X] T066 Validate all sync operations use transactions for atomicity in gps_tracker/lib/shared/services/local_database.dart
- [X] T067 Add comprehensive error handling for edge cases in gps_tracker/lib/features/shifts/services/sync_service.dart
- [X] T068 Run quickstart.md validation scenarios

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phase 3-8)**: All depend on Foundational phase completion
  - US1, US2, US3 are all P1 priority - should be completed in sequence
  - US4 and US5 are P2 priority - can proceed after P1 stories
  - US6 is P3 priority - final user story
- **Polish (Phase 9)**: Depends on all desired user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational (Phase 2) - Foundation for offline work
- **User Story 2 (P1)**: Depends on US1 - Builds on offline state to add auto-sync
- **User Story 3 (P1)**: Depends on US1/US2 - Adds storage monitoring to existing sync
- **User Story 4 (P2)**: Depends on US1/US2 - Adds UI visibility to sync state
- **User Story 5 (P2)**: Depends on US2 - Adds conflict handling to sync
- **User Story 6 (P3)**: Depends on US2 - Adds battery optimization to sync

### Within Each User Story

- Models before services (if any new models in story)
- Services before providers
- Providers before UI widgets
- Core implementation before integration

### Parallel Opportunities

**Phase 1 (Setup)**: T001-T004 must be sequential (same file)

**Phase 2 (Foundational)**:
- T005-T011 can run in parallel (different model files)
- T012-T015 must be sequential (same file - local_database.dart)
- T016-T017 can run in parallel (different service files)

**Phase 3 (US1)**: T018-T024 mostly sequential (provider dependencies)

**Phase 4 (US2)**: T025-T032 mostly sequential (sync_service.dart)

**Phase 5 (US3)**: T033-T034 can start in parallel, then sequential

**Phase 6 (US4)**: T041-T042-T049 can run in parallel (different widget files)

**Phase 7 (US5)**: T051 can start immediately, then sequential

**Phase 8 (US6)**: T060-T063 sequential (same file)

---

## Parallel Example: Foundational Phase Models

```bash
# Launch all model tasks together (different files):
Task: "Create SyncMetadata model in gps_tracker/lib/features/shifts/models/sync_metadata.dart"
Task: "Create QuarantinedRecord model in gps_tracker/lib/features/shifts/models/quarantined_record.dart"
Task: "Create SyncLogEntry model in gps_tracker/lib/features/shifts/models/sync_log_entry.dart"
Task: "Create StorageMetrics model in gps_tracker/lib/features/shifts/models/storage_metrics.dart"
Task: "Create SyncProgress model in gps_tracker/lib/features/shifts/models/sync_progress.dart"
Task: "Create SyncResult model in gps_tracker/lib/features/shifts/models/sync_result.dart"
Task: "Create SyncException in gps_tracker/lib/features/shifts/models/sync_exception.dart"
```

---

## Implementation Strategy

### MVP First (User Stories 1-3)

1. Complete Phase 1: Setup (database tables)
2. Complete Phase 2: Foundational (models, services)
3. Complete Phase 3: User Story 1 (offline operations)
4. **VALIDATE**: Test offline shift workflow in airplane mode
5. Complete Phase 4: User Story 2 (auto-sync)
6. **VALIDATE**: Test connectivity restore triggers sync
7. Complete Phase 5: User Story 3 (storage monitoring)
8. **VALIDATE**: Test 7-day offline simulation
9. **MVP COMPLETE**: Core offline resilience functional

### Incremental Delivery

1. Setup + Foundational → Infrastructure ready
2. Add User Story 1 → Test independently → Offline-capable
3. Add User Story 2 → Test independently → Auto-sync working
4. Add User Story 3 → Test independently → Storage monitored
5. Add User Story 4 → Test independently → UI visibility
6. Add User Story 5 → Test independently → Conflict handling
7. Add User Story 6 → Test independently → Battery optimized
8. Polish → Full feature complete

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently testable after completion
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- All database operations use SQLCipher for encryption (existing infrastructure)
- Exponential backoff: 30s base, 15min max, with ±10% jitter
- Storage thresholds: 80% warning, 95% critical
- Batch size: 100 GPS points per batch (existing pattern)
