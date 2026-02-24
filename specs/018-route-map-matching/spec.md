# Feature Specification: Route Map Matching & Real Route Visualization

**Feature Branch**: `018-route-map-matching`
**Created**: 2026-02-24
**Status**: Draft
**Input**: Replace straight-line distance calculation with real road-based distance using map matching. Display actual road routes on maps instead of straight lines between GPS points.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Accurate Road-Based Mileage (Priority: P1)

As an employee, after my shift ends and trips are detected, I want the system to automatically calculate my actual road-based mileage so that my reimbursement reflects the real distance I drove, not a rough straight-line estimate.

Currently, distances are calculated as-the-crow-flies with a generic correction factor. This underestimates winding suburban routes and overestimates highway routes. Employees doing urban deliveries or multi-stop routes are most impacted — their actual driven distance can be 1.5-2.5x the straight-line distance.

**Why this priority**: This is the core value of the feature — accurate mileage directly impacts employee reimbursement amounts. Everything else builds on having correct distances.

**Independent Test**: Can be tested by comparing a known trip (e.g., office to client site with known driving distance) against the system-calculated distance. The road-based distance should be within 5% of the actual driven distance.

**Acceptance Scenarios**:

1. **Given** a completed shift with GPS points recorded every 30-60 seconds along a known route, **When** trip detection and route matching complete, **Then** the calculated distance is within 10% of the actual road distance for that route.
2. **Given** a trip with GPS points along a winding suburban route, **When** route matching runs, **Then** the matched distance is greater than the previous straight-line estimate and closer to the real driving distance.
3. **Given** a trip where the employee drove on a highway (relatively straight), **When** route matching runs, **Then** the matched distance is similar to (but more accurate than) the previous straight-line estimate.
4. **Given** a completed shift, **When** the employee views their trip in the app, **Then** the distance shown reflects the road-based calculation, not the old straight-line estimate.

---

### User Story 2 - Real Route Displayed on Map (Priority: P1)

As an employee, when I view a trip's details, I want to see my actual driving route drawn on the map — following the real streets, turns, and curves I took — instead of straight lines between GPS dots.

This helps employees verify their trip visually ("yes, I did take that route") and builds trust in the system's accuracy. It also helps managers understand where employees actually drove.

**Why this priority**: Visual route display is tightly coupled with map matching (the matched route geometry is what gets displayed). It's the most visible proof that the system is working correctly.

**Independent Test**: Can be tested by viewing a trip detail screen and confirming the route line follows real streets on the map (not cutting through buildings or parks).

**Acceptance Scenarios**:

1. **Given** a trip with a matched route, **When** the employee opens the trip detail screen, **Then** the map displays a polyline that follows actual road geometry (curves, turns, intersections).
2. **Given** a trip that included a highway segment, **When** viewing the route on the map, **Then** the route follows the highway path (including ramps and curves) rather than a straight line.
3. **Given** a trip with no matched route available (matching failed or pending), **When** viewing the trip detail, **Then** the map falls back to showing straight lines between GPS points (existing behavior) with a visual indicator that the route is approximate.

---

### User Story 3 - Route Matching Status Indicator (Priority: P2)

As an employee, I want to see whether a trip's distance was calculated from real road data or is just an estimate, so I know how reliable the number is.

**Why this priority**: Transparency builds trust. Employees should know if a particular trip's distance is verified or estimated, especially for reimbursement purposes.

**Independent Test**: Can be tested by viewing trip cards in the mileage list — trips with matched routes show a "verified" indicator, while trips without show "estimated."

**Acceptance Scenarios**:

1. **Given** a trip where route matching succeeded, **When** viewing the trip card in the mileage list, **Then** it displays a "Route verified" indicator.
2. **Given** a trip where route matching failed or hasn't run yet, **When** viewing the trip card, **Then** it displays a "Distance estimated" indicator.
3. **Given** a trip initially showing "estimated," **When** route matching later succeeds (e.g., after connectivity restored), **Then** the indicator updates to "verified" and the distance is updated.

---

### User Story 4 - Shift Detail Shows Real Routes (Priority: P2)

As an employee or manager, when viewing a shift's details, I want the route map to show the actual road routes for all trips detected during that shift, so I can see the full picture of where the employee drove.

**Why this priority**: Extends the route visualization from individual trips to the shift overview. Useful for managers reviewing employee shifts.

**Independent Test**: Can be tested by viewing a shift detail screen that contains multiple trips — each trip's route is drawn in a distinct color on the map.

**Acceptance Scenarios**:

1. **Given** a completed shift with 2 or more matched trips, **When** viewing the shift detail screen, **Then** each trip's route is displayed on the map in a different color.
2. **Given** a shift with a mix of matched and unmatched trips, **When** viewing the shift map, **Then** matched trips show road-following routes and unmatched trips show straight-line connections.

---

### User Story 5 - Re-Process Historical Trips (Priority: P3)

As an administrator, I want to re-process existing trips through route matching to retroactively correct their distances and add route geometry, so that historical data is also accurate.

**Why this priority**: Nice-to-have for data consistency. Most value comes from new trips being matched going forward.

**Independent Test**: Can be tested by triggering a batch re-process and confirming that previously estimated trips are updated with road-based distances and route geometry.

**Acceptance Scenarios**:

