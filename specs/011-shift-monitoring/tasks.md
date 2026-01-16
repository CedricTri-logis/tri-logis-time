# Tasks: Shift Monitoring

**Input**: Design documents from `/specs/011-shift-monitoring/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: Tests are NOT included - not explicitly requested in the feature specification.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3, US4)
- Include exact file paths in descriptions

## Path Conventions

- **Dashboard**: `dashboard/src/` (Next.js app directory structure)
- **Database**: `supabase/migrations/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Install dependencies and create base project structure for monitoring feature

- [X] T001 Install react-leaflet, leaflet, date-fns dependencies in dashboard/package.json
- [X] T002 [P] Install @types/leaflet dev dependency in dashboard/package.json
- [X] T003 [P] Create monitoring types file at dashboard/src/types/monitoring.ts
- [X] T004 [P] Create Zod validation schemas at dashboard/src/lib/validations/monitoring.ts

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T005 Create database migration with get_monitored_team RPC function in supabase/migrations/
- [X] T006 Add get_shift_detail RPC function to the same migration file
- [X] T007 Add get_shift_gps_trail RPC function to the same migration file
- [X] T008 Add get_employee_current_shift RPC function to the same migration file
- [X] T009 Apply database migration with `supabase db push`
- [X] T010 Create useRealtimeShifts hook at dashboard/src/lib/hooks/use-realtime-shifts.ts
- [X] T011 [P] Create useRealtimeGps hook at dashboard/src/lib/hooks/use-realtime-gps.ts
- [X] T012 [P] Create empty-states component at dashboard/src/components/monitoring/empty-states.tsx
- [X] T013 [P] Create staleness-indicator component at dashboard/src/components/monitoring/staleness-indicator.tsx
- [X] T014 [P] Create duration-counter component at dashboard/src/components/monitoring/duration-counter.tsx

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - Real-Time Team Activity Overview (Priority: P1) 🎯 MVP

**Goal**: Supervisors can see which team members are currently working with live status updates

**Independent Test**: Login as supervisor, view dashboard showing all supervised employees with current shift status (active/inactive) and live duration for active shifts. Status updates automatically when employees clock in/out.

### Implementation for User Story 1

- [X] T015 [US1] Create useSupervisedTeam hook at dashboard/src/lib/hooks/use-supervised-team.ts
- [X] T016 [US1] Create team-list component at dashboard/src/components/monitoring/team-list.tsx
- [X] T017 [US1] Create monitoring overview page at dashboard/src/app/dashboard/monitoring/page.tsx
- [X] T018 [US1] Add Leaflet CSS import to monitoring page layout
- [X] T019 [US1] Integrate useRealtimeShifts with useSupervisedTeam for live updates
- [X] T020 [US1] Add loading and error states to monitoring page

**Checkpoint**: User Story 1 complete - supervisors can view team with live status updates

---

## Phase 4: User Story 2 - Live Location Tracking on Map (Priority: P2)

**Goal**: Supervisors can see current locations of on-shift employees on an interactive map

**Independent Test**: View monitoring dashboard with map showing markers for employees with active shifts. Markers update position when new GPS points arrive. Stale indicators appear for locations older than 5 minutes.

### Implementation for User Story 2

- [X] T021 [US2] Create location-marker component at dashboard/src/components/monitoring/location-marker.tsx
- [X] T022 [US2] Create team-map component with dynamic import at dashboard/src/components/monitoring/team-map.tsx
- [X] T023 [US2] Add team-map to monitoring page alongside team-list
- [X] T024 [US2] Integrate useRealtimeGps hook for live marker updates
- [X] T025 [US2] Add map error handling with graceful degradation fallback UI
- [X] T026 [US2] Add accuracy circle display for poor GPS accuracy (>100m)

**Checkpoint**: User Story 2 complete - map shows live employee locations with staleness indicators

---

## Phase 5: User Story 3 - Individual Shift Detail View (Priority: P3)

**Goal**: Supervisors can drill down to see GPS trail and full shift details for an employee

**Independent Test**: Click employee in team list, navigate to detail page showing shift start time, live duration, and GPS trail on map. New GPS points appear on trail within 60 seconds.

### Implementation for User Story 3

- [X] T027 [US3] Create shift-detail-card component at dashboard/src/components/monitoring/shift-detail-card.tsx
- [X] T028 [US3] Create gps-trail-map component at dashboard/src/components/monitoring/gps-trail-map.tsx
- [X] T029 [US3] Create employee shift detail page at dashboard/src/app/dashboard/monitoring/[employeeId]/page.tsx
- [X] T030 [US3] Add GPS trail data fetching using get_shift_gps_trail RPC
- [X] T031 [US3] Add realtime GPS trail updates via useRealtimeGps hook
- [X] T032 [US3] Add trail point click/hover interaction showing timestamp and accuracy
- [X] T033 [US3] Add navigation back to monitoring overview

**Checkpoint**: User Story 3 complete - full shift detail view with GPS trail

---

