# Feature Specification: Offline Resilience

**Feature Branch**: `005-offline-resilience`
**Created**: 2026-01-10
**Status**: Draft
**Input**: User description: "Spec 005: Offline Resilience"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Seamless Work During Network Outages (Priority: P1)

An employee working in an area with poor or no cellular connectivity needs to continue their normal work routine without interruption. They can clock in, track their locations, and clock out just as they would when online. The system operates identically whether connected or disconnected, with no user action required to switch modes.

**Why this priority**: The fundamental promise of offline resilience is that connectivity loss should be invisible to the work experience. Without seamless offline operation, employees in areas with poor coverage cannot reliably use the system.

**Independent Test**: Can be fully tested by enabling airplane mode, performing a complete shift (clock in, let tracking run, clock out), then verifying all data was captured correctly before restoring connectivity.

**Acceptance Scenarios**:

1. **Given** an employee with no network connectivity, **When** they tap "Clock In", **Then** the shift starts immediately with no error messages or delays
2. **Given** an employee is offline with an active shift, **When** GPS tracking intervals occur, **Then** location points are captured and stored locally without any indication of offline status affecting functionality
3. **Given** an employee is offline, **When** they tap "Clock Out", **Then** the shift ends immediately with full summary displayed
4. **Given** the device transitions from online to offline during a shift, **When** connectivity is lost, **Then** all operations continue without interruption or user notification required

---

### User Story 2 - Automatic Data Synchronization (Priority: P1)

An employee who has been working offline reconnects to the network and expects their data to sync automatically. All accumulated shifts and GPS points upload to the server without requiring any manual action, and the employee receives confirmation that their data is safely backed up.

**Why this priority**: Automatic synchronization ensures data integrity and eliminates the risk of lost work records. Without this, employees would need to remember to manually sync, leading to data loss and trust issues.

**Independent Test**: Can be tested by accumulating offline data, restoring connectivity, and verifying all data syncs automatically within the expected timeframe.

**Acceptance Scenarios**:

1. **Given** an employee has pending offline data, **When** network connectivity is restored, **Then** synchronization begins automatically within 30 seconds
2. **Given** synchronization is in progress, **When** the employee views the app, **Then** they see a progress indicator showing sync status
3. **Given** synchronization completes successfully, **When** the employee checks their data, **Then** all offline records appear in their shift history with accurate timestamps
4. **Given** partial sync failure occurs, **When** some items fail to sync, **Then** the system retries failed items and the employee is notified only if manual intervention is needed

---

### User Story 3 - Extended Offline Operation (Priority: P1)

An employee working in a remote location with no connectivity for multiple days needs confidence that their work data is being captured and stored safely. The system can operate offline for at least 7 days of normal use, storing all shifts and GPS points locally until connectivity returns.

**Why this priority**: Many work environments (construction sites, rural areas, offshore platforms) may have extended periods without connectivity. The system must reliably operate for realistic offline durations.

**Independent Test**: Can be tested by simulating extended offline operation (or accelerated testing with high data volumes) and verifying storage capacity and data integrity.

**Acceptance Scenarios**:

1. **Given** an employee works offline for 7 consecutive days with normal shift patterns, **When** they check local storage, **Then** all shifts and GPS points are retained without data loss
2. **Given** offline storage is accumulating data, **When** storage approaches capacity limits, **Then** the employee receives a warning before data would need to be pruned
3. **Given** offline storage reaches critical levels, **When** pruning is necessary, **Then** the most recent data is preserved and older synced data is removed first
4. **Given** an employee has been offline for an extended period, **When** they eventually reconnect, **Then** all accumulated data syncs successfully regardless of volume

---

### User Story 4 - Sync Status Visibility (Priority: P2)

An employee wants to know the status of their data synchronization, including how much data is pending upload, when the last successful sync occurred, and whether there are any sync issues requiring attention.

**Why this priority**: Transparency about sync status builds trust in the system. Employees need to know their work records are safe, especially after periods of offline operation.

**Independent Test**: Can be tested by accumulating offline data and verifying the sync status display shows accurate counts and timestamps.

**Acceptance Scenarios**:

