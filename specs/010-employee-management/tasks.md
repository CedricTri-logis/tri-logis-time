# Tasks: Employee Management

**Input**: Design documents from `/specs/010-employee-management/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, contracts/rpc-functions.md, quickstart.md

**Tests**: Tests are OPTIONAL and NOT included unless explicitly requested.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Dashboard app**: `dashboard/src/` for Next.js frontend
- **Supabase**: `supabase/migrations/` for database migrations

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization, shadcn/ui components, and basic type definitions

- [X] T001 Install required shadcn/ui components (dialog, form, input, label, toast, pagination) via `npx shadcn@latest add` in `dashboard/`
- [X] T002 [P] Create Zod validation schemas in `dashboard/src/lib/validations/employee.ts`
- [X] T003 [P] Create TypeScript type definitions in `dashboard/src/types/employee.ts`

---

## Phase 2: Foundational (Database & Infrastructure)

**Purpose**: Database migrations, audit logging, RPC functions, and data provider extension

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T004 Create audit schema, audit_logs table, and RLS policies in `supabase/migrations/011_employee_management.sql`
- [X] T005 Create audit.log_changes() trigger function in `supabase/migrations/011_employee_management.sql`
- [X] T006 Attach audit triggers to employee_profiles and employee_supervisors tables in `supabase/migrations/011_employee_management.sql`
- [X] T007 Create end_active_supervisions() function and trigger for auto-ending supervision on deactivation in `supabase/migrations/011_employee_management.sql`
- [X] T008 Create check_last_admin() helper function in `supabase/migrations/011_employee_management.sql`
- [X] T009 Create get_employees_paginated() RPC function with search/filter/pagination in `supabase/migrations/011_employee_management.sql`
- [X] T010 Create get_employee_detail() RPC function with supervision history in `supabase/migrations/011_employee_management.sql`
- [X] T011 Create update_employee_profile() RPC function in `supabase/migrations/011_employee_management.sql`
- [X] T012 Create update_employee_status() RPC function with active shift warning in `supabase/migrations/011_employee_management.sql`
- [X] T013 Create assign_supervisor() RPC function in `supabase/migrations/011_employee_management.sql`
- [X] T014 Create remove_supervisor() RPC function in `supabase/migrations/011_employee_management.sql`
- [X] T015 Create get_managers_list() RPC function in `supabase/migrations/011_employee_management.sql`
- [X] T016 Create check_employee_active_shift() RPC function in `supabase/migrations/011_employee_management.sql`
- [X] T017 Create get_employee_audit_log() RPC function in `supabase/migrations/011_employee_management.sql`
- [X] T018 Apply migration and regenerate TypeScript types in `dashboard/src/types/database.ts`
- [X] T019 Extend data provider getList to support RPC pagination in `dashboard/src/lib/providers/data-provider.ts`

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - Admin Views Employee Directory (Priority: P1) 🎯 MVP

**Goal**: Administrator can view all employees with search, filter, and pagination

**Independent Test**: Log in as admin/super_admin, navigate to employee management, verify paginated list displays with name, email, role, status, and employee ID

### Implementation for User Story 1

- [X] T020 [P] [US1] Create StatusBadge component for visual status indication in `dashboard/src/components/dashboard/employees/status-badge.tsx`
- [X] T021 [P] [US1] Create EmployeeFilters component with search, role, and status filters in `dashboard/src/components/dashboard/employees/employee-filters.tsx`
- [X] T022 [US1] Create EmployeeTable component with pagination using @tanstack/react-table in `dashboard/src/components/dashboard/employees/employee-table.tsx`
- [X] T023 [US1] Create EmptyState component with filter-aware messaging and "Clear filters" button in `dashboard/src/components/dashboard/employees/empty-state.tsx`
- [X] T024 [US1] Create employee directory page with useTable hook in `dashboard/src/app/dashboard/employees/page.tsx`
- [X] T025 [US1] Add Employees navigation link to sidebar in `dashboard/src/components/layout/sidebar.tsx`

**Checkpoint**: User Story 1 complete - admin can view, search, filter, and paginate employee directory

---

## Phase 4: User Story 2 - Admin Edits Employee Details (Priority: P1)

**Goal**: Administrator can update employee name and employee ID with validation

**Independent Test**: Select an employee, modify full name and employee ID, save changes, verify updates persist in directory and database

### Implementation for User Story 2

- [X] T026 [P] [US2] Create EmployeeForm component with react-hook-form and Zod validation in `dashboard/src/components/dashboard/employees/employee-form.tsx`
- [X] T027 [US2] Create employee detail/edit page with useOne and useForm hooks in `dashboard/src/app/dashboard/employees/[id]/page.tsx`
- [X] T028 [US2] Add concurrent edit detection with toast notification in `dashboard/src/app/dashboard/employees/[id]/page.tsx`
- [X] T029 [US2] Add super_admin protection (read-only display for non-super_admin editing super_admin) in `dashboard/src/app/dashboard/employees/[id]/page.tsx`

**Checkpoint**: User Story 2 complete - admin can edit employee profiles with validation and conflict handling

---

## Phase 5: User Story 3 - Admin Manages Employee Roles (Priority: P1)

**Goal**: Administrator can change employee roles with appropriate restrictions

**Independent Test**: Select an employee, change their role from employee to manager, verify new role is applied and affects their access

### Implementation for User Story 3

- [X] T030 [US3] Create RoleSelector component with role dropdown and super_admin restriction in `dashboard/src/components/dashboard/employees/role-selector.tsx`
- [X] T031 [US3] Integrate RoleSelector into employee detail page with update_user_role RPC in `dashboard/src/app/dashboard/employees/[id]/page.tsx`

**Checkpoint**: User Story 3 complete - admin can manage employee roles with security restrictions

---

## Phase 6: User Story 4 - Admin Manages Supervisor Assignments (Priority: P2)

**Goal**: Administrator can assign/reassign employees to managers and view supervision history

**Independent Test**: Select an unassigned employee, assign them to a manager, verify manager sees employee in their team dashboard

### Implementation for User Story 4

- [X] T032 [US4] Create SupervisorAssignment component with manager dropdown and supervision history in `dashboard/src/components/dashboard/employees/supervisor-assignment.tsx`
- [X] T033 [US4] Integrate SupervisorAssignment into employee detail page in `dashboard/src/app/dashboard/employees/[id]/page.tsx`

**Checkpoint**: User Story 4 complete - admin can manage supervisor assignments with history tracking

---

## Phase 7: User Story 5 - Admin Deactivates Employee Accounts (Priority: P2)

**Goal**: Administrator can deactivate employees with warnings for active shifts

**Independent Test**: Select an active employee, change status to inactive, verify they cannot log in while historical data remains accessible

### Implementation for User Story 5

- [X] T034 [US5] Create StatusSelector component with active/inactive/suspended options in `dashboard/src/components/dashboard/employees/status-selector.tsx`
- [X] T035 [US5] Create DeactivationWarningDialog for active shift confirmation in `dashboard/src/components/dashboard/employees/deactivation-warning-dialog.tsx`
- [X] T036 [US5] Integrate status management into employee detail page with self-deactivation and last-admin protection in `dashboard/src/app/dashboard/employees/[id]/page.tsx`

**Checkpoint**: User Story 5 complete - admin can deactivate employees with appropriate warnings and safeguards

---

## Phase 8: User Story 6 - Admin Reactivates Employee Accounts (Priority: P3)

**Goal**: Administrator can reactivate previously deactivated employees

**Independent Test**: Select an inactive employee, change status to active, verify they can log in and see their historical data

### Implementation for User Story 6

- [X] T037 [US6] Add reactivation flow to StatusSelector with messaging about manual supervisor reassignment in `dashboard/src/components/dashboard/employees/status-selector.tsx`
- [X] T038 [US6] Update employee detail page to show reactivation guidance (no auto-restore supervisor) in `dashboard/src/app/dashboard/employees/[id]/page.tsx`

**Checkpoint**: User Story 6 complete - admin can reactivate employees with clear guidance

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

- [X] T039 Add loading states and skeleton UI to employee table and detail page
- [X] T040 Add error boundary and error handling for RPC failures
- [X] T041 Run quickstart.md validation scenarios to verify all user stories work independently
- [X] T042 Verify performance with 1000+ employees (SC-005)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phase 3-8)**: All depend on Foundational phase completion
  - US1, US2, US3 are P1 priority - implement in order
  - US4, US5 are P2 priority - can proceed after P1 stories
  - US6 is P3 priority - final user story
- **Polish (Phase 9)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational (Phase 2) - provides directory foundation
- **User Story 2 (P1)**: Depends on US1 (needs employee detail page) - adds editing
- **User Story 3 (P1)**: Depends on US2 (extends detail page) - adds role management
- **User Story 4 (P2)**: Depends on US2 (extends detail page) - adds supervisor assignment
- **User Story 5 (P2)**: Depends on US2 (extends detail page) - adds status management
- **User Story 6 (P3)**: Depends on US5 (extends status selector) - adds reactivation

### Within Each User Story

- Models/schemas before services
- Services before components
- Components before pages
- Core implementation before integration

### Parallel Opportunities

- T002, T003 can run in parallel (Setup phase)
- T020, T021 can run in parallel (US1 components)
- T026 can run in parallel with US1 work
- Database migration tasks (T004-T017) must be sequential within the single migration file

---

## Parallel Example: Setup Phase

```bash
# After T001 completes, launch T002 and T003 together:
Task: "Create Zod validation schemas in dashboard/src/lib/validations/employee.ts"
Task: "Create TypeScript type definitions in dashboard/src/types/employee.ts"
```

## Parallel Example: User Story 1

```bash
# Launch status badge and filters components together:
Task: "Create StatusBadge component in dashboard/src/components/dashboard/employees/status-badge.tsx"
Task: "Create EmployeeFilters component in dashboard/src/components/dashboard/employees/employee-filters.tsx"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL - blocks all stories)
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: Test employee directory independently
5. Deploy/demo if ready - admins can now view employees

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add User Story 1 → Test independently → Deploy/Demo (MVP!)
3. Add User Story 2 → Test independently → Deploy/Demo (editing)
4. Add User Story 3 → Test independently → Deploy/Demo (roles)
5. Add User Story 4 → Test independently → Deploy/Demo (supervisors)
6. Add User Story 5 → Test independently → Deploy/Demo (deactivation)
7. Add User Story 6 → Test independently → Deploy/Demo (reactivation)
8. Each story adds value without breaking previous stories

### Parallel Team Strategy

With multiple developers:

1. Team completes Setup + Foundational together
2. Once Foundational is done:
   - Developer A: User Stories 1, 2 (directory + editing)
   - Developer B: User Stories 3, 4 (roles + supervisors)
   - Developer C: User Stories 5, 6 (status management)
3. Stories complete and integrate via shared employee detail page

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- Avoid: vague tasks, same file conflicts, cross-story dependencies that break independence
- All RPC functions are created in a single migration file (011_employee_management.sql) to maintain atomic deployment
