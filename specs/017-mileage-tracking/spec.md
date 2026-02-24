# Feature Specification: Mileage Tracking for Reimbursement

**Feature Branch**: `017-mileage-tracking`
**Created**: 2026-02-24
**Status**: Draft
**Input**: User description: Implement automatic mileage tracking during shifts with trip detection, distance calculation, and reimbursement report generation — providing direct employee benefit from background location and justifying "Always" location permission for App Store compliance (Guideline 2.5.4).

## App Store Context

Apple rejected Tri-Logis Clock (Submission ID: 6af8ffa6-a3cc-4bef-9d27-58ba11cf48de, reviewed 2026-02-22) under **Guideline 2.5.4 - Performance - Software Requirements**, stating that background location used solely for employee tracking is not appropriate for public App Store distribution. This feature adds a direct, tangible **employee benefit** — automatic mileage logging for expense reimbursement — that requires persistent background location to function correctly. The employee is the primary beneficiary: they no longer need to manually log trips, and they get accurate reimbursement without disputes.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Automatic Trip Detection During Shift (Priority: P1)

An employee who is clocked in and driving between job sites needs their trips to be automatically detected and recorded without any manual action. The system uses the existing background GPS points to identify when the employee is moving at vehicle speed versus stationary at a work location, and segments the shift into distinct trips.

**Why this priority**: This is the core value proposition. Without automatic trip detection, employees would need to manually start/stop mileage tracking, which defeats the purpose and doesn't require "Always" location. Automatic detection from background GPS is what makes this feature compelling and what justifies persistent location access.

**Independent Test**: Can be tested by clocking in, driving between two locations, stopping at the second location, then checking the shift details to verify a trip was detected with start/end points, distance, and duration.

**Acceptance Scenarios**:

1. **Given** an employee is clocked in with background tracking active, **When** they travel at sustained vehicle speed (>15 km/h for >2 minutes), **Then** the system automatically starts recording a new trip
2. **Given** a trip is being recorded, **When** the employee stops and remains stationary for >3 minutes, **Then** the trip is automatically ended with final distance and duration calculated
3. **Given** multiple trips occur during a single shift, **When** the employee views their shift details, **Then** each trip is listed separately with its own start point, end point, distance, and duration
4. **Given** the employee is stationary at a job site, **When** they make small movements within the site, **Then** no trip is erroneously created (noise filtering)
5. **Given** the app is in the background or the phone is locked, **When** the employee is driving, **Then** trip detection still functions correctly using background GPS points

---

### User Story 2 - View Trip Details and Shift Mileage Summary (Priority: P1)

An employee who has completed a shift wants to see a clear summary of all trips taken during that shift, including a map of each route, the total distance driven, and the estimated reimbursement amount. This gives the employee transparency and confidence that their mileage is being accurately captured.

**Why this priority**: Visibility is essential for employee trust and adoption. If employees can't see their trips and verify accuracy, they won't rely on the system and will continue manual logging, undermining the feature's purpose.

**Independent Test**: Can be tested by completing a shift with at least one trip, then navigating to shift details and verifying the mileage tab shows trip routes on a map, distances, durations, and reimbursement estimates.

**Acceptance Scenarios**:

1. **Given** an employee views a completed shift with trips, **When** they access the mileage tab, **Then** they see a list of all trips with start address, end address, distance (km), duration, and estimated reimbursement
2. **Given** an employee is viewing a trip, **When** they tap on it, **Then** they see the trip route displayed on a map with start and end markers
3. **Given** multiple trips occurred during the shift, **When** the employee views the mileage summary, **Then** they see the total distance and total estimated reimbursement for the entire shift
4. **Given** a trip has low-accuracy GPS points, **When** the route is displayed, **Then** the system smooths the route and flags any segments with uncertainty

---

### User Story 3 - Mileage Reimbursement Report Generation (Priority: P1)

An employee needs to generate a mileage reimbursement report for a selected period (week, pay period, custom date range) that they can submit to their employer or accounting department. The report includes all trips, distances, rates, and totals in a format suitable for expense processing.

**Why this priority**: The reimbursement report is the tangible output that makes mileage tracking valuable. Without it, the data exists but isn't actionable for the employee. This is the direct employee benefit that Apple requires to justify background location.

