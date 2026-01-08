# Tasks: Employee Authentication

**Input**: Design documents from `/specs/002-employee-auth/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/auth-api.md

**Tests**: Not explicitly requested in the specification - tests are NOT included in this task list. Add test tasks if TDD is required.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3, US4, US5)
- Include exact file paths in descriptions

## Path Conventions

Based on plan.md structure:
- **Flutter app**: `gps_tracker/lib/`
- **Auth feature**: `gps_tracker/lib/features/auth/`
- **Shared code**: `gps_tracker/lib/shared/`

---

## Phase 1: Setup

**Purpose**: Verify project readiness and add required dependencies

- [X] T001 Verify Spec 001 foundation is complete (flutter analyze passes, supabase_flutter installed)
- [X] T002 Add flutter_secure_storage 9.2.4 dependency to gps_tracker/pubspec.yaml and run flutter pub get
- [X] T003 Create auth feature directory structure at gps_tracker/lib/features/auth/ with models/, providers/, screens/, services/, widgets/ subdirectories

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**CRITICAL**: No user story work can begin until this phase is complete

- [X] T004 Create EmployeeProfile model with fromJson/toJson in gps_tracker/lib/features/auth/models/employee_profile.dart
- [X] T005 Create AuthService class wrapping Supabase auth methods in gps_tracker/lib/features/auth/services/auth_service.dart
- [X] T006 [P] Create email validator utility in gps_tracker/lib/features/auth/services/validators.dart
- [X] T007 [P] Create password validator utility (8+ chars, letters + numbers) in gps_tracker/lib/features/auth/services/validators.dart
- [X] T008 [P] Create AuthRateLimiter class (5 attempts per 15 minutes) in gps_tracker/lib/features/auth/services/auth_rate_limiter.dart
- [X] T009 Add auth providers (authStateChangesProvider, currentUserProvider, isAuthenticatedProvider, authServiceProvider) to gps_tracker/lib/shared/providers/supabase_provider.dart
- [X] T010 [P] Create reusable AuthFormField widget in gps_tracker/lib/features/auth/widgets/auth_form_field.dart
- [X] T011 [P] Create reusable AuthButton widget in gps_tracker/lib/features/auth/widgets/auth_button.dart
- [X] T012 [P] Create error_snackbar widget for displaying auth errors in gps_tracker/lib/shared/widgets/error_snackbar.dart

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - Employee Sign In (Priority: P1)

**Goal**: Allow employees to sign in with email/password and access the main dashboard

**Independent Test**: Launch app, enter valid credentials, verify user is authenticated and sees dashboard. Enter invalid credentials, verify error message is shown.

### Implementation for User Story 1

- [X] T013 [US1] Create SignInScreen with email/password form in gps_tracker/lib/features/auth/screens/sign_in_screen.dart
- [X] T014 [US1] Add form validation (email format, password required) to SignInScreen
- [X] T015 [US1] Implement sign-in button handler calling AuthService.signIn() with loading state
- [X] T016 [US1] Add error handling and display user-friendly messages using error_snackbar
- [X] T017 [US1] Integrate rate limiter to prevent brute force attempts
- [X] T018 [US1] Update gps_tracker/lib/app.dart to show SignInScreen when unauthenticated, HomeScreen when authenticated
- [X] T019 [US1] Add "Forgot Password?" navigation link to SignInScreen (links to Phase 5)
- [X] T020 [US1] Add "Create Account" navigation link to SignInScreen (links to Phase 4)

**Checkpoint**: User Story 1 complete - employees can sign in and stay signed in across app restarts

---

## Phase 4: User Story 2 - Employee Account Creation (Priority: P1)

**Goal**: Allow new employees to create accounts with email verification

**Independent Test**: Open app as new user, complete registration, verify email is sent, confirm email, verify can sign in.

### Implementation for User Story 2

- [X] T021 [US2] Create SignUpScreen with email/password/confirm password form in gps_tracker/lib/features/auth/screens/sign_up_screen.dart
- [X] T022 [US2] Add form validation (email format, password requirements FR-006, password confirmation match)
- [X] T023 [US2] Implement sign-up button handler calling AuthService.signUp() with loading state
- [X] T024 [US2] Add success state showing "Check your email for verification link" message
- [X] T025 [US2] Add error handling for email already registered and other signup errors
- [X] T026 [US2] Add navigation back to SignInScreen after successful registration

**Checkpoint**: User Story 2 complete - new employees can create accounts and receive verification emails

---

## Phase 5: User Story 3 - Password Recovery (Priority: P2)

**Goal**: Allow employees to reset forgotten passwords via email

**Independent Test**: Request password reset for existing account, click reset link in email, enter new password, verify can sign in with new password.

### Implementation for User Story 3

- [X] T027 [US3] Create ForgotPasswordScreen with email input in gps_tracker/lib/features/auth/screens/forgot_password_screen.dart
- [X] T028 [US3] Implement "Send Reset Link" button calling AuthService.resetPassword()
- [X] T029 [US3] Add success state showing "Check your email for reset link" message
- [X] T030 [US3] Add auth state listener for AuthChangeEvent.passwordRecovery in AuthService
- [X] T031 [US3] Create password update flow when password recovery event is detected (show new password form)
- [X] T032 [US3] Implement AuthService.updatePassword() for setting new password
- [X] T033 [US3] Add navigation back to SignInScreen after successful password reset

**Checkpoint**: User Story 3 complete - employees can recover access to their accounts

---

## Phase 6: User Story 4 - Employee Sign Out (Priority: P2)

**Goal**: Allow employees to sign out and end their session

**Independent Test**: Sign in, tap sign out, verify returned to sign-in screen, verify cannot access protected screens.

### Implementation for User Story 4

- [X] T034 [US4] Create AuthGuard widget to protect routes from unauthenticated access in gps_tracker/lib/shared/routing/auth_guard.dart
- [X] T035 [US4] Add sign out option to HomeScreen (settings icon or menu) in gps_tracker/lib/features/home/home_screen.dart
- [X] T036 [US4] Implement sign out handler calling AuthService.signOut()
- [X] T037 [US4] Ensure local session is cleared on sign out (automatic via Supabase)
- [X] T038 [US4] Navigate to SignInScreen after sign out

**Checkpoint**: User Story 4 complete - employees can securely sign out

---

## Phase 7: User Story 5 - Profile Information Management (Priority: P3)

**Goal**: Allow employees to view and update their profile information

**Independent Test**: Sign in, navigate to profile settings, view current info, update display name, verify change is saved.

### Implementation for User Story 5

- [X] T039 [US5] Create ProfileProvider for fetching and updating profile in gps_tracker/lib/features/auth/providers/profile_provider.dart
- [X] T040 [US5] Create ProfileScreen displaying user info (name, email, employee ID) in gps_tracker/lib/features/auth/screens/profile_screen.dart
- [X] T041 [US5] Add edit mode for full_name field with save button
- [X] T042 [US5] Implement profile update calling Supabase employee_profiles table
- [X] T043 [US5] Display email as read-only (cannot be changed via this screen)
- [X] T044 [US5] Add navigation to ProfileScreen from HomeScreen or settings menu
- [X] T045 [US5] Add loading and error states for profile operations

**Checkpoint**: User Story 5 complete - employees can view and update their profile

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

- [X] T046 Add offline session handling - allow cached session access when offline per research.md
- [X] T047 Implement graceful token refresh when connectivity returns
- [X] T048 Add constants for auth-related values (error messages, timeouts) to gps_tracker/lib/core/config/constants.dart
- [X] T049 Verify all auth screens follow Material Design guidelines and match app theme
- [X] T050 Run flutter analyze and fix any linting issues in auth feature
- [X] T051 Manual testing per quickstart.md validation checklist

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phase 3-7)**: All depend on Foundational phase completion
  - US1 (Sign In) and US2 (Sign Up) are both P1 - can proceed in parallel
  - US3 (Password Recovery) and US4 (Sign Out) are P2 - can proceed in parallel after foundational
  - US5 (Profile) is P3 - can proceed after foundational
- **Polish (Phase 8)**: Depends on all desired user stories being complete

### User Story Dependencies

- **User Story 1 (Sign In)**: Depends only on Foundational - No other story dependencies
- **User Story 2 (Sign Up)**: Depends only on Foundational - No other story dependencies (links to US1 screen for navigation)
- **User Story 3 (Password Recovery)**: Depends only on Foundational - Links to US1 screen for navigation
- **User Story 4 (Sign Out)**: Depends only on Foundational - Requires US1 to test (must sign in first)
- **User Story 5 (Profile)**: Depends only on Foundational - Requires US1 to test (must sign in first)

### Within Each User Story

- Core UI (Screen) before handlers
- Handlers before navigation links
- Form validation before submit
- Loading states before error handling

### Parallel Opportunities

**Foundational Phase:**
```
T006 [P] Email validator
T007 [P] Password validator
T008 [P] Rate limiter
T010 [P] AuthFormField widget
T011 [P] AuthButton widget
T012 [P] Error snackbar widget
```

**User Stories (after Foundational):**
```
US1 (Sign In) and US2 (Sign Up) can run in parallel - different screens
US3, US4, US5 can run in parallel - different screens/features
```

---

## Parallel Example: Foundational Phase

```bash
# Launch all parallelizable foundational tasks together:
Task: "Create email validator utility in gps_tracker/lib/features/auth/services/validators.dart"
Task: "Create password validator utility in gps_tracker/lib/features/auth/services/validators.dart"
Task: "Create AuthRateLimiter class in gps_tracker/lib/features/auth/services/auth_rate_limiter.dart"
Task: "Create reusable AuthFormField widget in gps_tracker/lib/features/auth/widgets/auth_form_field.dart"
Task: "Create reusable AuthButton widget in gps_tracker/lib/features/auth/widgets/auth_button.dart"
Task: "Create error_snackbar widget in gps_tracker/lib/shared/widgets/error_snackbar.dart"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL - blocks all stories)
3. Complete Phase 3: User Story 1 (Sign In)
4. **STOP and VALIDATE**: Test sign-in independently
5. Employees can now use the app with manual account creation in Supabase

### Incremental Delivery

1. Setup + Foundational → Foundation ready
2. Add User Story 1 (Sign In) → Test → Deploy (Basic MVP!)
3. Add User Story 2 (Sign Up) → Test → Deploy (Self-registration!)
4. Add User Story 3 (Password Recovery) → Test → Deploy
5. Add User Story 4 (Sign Out) → Test → Deploy
6. Add User Story 5 (Profile) → Test → Deploy (Complete Auth!)
7. Each story adds value without breaking previous stories

### Suggested MVP Scope

**Minimum**: Complete through User Story 1 (Sign In)
- Employees can sign in with credentials
- Sessions persist across app restarts
- Basic auth flow working

**Recommended MVP**: Complete through User Story 2 (Sign Up)
- Adds self-registration capability
- Full onboarding flow for new employees

---

## Notes

- [P] tasks = different files, no dependencies on incomplete tasks
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- Database schema (employee_profiles) already exists from Spec 001
- Supabase Auth handles password hashing, email verification, and token management
- flutter_secure_storage handles secure session persistence automatically
