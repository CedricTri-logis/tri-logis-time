# GPS Tracker - Phase 2 Development Roadmap

**Project**: Employee GPS Clock-In Tracker
**Status**: MVP Complete (Specs 001-004)
**Next Phase**: Specs 005-008

---

## Spec Overview

| Spec # | Name | Priority | Dependencies | MVP? |
|--------|------|----------|--------------|------|
| 005 | Offline Resilience | P2 | 004 | No |
| 006 | Employee History | P3 | 003 | No |
| 007 | Location Permission Guard | P1 | 004 | No |
| 008 | Employee & Shift Dashboard | P2 | 003 | No |

---

## Spec 005: Offline Resilience

**Branch**: `005-offline-resilience`
**Complexity**: High

### Purpose

Ensure the app functions reliably without network connectivity, storing data locally and syncing when online.

### Scope

#### In Scope
- Local SQLite storage for GPS points
- Offline clock in/out capability
- Automatic sync when connectivity returns
- Sync status indication
- Conflict resolution for offline data

#### Out of Scope
- Offline employee registration
- Offline password changes

### User Stories

#### US1: Offline GPS Storage (P1)
**As an** employee working in a low-coverage area
**I want** GPS points stored locally when offline
**So that** no location data is lost

**Acceptance Criteria**:
- Given I have no network, when a GPS point is captured, then it is stored locally
- Given I regain network, then local GPS points are uploaded to Supabase
- Given upload succeeds, then local points are marked as synced

**Independent Test**: Enable airplane mode, wait for GPS captures, disable airplane mode, verify points uploaded

#### US2: Offline Clock In/Out (P1)
**As an** employee
**I want to** clock in/out even without network
**So that** I can always record my shift times

**Acceptance Criteria**:
- Given I have no network, when I clock in, then the action is stored locally
- Given I regain network, then my shift is synced to Supabase
- Given there's a conflict (shift already exists), then the local data wins (latest timestamp)

**Independent Test**: Clock in while offline, verify local storage, go online, verify Supabase updated

#### US3: Sync Status Display (P2)
**As an** employee
**I want to** see sync status
**So that** I know if my data has been uploaded

**Acceptance Criteria**:
- Given I have unsynced data, then I see "X items pending sync"
- Given all data is synced, then I see "All data synced" or nothing
- Given sync is in progress, then I see a sync indicator

**Independent Test**: Visual verification of sync status in various states

### Technical Implementation

#### Local Database Schema (SQLite)
```sql
-- Local GPS points queue
CREATE TABLE local_gps_points (
    id TEXT PRIMARY KEY,
    shift_id TEXT NOT NULL,
    employee_id TEXT NOT NULL,
    latitude REAL NOT NULL,
    longitude REAL NOT NULL,
    accuracy REAL,
    altitude REAL,
    captured_at TEXT NOT NULL,
    synced INTEGER DEFAULT 0,
    sync_attempts INTEGER DEFAULT 0,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

-- Local shifts queue
CREATE TABLE local_shifts (
    id TEXT PRIMARY KEY,
    employee_id TEXT NOT NULL,
    clock_in_at TEXT NOT NULL,
    clock_out_at TEXT,
    clock_in_latitude REAL,
    clock_in_longitude REAL,
    clock_out_latitude REAL,
    clock_out_longitude REAL,
    status TEXT DEFAULT 'active',
    synced INTEGER DEFAULT 0,
    sync_attempts INTEGER DEFAULT 0,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
```

#### Sync Logic
```dart
class SyncService {
  Future<void> syncPendingData() async {
    if (!await hasConnectivity()) return;

    // Sync shifts first (GPS points depend on shift_id)
    final pendingShifts = await getUnsyncedShifts();
    for (final shift in pendingShifts) {
      await syncShift(shift);
    }

    // Then sync GPS points
    final pendingPoints = await getUnsyncedGpsPoints();
    for (final point in pendingPoints) {
      await syncGpsPoint(point);
    }
  }
}
```

### Success Criteria

- [x] GPS points stored locally when offline
- [x] GPS points sync automatically when online
- [x] Clock in/out works offline
- [x] Shifts sync automatically when online
- [x] Sync status displayed to user
- [x] No data loss in poor connectivity scenarios
- [x] Conflict resolution works correctly

### Checkpoint

**After this spec**: The app is robust for field use. Employees in areas with poor cellular coverage can still use the app effectively.

---

## Spec 006: Employee History

**Branch**: `006-employee-history`
**Complexity**: Medium

### Purpose

Allow employees to view their past shifts and GPS trail for transparency.

### Scope

