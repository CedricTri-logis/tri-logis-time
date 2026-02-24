# Tasks: Location Geofences & Shift Segmentation

**Input**: Design documents from `/specs/015-location-geofences/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/rpc-functions.md

**Tests**: Playwright E2E tests are available (existing infrastructure from Spec 013). Tests will be added in the Polish phase.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Dashboard**: `dashboard/src/` (Next.js web application)
- **Backend**: `supabase/migrations/` (PostgreSQL database)

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Database schema, types, and shared utilities

- [X] T001 Create database migration for location_type enum, locations table, and location_matches table in supabase/migrations/015_location_geofences.sql
- [X] T002 Add PostGIS spatial index and RLS policies in supabase/migrations/015_location_geofences.sql
- [X] T003 [P] Create RPC function get_locations_paginated in supabase/migrations/015_location_geofences.sql
- [X] T004 [P] Create RPC function match_shift_gps_to_locations in supabase/migrations/015_location_geofences.sql
- [X] T005 [P] Create RPC function get_shift_timeline in supabase/migrations/015_location_geofences.sql
- [X] T006 [P] Create RPC function bulk_insert_locations in supabase/migrations/015_location_geofences.sql
- [X] T007 [P] Create RPC function check_shift_matches_exist in supabase/migrations/015_location_geofences.sql
- [X] T008 Install papaparse dependency in dashboard/package.json

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core types, validation schemas, and shared utilities that ALL user stories depend on

**CRITICAL**: No user story work can begin until this phase is complete

- [X] T009 Create location TypeScript types (LocationRow, LocationType, LocationMatchRow, TimelineSegmentRow) in dashboard/src/types/location.ts
- [X] T010 [P] Create Zod validation schemas for location form and CSV import in dashboard/src/lib/validations/location.ts
- [X] T011 [P] Create location type color constants and utilities in dashboard/src/lib/utils/segment-colors.ts
- [X] T012 [P] Create CSV parser utility with PapaParse integration in dashboard/src/lib/utils/csv-parser.ts
- [X] T013 Create useLocations hook with Refine integration for CRUD operations in dashboard/src/lib/hooks/use-locations.ts

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - Manage Workplace Locations (Priority: P1)

**Goal**: Supervisors can create and manage geographic zones (geofences) representing workplaces

**Independent Test**: Create, edit, and delete locations. Verify coordinates update on map click. Verify radius slider updates geofence circle.

### Implementation for User Story 1

- [X] T014 [P] [US1] Create geofence-circle.tsx Leaflet circle component in dashboard/src/components/locations/geofence-circle.tsx
- [X] T015 [P] [US1] Create location-map.tsx with click-to-place marker and draggable functionality in dashboard/src/components/locations/location-map.tsx
- [X] T016 [US1] Create location-form.tsx with all fields (name, type, coordinates, radius, address, notes) and map integration in dashboard/src/components/locations/location-form.tsx
- [X] T017 [US1] Create geocoding API route for address-to-coordinates conversion in dashboard/src/app/api/geocode/route.ts
- [X] T018 [US1] Create locations list page with table, filtering (type, active, search), and pagination in dashboard/src/app/dashboard/locations/page.tsx
- [X] T019 [US1] Create location detail/edit page with form and map in dashboard/src/app/dashboard/locations/[id]/page.tsx
- [X] T020 [US1] Add "Add Location" button and create location modal/page integration in dashboard/src/app/dashboard/locations/page.tsx

**Checkpoint**: User Story 1 complete - supervisors can create, view, edit, and deactivate locations

---

## Phase 4: User Story 2 - View Shift Timeline with Location Segments (Priority: P1)

**Goal**: Display visual timeline showing where employee spent time during shift with colored segments

**Independent Test**: View any completed shift with GPS data and see horizontal timeline bar with colored segments

### Implementation for User Story 2

- [X] T021 [US2] Create useLocationMatches hook to fetch GPS-to-location matches via RPC in dashboard/src/lib/hooks/use-location-matches.ts
- [X] T022 [US2] Create useTimelineSegments hook to compute/fetch timeline segments in dashboard/src/lib/hooks/use-timeline-segments.ts
- [X] T023 [P] [US2] Create timeline-segment.tsx component with tooltip for individual segments in dashboard/src/components/timeline/timeline-segment.tsx
- [X] T024 [US2] Create timeline-bar.tsx horizontal bar visualization with proportional segments in dashboard/src/components/timeline/timeline-bar.tsx
- [X] T025 [US2] Integrate timeline-bar into shift detail page (monitoring/[employeeId]) in dashboard/src/app/dashboard/monitoring/[employeeId]/page.tsx

**Checkpoint**: User Story 2 complete - supervisors can see timeline visualization for any shift

---

## Phase 5: User Story 3 - View Timeline Summary Statistics (Priority: P2)

**Goal**: Show summary of time spent at each location type as percentages and durations

**Independent Test**: View summary panel alongside any shift timeline

### Implementation for User Story 3

- [X] T026 [US3] Create timeline-summary.tsx component with duration breakdown by segment type in dashboard/src/components/timeline/timeline-summary.tsx
- [X] T027 [US3] Integrate timeline-summary into shift detail page alongside timeline-bar in dashboard/src/app/dashboard/monitoring/[employeeId]/page.tsx

**Checkpoint**: User Story 3 complete - supervisors can see aggregated statistics for shifts

---

## Phase 6: User Story 4 - Bulk Import Locations via CSV (Priority: P2)

**Goal**: Import many locations at once via CSV file upload with validation and preview

**Independent Test**: Upload CSV file with location data and verify records created

### Implementation for User Story 4

- [X] T028 [US4] Create csv-import-dialog.tsx with file upload, preview table, and validation status in dashboard/src/components/locations/csv-import-dialog.tsx
- [X] T029 [US4] Integrate CSV import dialog into locations page with "Import CSV" button in dashboard/src/app/dashboard/locations/page.tsx
- [X] T030 [US4] Add CSV import error handling and partial success reporting in dashboard/src/components/locations/csv-import-dialog.tsx

**Checkpoint**: User Story 4 complete - supervisors can bulk import locations from CSV

---

## Phase 7: User Story 5 - View Locations on Map with Geofence Circles (Priority: P3)

**Goal**: Display all locations on interactive map with geofence circles for coverage visualization

**Independent Test**: View locations map with multiple locations defined, verify circles render correctly

### Implementation for User Story 5

- [X] T031 [US5] Create locations-overview-map.tsx showing all locations with circles and markers in dashboard/src/components/locations/locations-overview-map.tsx
- [X] T032 [US5] Add map view toggle (list/map) to locations page in dashboard/src/app/dashboard/locations/page.tsx
- [X] T033 [US5] Implement location popup on marker click with details in dashboard/src/components/locations/locations-overview-map.tsx
- [X] T034 [US5] Add active/inactive toggle filter for map view in dashboard/src/app/dashboard/locations/page.tsx

**Checkpoint**: User Story 5 complete - supervisors can see all locations on map with geofences

---

## Phase 8: User Story 6 - View Segmented GPS Trail on Map (Priority: P3)

**Goal**: Display GPS trail on map with polylines colored by location type

**Independent Test**: View map for any shift with GPS data and see trail colored by segment type

### Implementation for User Story 6

- [X] T035 [US6] Create segmented-trail-map.tsx with color-coded polylines by segment type in dashboard/src/components/timeline/segmented-trail-map.tsx
- [X] T036 [US6] Add segment highlight functionality when timeline segment is selected in dashboard/src/components/timeline/segmented-trail-map.tsx
- [X] T037 [US6] Integrate segmented-trail-map into shift detail page with timeline interaction in dashboard/src/app/dashboard/monitoring/[employeeId]/page.tsx

**Checkpoint**: User Story 6 complete - supervisors can see GPS trail colored by location segments

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Navigation integration, testing, and refinements

- [X] T038 Add "Locations" navigation item to dashboard sidebar in dashboard/src/components/layout/sidebar.tsx
- [X] T039 Seed the 77 sample locations from specs/014-seed-locations.json using bulk_insert_locations RPC
- [X] T040 [P] Add E2E test for location CRUD operations in dashboard/e2e/locations.spec.ts
- [X] T041 [P] Add E2E test for timeline visualization in dashboard/e2e/timeline.spec.ts
- [X] T042 [P] Add E2E test for CSV import functionality in dashboard/e2e/csv-import.spec.ts
- [X] T043 Run quickstart.md validation and verify all PostGIS queries work correctly

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 (migration must exist) - BLOCKS all user stories
- **User Stories (Phases 3-8)**: All depend on Foundational phase completion
  - US1 (Manage Locations): No dependencies on other stories
  - US2 (Timeline): No dependencies on other stories (uses existing GPS data)
  - US3 (Summary): Depends on US2 (uses timeline segments)
  - US4 (CSV Import): No dependencies on other stories
  - US5 (Map View): Depends on US1 (needs locations data)
  - US6 (Trail Map): Depends on US2 (uses timeline segments)
- **Polish (Phase 9)**: Depends on all desired user stories being complete

### Within Each User Story

- Hooks before components
- Components before page integration
- Core implementation before integration

### Parallel Opportunities

**Phase 1** (after T001-T002 complete):
```bash
# Launch all RPC function tasks in parallel:
Task: T003 - get_locations_paginated
Task: T004 - match_shift_gps_to_locations
Task: T005 - get_shift_timeline
Task: T006 - bulk_insert_locations
Task: T007 - check_shift_matches_exist
```

**Phase 2** (after T009 complete):
```bash
# Launch all utility tasks in parallel:
Task: T010 - Zod validation schemas
Task: T011 - Segment colors
Task: T012 - CSV parser
```

**Phase 3 (US1)** (after T013 complete):
```bash
# Launch map components in parallel:
Task: T014 - geofence-circle
Task: T015 - location-map
```

**Phase 4 (US2)** (after T021-T022 complete):
```bash
# Timeline segment component can be built parallel:
Task: T023 - timeline-segment
```

**Phase 9** (all E2E tests):
```bash
# All E2E tests can run in parallel:
Task: T040 - locations E2E
Task: T041 - timeline E2E
Task: T042 - CSV import E2E
```

---

## Implementation Strategy

### MVP First (User Stories 1 & 2 Only)

1. Complete Phase 1: Setup (database migration)
2. Complete Phase 2: Foundational (types, schemas, hooks)
3. Complete Phase 3: User Story 1 (Location CRUD)
4. Complete Phase 4: User Story 2 (Timeline visualization)
5. **STOP and VALIDATE**: Both stories should work independently
6. Deploy/demo if ready

### Incremental Delivery

1. Setup + Foundational → Foundation ready
2. Add US1 (Location CRUD) → Test independently → **MVP-A**
3. Add US2 (Timeline) → Test independently → **MVP-B** (primary value)
4. Add US3 (Summary) → Enhances timeline → Deploy
5. Add US4 (CSV Import) → Efficiency feature → Deploy
6. Add US5 (Map View) → Visual enhancement → Deploy
7. Add US6 (Trail Map) → Advanced visualization → Deploy

### Critical Path

```
T001 → T002 → T009 → T013 → T016 → T018 → [US1 Complete]
                ↓
              T021 → T022 → T024 → T025 → [US2 Complete]
```

---

## Task Count Summary

| Phase | User Story | Task Count |
|-------|------------|------------|
| Phase 1 | Setup | 8 |
| Phase 2 | Foundational | 5 |
| Phase 3 | US1 - Manage Locations (P1) | 7 |
| Phase 4 | US2 - Timeline (P1) | 5 |
| Phase 5 | US3 - Summary (P2) | 2 |
| Phase 6 | US4 - CSV Import (P2) | 3 |
| Phase 7 | US5 - Map View (P3) | 4 |
| Phase 8 | US6 - Trail Map (P3) | 3 |
| Phase 9 | Polish | 6 |
| **Total** | | **43** |

### Tasks by Priority

- **P1 (MVP)**: 12 tasks (US1 + US2)
- **P2 (Enhanced)**: 5 tasks (US3 + US4)
- **P3 (Visual)**: 7 tasks (US5 + US6)
- **Infrastructure**: 19 tasks (Setup + Foundational + Polish)

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- Google Maps API key required for geocoding (optional - can use map click instead)