## Phase 6: User Story 4 - Filtering and Search (Priority: P4)

**Goal**: Supervisors can filter and search the team list to find specific employees

**Independent Test**: Use search box to filter by employee name or ID. Toggle status filter between All/On-shift/Off-shift. List updates immediately.

### Implementation for User Story 4

- [X] T034 [US4] Create team-filters component at dashboard/src/components/monitoring/team-filters.tsx
- [X] T035 [US4] Add search input with debounced filtering
- [X] T036 [US4] Add shift status filter (All, On-shift, Off-shift) toggle
- [X] T037 [US4] Integrate filters with useSupervisedTeam hook parameters
- [X] T038 [US4] Add clear filters functionality
- [X] T039 [US4] Update team-map to respect active filters

**Checkpoint**: User Story 4 complete - full search and filter functionality

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Edge cases, performance optimizations, and final improvements

- [X] T040 [P] Add network offline detection with warning banner
- [X] T041 [P] Add connection status indicator for realtime subscriptions
- [X] T042 [P] Add "Location pending" state for active shifts without GPS data
- [X] T043 Implement GPS update batching for high-frequency updates
- [X] T044 Add trail point simplification for large trails (500+ points)
- [X] T045 Run quickstart.md validation checklist
- [X] T046 Verify all empty states display correctly (no team, no active shifts, no GPS)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phase 3-6)**: All depend on Foundational phase completion
  - User stories should proceed sequentially (P1 → P2 → P3 → P4)
  - P2 builds on P1's team list, P3 builds on P2's map patterns
- **Polish (Phase 7)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Foundational only - creates core team list and status
- **User Story 2 (P2)**: Depends on US1 (adds map to existing team list page)
- **User Story 3 (P3)**: Depends on US1 (navigates from team list), uses patterns from US2 (map)
- **User Story 4 (P4)**: Depends on US1 (filters applied to team list)

### Within Each User Story

- Components before pages
- Data hooks before UI integration
- Core implementation before refinements
- Story complete before moving to next priority

### Parallel Opportunities

**Setup Phase:**
```bash
# All can run in parallel:
Task: T002 "Install @types/leaflet dev dependency"
Task: T003 "Create monitoring types file"
Task: T004 "Create Zod validation schemas"
```

**Foundational Phase:**
```bash
# After RPC migration applied, these can run in parallel:
Task: T010 "Create useRealtimeShifts hook"
Task: T011 "Create useRealtimeGps hook"
Task: T012 "Create empty-states component"
Task: T013 "Create staleness-indicator component"
Task: T014 "Create duration-counter component"
```

**Polish Phase:**
```bash
# All can run in parallel:
Task: T040 "Add network offline detection"
Task: T041 "Add connection status indicator"
Task: T042 "Add Location pending state"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL - blocks all stories)
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: Test team list with live status updates
5. Deploy/demo if ready - supervisors can see who's working

### Incremental Delivery

1. Setup + Foundational → Foundation ready
2. Add User Story 1 → Team list with live status → Deploy (MVP!)
3. Add User Story 2 → Add map with markers → Deploy
4. Add User Story 3 → Add shift detail drill-down → Deploy
5. Add User Story 4 → Add search/filter → Deploy
6. Polish → Final refinements → Complete

### Key Files Summary

```
dashboard/src/
├── app/dashboard/monitoring/
│   ├── page.tsx                    # US1: Team overview page
│   └── [employeeId]/page.tsx       # US3: Shift detail page
├── components/monitoring/
│   ├── team-list.tsx               # US1: Employee status list
│   ├── team-filters.tsx            # US4: Search and status filter
│   ├── team-map.tsx                # US2: Interactive map
│   ├── location-marker.tsx         # US2: Map marker component
│   ├── shift-detail-card.tsx       # US3: Shift info display
│   ├── gps-trail-map.tsx           # US3: Trail visualization
│   ├── duration-counter.tsx        # Foundational: Live HH:MM:SS
│   ├── staleness-indicator.tsx     # Foundational: Freshness badge
│   └── empty-states.tsx            # Foundational: No data states
├── lib/hooks/
│   ├── use-realtime-shifts.ts      # Foundational: Shift subscriptions
│   ├── use-realtime-gps.ts         # Foundational: GPS subscriptions
│   └── use-supervised-team.ts      # US1: Combined team data
├── lib/validations/
│   └── monitoring.ts               # Setup: Zod schemas
└── types/
    └── monitoring.ts               # Setup: TypeScript types

supabase/migrations/
└── YYYYMMDDHHMMSS_add_monitoring_functions.sql  # Foundational: RPC functions
```

---

## Notes

- [P] tasks = different files, no dependencies on other in-progress tasks
- [Story] label maps task to specific user story for traceability
- Each user story builds incrementally but maintains independent test criteria
- GPS trail only available for active shifts (per spec FR-007)
- RLS policies handle authorization - client filters by supervised employees
- Use dynamic imports for map components to avoid SSR issues
- Leaflet CSS must be imported for map to render correctly