#### In Scope
- List of past shifts
- Shift detail view with GPS points
- Simple map view of GPS trail (optional)
- Basic statistics (hours worked this week/month)

#### Out of Scope
- Admin portal (separate project)
- Data export
- Editing past shifts

### User Stories

#### US1: View Shift History (P1)
**As an** employee
**I want to** see my past shifts
**So that** I can verify my work history

**Acceptance Criteria**:
- Given I navigate to history, then I see a list of my past shifts
- Given I tap a shift, then I see shift details including start/end time
- Given I have many shifts, then I can scroll through them

**Independent Test**: Create shifts, view history, verify accuracy

#### US2: View GPS Trail (P2)
**As an** employee
**I want to** see GPS points for a shift
**So that** I can verify my location data

**Acceptance Criteria**:
- Given I am viewing shift details, then I see count of GPS points
- Given I tap "View GPS Points", then I see a list of timestamps/locations
- (Optional) Given I tap "View Map", then I see points on a map

**Independent Test**: View shift with GPS points, verify all points shown

#### US3: Basic Statistics (P3)
**As an** employee
**I want to** see my work statistics
**So that** I can track my hours

**Acceptance Criteria**:
- Given I am on the history screen, then I see "Hours this week: X"
- Given I am on the history screen, then I see "Shifts this month: Y"

**Independent Test**: Work multiple shifts, verify statistics accuracy

### Screens

1. **History List Screen**
   ```
   +-----------------------------+
   |  Shift History              |
   |  -------------------------  |
   |  This Week: 32.5 hours      |
   |  -------------------------  |
   |                             |
   |  +---------------------+    |
   |  | Mon, Jan 6          |    |
   |  | 9:00 AM - 5:30 PM   |    |
   |  | 8.5 hours - 98 GPS  |    |
   |  +---------------------+    |
   |                             |
   |  +---------------------+    |
   |  | Tue, Jan 7          |    |
   |  | 8:30 AM - 4:00 PM   |    |
   |  | 7.5 hours - 84 GPS  |    |
   |  +---------------------+    |
   |                             |
   |  [Load More...]             |
   +-----------------------------+
   ```

2. **Shift Detail Screen**
   ```
   +-----------------------------+
   |  <- Shift Details           |
   |  -------------------------  |
   |                             |
   |  Monday, January 6, 2026    |
   |                             |
   |  Clock In:  9:00:23 AM      |
   |  Location:  45.123, -73.456 |
   |                             |
   |  Clock Out: 5:30:45 PM      |
   |  Location:  45.124, -73.455 |
   |                             |
   |  Duration: 8h 30m 22s       |
   |  GPS Points: 98             |
   |                             |
   |  [View GPS Points]          |
   |  [View on Map] (optional)   |
   +-----------------------------+
   ```

### Success Criteria

- [ ] Shift history list displays correctly
- [ ] Shift details show clock in/out times and locations
- [ ] GPS point count shown per shift
- [ ] GPS point list viewable
- [ ] Basic statistics calculated correctly

### Checkpoint

**After this spec**: The app is feature-complete from the employee perspective. Employees have full visibility into their tracked data.

---

## Spec 007: Location Permission Guard

**Branch**: `007-location-permission-guard`
**Complexity**: Medium

### Purpose

Ensure location permission is always granted while clocked in. Auto clock-out if permission is revoked, with guided UI to help users grant the correct permission.

### Scope

#### In Scope
- Permission check on app resume
- Auto clock-out if permission revoked while clocked in
- Platform-specific permission guidance (iOS/Android)
- Localized button instructions (EN/FR)

#### Out of Scope
- Background permission monitoring
- Permission recovery flow

### User Stories

#### US1: Auto Clock-Out on Permission Revoked (P1)
**As an** employer
**I want** employees auto-clocked out if they revoke location permission
**So that** GPS tracking integrity is maintained

**Acceptance Criteria**:
- Given employee is clocked in, when app resumes and permission is revoked, then auto clock-out occurs
- Given auto clock-out occurs, then employee sees message explaining why
- Given permission is still granted, then nothing happens

#### US2: Guided Permission Request (P1)
**As an** employee
**I want** clear instructions on which button to tap for location permission
**So that** I don't accidentally deny permission

**Acceptance Criteria**:
- Given iOS + English, then show "Tap **Always Allow**"
- Given iOS + French, then show "Appuyez sur **Toujours autoriser**"
- Given Android + English, then show "Tap **Allow all the time**"
- Given Android + French, then show "Appuyez sur **Toujours autoriser**"

### Technical Notes

