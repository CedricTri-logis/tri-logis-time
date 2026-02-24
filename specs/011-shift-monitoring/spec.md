# Feature Specification: Shift Monitoring

**Feature Branch**: `011-shift-monitoring`
**Created**: 2026-01-15
**Status**: Draft
**Input**: User description: "Spec 011: Shift Monitoring"

## Clarifications

### Session 2026-01-15

- Q: What is the target platform for the shift monitoring interface? → A: Web dashboard extension (add to existing Next.js admin dashboard at `/admin`)
- Q: How should the dashboard receive real-time data updates for shift status and GPS locations? → A: Supabase Realtime (WebSocket subscriptions for push-based updates)
- Q: How should the dashboard behave when the map provider API is unavailable or rate-limited? → A: Graceful degradation (cached tiles, last known positions with warning, team list remains functional)
- Q: What GPS location data should supervisors be able to access for historical (completed) shifts? → A: Active shifts only (historical shifts show times/durations but no location trail)
- Q: What features should be explicitly out of scope for this shift monitoring feature? → A: Shift editing/approval, geofence/alert configuration, employee messaging, schedule management, payroll integration, route optimization

## Out of Scope

The following features are explicitly excluded from this specification:

- **Shift editing/approval**: Supervisors cannot modify, approve, or reject shifts from this interface (read-only monitoring)
- **Geofence/alert configuration**: No geofence boundaries or automated alerts when employees enter/leave zones
- **Employee messaging**: No direct communication or messaging features to employees
- **Schedule management**: No shift scheduling, assignment, or calendar functionality
- **Payroll integration**: No time-to-payroll calculations or export to payroll systems
- **Route optimization**: No suggested routes or navigation assistance for field workers

## Technical Constraints

- **Platform**: Web dashboard module integrated into the existing Next.js admin dashboard (`/admin`) built in specs 009-010. Uses TypeScript, Next.js 14+ App Router, Refine, shadcn/ui, and Tailwind CSS.
- **Data Sync**: Supabase Realtime WebSocket subscriptions for push-based updates on shift status changes and GPS location updates. No polling required.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Real-Time Team Activity Overview (Priority: P1)

As a supervisor, I need to see which of my team members are currently working and their live status so I can manage workload and respond to operational needs.

**Why this priority**: Real-time visibility into team activity is the core value proposition of shift monitoring. Supervisors need immediate awareness of who is working to make informed decisions about resource allocation and respond to operational issues.

**Independent Test**: Can be fully tested by logging in as a supervisor and viewing a dashboard that shows all supervised employees with their current shift status (active/inactive), displaying live duration for active shifts.

**Acceptance Scenarios**:

1. **Given** I am a supervisor with assigned team members, **When** I access the shift monitoring dashboard, **Then** I see a list of all my supervised employees with their current status (on-shift/off-shift).
2. **Given** one of my team members is currently on an active shift, **When** I view the monitoring dashboard, **Then** I see their shift start time and a live-updating duration counter.
3. **Given** a team member clocks in while I am viewing the dashboard, **When** their shift becomes active, **Then** their status updates to "on-shift" within 30 seconds without requiring a manual page refresh.
4. **Given** a team member clocks out while I am viewing the dashboard, **When** their shift ends, **Then** their status updates to "off-shift" and the shift duration is finalized.

---

### User Story 2 - Live Location Tracking on Map (Priority: P2)

As a supervisor, I need to see the current location of team members who are on active shifts displayed on a map so I can verify they are at expected work locations and coordinate field operations.

**Why this priority**: Location visibility is the defining feature that distinguishes this from a simple status board. It provides supervisors with situational awareness for field workforce management, but only delivers value after the real-time activity overview (P1) is in place.

**Independent Test**: Can be fully tested by having an employee with an active shift transmit GPS coordinates, then viewing a map interface that displays that employee's current location with visual indicators of their accuracy and recency.

**Acceptance Scenarios**:

1. **Given** I am viewing the shift monitoring dashboard with the map view, **When** a team member is on an active shift, **Then** their current location is displayed as a marker on the map.
2. **Given** a team member's GPS location updates, **When** the new coordinates are received, **Then** the marker position updates on the map within 60 seconds.
3. **Given** a team member's location data is stale (older than 5 minutes), **When** I view their marker on the map, **Then** a visual indicator shows the data is not current.
4. **Given** multiple team members are on active shifts, **When** I view the map, **Then** I see all their locations simultaneously with distinguishable markers.

---

### User Story 3 - Individual Shift Detail View (Priority: P3)

As a supervisor, I need to drill down into an individual team member's current or recent shift to see their GPS trail and shift details so I can review their work activity and address any questions about their whereabouts.

**Why this priority**: Detailed shift inspection supports accountability and issue investigation. This builds upon P1 (knowing who is working) and P2 (seeing current location) by adding historical context within a shift.

**Independent Test**: Can be fully tested by selecting an employee from the team list, viewing their shift detail page that displays the complete GPS trail on a map with timestamps and a timeline of their locations.

**Acceptance Scenarios**:

1. **Given** I am viewing the shift monitoring dashboard, **When** I select a team member with an active or recently completed shift, **Then** I see a detail view showing the shift's start time, duration, and all GPS points collected.
2. **Given** I am viewing a shift detail, **When** the shift has GPS points, **Then** I see the GPS trail displayed as a path on a map with start and end markers.
3. **Given** I am viewing an active shift detail, **When** new GPS points are captured, **Then** the trail updates to include the new points within 60 seconds.
4. **Given** I am viewing a shift detail, **When** I hover over or tap a GPS point marker, **Then** I see the timestamp and accuracy of that reading.

---

### User Story 4 - Filtering and Search (Priority: P4)

As a supervisor with a large team, I need to filter and search my team list so I can quickly find specific employees or focus on particular groups.

**Why this priority**: This is an efficiency enhancement that improves usability for supervisors managing larger teams. Core monitoring functionality (P1-P3) must work first before optimizing the discovery experience.

**Independent Test**: Can be fully tested by loading a team list with multiple employees and using search/filter controls to narrow down the displayed results by name, employee ID, or shift status.

**Acceptance Scenarios**:

1. **Given** I am viewing the shift monitoring dashboard with multiple team members, **When** I enter a search term matching an employee name, **Then** the list filters to show only matching employees.
2. **Given** I want to see only currently working team members, **When** I apply an "on-shift" filter, **Then** the list shows only employees with active shifts.
3. **Given** I have applied filters, **When** I clear all filters, **Then** I see the complete list of all supervised employees.

---

### Edge Cases

- What happens when an employee has an active shift but no GPS data has been received yet? The employee should appear in the list with "on-shift" status, but their location should show as "Location pending" rather than displaying an empty map or error.
- What happens when GPS accuracy is very poor (>100 meters)? The location marker should include a visual indicator (e.g., larger radius circle) showing the uncertainty, and a warning badge indicating poor accuracy.
- What happens when a supervisor has no assigned team members? The dashboard should display an informative empty state explaining that no employees are currently assigned for supervision.
- What happens when network connectivity is lost while viewing the dashboard? The dashboard should display a connectivity warning and show the last known data with timestamps indicating when data was last refreshed.
- What happens when the map provider API is unavailable or rate-limited? The dashboard gracefully degrades: cached map tiles display if available, markers show last known positions with a "map service unavailable" warning banner, and the team list remains fully functional.
- What happens when an employee is supervised by multiple managers (matrix supervision)? Each supervisor should see the employee in their own monitoring view with identical data.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST display a list of all employees under the supervisor's direct, matrix, or temporary supervision with their current shift status (on-shift/off-shift).
- **FR-002**: System MUST show live-updating shift duration for employees currently on active shifts, updating at minimum every 60 seconds.
- **FR-003**: System MUST automatically refresh team status data without requiring manual page reload, with updates reflected within 60 seconds of database changes.
- **FR-004**: System MUST display current GPS location of on-shift employees on an interactive map.
- **FR-005**: System MUST visually indicate when location data is stale (not updated within 5 minutes).
- **FR-006**: System MUST display GPS accuracy information for each location reading.
- **FR-007**: System MUST allow supervisors to view detailed shift information for any supervised employee's shift; GPS trail is available only for currently active shifts, while historical shifts display times and durations without location data.
- **FR-008**: System MUST render GPS trails as a connected path showing the employee's movement during a shift.
- **FR-009**: System MUST allow filtering the employee list by shift status (all, on-shift, off-shift).
- **FR-010**: System MUST allow searching employees by name or employee ID.
- **FR-011**: System MUST respect existing Row-Level Security policies, only showing data for employees the supervisor is authorized to view.
- **FR-012**: System MUST display appropriate empty states when no data is available (no team members, no location data, no shifts).
- **FR-013**: System MUST provide visual feedback when data is being refreshed or when an error occurs.

### Key Entities

- **Supervised Employee**: An employee who is under the supervisor's current direct, matrix, or temporary supervision relationship. Has attributes: name, employee ID, current shift status, current location (if on-shift).
- **Active Shift**: A work session that is currently in progress (clocked in but not clocked out). Has attributes: start time, duration (live-calculated), clock-in location.
- **GPS Trail**: An ordered sequence of GPS points captured during a shift, representing the employee's movement path. Has attributes: collection of GPS points with coordinates, timestamps, and accuracy readings.
- **Location Marker**: A visual representation of an employee's position on a map. Has attributes: coordinates, timestamp, accuracy radius, staleness indicator.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Supervisors can identify which team members are currently on-shift within 5 seconds of accessing the monitoring dashboard.
- **SC-002**: Employee status changes (clock-in/clock-out) are reflected in the dashboard within 60 seconds of occurrence.
- **SC-003**: Supervisors can locate any on-shift employee's position on the map within 10 seconds of viewing the dashboard.
- **SC-004**: GPS trail for a shift loads and displays within 3 seconds for shifts with up to 500 GPS points.
- **SC-005**: Dashboard remains responsive and usable when monitoring teams of up to 50 employees.
- **SC-006**: 90% of supervisors can successfully identify an employee's current location without additional training or documentation.
- **SC-007**: System displays accurate location data (no more than 60 seconds old under normal network conditions).
- **SC-008**: Supervisors can access shift history (start time, end time, duration) for any shift from the past 30 days; GPS trails are only available for currently active shifts.
