# Feature Specification: Location Geofences & Shift Segmentation

**Feature Branch**: `015-location-geofences`
**Created**: 2026-01-16
**Status**: Draft
**Input**: User description: Implement workplace location management (geofences) with automatic shift timeline segmentation based on GPS position

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Manage Workplace Locations (Priority: P1)

A supervisor needs to create and manage geographic zones (geofences) representing workplaces such as offices, construction sites, vendors, and employee homes. They can set a name, type, coordinates, and detection radius for each location.

**Why this priority**: Core functionality - without locations defined, no shift segmentation is possible. This is the foundation for all other features.

**Independent Test**: Can be fully tested by creating, editing, and deleting locations. Delivers immediate value by providing a centralized database of work locations.

**Acceptance Scenarios**:

1. **Given** a supervisor is on the locations page, **When** they click "Add Location", **Then** they see a form with name, type (office/building/vendor/home/other), coordinates, radius (10-1000m), address, and notes fields
2. **Given** a supervisor enters an address, **When** they click "Geocode", **Then** the system converts the address to latitude/longitude and updates the map marker
3. **Given** a supervisor is creating a location, **When** they click on the interactive map, **Then** the coordinates update to the clicked position
4. **Given** a supervisor adjusts the radius slider, **When** the value changes, **Then** the geofence circle on the map updates in real-time
5. **Given** a location exists, **When** a supervisor edits it, **Then** all fields are pre-populated and changes are saved
6. **Given** a location exists, **When** a supervisor toggles "active" off, **Then** the location is excluded from GPS matching but retained for historical data

---

### User Story 2 - View Shift Timeline with Location Segments (Priority: P1)

A supervisor viewing an employee's completed shift wants to see a visual timeline showing where the employee spent time during their shift. The timeline displays colored segments representing different location types (office, building, vendor, home, travel, unmatched).

**Why this priority**: Primary user value - supervisors need visibility into employee work patterns and location-based time allocation.

**Independent Test**: Can be tested by viewing any shift with GPS data. The timeline renders segments based on GPS points matched to locations.

**Acceptance Scenarios**:

1. **Given** a completed shift with GPS data, **When** a supervisor views the shift details, **Then** a horizontal timeline bar displays segments colored by location type
2. **Given** the timeline is displayed, **When** a supervisor hovers over a segment, **Then** a tooltip shows the location name, duration, and GPS point count
3. **Given** GPS points fall within a location's geofence, **When** the timeline is generated, **Then** those points are grouped into a segment with the location's type color
4. **Given** GPS points fall outside all defined geofences, **When** the timeline is generated, **Then** those points are marked as "unmatched" (red)
5. **Given** GPS points transition between locations, **When** the timeline is generated, **Then** "travel" segments (yellow) appear between location segments

---

### User Story 3 - View Timeline Summary Statistics (Priority: P2)

A supervisor wants to see a summary of time spent at each location type during a shift, displayed as percentages and durations.

**Why this priority**: Enhances the timeline feature by providing aggregate data for quick assessment of work patterns.

**Independent Test**: Can be tested by viewing the summary panel alongside any shift timeline.

**Acceptance Scenarios**:

1. **Given** a shift timeline is displayed, **When** the supervisor views the summary, **Then** they see total time and breakdown by location type
2. **Given** the summary is displayed, **When** segments of a type exist, **Then** the duration and percentage for that type are shown
3. **Given** a shift has multiple locations of the same type, **When** viewing summary, **Then** times are aggregated across all locations of that type

---

### User Story 4 - Bulk Import Locations via CSV (Priority: P2)

A supervisor with many existing work locations wants to import them in bulk via CSV file rather than entering each one manually.

**Why this priority**: Efficiency feature for initial setup. The JSON seed data with 77 locations demonstrates the need for bulk import.

**Independent Test**: Can be tested by uploading a CSV file with location data and verifying all records are created.

**Acceptance Scenarios**:

1. **Given** a supervisor is on the locations page, **When** they click "Import CSV", **Then** a dialog opens for file upload
2. **Given** a CSV is uploaded, **When** the system parses it, **Then** a preview table shows rows to be imported with validation status
3. **Given** the preview contains valid rows, **When** the supervisor confirms, **Then** locations are created and the count is displayed
4. **Given** a CSV row has invalid data, **When** previewed, **Then** the row is highlighted with specific validation errors
5. **Given** a CSV has a mix of valid/invalid rows, **When** confirmed, **Then** only valid rows are imported and invalid rows are listed

---

### User Story 5 - View Locations on Map with Geofence Circles (Priority: P3)

A supervisor wants to see all locations displayed on an interactive map with their geofence circles to understand coverage and identify gaps.

**Why this priority**: Visual aid for location management. Helps identify overlapping geofences or areas without coverage.

**Independent Test**: Can be tested by viewing the locations map with multiple locations defined.

**Acceptance Scenarios**:

1. **Given** locations exist, **When** a supervisor opens the locations map view, **Then** all active locations display as markers with geofence circles
2. **Given** the map is displayed, **When** a supervisor clicks a location marker, **Then** a popup shows the location details
3. **Given** multiple locations are close together, **When** viewing the map, **Then** overlapping geofence circles are visually distinguishable
4. **Given** a location is inactive, **When** viewing the map, **Then** inactive locations are hidden by default (toggleable)

---

### User Story 6 - View Segmented GPS Trail on Map (Priority: P3)

A supervisor viewing a shift wants to see the GPS trail on a map with polylines colored by the location type where each segment occurred.

**Why this priority**: Enhanced visualization complementing the timeline bar. Provides geographic context for the time-based segments.

**Independent Test**: Can be tested by viewing the map for any shift with GPS data and defined locations.