**Independent Test**: Can be tested by selecting a date range with multiple shifts containing trips, generating a PDF report, and verifying it contains all trip details, correct distance totals, and reimbursement calculations.

**Acceptance Scenarios**:

1. **Given** an employee opens the mileage section, **When** they select a date range, **Then** they see all trips from that period grouped by shift/day
2. **Given** an employee has selected trips for a report, **When** they tap "Generate Report", **Then** a PDF is generated with: employee name, period, trip details (date, from, to, distance), per-trip reimbursement, and total amount
3. **Given** a report is generated, **When** the employee views it, **Then** they can share it via email, save to device, or export to Files app
4. **Given** the reimbursement rate is configurable, **When** the employee generates a report, **Then** the rate used is clearly displayed on the report (default: CRA/ARC standard rate for the current year)

---

### User Story 4 - Personal vs. Business Trip Classification (Priority: P2)

An employee who uses their personal vehicle for both personal and work errands during a shift needs the ability to classify trips as "business" or "personal". Only business trips are included in reimbursement reports. By default, all trips during a shift are classified as business, but the employee can reclassify.

**Why this priority**: Accurate classification prevents disputes and ensures reimbursement reports are honest. This also demonstrates respect for employee privacy — the system acknowledges that not all movement during a shift is work-related.

**Independent Test**: Can be tested by completing a shift with multiple trips, then reclassifying one trip as personal and verifying the reimbursement report excludes it.

**Acceptance Scenarios**:

1. **Given** an employee views their trips for a shift, **When** they long-press on a trip, **Then** they can toggle it between "Business" and "Personal"
2. **Given** a trip is marked as "Personal", **When** the employee generates a reimbursement report, **Then** personal trips are excluded from the total and not listed
3. **Given** a trip is reclassified, **When** the employee views the shift mileage summary, **Then** the total reimbursable distance updates immediately
4. **Given** all trips in a shift default to "Business", **When** the employee does nothing, **Then** the default behavior requires no extra action for normal use

---

### User Story 5 - Manager Views Team Mileage Dashboard (Priority: P2)

A manager needs to see mileage summaries for their supervised employees to approve reimbursements, identify excessive driving, or optimize route planning. They can view per-employee mileage totals, review individual trips, and export team mileage reports.

**Why this priority**: Managerial oversight ensures accuracy and prevents abuse. This adds value to the existing management dashboard (specs 009-013) by providing a new mileage dimension to workforce management.

**Independent Test**: Can be tested by logging in as a manager, navigating to the mileage section of the dashboard, and verifying that supervised employees' mileage data is visible with filtering and export capabilities.

**Acceptance Scenarios**:

1. **Given** a manager is on the dashboard, **When** they access the Mileage tab, **Then** they see a summary table of all supervised employees with total km driven for the selected period
2. **Given** a manager selects an employee, **When** they drill down, **Then** they see that employee's trip history with the same detail the employee sees
3. **Given** a manager selects a date range, **When** they click "Export Team Report", **Then** a CSV/PDF is generated with all employees' mileage data for that period
4. **Given** the mileage data is displayed, **When** a manager sorts by total km, **Then** they can quickly identify anomalies or high-mileage employees

---

### User Story 6 - Configure Reimbursement Rate (Priority: P3)

An employer/admin needs to set the per-km reimbursement rate used for all mileage calculations. The rate defaults to the current CRA/ARC standard rate but can be customized per organization. Rate changes apply going forward and don't retroactively affect past reports.

**Why this priority**: Different organizations may have different reimbursement policies. While a sensible default covers most cases, configurability ensures the feature works for all customers.

**Independent Test**: Can be tested by an admin changing the rate in settings, then generating a new mileage report and verifying the new rate is applied.

**Acceptance Scenarios**:

1. **Given** an admin accesses mileage settings, **When** they view the rate configuration, **Then** the current CRA/ARC rate is shown as the default (2026: $0.72/km first 5,000 km, $0.66/km thereafter)
2. **Given** an admin sets a custom rate, **When** they save, **Then** all future reimbursement calculations use the new rate
3. **Given** a rate change is saved, **When** previously generated reports are viewed, **Then** they still show the rate that was in effect when they were generated
4. **Given** the CRA/ARC rate changes annually, **When** a new year starts, **Then** the system uses the updated default rate (can be updated via app update or remote config)

