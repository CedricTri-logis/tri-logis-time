# Tasks: Dashboard Foundation

**Input**: Design documents from `/specs/009-dashboard-foundation/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, contracts/api-contracts.md

**Tests**: Not explicitly requested in spec - test tasks omitted.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Dashboard web app**: `dashboard/src/` at repository root
- **Supabase migrations**: `supabase/migrations/` at repository root

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Next.js project initialization and basic structure

- [X] T001 Create Next.js project with TypeScript, Tailwind, ESLint, App Router at `dashboard/`
- [X] T002 Install core dependencies: @refinedev/core, @refinedev/nextjs-router, @refinedev/supabase, @supabase/ssr, @supabase/supabase-js, @tanstack/react-table, zod, lucide-react
- [X] T003 [P] Initialize shadcn/ui with default style and slate base color in `dashboard/`
- [X] T004 [P] Add shadcn/ui components: card, table, badge, button, skeleton, dropdown-menu, select
- [X] T005 [P] Create environment configuration file `dashboard/.env.local` with Supabase URL and anon key placeholders
- [X] T006 [P] Configure TypeScript path aliases in `dashboard/tsconfig.json`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T007 Apply database migration for dashboard RPC functions in `supabase/migrations/010_dashboard_aggregations.sql`
- [X] T008 Create Supabase browser client in `dashboard/src/lib/supabase/client.ts`
- [X] T009 [P] Create Supabase server client in `dashboard/src/lib/supabase/server.ts`
- [X] T010 Create extended data provider with RPC support in `dashboard/src/lib/providers/data-provider.ts`
- [X] T011 Create auth provider for Refine in `dashboard/src/lib/providers/auth-provider.ts`
- [X] T012 Create middleware for auth session refresh and route protection in `dashboard/middleware.ts`
- [X] T013 [P] Create TypeScript types for dashboard data in `dashboard/src/types/dashboard.ts`
- [X] T014 [P] Generate Supabase database types in `dashboard/src/types/database.ts`
- [X] T015 Create root layout with Refine provider wrapper in `dashboard/src/app/layout.tsx`
- [X] T016 Create root page with redirect to /dashboard in `dashboard/src/app/page.tsx`
- [X] T017 Create login page with Supabase auth in `dashboard/src/app/login/page.tsx`

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - Admin Views Organization-Wide Dashboard (Priority: P1) 🎯 MVP

**Goal**: Administrators can view system-wide statistics, employee counts by role, and active shift summary on a comprehensive dashboard.

**Independent Test**: Login as admin/super_admin, navigate to /dashboard, verify organization-wide metrics (employee counts, shift stats, activity feed) display correctly with data freshness indicator.

### Implementation for User Story 1

- [X] T018 [US1] Create dashboard layout with sidebar navigation in `dashboard/src/app/dashboard/layout.tsx`
- [X] T019 [P] [US1] Create sidebar component in `dashboard/src/components/layout/sidebar.tsx`
- [X] T020 [P] [US1] Create header component with user info and logout in `dashboard/src/components/layout/header.tsx`
- [X] T021 [P] [US1] Create stats cards component for employee/shift counts in `dashboard/src/components/dashboard/stats-cards.tsx`
- [X] T022 [P] [US1] Create activity feed component for active employees in `dashboard/src/components/dashboard/activity-feed.tsx`
- [X] T023 [P] [US1] Create data freshness indicator component in `dashboard/src/components/dashboard/data-freshness.tsx`
- [X] T024 [US1] Create organization dashboard page with 30s auto-refresh in `dashboard/src/app/dashboard/page.tsx`
- [X] T025 [US1] Implement manual refresh button functionality in `dashboard/src/app/dashboard/page.tsx`
- [X] T026 [US1] Add loading skeleton states to dashboard components in `dashboard/src/components/dashboard/stats-cards.tsx` and `dashboard/src/components/dashboard/activity-feed.tsx`
- [X] T027 [US1] Add empty/zero-state handling for organizations with no employees in `dashboard/src/app/dashboard/page.tsx`

**Checkpoint**: At this point, User Story 1 should be fully functional and testable independently

---

## Phase 4: User Story 2 - Admin Monitors Team Performance Comparisons (Priority: P2)

**Goal**: Administrators can compare performance metrics across teams/managers with date range filtering and drill-down navigation.

**Independent Test**: Login as admin, navigate to /dashboard/teams, verify team comparison table shows all managers with metrics, date range filter updates data, clicking a team navigates to manager's team detail.

### Implementation for User Story 2

- [X] T028 [P] [US2] Create team comparison table component in `dashboard/src/components/dashboard/team-comparison-table.tsx`
- [X] T029 [P] [US2] Create date range selector component in `dashboard/src/components/dashboard/date-range-selector.tsx`
- [X] T030 [US2] Create teams page with date range filtering in `dashboard/src/app/dashboard/teams/page.tsx`
- [X] T031 [US2] Implement team sorting by total hours, shifts, and team size in `dashboard/src/components/dashboard/team-comparison-table.tsx`
- [X] T032 [US2] Add navigation from team row to manager's team dashboard (external link to mobile app team view) in `dashboard/src/components/dashboard/team-comparison-table.tsx`
- [X] T033 [US2] Add empty state for organizations with no managers/teams in `dashboard/src/app/dashboard/teams/page.tsx`
- [X] T034 [US2] Add loading skeleton states to team comparison table in `dashboard/src/components/dashboard/team-comparison-table.tsx`

**Checkpoint**: At this point, User Stories 1 AND 2 should both work independently

---

## Phase 5: User Story 3 - Admin Accesses Dashboard from Multiple Devices (Priority: P3)

**Goal**: Dashboard is fully responsive and accessible via web browser from desktop computers with consistent data across platforms.

**Independent Test**: Access dashboard URL in Chrome, Firefox, Safari, and Edge browsers on desktop; verify all features work within 2 seconds response time; verify data matches what mobile app would show.

### Implementation for User Story 3

- [X] T035 [P] [US3] Add responsive styling to sidebar for desktop viewports in `dashboard/src/components/layout/sidebar.tsx`
- [X] T036 [P] [US3] Add responsive styling to header for desktop viewports in `dashboard/src/components/layout/header.tsx`
- [X] T037 [P] [US3] Add responsive grid layout to stats cards for desktop in `dashboard/src/components/dashboard/stats-cards.tsx`
- [X] T038 [P] [US3] Add responsive styling to activity feed for desktop in `dashboard/src/components/dashboard/activity-feed.tsx`
- [X] T039 [P] [US3] Add responsive styling to team comparison table for desktop in `dashboard/src/components/dashboard/team-comparison-table.tsx`
- [X] T040 [US3] Verify and optimize component performance for <2s interactions in `dashboard/src/app/dashboard/page.tsx` and `dashboard/src/app/dashboard/teams/page.tsx`
- [X] T041 [US3] Add browser compatibility meta tags and viewport configuration in `dashboard/src/app/layout.tsx`

**Checkpoint**: All user stories should now be independently functional

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Final improvements that affect multiple user stories

- [X] T042 [P] Add error boundary component for graceful error handling in `dashboard/src/components/error-boundary.tsx`
- [X] T043 [P] Add network error handling with stale data indicator in `dashboard/src/components/dashboard/data-freshness.tsx`
- [X] T044 Configure Next.js production build settings in `dashboard/next.config.ts`
- [X] T045 Add Vercel deployment configuration in `dashboard/vercel.json`
- [X] T046 Run quickstart.md validation checklist

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phase 3+)**: All depend on Foundational phase completion
  - User stories can then proceed in parallel (if staffed)
  - Or sequentially in priority order (P1 → P2 → P3)
- **Polish (Final Phase)**: Depends on all desired user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational (Phase 2) - No dependencies on other stories
- **User Story 2 (P2)**: Can start after Foundational (Phase 2) - Uses same layout components from US1 but independently testable
- **User Story 3 (P3)**: Depends on US1 and US2 completion (adds responsive styling to existing components)

### Within Each User Story

- Layout/shell components before page components
- UI components before page integration
- Core functionality before refinements (empty states, loading states)
- Story complete before moving to next priority

### Parallel Opportunities

- T003-T006 can all run in parallel (independent setup tasks)
- T008-T009 can run in parallel (different Supabase clients)
- T013-T014 can run in parallel (different type files)
- T019-T023 can all run in parallel (independent UI components)
- T028-T029 can run in parallel (independent US2 components)
- T035-T039 can all run in parallel (responsive styling for different components)
- T042-T043 can run in parallel (error handling components)

---

## Parallel Example: User Story 1 Components

```bash
# Launch all UI components for User Story 1 together:
Task: "Create sidebar component in dashboard/src/components/layout/sidebar.tsx"
Task: "Create header component in dashboard/src/components/layout/header.tsx"
Task: "Create stats cards component in dashboard/src/components/dashboard/stats-cards.tsx"
Task: "Create activity feed component in dashboard/src/components/dashboard/activity-feed.tsx"
Task: "Create data freshness indicator in dashboard/src/components/dashboard/data-freshness.tsx"
```

---

## Parallel Example: Responsive Styling (User Story 3)

```bash
# Launch all responsive styling tasks together:
Task: "Add responsive styling to sidebar in dashboard/src/components/layout/sidebar.tsx"
Task: "Add responsive styling to header in dashboard/src/components/layout/header.tsx"
Task: "Add responsive grid layout to stats cards in dashboard/src/components/dashboard/stats-cards.tsx"
Task: "Add responsive styling to activity feed in dashboard/src/components/dashboard/activity-feed.tsx"
Task: "Add responsive styling to team comparison table in dashboard/src/components/dashboard/team-comparison-table.tsx"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL - blocks all stories)
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: Test User Story 1 independently
   - Login as admin → see organization dashboard
   - Verify employee counts by role
   - Verify active shift count and activity feed
   - Verify data freshness indicator
   - Verify 30s auto-refresh works
5. Deploy/demo if ready

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add User Story 1 → Test independently → Deploy/Demo (MVP!)
3. Add User Story 2 → Test independently → Deploy/Demo
4. Add User Story 3 → Test independently → Deploy/Demo
5. Each story adds value without breaking previous stories

### Parallel Team Strategy

With multiple developers:

1. Team completes Setup + Foundational together
2. Once Foundational is done:
   - Developer A: User Story 1 (dashboard overview)
   - Developer B: User Story 2 (team comparison) - can start after T018-T020 layout components
3. User Story 3 (responsive styling) can be done by any developer after US1+US2 components exist

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- Migration T007 creates `get_org_dashboard_summary()` and `get_manager_team_summaries()` RPC functions
- Existing RPC `get_team_active_status()` from Spec 008 is reused for activity feed
- Dashboard uses Refine's `useCustom` hook with `meta.rpc` for Supabase RPC calls
- 30-second auto-refresh via `queryOptions.refetchInterval`