**Acceptance Scenarios**:

1. **Given** a shift has GPS data, **When** viewing the map, **Then** the GPS trail is drawn as polylines colored by segment type
2. **Given** a segment is selected on the timeline, **When** viewing the map, **Then** that segment's portion of the trail is highlighted
3. **Given** the map is displayed, **When** a supervisor hovers over a trail section, **Then** the corresponding segment info is shown

---

### Edge Cases

- What happens when GPS accuracy is very poor (>100m)? System uses the point but confidence score reflects accuracy.
- How does system handle a GPS point exactly on a geofence boundary? Point is included in the geofence (boundary is inclusive).
- What happens when a GPS point falls within multiple overlapping geofences? The closest location (smallest distance to center) is selected.
- How does system handle a shift with no GPS points? Timeline displays "No GPS data available" message.
- What happens when no locations are defined? All GPS points are marked as "unmatched" in the timeline.
- How does system handle deleted locations? Historical matches are preserved but location shows as "(Deleted)" in timeline.
- What happens when geocoding fails (API error, rate limit, address not found)? System displays an error message and allows the supervisor to enter coordinates manually via map click.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST allow supervisors to create locations with name, type, coordinates, radius, address, and notes
- **FR-002**: System MUST validate latitude (-90 to 90), longitude (-180 to 180), and radius (10-1000 meters)
- **FR-003**: System MUST support five location types: office, building (construction site), vendor, home, and other
- **FR-004**: System MUST provide address geocoding to convert addresses to coordinates
- **FR-005**: System MUST display an interactive map for coordinate selection with a draggable marker
- **FR-006**: System MUST show the geofence radius as a circle on the map that updates in real-time with slider changes
- **FR-007**: System MUST allow locations to be marked as active/inactive without deletion
- **FR-008**: System MUST match GPS points to locations based on whether the point falls within the location's radius
- **FR-009**: System MUST select the closest location when a GPS point falls within multiple geofences
- **FR-010**: System MUST calculate a confidence score based on distance from geofence center (1.0 at center, 0.0 at edge)
- **FR-011**: System MUST generate timeline segments by grouping consecutive GPS points with the same location match
- **FR-012**: System MUST categorize unmatched GPS points as "unmatched" segments
- **FR-013**: System MUST classify unmatched GPS points that occur between two matched location segments as "travel" segments (unmatched points at shift start/end remain "unmatched")
- **FR-014**: System MUST display timeline as a horizontal bar with segments proportional to duration
- **FR-015**: System MUST use consistent colors for each segment type across all visualizations
- **FR-016**: System MUST show segment details (location name, duration, point count) on hover/click
- **FR-017**: System MUST calculate and display summary statistics by location type
- **FR-018**: System MUST support bulk CSV import with validation and preview
- **FR-019**: System MUST perform GPS-to-location matching on-demand when a shift timeline is first viewed, then cache results in the database
- **FR-020**: System MUST serve cached location matches on subsequent views; historical matches remain unchanged even if locations are later modified
- **FR-021**: System MUST support pagination and filtering (by type, search, active status) for the locations list
- **FR-022**: System MUST allow import of pre-existing location data (77 locations from seed data)
- **FR-023**: System MUST apply uniform access control—all location types (including home) are visible to all supervisors with no additional privacy restrictions

### Key Entities

- **Location**: A geographic zone representing a workplace. Has name, type (office/building/vendor/home/other), coordinates (lat/lng), radius in meters, address, notes, and active status. Company-wide resource accessible to all supervisors (any supervisor can create, view, or edit any location).
- **Location Match**: An association between a GPS point and a location. Records distance from location center and confidence score. Created on-demand when viewing timeline.
- **Timeline Segment**: A computed grouping of consecutive GPS points sharing the same location match. Segment types: matched (associated with a location), travel (unmatched points between two matched segments), or unmatched (unmatched points at shift start/end). Has start/end times, duration, location reference, and point count.
- **Timeline Summary**: Aggregated statistics for a shift showing total time and time breakdown by segment type.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Supervisors can create a new location with coordinates in under 60 seconds using either address geocoding or map click
- **SC-002**: Timeline visualization loads for a shift with 500+ GPS points in under 3 seconds
- **SC-003**: 100% of GPS points within a defined geofence radius are correctly matched to that location
- **SC-004**: Bulk CSV import processes 100 locations in under 10 seconds with clear validation feedback
- **SC-005**: Timeline segments correctly represent all time periods of a shift with no gaps or overlaps
- **SC-006**: 95% of supervisors can identify where an employee spent the most time by glancing at the timeline
- **SC-007**: All 77 seed locations are successfully imported and available for GPS matching

## Clarifications

### Session 2026-01-16

- Q: What is the access scope for locations? → A: Company-wide, any supervisor can create/view/edit all locations
- Q: What happens when geocoding fails? → A: Show error message and allow manual coordinate entry via map click
- Q: Are home locations restricted for privacy? → A: No, all location types (including home) are visible to all supervisors equally
- Q: How are location matches persisted? → A: Computed on-demand first time, then cached/persisted in database for future views
- Q: How are travel segments identified? → A: Any unmatched points between two matched location segments are classified as travel

## Assumptions

- Google Maps Geocoding API is available and configured for address-to-coordinates conversion
- GPS points are already being collected by the mobile app (existing functionality from Spec 004)
- Supervisors have appropriate permissions to view shifts of employees they supervise (existing RLS from previous specs)
- The dashboard uses react-leaflet for map visualizations (existing from Spec 012)
- PostGIS extension is available in Supabase for efficient spatial queries
- GPS matching is performed on-demand (not real-time) to minimize computational overhead
