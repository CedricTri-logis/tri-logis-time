# Tasks: GPS Visualization

**Input**: Design documents from `/specs/012-gps-visualization/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/rpc-functions.md

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3, US4)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and shared types/utilities

- [x] T001 Create TypeScript types for historical GPS visualization in `dashboard/src/types/history.ts`
- [x] T002 [P] Create Zod validation schemas for history feature in `dashboard/src/lib/validations/history.ts`
- [x] T003 [P] Implement Haversine distance calculation utility in `dashboard/src/lib/utils/distance.ts`
- [x] T004 [P] Implement Douglas-Peucker trail simplification in `dashboard/src/lib/utils/trail-simplify.ts`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Database RPC functions and data hooks that ALL user stories depend on

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T005 Create database migration with all 4 RPC functions in `supabase/migrations/013_gps_visualization.sql`
- [x] T006 [P] Implement useHistoricalTrail hook for single shift GPS data in `dashboard/src/lib/hooks/use-historical-gps.ts`
- [x] T007 [P] Implement useShiftHistory hook for shift list with filters in `dashboard/src/lib/hooks/use-historical-gps.ts`
- [x] T008 [P] Implement useSupervisedEmployees hook for employee dropdown in `dashboard/src/lib/hooks/use-historical-gps.ts`
- [x] T009 Create shift history list page skeleton in `dashboard/src/app/dashboard/history/page.tsx`
- [x] T010 Create shift detail page skeleton in `dashboard/src/app/dashboard/history/[shiftId]/page.tsx`

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - View Historical GPS Trail (Priority: P1) 🎯 MVP

**Goal**: Supervisors can view the GPS trail for completed shifts with start/end markers and point details

**Independent Test**: Select a completed shift from history, verify GPS trail renders on map with timestamps and movement path

### Implementation for User Story 1

- [x] T011 [US1] Create ShiftHistoryTable component with employee filter and date range in `dashboard/src/components/history/shift-history-table.tsx`
- [x] T012 [US1] Complete history list page with table and filtering in `dashboard/src/app/dashboard/history/page.tsx`
- [x] T013 [US1] Extend gps-trail-map component for historical trails (static view) in `dashboard/src/components/monitoring/gps-trail-map.tsx`
- [x] T014 [US1] Create GpsTrailTable fallback component for when map fails in `dashboard/src/components/history/gps-trail-table.tsx`
- [x] T015 [US1] Create trail info panel showing distance, duration, point count in `dashboard/src/components/history/trail-info-panel.tsx`
- [x] T016 [US1] Implement shift detail page with historical trail map and info in `dashboard/src/app/dashboard/history/[shiftId]/page.tsx`
- [x] T017 [US1] Add empty state for shifts with no GPS data in `dashboard/src/components/history/empty-gps-state.tsx`
- [x] T018 [US1] Add retention period expired state messaging in `dashboard/src/components/history/retention-expired-state.tsx`

**Checkpoint**: User Story 1 complete - supervisors can view historical GPS trails for completed shifts

---

## Phase 4: User Story 2 - Playback GPS Movement (Priority: P2)

**Goal**: Supervisors can animate marker movement along a GPS trail to understand sequence and timing

**Independent Test**: Load shift with GPS points, click play, observe marker animate along trail with timestamp display

### Implementation for User Story 2

- [x] T019 [US2] Create usePlaybackAnimation hook with play/pause/seek/speed in `dashboard/src/lib/hooks/use-playback-animation.ts`
- [x] T020 [US2] Create GpsPlaybackControls component with play/pause button and speed selector in `dashboard/src/components/history/gps-playback-controls.tsx`
- [x] T021 [US2] Create timeline scrubber component for seek functionality in `dashboard/src/components/history/playback-timeline.tsx`
- [x] T022 [US2] Extend gps-trail-map to support animated marker position in `dashboard/src/components/monitoring/gps-trail-map.tsx`
- [x] T023 [US2] Integrate playback controls and animated marker into shift detail page in `dashboard/src/app/dashboard/history/[shiftId]/page.tsx`
- [x] T024 [US2] Handle large time gaps in playback with visual indicator in `dashboard/src/lib/hooks/use-playback-animation.ts`

**Checkpoint**: User Story 2 complete - supervisors can replay GPS movement with playback controls

---

## Phase 5: User Story 3 - Multi-Day Route Summary (Priority: P3)

**Goal**: Supervisors can view GPS data aggregated across multiple shifts with color-coded differentiation

**Independent Test**: Select date range spanning multiple shifts, verify all trails display on single map with distinct colors and legend

### Implementation for User Story 3

- [x] T025 [US3] Implement useMultiShiftTrails hook for batch GPS data in `dashboard/src/lib/hooks/use-historical-gps.ts`
- [x] T026 [US3] Create color generation utility for multi-shift trails (HSL golden angle) in `dashboard/src/lib/utils/trail-colors.ts`
- [x] T027 [US3] Create MultiShiftMap component with color-coded trails in `dashboard/src/components/history/multi-shift-map.tsx`
- [x] T028 [US3] Create shift legend component showing date-to-color mapping in `dashboard/src/components/history/shift-legend.tsx`
- [x] T029 [US3] Add trail highlighting on hover/click (dim other trails) in `dashboard/src/components/history/multi-shift-map.tsx`
- [x] T030 [US3] Create multi-shift view page with date range selector in `dashboard/src/app/dashboard/history/multi/page.tsx`
- [x] T031 [US3] Add simplified view toggle for large point counts in `dashboard/src/components/history/multi-shift-map.tsx`

**Checkpoint**: User Story 3 complete - supervisors can view aggregated multi-shift trails

---

## Phase 6: User Story 4 - Export GPS Data (Priority: P4)

**Goal**: Supervisors can export GPS data to CSV or GeoJSON for external reporting and analysis

**Independent Test**: View shift GPS trail, click export, select format, verify file downloads with correct data and metadata

### Implementation for User Story 4

- [x] T032 [US4] Implement CSV export utility with metadata header in `dashboard/src/lib/utils/export-gps.ts`
- [x] T033 [US4] Implement GeoJSON export utility with FeatureCollection format in `dashboard/src/lib/utils/export-gps.ts`
- [x] T034 [US4] Create ExportDialog component with format selection in `dashboard/src/components/history/export-dialog.tsx`
- [x] T035 [US4] Add export button and dialog to shift detail page in `dashboard/src/app/dashboard/history/[shiftId]/page.tsx`
- [x] T036 [US4] Add multi-shift export support (separate features per shift) in `dashboard/src/lib/utils/export-gps.ts`
- [x] T037 [US4] Add export button to multi-shift view page in `dashboard/src/app/dashboard/history/multi/page.tsx`
- [x] T038 [US4] Add progress indicator for large exports (>10,000 points) in `dashboard/src/components/history/export-dialog.tsx`

**Checkpoint**: User Story 4 complete - supervisors can export GPS data in CSV/GeoJSON formats

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Final integration, error handling, and navigation improvements

- [x] T039 [P] Add history link to dashboard sidebar navigation in `dashboard/src/components/layout/sidebar.tsx`
- [x] T040 [P] Add error boundary wrapper for map components in `dashboard/src/components/history/map-error-boundary.tsx`
- [x] T041 Integrate map error boundary with fallback table view throughout history pages
- [x] T042 Run quickstart.md validation - verify all documented workflows function correctly

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 types - BLOCKS all user stories
- **User Story 1 (Phase 3)**: Depends on Foundational phase
- **User Story 2 (Phase 4)**: Depends on Foundational phase; builds on US1 map component
- **User Story 3 (Phase 5)**: Depends on Foundational phase; independent of US1/US2
- **User Story 4 (Phase 6)**: Depends on Foundational phase; independent of US1/US2/US3
- **Polish (Phase 7)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Core trail viewing - foundation for playback (US2)
- **User Story 2 (P2)**: Extends US1 map component for animation; can start once US1 map exists
- **User Story 3 (P3)**: Independent multi-shift view; can start after Foundational
- **User Story 4 (P4)**: Independent export utilities; can start after Foundational

### Within Each User Story

- Hooks before components
- Components before pages
- Core implementation before edge cases

### Parallel Opportunities

Phase 1 (all parallel):
- T002, T003, T004 can run in parallel

Phase 2:
- T006, T007, T008 hooks can run in parallel after T005 migration
- T009, T010 page skeletons can run in parallel

Phase 3-6: User stories can be worked in parallel by different developers
- US1: T011-T018 (sequential within story)
- US2: T019-T024 (requires US1 map component)
- US3: T025-T031 (independent after Foundational)
- US4: T032-T038 (independent after Foundational)

Phase 7:
- T039, T040 can run in parallel

---

## Parallel Example: Setup Phase

```bash
# Launch all setup utilities together:
Task: "Create Zod validation schemas in dashboard/src/lib/validations/history.ts"
Task: "Implement Haversine distance calculation in dashboard/src/lib/utils/distance.ts"
Task: "Implement Douglas-Peucker trail simplification in dashboard/src/lib/utils/trail-simplify.ts"
```

## Parallel Example: Foundational Hooks

```bash
# After migration T005 completes, launch all hooks:
Task: "Implement useHistoricalTrail hook in dashboard/src/lib/hooks/use-historical-gps.ts"
Task: "Implement useShiftHistory hook in dashboard/src/lib/hooks/use-historical-gps.ts"
Task: "Implement useSupervisedEmployees hook in dashboard/src/lib/hooks/use-historical-gps.ts"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (types, validations, utilities)
2. Complete Phase 2: Foundational (migration, hooks, page skeletons)
3. Complete Phase 3: User Story 1 (historical trail viewing)
4. **STOP and VALIDATE**: Test viewing historical GPS trails independently
5. Deploy/demo if ready

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add User Story 1 → Test independently → Deploy/Demo (MVP!)
3. Add User Story 2 → Test independently → Deploy/Demo (playback)
4. Add User Story 3 → Test independently → Deploy/Demo (multi-shift)
5. Add User Story 4 → Test independently → Deploy/Demo (export)
6. Each story adds value without breaking previous stories

### Parallel Team Strategy

With multiple developers after Foundational phase:
- Developer A: User Story 1 + User Story 2 (related map work)
- Developer B: User Story 3 (independent multi-shift view)
- Developer C: User Story 4 (independent export utilities)

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- Existing Spec 011 map components are extended, not replaced
- No new npm dependencies required - all implementations use native APIs