1. **Given** an employee has pending unsynced data, **When** they view sync status, **Then** they see the count of pending shifts and GPS points
2. **Given** an employee's data is fully synced, **When** they view sync status, **Then** they see confirmation that all data is backed up with the last sync timestamp
3. **Given** sync errors have occurred, **When** the employee views sync status, **Then** they see a clear indication of the issue and any available remediation steps
4. **Given** an employee is viewing the dashboard, **When** they glance at the persistent sync status indicator (icon with badge), **Then** they can quickly determine if there is pending data without navigating elsewhere

---

### User Story 5 - Conflict Resolution (Priority: P2)

An employee who has been working offline reconnects and the system needs to reconcile any differences between local and server data. The system handles conflicts gracefully, preserving employee work records and ensuring no legitimate data is lost.

**Why this priority**: Data conflicts can occur in edge cases (device replacement, reinstallation, server-side corrections). Proper conflict handling prevents data loss and maintains employee trust.

**Independent Test**: Can be tested by creating intentional conflicts (e.g., same shift ID on local and server with different data) and verifying resolution behavior.

**Acceptance Scenarios**:

1. **Given** a shift exists locally but not on the server, **When** sync occurs, **Then** the local shift is uploaded to create a new server record
2. **Given** a shift exists on the server but was also modified locally, **When** sync occurs, **Then** the system uses timestamps to determine the most recent version or merges changes appropriately
3. **Given** duplicate records could be created, **When** sync occurs, **Then** the system uses idempotency keys to prevent duplicates
4. **Given** a conflict cannot be automatically resolved, **When** manual intervention is needed, **Then** the employee is notified with clear instructions

---

### User Story 6 - Network-Aware Battery Optimization (Priority: P3)

An employee working in an area with intermittent connectivity benefits from intelligent sync behavior that considers network quality and battery level. The system optimizes sync timing to balance data freshness with power consumption.

**Why this priority**: Battery life is critical for mobile workers. Intelligent sync behavior prevents unnecessary battery drain from repeated failed sync attempts in poor network conditions.

**Independent Test**: Can be tested by monitoring sync behavior and battery usage under various network conditions (strong signal, weak signal, intermittent connectivity).

**Acceptance Scenarios**:

1. **Given** the device has strong network connectivity, **When** pending data exists, **Then** sync occurs promptly with normal batch sizes
2. **Given** the device has weak or intermittent connectivity, **When** sync attempts fail repeatedly, **Then** the system implements exponential backoff to reduce retry frequency
3. **Given** the device battery is below 20%, **When** non-critical sync is pending, **Then** the system may defer large uploads until battery is adequate or device is charging
4. **Given** the device is on metered data (mobile) with limited data plan, **When** large amounts of data need to sync, **Then** the system respects data saver settings if enabled

---

### Edge Cases

- What happens when device storage is completely full? The system should warn the user before storage is exhausted and prevent new data capture only as a last resort, with clear guidance on freeing space.
- How does sync handle extremely large backlogs (1000+ GPS points)? Sync should process in batches to avoid timeouts, with progress reporting and the ability to resume interrupted syncs.
- What happens if the app is uninstalled and reinstalled while offline data exists? Local encrypted data cannot be recovered after uninstallation. Users should be warned about pending unsynced data before any destructive action.
- How does the system handle clock skew between device and server? All timestamps should be captured with device time but may be flagged if significantly different from server time when syncing.
- What happens when sync is interrupted mid-operation? The system should use transactions and idempotency to ensure partial syncs don't corrupt data, and resume seamlessly.
- How does the system behave during a background sync when the user opens the app? The sync continues, and the UI updates to reflect real-time progress without interruption.
- What if the server rejects data as invalid during sync? Invalid records should be quarantined for review rather than silently deleted, with user notification.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST allow clock-in operations to complete successfully without network connectivity
- **FR-002**: System MUST allow clock-out operations to complete successfully without network connectivity
- **FR-003**: System MUST continue GPS tracking and local storage during network outages without user intervention
- **FR-004**: System MUST automatically detect network connectivity changes and respond appropriately
- **FR-005**: System MUST automatically initiate data synchronization when connectivity is restored
- **FR-006**: System MUST preserve original device timestamps for all records regardless of sync timing
- **FR-007**: System MUST store at least 7 days of shift and GPS data locally for offline operation
- **FR-008**: System MUST display synchronization status including pending item counts and last sync time
- **FR-009**: System MUST provide visual feedback during active synchronization operations
- **FR-010**: System MUST process sync operations in batches to prevent timeout failures
- **FR-011**: System MUST implement exponential backoff for repeated sync failures
- **FR-012**: System MUST use client-generated UUID v4 as idempotency keys to prevent duplicate record creation during sync
- **FR-013**: System MUST warn users when local storage approaches capacity limits
- **FR-014**: System MUST prioritize recent data preservation if storage pruning becomes necessary
- **FR-015**: System MUST handle sync conflicts by preferring the most recent timestamp or user data
- **FR-016**: System MUST quarantine invalid or rejected records for review rather than deleting them
- **FR-017**: System MUST support resumable sync operations that can continue after interruption
- **FR-018**: System MUST notify users of persistent sync failures that require attention
- **FR-019**: System MUST operate identically from the user perspective whether online or offline
- **FR-020**: System MUST sync pending data on app launch if connectivity is available
- **FR-021**: System MUST implement structured logging with configurable levels (error/warn/info/debug) for sync operations, stored locally with automatic rotation

