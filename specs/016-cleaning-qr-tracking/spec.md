# Feature Specification: Cleaning Session Tracking via QR Code

**Feature Branch**: `016-cleaning-qr-tracking`
**Created**: 2026-02-12
**Status**: Draft
**Input**: Track housekeeping of short-term rental units via QR code scanning — employees scan when entering and leaving each room.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Scan In to Start Cleaning a Room (Priority: P1)

A cleaning employee is on shift (already clocked in). They arrive at a studio/room and see a QR code installed beside the door. They open the app, tap "Scan", and scan the QR code. The app recognizes the studio (e.g., "Studio 201 — Le Citadin") and confirms the cleaning session has started. A timer begins counting the duration.

**Why this priority**: This is the core action — without scan-in, nothing else works. It establishes the link between employee, room, and time.

**Independent Test**: Can be fully tested by scanning a QR code in the app while on an active shift. Delivers immediate value by recording which employee started cleaning which room and when.

**Acceptance Scenarios**:

1. **Given** an employee is clocked into an active shift, **When** they scan a valid studio QR code, **Then** a cleaning session is created with the current timestamp as start time, and the app shows the studio name, building, and a running timer.
2. **Given** an employee scans a QR code that is not recognized (invalid code), **When** the scan completes, **Then** the app shows an error message indicating the QR code is not registered, and no session is created.
3. **Given** an employee is NOT on an active shift, **When** they try to scan a QR code, **Then** the app prompts them to clock in first before scanning.
4. **Given** an employee already has an active cleaning session for a room, **When** they scan a DIFFERENT room's QR code, **Then** the app warns them they have an unclosed session and asks whether to close it first or cancel.

---

### User Story 2 - Scan Out to Complete Cleaning (Priority: P1)

After finishing cleaning a room, the employee scans the same QR code again. The app detects that an active session exists for this room and closes it, recording the end time. The session duration is calculated and displayed.

**Why this priority**: Equally critical as scan-in — the pair of scans forms the complete tracking record.

**Independent Test**: Can be tested by scanning a QR code for a room with an active session. Delivers value by recording the cleaning completion time and duration.

**Acceptance Scenarios**:

1. **Given** an employee has an active cleaning session for Studio 201, **When** they scan Studio 201's QR code again, **Then** the session is closed with the current timestamp, duration is calculated and displayed, and the session status changes to "completed".
2. **Given** an employee scans a room's QR code to close a session, **When** the duration is unusually short (under 5 minutes for a studio, under 2 minutes for common areas), **Then** the app shows a brief warning but still allows closing the session.
3. **Given** a cleaning session has been open for more than 4 hours, **When** the employee scans to close it, **Then** the app flags the session as "review needed" and still closes it.

---

### User Story 3 - View Active Cleaning Session (Priority: P1)

While cleaning, the employee can see their current active session on the app's main screen — showing room name, building, start time, and a live running timer. This gives them visibility without needing to re-scan.

**Why this priority**: Employees need real-time feedback to know they scanned correctly and to track their time.

**Independent Test**: Can be tested by starting a cleaning session and verifying the timer and session details display on the main screen.

**Acceptance Scenarios**:

1. **Given** an employee has an active cleaning session, **When** they view the main screen, **Then** they see the studio name, building name, start time, and a live duration counter.
2. **Given** an employee has no active cleaning session, **When** they view the main screen, **Then** they see a prompt to scan a QR code to begin cleaning.

---

### User Story 4 - View Cleaning History for Current Shift (Priority: P2)

An employee can see a list of all rooms they've cleaned during their current shift — with room name, building, duration, and status (completed / in progress). This lets them track their progress throughout the day.

**Why this priority**: Supports employee self-management and gives a sense of accomplishment during a shift.

**Independent Test**: Can be tested by completing multiple cleaning sessions in a shift and viewing the list.

**Acceptance Scenarios**:

1. **Given** an employee has completed 3 cleaning sessions and has 1 active, **When** they view their shift history, **Then** all 4 sessions appear in chronological order with correct statuses and durations.
2. **Given** an employee starts a new shift, **When** they view the cleaning history, **Then** the list is empty (only shows current shift sessions).

---

### User Story 5 - Dashboard: View Cleaning Sessions Overview (Priority: P2)

A supervisor opens the web dashboard and sees a summary of today's cleaning activity across all buildings. They can see which rooms have been cleaned, which are in progress, and which haven't been cleaned yet. They can filter by building, date range, and employee.

**Why this priority**: Management visibility is essential for operations but depends on employees generating cleaning data first.

**Independent Test**: Can be tested by viewing the dashboard after cleaning sessions have been recorded. Delivers value by showing operational status at a glance.

**Acceptance Scenarios**:

1. **Given** cleaning sessions exist for today, **When** a supervisor opens the cleaning dashboard, **Then** they see a summary showing total rooms cleaned, rooms in progress, average cleaning time, and sessions by building.
2. **Given** a supervisor selects a specific building, **When** they view the filtered list, **Then** only studios from that building appear with their cleaning status (cleaned, in-progress, not started).
3. **Given** a supervisor selects a date range, **When** results load, **Then** they see all cleaning sessions within that period with aggregate statistics.

---

