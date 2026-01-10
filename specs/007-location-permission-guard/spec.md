# Feature Specification: Location Permission Guard

**Feature Branch**: `007-location-permission-guard`
**Created**: 2026-01-10
**Status**: Draft
**Input**: User description: "Spec 007: Location Permission Guard"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Permission Status Awareness (Priority: P1)

An employee opens the app and immediately sees their current location permission status. If permissions are insufficient for GPS tracking, they see a clear, non-intrusive indicator that prompts them to take action before they need to clock in. This prevents the frustrating experience of discovering permission issues only when trying to start a shift.

**Why this priority**: This is foundational - users cannot effectively use the app's core functionality (GPS tracking during shifts) without proper permissions. Proactive awareness prevents failed clock-ins and reduces support burden.

**Independent Test**: Can be fully tested by opening the app with various permission states (denied, while-in-use, always) and verifying the appropriate status indicator appears with actionable guidance.

**Acceptance Scenarios**:

1. **Given** an employee has not granted any location permission, **When** they open the app dashboard, **Then** they see a prominent indicator showing location access is required with a clear call-to-action.
2. **Given** an employee has granted "while in use" permission but not "always" permission, **When** they open the app dashboard, **Then** they see an indicator suggesting they upgrade to full background access for uninterrupted tracking.
3. **Given** an employee has granted full "always" location permission, **When** they open the app dashboard, **Then** they see no permission warning (or a subtle confirmation that permissions are properly configured).

---

### User Story 2 - Guided Permission Request Flow (Priority: P1)

When an employee needs to grant or upgrade location permissions, they are guided through a clear, educational flow that explains why the permission is needed and how to grant it. The flow adapts based on the current permission state and whether the user has previously denied the request.

**Why this priority**: Without clear guidance, users often deny permissions they don't understand, leading to broken functionality. This story directly enables core app features.

**Independent Test**: Can be tested by triggering the permission flow from various states (first-time, previously denied, permanently denied) and verifying appropriate guidance appears.

**Acceptance Scenarios**:

1. **Given** an employee has never been asked for location permission, **When** they tap to grant permission, **Then** they see an explanation of why location is needed before the system permission dialog appears.
2. **Given** an employee previously denied location permission, **When** they tap to grant permission, **Then** they see the explanation again and the system permission dialog is shown.
3. **Given** an employee permanently denied location permission, **When** they tap to grant permission, **Then** they are shown step-by-step instructions to enable it in device settings with a button to open settings.
4. **Given** an employee is on the permission explanation screen, **When** they dismiss without granting, **Then** they return to the previous screen with the permission indicator still visible.

---

### User Story 3 - Pre-Shift Permission Check (Priority: P2)

Before an employee attempts to clock in, the system checks if location permissions are sufficient. If not, the employee is guided to fix the issue before proceeding, preventing failed clock-in attempts and ensuring location data can be captured.

**Why this priority**: While P1 stories provide proactive awareness, this story acts as a safety net at the critical moment of clocking in, preventing data gaps.

**Independent Test**: Can be tested by attempting to clock in with various permission states and verifying the appropriate blocking or warning behavior occurs.

**Acceptance Scenarios**:

1. **Given** an employee has no location permission, **When** they attempt to clock in, **Then** they are blocked and shown the permission request flow before proceeding.
2. **Given** an employee has "while in use" permission only, **When** they attempt to clock in, **Then** they are warned that background tracking may be interrupted and offered to upgrade permissions (but allowed to proceed).
3. **Given** an employee has full "always" permission, **When** they attempt to clock in, **Then** they proceed immediately without any permission-related interruption.

---

### User Story 4 - Real-Time Permission Monitoring (Priority: P2)

During an active shift, the system monitors location permission status. If permissions are revoked or downgraded (e.g., user changes settings mid-shift), the employee is notified and guided to restore permissions to prevent data loss.

**Why this priority**: Protects data integrity during active tracking sessions. Less critical than initial permission setup but important for complete tracking coverage.

**Independent Test**: Can be tested by starting a shift, then revoking location permission via device settings, and verifying the app responds with appropriate notification and guidance.

**Acceptance Scenarios**:

1. **Given** an employee has an active shift with background tracking, **When** they revoke location permission via device settings, **Then** they receive a notification (if app is backgrounded) or in-app alert (if app is open) prompting them to restore permission.
2. **Given** an employee downgrades from "always" to "while in use" during a shift, **When** the app detects this change, **Then** they see a warning that tracking may be interrupted when the app is backgrounded.
3. **Given** permissions are revoked during an active shift, **When** the employee restores permissions, **Then** tracking resumes automatically without requiring manual intervention.

---

### User Story 5 - Permission Recovery Assistance (Priority: P3)

When an employee has permanently denied permissions and needs to use the app, they receive clear, platform-specific instructions on how to navigate to the correct settings screen and what options to select.