### Key Entities

- **Sync Queue**: Represents the collection of pending items awaiting synchronization; contains pending shifts count, pending GPS points count, total size estimate, and queue age. Persisted in SQLCipher database alongside local_gps_points table.
- **Sync Operation**: A single synchronization attempt; contains operation type (shift/gps_points), batch size, status (pending/in_progress/completed/failed), retry count, and last attempt timestamp. Stored in SQLCipher for crash recovery.
- **Sync Status**: Current state of the synchronization system; contains connection status, sync state (idle/syncing/error), pending counts, last successful sync time, and current error if any. Persisted in SQLCipher to survive app restarts.
- **Storage Metrics**: Information about local storage usage; contains total capacity, used space, available space, and data breakdown by type (shifts, GPS points)

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Clock-in and clock-out operations complete within 3 seconds regardless of network connectivity
- **SC-002**: Automatic sync begins within 30 seconds of network connectivity being restored
- **SC-003**: System can store at least 7 days of normal shift data (assuming 8-hour shifts with 5-minute GPS intervals) locally
- **SC-004**: 100% of offline-captured data syncs successfully when connectivity is restored, with accurate timestamps
- **SC-005**: Batch sync operations complete within 60 seconds per batch of 100 GPS points
- **SC-006**: Users can view current sync status within 0 taps (visible on dashboard) with detailed view within 1 tap
- **SC-007**: Storage warning appears when local storage exceeds 80% of allocated capacity
- **SC-008**: Failed sync operations retry with exponential backoff, reaching maximum interval of 15 minutes
- **SC-009**: Zero duplicate records created due to sync retry operations (100% idempotency)
- **SC-010**: Sync progress indicator updates at least every 5 seconds during active synchronization

## Clarifications

### Session 2026-01-10

- Q: Where should sync queue and sync status metadata be persisted locally? → A: Store sync queue/status metadata in SQLCipher alongside local_gps_points
- Q: Where should the sync status indicator appear in the UI? → A: Persistent status indicator on the main shift dashboard (icon + badge for pending count)
- Q: What level of diagnostic logging for sync operations? → A: Structured logging with configurable levels (error/warn/info/debug) stored locally with rotation
- Q: How should offline-created shifts be assigned IDs? → A: Client-generated UUID v4 assigned immediately on creation, used as idempotency key
- Q: Which Supabase API approach for sync uploads? → A: Standard REST/PostgREST API with batch upsert operations

## Assumptions

- The device has sufficient storage capacity for local data (at least 50MB available for app data)
- SQLCipher encryption has negligible performance impact on storage operations
- Network connectivity detection is reliable on target platforms (iOS and Android)
- Server infrastructure can handle burst sync traffic when many offline users reconnect simultaneously
- 7 days of offline operation represents the upper bound of expected disconnected scenarios
- Users will not intentionally manipulate device time to circumvent tracking (timestamps are device-based)
- Existing Supabase backend supports the required batch sync operations and idempotency via REST/PostgREST upsert API