### User Story 6 - Dashboard: Cleaning Session Detail & Analytics (Priority: P3)

A supervisor clicks on a specific studio or employee to see detailed cleaning history — including cleaning frequency, average duration, and trends over time. This helps identify performance patterns and scheduling needs.

**Why this priority**: Analytics and detailed views are valuable but build on top of the core data already captured by P1 and P2 stories.

**Independent Test**: Can be tested by navigating to a studio detail page and verifying historical data and statistics display correctly.

**Acceptance Scenarios**:

1. **Given** a supervisor views a specific studio's detail page, **When** the page loads, **Then** they see cleaning history (date, employee, duration), average cleaning time, and cleaning frequency.
2. **Given** a supervisor views an employee's cleaning performance, **When** the page loads, **Then** they see total rooms cleaned, average time per room, and sessions grouped by building.

---

### Edge Cases

- What happens when the employee's phone camera cannot read the QR code? The app provides manual entry as a fallback — the employee types the QR code ID printed on the physical label below the QR code.
- What happens when the same room is scanned by two different employees (e.g., team cleaning)? Each employee gets their own independent cleaning session for the same room.
- What happens if the app crashes or the phone dies mid-session? The session remains open. The employee can scan out later, or a supervisor can manually close the session from the dashboard.
- What happens if an employee forgets to scan out and clocks out of their shift? All open cleaning sessions for that employee are automatically closed when the shift ends, marked with status "auto-closed".
- What happens if a QR code is damaged or unreadable? The employee uses the manual fallback (entering QR code ID text) or contacts a supervisor.
- What happens when scanning a QR code for a deactivated or deleted studio? The app shows an error that the studio is no longer active.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST allow employees to scan QR codes using their device camera to identify a studio/room.
- **FR-002**: System MUST create a cleaning session when an employee scans a QR code for a room they are not currently cleaning (scan-in).
- **FR-003**: System MUST close an active cleaning session when the employee scans the same room's QR code again (scan-out).
- **FR-004**: System MUST record start time, end time, and calculated duration for each cleaning session.
- **FR-005**: System MUST link each cleaning session to the employee, the studio, and the active shift.
- **FR-006**: System MUST display the active cleaning session (room name, building, timer) on the employee's main screen.
- **FR-007**: System MUST show a list of all cleaning sessions completed during the current shift.
- **FR-008**: System MUST validate that the scanned QR code maps to a registered studio before creating a session.
- **FR-009**: System MUST prevent creating a new cleaning session if the employee is not on an active shift.
- **FR-010**: System MUST warn employees when they scan a different room while an active session is open.
- **FR-011**: System MUST automatically close all open cleaning sessions when an employee's shift ends (clock-out).
- **FR-012**: System MUST provide a manual QR code ID entry as fallback when camera scanning fails.
- **FR-013**: System MUST allow multiple employees to have concurrent sessions for the same room (team cleaning).
- **FR-014**: System MUST store all studio/room data with their QR code IDs, studio numbers, and building names.
- **FR-015**: System MUST provide a dashboard view for supervisors showing cleaning activity by building, employee, and date.
- **FR-016**: System MUST provide per-studio and per-employee cleaning analytics (average duration, frequency, history).
- **FR-017**: System MUST flag sessions with unusually short or long durations for review.
- **FR-018**: System MUST allow supervisors to manually close orphaned cleaning sessions from the dashboard.

### Key Entities

- **Building**: A physical property containing multiple studios. Has a name (e.g., "Le Citadin"). Groups studios for reporting and filtering.
- **Studio**: An individual rental unit, common area, or conciergerie within a building. Identified by a unique QR code ID and a human-readable studio number (e.g., "201"). Types include: rental unit, common area ("Aires communes"), conciergerie.
- **Cleaning Session**: A record of one employee cleaning one studio. Tracks start time, end time, duration, and status. Linked to an employee, a studio, and a shift.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Employees can start a cleaning session (scan in) in under 10 seconds from opening the scanner.
- **SC-002**: 100% of cleaning sessions are linked to a verified studio via QR code — no room selection errors.
- **SC-003**: Supervisors can view today's cleaning status for any building within 3 clicks from the dashboard home.
- **SC-004**: All open cleaning sessions are automatically resolved when shifts end — zero orphaned sessions after 24 hours.
- **SC-005**: The system accurately tracks cleaning duration to within 1 minute of actual time spent.
- **SC-006**: Supervisors can identify rooms not yet cleaned today within 30 seconds using the dashboard.
- **SC-007**: The system supports all 100+ studios across 10 buildings with their QR code mappings from day one.

## Assumptions

- Physical QR code labels are already printed and installed beside each room. The QR code encodes only the unique ID string (e.g., "8FJ3K2L9H4"), not a URL.
- The employee's device has a working camera for QR scanning.
- Employees are already familiar with the clock-in/clock-out shift system (existing feature).
- Studios, common areas, and conciergerie entries are all treated as "studios" with different type classifications.
- The 10 buildings and ~100+ studios listed by the user represent the complete initial dataset to be seeded.
- Cleaning sessions are only valid during an active shift — no off-shift cleaning tracking.
- Supervisors have existing dashboard access via the web application (specs 009+).
- Session duration warnings (too short / too long) are informational only and do not block session completion.
