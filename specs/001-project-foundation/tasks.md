# Tasks: Project Foundation

**Input**: Design documents from `/specs/001-project-foundation/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/database-schema.sql

**Tests**: Not explicitly requested in the feature specification. Test tasks are excluded.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

Based on plan.md structure:
- **Flutter project**: `gps_tracker/lib/` for Dart source code
- **Supabase**: `supabase/` for database migrations and config
- **Tests**: `gps_tracker/test/` for unit/widget tests

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and Flutter project creation

- [X] T001 Create Flutter project with `flutter create gps_tracker` in repository root
- [X] T002 Configure pubspec.yaml with all dependencies from research.md in gps_tracker/pubspec.yaml
- [X] T003 [P] Configure analysis_options.yaml with Flutter linting rules in gps_tracker/analysis_options.yaml
- [X] T004 [P] Create .env.example file with environment variable template in gps_tracker/.env.example
- [X] T005 [P] Update .gitignore to exclude .env files and platform-specific artifacts in root .gitignore

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**CRITICAL**: No user story work can begin until this phase is complete

- [X] T006 Create lib/main.dart app entry point with Supabase initialization in gps_tracker/lib/main.dart
- [X] T007 Create lib/app.dart root widget with MaterialApp scaffold in gps_tracker/lib/app.dart
- [X] T008 [P] Create core/config/env_config.dart for environment variable loading in gps_tracker/lib/core/config/env_config.dart
- [X] T009 [P] Create core/config/constants.dart for app constants in gps_tracker/lib/core/config/constants.dart
- [X] T010 [P] Create shared/providers/supabase_provider.dart Riverpod provider in gps_tracker/lib/shared/providers/supabase_provider.dart
- [X] T011 Create Supabase project directory structure with config.toml in supabase/config.toml
- [X] T012 Create placeholder home screen widget in gps_tracker/lib/features/home/home_screen.dart

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - Developer Sets Up Local Environment (Priority: P1) MVP

**Goal**: A developer can clone the repository, run setup commands, and launch the app on iOS and Android simulators displaying a placeholder welcome screen.

**Independent Test**: Clone repo, run `flutter pub get`, run `flutter run` on both iOS simulator and Android emulator - app launches with welcome screen.

### Implementation for User Story 1

- [X] T013 [US1] Run flutter pub get to verify all dependencies install correctly in gps_tracker/
- [X] T014 [US1] Create welcome_screen.dart placeholder UI with app name and setup confirmation message in gps_tracker/lib/features/home/welcome_screen.dart
- [X] T015 [US1] Update app.dart to route to welcome screen as initial route in gps_tracker/lib/app.dart
- [ ] T016 [US1] Verify app builds and runs on iOS simulator via `flutter run -d ios`
- [ ] T017 [US1] Verify app builds and runs on Android emulator via `flutter run -d android`
- [X] T018 [US1] Add setup verification checklist to quickstart.md with exact commands in specs/001-project-foundation/quickstart.md

**Checkpoint**: User Story 1 complete - developers can set up and run the app on both platforms

---

## Phase 4: User Story 2 - Backend Infrastructure Ready for Development (Priority: P1)

**Goal**: Supabase backend is configured with database schema, authentication settings, and RLS policies ready for data storage.

**Independent Test**: Connect to Supabase project, verify all tables exist (employee_profiles, shifts, gps_points), confirm RLS policies are active, verify email/password auth is enabled.

### Implementation for User Story 2

- [X] T019 [US2] Create database migration file from contracts/database-schema.sql in supabase/migrations/001_initial_schema.sql
- [X] T020 [US2] Create .env.local template for local Supabase development in supabase/.env.local.example
- [X] T021 [US2] Document Supabase setup steps (supabase start, link, db push) in specs/001-project-foundation/quickstart.md
- [X] T022 [US2] Verify database tables exist after migration with `supabase db push`
- [X] T023 [US2] Verify RLS policies are active on all three tables via Supabase dashboard/CLI
- [X] T024 [US2] Configure email/password authentication in Supabase auth settings
- [X] T025 [US2] Test unauthenticated request denial to verify RLS is working

**Checkpoint**: User Story 2 complete - backend infrastructure is ready for feature development

---

## Phase 5: User Story 3 - Platform Permissions Configured (Priority: P2)

**Goal**: iOS and Android platform configurations include all necessary permissions for location tracking, background processing, and notifications.

**Independent Test**: Review Info.plist and AndroidManifest.xml, build for both platforms - builds succeed with all permissions declared, no permission-related errors.

### Implementation for User Story 3

- [X] T026 [P] [US3] Configure iOS Info.plist with location permission strings (NSLocationWhenInUseUsageDescription, NSLocationAlwaysAndWhenInUseUsageDescription) in gps_tracker/ios/Runner/Info.plist
- [X] T027 [P] [US3] Configure iOS Info.plist with UIBackgroundModes (location, fetch) in gps_tracker/ios/Runner/Info.plist
- [X] T028 [P] [US3] Configure Android AndroidManifest.xml with location permissions (ACCESS_FINE_LOCATION, ACCESS_COARSE_LOCATION, ACCESS_BACKGROUND_LOCATION) in gps_tracker/android/app/src/main/AndroidManifest.xml
- [X] T029 [P] [US3] Configure Android AndroidManifest.xml with foreground service permissions (FOREGROUND_SERVICE, FOREGROUND_SERVICE_LOCATION) in gps_tracker/android/app/src/main/AndroidManifest.xml
- [X] T030 [P] [US3] Configure Android AndroidManifest.xml with notification permission (POST_NOTIFICATIONS) in gps_tracker/android/app/src/main/AndroidManifest.xml
- [ ] T031 [US3] Run `flutter build ios --debug` to verify iOS builds with permissions
- [ ] T032 [US3] Run `flutter build apk --debug` to verify Android builds with permissions
- [X] T033 [US3] Document platform permission configuration in CLAUDE.md for future reference

**Checkpoint**: User Story 3 complete - platform permissions are ready for location tracking features

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Final validation and documentation updates

- [ ] T034 Run full quickstart.md validation on clean environment
- [X] T035 [P] Update CLAUDE.md with project commands (flutter pub get, flutter run, supabase start)
- [ ] T036 Verify all success criteria from spec.md are met (SC-001 through SC-005)
- [ ] T037 Clean up any generated files or temporary artifacts

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Story 1 (Phase 3)**: Depends on Foundational (Phase 2)
- **User Story 2 (Phase 4)**: Depends on Foundational (Phase 2) - can run in parallel with US1
- **User Story 3 (Phase 5)**: Depends on Foundational (Phase 2) - can run in parallel with US1/US2
- **Polish (Phase 6)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Depends on Flutter project setup (Phase 2) - tests app launch
- **User Story 2 (P1)**: Depends on Supabase directory (T011) - tests backend infrastructure
- **User Story 3 (P2)**: Depends on Flutter project creation (T001) - tests platform configurations

### Within Each User Story

- Tasks marked [P] within a story can run in parallel
- Sequential tasks depend on prior tasks in that story
- Verification tasks (build/run) must come after configuration tasks

### Parallel Opportunities

**Phase 1 (Setup)**:
```
T003, T004, T005 can run in parallel after T001, T002
```

**Phase 2 (Foundational)**:
```
T008, T009, T010 can run in parallel
```

**Phase 5 (User Story 3)**:
```
T026, T027, T028, T029, T030 can all run in parallel (different files)
```

---

## Parallel Example: User Story 3

```bash
# Launch all iOS config tasks together:
Task: "Configure iOS Info.plist with location permission strings"
Task: "Configure iOS Info.plist with UIBackgroundModes"