**Why this priority**: Addresses a recovery scenario that affects a subset of users but is critical for those affected. Without this, permanently-denied users are effectively locked out.

**Independent Test**: Can be tested by permanently denying permission and verifying the recovery flow provides accurate, platform-specific instructions.

**Acceptance Scenarios**:

1. **Given** an employee on iOS has permanently denied location permission, **When** they view the permission recovery screen, **Then** they see iOS-specific instructions (Settings > GPS Tracker > Location > Always).
2. **Given** an employee on Android has permanently denied location permission, **When** they view the permission recovery screen, **Then** they see Android-specific instructions (Settings > Apps > GPS Tracker > Permissions > Location > Allow all the time).
3. **Given** an employee taps "Open Settings" on the recovery screen, **When** the device settings open, **Then** the employee can navigate to the correct location and the app detects the change when they return.

---

### Edge Cases

- What happens when location services are disabled at the device level (not just app permission)?
  - System shows a specific message directing user to enable location services in device settings, distinct from app permission messaging.
- How does the system handle permission state changes while the app is in the background?
  - When app returns to foreground, permission state is re-checked and UI is updated accordingly.
- What if the user grants "while in use" but the app needs "always" for background tracking?
  - User is warned but allowed to proceed; tracking works when app is visible but may pause when backgrounded.
- What happens on Android when battery optimization is not disabled?
  - User is informed that background tracking may be affected and offered guidance to disable battery optimization.
- How does the system handle rapid permission changes (user toggling permissions quickly)?
  - Permission state is debounced to prevent UI flicker; final state is what matters.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST display the current location permission status as a persistent top banner on the main dashboard within 2 seconds of app launch; the banner pushes content down when permissions are insufficient and is hidden when permissions are fully granted.
- **FR-002**: System MUST differentiate between permission levels: not determined, denied, denied permanently, while-in-use only, and always/full access.
- **FR-003**: System MUST provide a clear call-to-action when permissions are insufficient for GPS tracking functionality.
- **FR-004**: System MUST show an educational explanation before requesting location permission for the first time.
- **FR-005**: System MUST detect when permission has been permanently denied and show settings navigation instructions instead of re-requesting.
- **FR-006**: System MUST provide platform-specific instructions (iOS vs Android) for navigating device settings.
- **FR-007**: System MUST include a button to open the device settings app directly from the permission recovery screen.
- **FR-008**: System MUST block clock-in attempts when no location permission has been granted.
- **FR-009**: System MUST warn (but not block) clock-in attempts when only "while in use" permission is granted.
- **FR-010**: System MUST re-check permission status when the app returns to the foreground.
- **FR-011**: System MUST detect permission changes during an active shift and notify the user.
- **FR-012**: System MUST automatically resume tracking when permissions are restored during an active shift.
- **FR-013**: System MUST detect when device-level location services are disabled and show appropriate guidance.
- **FR-014**: System MUST request battery optimization exemption on Android and explain its importance for uninterrupted tracking.
- **FR-015**: System MUST allow users to dismiss permission prompts and reminders without immediately fixing the issue.
- **FR-016**: System MUST persist the user's acknowledgment of permission warnings within a single app session to avoid repetitive prompting; acknowledgment resets when the app is fully restarted.

### Key Entities

- **PermissionStatus**: Represents the current state of location permission (level, last checked, can request, requires settings).
- **PermissionPrompt**: Educational content shown before requesting permission (title, explanation, benefits, platform-specific guidance).
- **SettingsGuidance**: Platform-specific navigation instructions for granting permission via device settings.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 95% of employees with insufficient permissions see the permission status indicator within 3 seconds of opening the app.
- **SC-002**: 80% of employees complete the permission grant flow on their first attempt when guided by the educational screens.
- **SC-003**: Zero clock-in attempts fail silently due to permission issues - all permission problems are communicated to the user before or during the clock-in attempt.
- **SC-004**: Employees can restore permissions from a "permanently denied" state in under 60 seconds when following the in-app guidance.
- **SC-005**: Permission changes during active shifts are detected and communicated to users within 5 seconds.
- **SC-006**: Tracking automatically resumes within 10 seconds of permission restoration during an active shift.
- **SC-007**: App accurately distinguishes between device location services being disabled vs. app-specific permission being denied.

## Clarifications

### Session 2026-01-10

- Q: Where should the permission status indicator be displayed on the dashboard? → A: Top banner (persistent, pushes content down when insufficient)
- Q: How long should the dismissed warning acknowledgment persist before showing the warning again? → A: Reset once per app session (show again after full app restart)

## Assumptions

- Users have basic familiarity with their device's settings app.
- The app already has infrastructure for location permission checking and requesting (confirmed by codebase exploration).
- Background tracking requires "always" permission for optimal functionality, but "while in use" provides partial functionality.
- Battery optimization affects Android background tracking reliability.
- iOS and Android have different permission flows and terminology that require platform-specific handling.
- Users may change permissions via device settings at any time, including during active shifts.