---

### Edge Cases

- What happens when GPS accuracy is poor (indoors, tunnels, parking garages)? The system should use the Haversine formula on available points, apply smoothing to remove GPS jitter, and flag segments with accuracy >100m as "estimated". Trips with >50% estimated segments get a warning badge.
- What happens when an employee takes a very short trip (<500m)? Short trips below a configurable minimum (default: 500m) are not counted to filter out parking lot movements and GPS noise. The employee can manually include them if needed.
- How does the system handle trips that cross shift boundaries (employee forgot to clock out, drove home, then clocked out)? Trips are only calculated from GPS points within the shift window. If a shift spans midnight due to forgotten clock-out and is later corrected, mileage recalculates.
- What happens when the employee is a passenger (carpooling)? The system cannot distinguish driver vs. passenger. The trip classification feature (US4) allows the employee to mark such trips as personal.
- How does the system handle round trips (office → site → office)? Each leg is a separate trip with its own entry, making the route clear and auditable.
- What about Quebec-specific mileage deduction rules? The reimbursement report clearly labels the rate source (CRA/ARC or custom). Tax compliance is the employee's/employer's responsibility; the app provides data, not tax advice.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST automatically detect vehicle trips from background GPS points using speed and movement analysis
- **FR-002**: System MUST calculate trip distance using GPS point-to-point Haversine formula with route smoothing
- **FR-003**: System MUST segment shifts into distinct trips with start location, end location, distance, and duration
- **FR-004**: System MUST reverse-geocode trip start and end points to human-readable addresses
- **FR-005**: System MUST display trip routes on a map within the shift detail view
- **FR-006**: System MUST calculate estimated reimbursement per trip using the configured rate
- **FR-007**: System MUST allow employees to generate mileage reimbursement PDF reports for custom date ranges
- **FR-008**: System MUST allow employees to share/export generated reports via system share sheet
- **FR-009**: System MUST allow employees to classify trips as "Business" or "Personal"
- **FR-010**: System MUST exclude personal trips from reimbursement totals and reports
- **FR-011**: System MUST provide a mileage summary view showing total km, total reimbursement, and trip count per period
- **FR-012**: System MUST allow managers to view mileage data for supervised employees on the web dashboard
- **FR-013**: System MUST allow managers to export team mileage reports (CSV and PDF)
- **FR-014**: System MUST allow admins to configure the per-km reimbursement rate
- **FR-015**: System MUST default to the current CRA/ARC automobile allowance rate
- **FR-016**: System MUST filter out GPS noise and short movements (<500m default) from trip detection
- **FR-017**: System MUST flag low-accuracy trip segments and display confidence indicators
- **FR-018**: System MUST store trip data locally for offline access and sync when connectivity returns
- **FR-019**: System MUST process trip detection from existing `gps_points` data — no additional GPS collection required beyond what spec 004 already provides

### Key Entities

- **Trip**: A detected vehicle movement within a shift; contains shift_id, employee_id, start_location (lat/lng), end_location (lat/lng), start_address (reverse-geocoded), end_address (reverse-geocoded), distance_km, duration_minutes, started_at, ended_at, classification (business/personal), confidence_score, gps_point_ids (array of contributing GPS points)
- **Mileage Summary**: Aggregated mileage data for a period; contains employee_id, period_start, period_end, total_distance_km, business_distance_km, personal_distance_km, trip_count, estimated_reimbursement
- **Reimbursement Rate**: Configuration for mileage calculation; contains rate_per_km, effective_from, effective_to, rate_source (CRA/custom), tier structure (first 5000km rate, thereafter rate)
- **Mileage Report**: Generated PDF document; contains employee_id, period_start, period_end, generated_at, rate_used, trips_included, total_reimbursement, file_url

## Technical Context

### Existing Infrastructure (from specs 001-016)

This feature builds on top of the existing GPS tracking system:

- **`gps_points` table**: Already captures GPS location every 5 minutes during active shifts (spec 004). Trip detection analyzes these existing points — no new GPS collection needed.
- **`shifts` table**: Provides the time window for trip detection. Trips are always scoped to a shift.
- **`employee_profiles` table**: Employee identity and role (employee/manager/admin).
- **`employee_supervisors` table**: Manager-employee relationships for dashboard access control.
- **`locations` table** (spec 015): Geofence definitions. Can be used to auto-label trip endpoints (e.g., "Arrived at: Bureau Montréal").
- **Background GPS tracking** (spec 004): Already runs with "Always" location permission. This feature adds a user-facing reason for that permission.
- **Offline resilience** (spec 005): GPS points sync when connectivity returns. Trip detection can run on synced data.
- **Web dashboard** (specs 009-013): Existing manager dashboard where mileage tab will be added.
- **Reports/Export** (spec 013): Existing export infrastructure (CSV, PDF) to reuse.

### New Database Objects Needed

- `trips` table — stores detected trips with all metadata
- `mileage_reports` table — stores generated report references
- `reimbursement_rates` table — stores rate configuration with effective dates
- `local_trips` SQLCipher table — offline trip cache on device

### Tech Stack

- **Mobile (Flutter)**: Trip detection algorithm, trip display UI, PDF report generation (reuse `pdf` package from spec 006), map route display (reuse `google_maps_flutter`)
- **Dashboard (Next.js)**: Mileage tab in existing dashboard, team mileage reports, rate configuration admin page
- **Backend (Supabase)**: New tables with RLS, trip detection could also run server-side as a Supabase Edge Function for consistency

### App Store Justification

With this feature, the "Always" location permission serves a **direct employee benefit**:

1. **Automatic mileage logging** — employees don't need to remember to start/stop tracking; it happens seamlessly during their shift
2. **Accurate reimbursement** — GPS-based distance is more accurate and less disputable than manual estimates
3. **Time savings** — no manual trip logging, no paper forms, no spreadsheets
4. **Financial benefit** — ensures employees get reimbursed for every qualifying trip

This transforms background location from "employer tracks employees" to "app helps employees get paid for their driving."

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Trip detection correctly identifies 90%+ of vehicle trips (>1km) during shifts with normal GPS accuracy
- **SC-002**: Calculated trip distances are within 10% of actual driving distance (validated against Google Maps)
- **SC-003**: False positive trip rate is below 5% (trips created from non-vehicle movement)
- **SC-004**: Mileage PDF report generates within 5 seconds for up to 100 trips
- **SC-005**: Trip detection processes a full shift's GPS points within 3 seconds
- **SC-006**: Employees can view their mileage summary within 2 taps from the main screen
- **SC-007**: 100% of trip data persists correctly through offline storage and sync
- **SC-008**: Manager mileage dashboard loads team data within 3 seconds for up to 50 employees
- **SC-009**: The feature provides sufficient justification for Apple to approve "Always" location permission under Guideline 2.5.4

## Assumptions

- Existing GPS point capture (every 5 minutes, spec 004) provides sufficient granularity for trip detection. Very short trips (<5 min) may not be captured.
- Employees primarily use vehicles for work travel (not public transit, cycling). The speed-based detection threshold (>15 km/h) may need tuning.
- Reverse geocoding will use a free/affordable API (e.g., Nominatim, or limited Google Geocoding API calls).
- The CRA/ARC automobile allowance rate is publicly available and updates annually.
- Employees have consented to mileage data being shared with their managers as part of employment terms (covered by existing privacy consent in spec 002).
- Trip detection runs primarily on the server side after GPS sync to ensure consistency across devices and reduce mobile battery usage.

## Dependencies

- **Spec 004** (Background GPS Tracking) — Required. Provides the GPS points that trip detection analyzes.
- **Spec 005** (Offline Resilience) — Required. Ensures GPS points captured offline are synced and available for trip detection.
- **Spec 009** (Dashboard Foundation) — Required for manager mileage dashboard.
- **Spec 013** (Reports & Export) — Beneficial. Can reuse export infrastructure.
- **Spec 015** (Location Geofences) — Beneficial. Can auto-label trip endpoints with known location names.