1. **Given** historical trips with only straight-line distances, **When** an admin triggers batch re-processing, **Then** the system processes each trip through route matching and updates the distance and route geometry.
2. **Given** a batch re-process is running, **When** some trips fail to match (insufficient GPS points, no nearby roads), **Then** those trips retain their original distance and are flagged as "estimated."
3. **Given** a batch re-process completes, **When** the admin views the results, **Then** they see a summary of how many trips were updated, how many failed, and the total distance correction.

---

### Edge Cases

- What happens when GPS points are too sparse (e.g., only 2-3 points for a trip)? The system should fall back to straight-line distance with the "estimated" indicator.
- What happens when the route matching service is unavailable (network issues, API down)? The system should use the existing Haversine distance as a fallback and retry matching later.
- What happens when GPS points are in a location with no roads (e.g., parking lot, private property, off-road)? The matching should gracefully handle this, potentially matching to the nearest road or falling back to straight-line for that segment.
- What happens when the employee drove on a road not yet in the map data? The matching should fall back gracefully, and the distance should not be worse than the current straight-line estimate.
- What happens when there are large time gaps between GPS points (>5 minutes)? The system should split the matching at gaps and handle each segment independently.
- What happens when route matching produces a distance significantly different from the Haversine estimate (e.g., 5x longer)? The system should flag anomalous results for review rather than blindly accepting them.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST automatically match GPS traces from detected trips to the actual road network and calculate road-based distance.
- **FR-002**: System MUST store the matched route geometry for each trip so it can be displayed on maps without re-processing.
- **FR-003**: System MUST display the matched road route on the trip detail map, showing the actual path along streets, turns, and curves.
- **FR-004**: System MUST fall back to the existing straight-line distance calculation when route matching is unavailable or fails.
- **FR-005**: System MUST indicate on each trip whether its distance is "road-verified" or "estimated" (fallback).
- **FR-006**: Route matching MUST happen asynchronously — it must not delay or block the clock-out process.
- **FR-007**: System MUST handle trips with varying numbers of GPS points (from 3 to 200+) gracefully.
- **FR-008**: System MUST support GPS traces with 30-60 second intervals between points (sparse traces typical of background tracking).
- **FR-009**: System MUST update the trip distance when route matching completes, replacing the previous straight-line estimate with the road-based distance.
- **FR-010**: System MUST display matched routes for all trips within a shift on the shift detail map, using distinct visual styling per trip.
- **FR-011**: System MUST provide a mechanism for administrators to re-process historical trips through route matching.
- **FR-012**: System MUST reject anomalous matching results (e.g., matched distance >3x the straight-line distance) and flag them rather than automatically accepting.
- **FR-013**: System MUST work accurately for road networks in Quebec, Canada (primary operating region).
- **FR-014**: System MUST retry failed route matching attempts (e.g., due to temporary network issues) before giving up and keeping the fallback distance.

### Key Entities

- **Matched Route**: The road-based route geometry for a detected trip. Contains the polyline/shape following actual roads, the road-based distance, and matching confidence. Associated with exactly one Trip.
- **Trip** (existing, extended): Gains a matched route geometry, a road-based distance (replacing or supplementing the Haversine distance), and a matching status (matched, pending, failed, anomalous).
- **Matching Job**: A processing request to match a trip's GPS points to roads. Has a status (queued, processing, completed, failed) and retry count. Created automatically after trip detection or manually by admin batch action.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Road-based distances are within 10% of the actual driven distance for 90% of trips (validated against known routes).
- **SC-002**: 85% or more of detected trips successfully receive a matched route within 2 minutes of shift clock-out.
- **SC-003**: The route displayed on the trip detail map visually follows actual roads (no lines cutting through buildings, parks, or bodies of water) for all matched trips.
- **SC-004**: Route matching does not add more than 5 seconds to the perceived clock-out experience for employees (processing happens in background).
- **SC-005**: When route matching is unavailable, 100% of trips still receive a distance estimate via the fallback calculation — no trips are left without a distance.
- **SC-006**: Employees can visually distinguish between verified (road-matched) and estimated (fallback) trips at a glance in the mileage list.
- **SC-007**: Batch re-processing of 100 historical trips completes within 10 minutes.
- **SC-008**: Employee GPS trace data used for route matching is not shared with third-party services that retain or use the data for their own purposes (privacy requirement).

## Assumptions

- The primary operating region is Quebec, Canada; road data coverage for this region is sufficient in open-source map databases.
- GPS points are already recorded and stored during shifts at 30-60 second intervals; no changes to GPS collection frequency are needed for this feature (though higher frequency would improve accuracy).
- The existing trip detection algorithm (`detect_trips`) continues to identify trip start/end boundaries; route matching refines the distance and adds geometry after trips are detected.
- Internet connectivity is available on the backend/server at the time of processing (route matching happens server-side, not on the employee's mobile device).
- The existing map display components can render polyline geometries overlaid on the map.
- The 1.3x Haversine correction factor is removed or replaced once road-based matching is available; it is only used as a fallback when matching fails.

## Scope Boundaries

**In Scope**:
- Automatic route matching for newly detected trips
- Road-based distance calculation replacing Haversine
- Route visualization on trip detail and shift detail maps
- Matching status indicators on trip cards
- Fallback to Haversine when matching unavailable
- Admin batch re-processing of historical trips
- Anomaly detection for unreasonable matching results

**Out of Scope**:
- Real-time turn-by-turn navigation during shifts
- Changing GPS collection frequency or intervals
- Route optimization or suggestion of better routes
- Speed limit violation detection
- Fuel consumption estimation
- Multi-modal trip detection (e.g., switching between car and walking)
- Self-hosting of the map matching engine (Phase 2 — separate future feature)