# Launch all Android config tasks together:
Task: "Configure Android AndroidManifest.xml with location permissions"
Task: "Configure Android AndroidManifest.xml with foreground service permissions"
Task: "Configure Android AndroidManifest.xml with notification permission"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001-T005)
2. Complete Phase 2: Foundational (T006-T012)
3. Complete Phase 3: User Story 1 (T013-T018)
4. **STOP and VALIDATE**: App launches on both platforms with welcome screen
5. Deploy/demo if ready

### Incremental Delivery

1. Setup + Foundational → Foundation ready
2. Add User Story 1 → Developers can run app → **MVP!**
3. Add User Story 2 → Backend ready for data features
4. Add User Story 3 → Platform permissions ready for GPS tracking
5. Each story adds value without breaking previous stories

### Parallel Team Strategy

With multiple developers:
1. Team completes Setup + Foundational together
2. Once Foundational is done:
   - Developer A: User Story 1 (Flutter app verification)
   - Developer B: User Story 2 (Supabase backend)
   - Developer C: User Story 3 (Platform permissions)
3. Stories complete and integrate independently

---

## Notes

- [P] tasks = different files, no dependencies on incomplete parallel tasks
- [Story] label maps task to specific user story for traceability
- Each user story is independently completable and testable
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- User Stories 1 and 2 are both P1 priority - both critical for foundation