```dart
// On app resume (in WidgetsBindingObserver)
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) {
    _checkLocationPermission();
  }
}

Future<void> _checkLocationPermission() async {
  final permission = await Geolocator.checkPermission();
  final isClocked = ref.read(shiftProvider).isActive;

  if (isClocked && permission == LocationPermission.denied) {
    await _autoClockOut();
    _showPermissionRevokedMessage();
  }
}
```

### Permission Guidance Strings

| Platform | Locale | Text |
|----------|--------|------|
| iOS | en | Tap **"Always Allow"** to enable GPS tracking |
| iOS | fr | Appuyez sur **"Toujours autoriser"** pour activer le suivi GPS |
| Android | en | Tap **"Allow all the time"** for background tracking |
| Android | fr | Appuyez sur **"Toujours autoriser"** pour le suivi en arriere-plan |

### Success Criteria

- [ ] App checks permission on every resume
- [ ] Auto clock-out triggers if permission revoked while clocked in
- [ ] User sees clear message after auto clock-out
- [ ] Permission guidance shows correct platform/language text
- [ ] Guidance appears before system permission dialog

### Checkpoint

**After this spec**: GPS tracking integrity is protected. Users cannot bypass location tracking by revoking permissions.

---

## Spec 008: Employee & Shift Dashboard

**Branch**: `008-employee-shift-dashboard`
**Complexity**: Medium

### Purpose

Provide a UI to visualize all employees and their shifts for administrative oversight.

### Scope

#### In Scope
- Employee list view
- Shift list per employee
- Current shift status (who is clocked in now)
- Basic filtering (date range, employee)

#### Out of Scope
- GPS point visualization on map
- Shift editing/correction
- Export functionality

### User Stories

#### US1: View All Employees (P1)
**As an** admin/manager
**I want** to see a list of all employees
**So that** I can monitor the workforce

**Acceptance Criteria**:
- Given I open the dashboard, then I see list of employees
- Given an employee is clocked in, then I see an "Active" indicator
- Given I tap an employee, then I see their shift history

#### US2: View Employee Shifts (P1)
**As an** admin/manager
**I want** to see shift history for an employee
**So that** I can verify work hours

**Acceptance Criteria**:
- Given I select an employee, then I see their shifts
- Given a shift, then I see clock-in/out times and duration
- Given a shift, then I see GPS point count

#### US3: Filter Shifts (P2)
**As an** admin/manager
**I want** to filter shifts by date
**So that** I can focus on specific periods

**Acceptance Criteria**:
- Given I select a date range, then only matching shifts appear
- Given I clear filters, then all shifts appear

### Screens

```
+---------------------------+     +---------------------------+
|  Employees                |     |  John Doe                 |
|  ----------------------   |     |  ----------------------   |
|                           |     |  Status: Clocked In       |
|  +---------------------+  |     |  Since: 9:00 AM           |
|  | John Doe       [ON] |  |     |  ----------------------   |
|  +---------------------+  |     |                           |
|  +---------------------+  |     |  Recent Shifts:           |
|  | Jane Smith          |  |     |  +---------------------+  |
|  +---------------------+  |     |  | Jan 9 - 8h 30m      |  |
|  +---------------------+  |     |  | 52 GPS points       |  |
|  | Bob Wilson          |  |     |  +---------------------+  |
|  +---------------------+  |     |  +---------------------+  |
|                           |     |  | Jan 8 - 7h 45m      |  |
+---------------------------+     +---------------------------+
```

### Technical Notes

- Requires admin role check (new RLS policy or separate auth)
- Query: `SELECT * FROM employee_profiles`
- Query: `SELECT * FROM shifts WHERE employee_id = ? ORDER BY clock_in_at DESC`
- Real-time subscription for active shifts (optional)

### Success Criteria

- [ ] Employee list displays all employees
- [ ] Active employees show visual indicator
- [ ] Shift history loads for selected employee
- [ ] Shift details show times, duration, GPS count
- [ ] Date filter works correctly

### Checkpoint

**After this spec**: Full administrative visibility into workforce activity.

---

## Implementation Order

```
Recommended Sequence:

Phase 1: Spec 007 (Location Permission Guard)
         +-- Protects GPS tracking integrity (HIGH PRIORITY)

Phase 2: Spec 005 (Offline Resilience)
         +-- Robust for field use

Phase 3: Spec 006 (Employee History)
         +-- Employee self-service

Phase 4: Spec 008 (Dashboard)
         +-- Admin visibility
```

---

## Dependencies Graph

```
001-004 (MVP Complete)
      |
      +-------+-------+
      |               |
      v               v
005-Offline      007-Permission-Guard
      |               |
      v               v
006-History      008-Dashboard
```
