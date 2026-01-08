# GPS Tracker App - Complete Development Roadmap

**Project**: Employee GPS Clock-In Tracker
**Framework**: Flutter (iOS + Android)
**Backend**: Supabase
**Target Users**: 25 employees
**Distribution**: TestFlight (iOS) + Google Play Internal Testing (Android)

---

## Executive Summary

This document outlines the complete development roadmap for the GPS Tracker app, decomposed into **6 independent specifications** following Speckit best practices. Each spec is designed to be:

- **Independently implementable** - Can be developed without waiting for others
- **Independently testable** - Delivers standalone value that can be validated
- **Incrementally deployable** - Can be shipped to users at each milestone

### Spec Overview

| Spec # | Name | Priority | Dependencies | MVP? |
|--------|------|----------|--------------|------|
| 001 | Project Foundation | P0 | None | Yes |
| 002 | Employee Authentication | P1 | 001 | Yes |
| 003 | Shift Management | P1 | 002 | Yes |
| 004 | Background GPS Tracking | P1 | 003 | Yes |
| 005 | Offline Resilience | P2 | 004 | No |
| 006 | Employee History | P3 | 003 | No |

### Development Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        MVP DELIVERY PATH                            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  001-Foundation ──► 002-Auth ──► 003-Shift ──► 004-GPS             │
│       (Setup)       (Login)     (Clock)      (Track)               │
│                                                                     │
│  ════════════════════════════════════════════════════════════════  │
│                         MVP COMPLETE                                │
│  ════════════════════════════════════════════════════════════════  │
│                                                                     │
│                              │                                      │
│                              ▼                                      │
│                    005-Offline ──► 006-History                     │
│                    (Robustness)    (Nice-to-have)                  │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Spec Decomposition Rationale

### Why This Split?

Based on Speckit's **independence principle**, each spec must deliver standalone value. Here's the reasoning:

| If we stopped after... | Would the app be useful? |
|------------------------|--------------------------|
| 001 - Foundation | No - just empty shell |
| 002 - Auth | No - can log in but do nothing |
| 003 - Shift | **Partial** - time tracking works, single GPS on clock in/out |
| 004 - GPS | **Yes** - full GPS tracking every 5 min (MVP!) |
| 005 - Offline | **Better** - works in poor coverage |
| 006 - History | **Complete** - employees see their data |

The MVP milestone is after **Spec 004** - at that point, the core requirement (GPS every 5 minutes while clocked in) is fully functional.

### Alternative Approaches Considered

| Approach | Pros | Cons | Decision |
|----------|------|------|----------|
| One mega-spec | Simple tracking | Too large, no incremental validation | Rejected |
| Split by platform (iOS/Android) | Platform experts | Violates Flutter single-codebase principle | Rejected |
| Split by layer (UI/Backend/Services) | Clean separation | Not independently testable | Rejected |
| **Split by user value** | Each spec delivers value | Slightly more specs | **Selected** |

---

## Detailed Spec Breakdown

---

## Spec 001: Project Foundation

**Branch**: `001-project-foundation`
**Estimated Complexity**: Medium
**Constitution Alignment**: All principles

### Purpose

Establish the complete development environment, project structure, and backend infrastructure. This is the **foundational phase** that all other specs depend on.

### Scope

#### In Scope
- Flutter project creation with proper structure
- Supabase project setup and configuration
- Database schema design (all tables)
- Platform configurations (iOS entitlements, Android permissions)
- CI/CD pipeline setup (optional)
- Development environment documentation

#### Out of Scope
- Any user-facing features
- Authentication logic (only Supabase client setup)
- GPS functionality

### User Stories

This spec has no user stories - it's pure infrastructure.

### Technical Deliverables

#### 1. Flutter Project Structure
```
gps_tracker/
├── lib/
│   ├── main.dart
│   ├── app.dart
│   ├── config/
│   │   ├── supabase_config.dart
│   │   ├── app_config.dart
│   │   └── constants.dart
│   ├── models/
│   │   └── (empty, ready for entities)
│   ├── services/
│   │   └── (empty, ready for business logic)
│   ├── screens/
│   │   └── (empty, ready for UI)
│   ├── widgets/
│   │   └── (empty, ready for components)
│   └── utils/
│       └── (empty, ready for helpers)
├── ios/
│   └── (configured with location permissions)
├── android/
│   └── (configured with location permissions)
├── test/
│   └── (test structure ready)
└── pubspec.yaml
```

#### 2. Supabase Database Schema
```sql
-- employees table (managed by Supabase Auth, extended)
CREATE TABLE employee_profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id),
    email TEXT NOT NULL,
    full_name TEXT NOT NULL,
    employee_id TEXT UNIQUE,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- shifts table
CREATE TABLE shifts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id UUID REFERENCES employee_profiles(id) NOT NULL,
    clock_in_at TIMESTAMPTZ NOT NULL,
    clock_out_at TIMESTAMPTZ,
    clock_in_latitude DOUBLE PRECISION,
    clock_in_longitude DOUBLE PRECISION,
    clock_out_latitude DOUBLE PRECISION,
    clock_out_longitude DOUBLE PRECISION,
    status TEXT DEFAULT 'active' CHECK (status IN ('active', 'completed')),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- gps_points table
CREATE TABLE gps_points (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    shift_id UUID REFERENCES shifts(id) NOT NULL,
    employee_id UUID REFERENCES employee_profiles(id) NOT NULL,
    latitude DOUBLE PRECISION NOT NULL,
    longitude DOUBLE PRECISION NOT NULL,
    accuracy DOUBLE PRECISION,
    altitude DOUBLE PRECISION,
    captured_at TIMESTAMPTZ NOT NULL,
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    is_offline_capture BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Row Level Security
ALTER TABLE employee_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE shifts ENABLE ROW LEVEL SECURITY;
ALTER TABLE gps_points ENABLE ROW LEVEL SECURITY;

-- RLS Policies (employees see only their own data)
CREATE POLICY "Employees can view own profile"
    ON employee_profiles FOR SELECT
    USING (auth.uid() = id);

CREATE POLICY "Employees can view own shifts"
    ON shifts FOR SELECT
    USING (auth.uid() = employee_id);

CREATE POLICY "Employees can insert own shifts"
    ON shifts FOR INSERT
    WITH CHECK (auth.uid() = employee_id);

CREATE POLICY "Employees can update own active shifts"
    ON shifts FOR UPDATE
    USING (auth.uid() = employee_id AND status = 'active');

CREATE POLICY "Employees can view own GPS points"
    ON gps_points FOR SELECT
    USING (auth.uid() = employee_id);

CREATE POLICY "Employees can insert own GPS points"
    ON gps_points FOR INSERT
    WITH CHECK (auth.uid() = employee_id);
```

#### 3. Platform Configurations

**iOS (Info.plist)**:
- `NSLocationWhenInUseUsageDescription`
- `NSLocationAlwaysAndWhenInUseUsageDescription`
- `UIBackgroundModes`: `location`

**Android (AndroidManifest.xml)**:
- `ACCESS_FINE_LOCATION`
- `ACCESS_COARSE_LOCATION`
- `ACCESS_BACKGROUND_LOCATION`
- `FOREGROUND_SERVICE`
- `FOREGROUND_SERVICE_LOCATION`

#### 4. Dependencies (pubspec.yaml)
```yaml
dependencies:
  flutter:
    sdk: flutter
  supabase_flutter: ^2.0.0
  geolocator: ^11.0.0
  flutter_local_notifications: ^16.0.0
  shared_preferences: ^2.2.0
  connectivity_plus: ^5.0.0
  sqflite: ^2.3.0
  path_provider: ^2.1.0
  provider: ^6.1.0
  go_router: ^13.0.0
```

### Success Criteria

- [ ] Flutter project builds successfully on iOS and Android
- [ ] Supabase connection established
- [ ] Database tables created with RLS enabled
- [ ] Location permissions configured (not yet requested)
- [ ] Project runs on simulator/emulator showing blank app shell

### Checkpoint

**After this spec**: Development environment is fully ready. No user-visible features exist yet, but all infrastructure is in place for rapid feature development.

---

## Spec 002: Employee Authentication

**Branch**: `002-employee-authentication`
**Estimated Complexity**: Medium
**Constitution Alignment**: Privacy & Compliance, Simplicity

### Purpose

Enable employees to securely identify themselves and consent to location tracking.

### Scope

#### In Scope
- Login screen with email/password
- Logout functionality
- Privacy consent flow (first launch)
- Session persistence (stay logged in)
- Basic error handling (wrong password, network error)

#### Out of Scope
- Password reset (can use Supabase default)
- Employee registration (admin creates accounts)
- Profile editing

### User Stories

#### US1: Employee Login (P1)
**As an** employee
**I want to** log in with my email and password
**So that** the app knows who I am and can track my shifts

**Acceptance Criteria**:
- Given I am on the login screen, when I enter valid credentials, then I am taken to the home screen
- Given I enter invalid credentials, then I see an error message
- Given I have no network, then I see an appropriate error

**Independent Test**: Can verify login/logout flow without any other features

#### US2: Privacy Consent (P1)
**As an** employee
**I want to** understand and consent to location tracking
**So that** I am informed about how my data is used

**Acceptance Criteria**:
- Given I log in for the first time, when the app loads, then I see the privacy consent screen
- Given I have not accepted privacy terms, then I cannot proceed to the home screen
- Given I accept the terms, then my consent is recorded and I proceed to the home screen

**Independent Test**: Can verify consent flow appears on first login

#### US3: Session Persistence (P2)
**As an** employee
**I want to** stay logged in between app launches
**So that** I don't have to enter credentials every time

**Acceptance Criteria**:
- Given I logged in previously, when I reopen the app, then I am automatically logged in
- Given my session expired, when I open the app, then I am taken to the login screen

**Independent Test**: Close and reopen app, verify session persists

### Screens

1. **Login Screen**
   - Email field
   - Password field
   - Login button
   - Error message area

2. **Privacy Consent Screen**
   - Privacy policy summary
   - Bullet points of what data is collected
   - "I Agree" button
   - "Decline" button (logs out)

3. **Home Screen Shell**
   - Placeholder for clock in/out (Spec 003)
   - Logout button in settings/profile

### Technical Notes

- Use Supabase Auth for authentication
- Store consent acceptance in `employee_profiles.privacy_accepted_at`
- Use `shared_preferences` for session token caching

### Success Criteria

- [ ] Employee can log in with valid credentials
- [ ] Invalid credentials show error message
- [ ] Privacy consent appears on first login
- [ ] Session persists between app launches
- [ ] Logout clears session

### Checkpoint

**After this spec**: Employees can identify themselves. The app shows a home screen but has no functionality yet beyond login/logout.

---

## Spec 003: Shift Management

**Branch**: `003-shift-management`
**Estimated Complexity**: Medium-High
**Constitution Alignment**: Privacy (only track when clocked in), Simplicity

### Purpose

Enable employees to clock in and out, recording their shift times and capturing GPS at clock in/out moments.

### Scope

#### In Scope
- Clock In button with single GPS capture
- Clock Out button with single GPS capture
- Current shift status display
- Location permission request flow
- Basic shift record creation

#### Out of Scope
- Background GPS tracking (Spec 004)
- Shift history viewing (Spec 006)
- Offline clock in/out (Spec 005)

### User Stories

#### US1: Clock In (P1)
**As an** employee
**I want to** clock in when I start work
**So that** my shift start time and location are recorded

**Acceptance Criteria**:
- Given I am on the home screen and not clocked in, when I tap "Clock In", then my shift starts and my location is captured
- Given location permission is not granted, when I tap "Clock In", then I am prompted to grant permission
- Given I am already clocked in, then the "Clock In" button is disabled/hidden

**Independent Test**: Clock in, verify shift record created in Supabase with GPS coordinates

#### US2: Clock Out (P1)
**As an** employee
**I want to** clock out when I finish work
**So that** my shift end time and location are recorded

**Acceptance Criteria**:
- Given I am clocked in, when I tap "Clock Out", then my shift ends and my location is captured
- Given I am not clocked in, then the "Clock Out" button is disabled/hidden
- Given I clock out, then my total shift duration is displayed

**Independent Test**: Clock out, verify shift record updated with end time and GPS

#### US3: Current Shift Status (P2)
**As an** employee
**I want to** see my current shift status
**So that** I know if I'm clocked in and for how long

**Acceptance Criteria**:
- Given I am clocked in, then I see "Clocked In" status with elapsed time
- Given I am not clocked in, then I see "Not Clocked In" status
- Given I am clocked in, then elapsed time updates every minute

**Independent Test**: Visual verification of status display

### Screens

1. **Home Screen (Updated)**
   ```
   ┌─────────────────────────────┐
   │  GPS Tracker                │
   │  ─────────────────────────  │
   │                             │
   │  ┌───────────────────────┐  │
   │  │   NOT CLOCKED IN      │  │
   │  │   Tap below to start  │  │
   │  └───────────────────────┘  │
   │                             │
   │  ┌───────────────────────┐  │
   │  │      CLOCK IN         │  │
   │  │         ⏱️             │  │
   │  └───────────────────────┘  │
   │                             │
   │  ─────────────────────────  │
   │  ⚙️ Settings                │
   └─────────────────────────────┘
   ```

2. **Home Screen (Clocked In)**
   ```
   ┌─────────────────────────────┐
   │  GPS Tracker                │
   │  ─────────────────────────  │
   │                             │
   │  ┌───────────────────────┐  │
   │  │   CLOCKED IN          │  │
   │  │   02:34:15 elapsed    │  │
   │  │   Started: 9:00 AM    │  │
   │  └───────────────────────┘  │
   │                             │
   │  ┌───────────────────────┐  │
   │  │      CLOCK OUT        │  │
   │  │         🛑             │  │
   │  └───────────────────────┘  │
   │                             │
   │  📍 GPS Active (5 points)   │
   │  ─────────────────────────  │
   │  ⚙️ Settings                │
   └─────────────────────────────┘
   ```

### Technical Notes

- Request `ACCESS_FINE_LOCATION` on first clock-in attempt
- Use `geolocator` package for single GPS fix
- Create shift record in Supabase on clock in
- Update shift record on clock out
- Store `clock_in_latitude`, `clock_in_longitude`, etc.

### Success Criteria

- [ ] Employee can clock in and GPS is captured
- [ ] Employee can clock out and GPS is captured
- [ ] Shift record created/updated in Supabase
- [ ] Current status displayed correctly
- [ ] Elapsed time updates while clocked in
- [ ] Location permission handled gracefully

### Checkpoint

**After this spec**: Basic time tracking works. Employees can clock in/out with location captured at those moments. This is a **usable app** but not yet meeting the "GPS every 5 minutes" requirement.

---

## Spec 004: Background GPS Tracking

**Branch**: `004-background-gps-tracking`
**Estimated Complexity**: High
**Constitution Alignment**: Battery-Conscious Design, Privacy (only while clocked in)

### Purpose

Capture GPS coordinates every 5 minutes while an employee is clocked in, even when the app is in the background.

### Scope

#### In Scope
- Background location service
- 5-minute interval GPS capture
- iOS Background Modes implementation
- Android Foreground Service implementation
- Battery optimization considerations
- Persistent notification (Android requirement)
- GPS point storage in Supabase

#### Out of Scope
- Offline GPS storage (Spec 005)
- GPS history viewing (Spec 006)
- Geofencing

### User Stories

#### US1: Background GPS Capture (P1)
**As an** employer
**I want** GPS captured every 5 minutes while employees are clocked in
**So that** I can verify employee locations during their shift

**Acceptance Criteria**:
- Given an employee is clocked in, when 5 minutes pass, then a GPS point is captured and uploaded
- Given the app is in the background, then GPS capture continues
- Given the employee clocks out, then GPS capture stops immediately
- Given the employee force-closes the app while clocked in, then GPS capture continues (with notification)

**Independent Test**: Clock in, wait 10+ minutes, verify multiple GPS points in Supabase

#### US2: Tracking Notification (P1)
**As an** employee
**I want to** see when GPS tracking is active
**So that** I know my location is being recorded

**Acceptance Criteria**:
- Given I am clocked in on Android, then a persistent notification shows "GPS tracking active"
- Given I am clocked in on iOS, then the location indicator appears in status bar
- Given I clock out, then the notification/indicator disappears

**Independent Test**: Visual verification on both platforms

#### US3: Battery Information (P2)
**As an** employee
**I want to** understand the battery impact
**So that** I can manage my device accordingly

**Acceptance Criteria**:
- Given I am on the settings screen, then I see estimated battery usage info
- Given GPS tracking is active, then I can see how many points have been captured

**Independent Test**: Read settings screen information

### Technical Implementation

#### iOS Implementation
```dart
// Use geolocator with background mode
// Info.plist: UIBackgroundModes = [location]
// Request "Always" permission

Position position = await Geolocator.getCurrentPosition(
  desiredAccuracy: LocationAccuracy.high,
);
```

#### Android Implementation
```dart
// Use Foreground Service
// Show persistent notification
// AndroidManifest.xml: FOREGROUND_SERVICE_LOCATION

// Start foreground service on clock in
// Stop foreground service on clock out
```

#### Timer Logic
```dart
// Pseudocode for GPS capture timer
Timer.periodic(Duration(minutes: 5), (timer) async {
  if (!isEmployeeClockedIn) {
    timer.cancel();
    return;
  }

  final position = await getCurrentPosition();
  await uploadGpsPoint(position);
});
```

### Platform-Specific Requirements

| Platform | Requirement | Implementation |
|----------|-------------|----------------|
| iOS | Background Modes | Enable "Location updates" in capabilities |
| iOS | Always Permission | Request with clear usage description |
| iOS | Background indicator | Automatic blue bar shown by OS |
| Android | Foreground Service | Required for background work |
| Android | Notification | Persistent notification while tracking |
| Android | Battery optimization | Request exclusion from Doze mode |

### Success Criteria

- [ ] GPS captured every 5 minutes while clocked in
- [ ] GPS capture works in background on both platforms
- [ ] GPS capture stops when clocked out
- [ ] Android shows persistent notification
- [ ] iOS shows location indicator
- [ ] GPS points uploaded to Supabase
- [ ] Battery usage is reasonable (<15% per 8-hour shift)

### Checkpoint

**After this spec**: **MVP COMPLETE**. The app now does exactly what was requested - captures GPS every 5 minutes while employees are clocked in. This can be deployed to employees via TestFlight/Internal Testing.

---

## Spec 005: Offline Resilience

**Branch**: `005-offline-resilience`
**Estimated Complexity**: High
**Constitution Alignment**: Offline-First Architecture

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
// Pseudocode for sync service
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

- [ ] GPS points stored locally when offline
- [ ] GPS points sync automatically when online
- [ ] Clock in/out works offline
- [ ] Shifts sync automatically when online
- [ ] Sync status displayed to user
- [ ] No data loss in poor connectivity scenarios
- [ ] Conflict resolution works correctly

### Checkpoint

**After this spec**: The app is now robust for field use. Employees in areas with poor cellular coverage can still use the app effectively.

---

## Spec 006: Employee History

**Branch**: `006-employee-history`
**Estimated Complexity**: Medium
**Constitution Alignment**: Simplicity (nice-to-have, not core)

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
   ┌─────────────────────────────┐
   │  Shift History              │
   │  ─────────────────────────  │
   │  This Week: 32.5 hours      │
   │  ─────────────────────────  │
   │                             │
   │  ┌───────────────────────┐  │
   │  │ Mon, Jan 6            │  │
   │  │ 9:00 AM - 5:30 PM     │  │
   │  │ 8.5 hours • 98 GPS    │  │
   │  └───────────────────────┘  │
   │                             │
   │  ┌───────────────────────┐  │
   │  │ Tue, Jan 7            │  │
   │  │ 8:30 AM - 4:00 PM     │  │
   │  │ 7.5 hours • 84 GPS    │  │
   │  └───────────────────────┘  │
   │                             │
   │  [Load More...]             │
   └─────────────────────────────┘
   ```

2. **Shift Detail Screen**
   ```
   ┌─────────────────────────────┐
   │  ← Shift Details            │
   │  ─────────────────────────  │
   │                             │
   │  Monday, January 6, 2026    │
   │                             │
   │  Clock In:  9:00:23 AM      │
   │  Location:  45.123, -73.456 │
   │                             │
   │  Clock Out: 5:30:45 PM      │
   │  Location:  45.124, -73.455 │
   │                             │
   │  Duration: 8h 30m 22s       │
   │  GPS Points: 98             │
   │                             │
   │  [View GPS Points]          │
   │  [View on Map] (optional)   │
   └─────────────────────────────┘
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

## Implementation Timeline

### Recommended Order

```
Week 1-2: Spec 001 (Foundation) + Spec 002 (Auth)
          └─ Deliverable: Employees can log in

Week 3:   Spec 003 (Shift Management)
          └─ Deliverable: Basic clock in/out works

Week 4-5: Spec 004 (Background GPS)
          └─ Deliverable: MVP COMPLETE - Full GPS tracking

Week 6:   Spec 005 (Offline)
          └─ Deliverable: Robust for field use

Week 7:   Spec 006 (History)
          └─ Deliverable: Feature-complete app
```

### MVP Milestone

After completing Specs 001-004, you have a **fully functional MVP** that:
- Employees can log in
- Employees can clock in/out
- GPS is captured every 5 minutes while clocked in
- Works on iOS and Android
- Can be distributed via TestFlight and Google Play Internal Testing

Specs 005-006 add robustness and user experience improvements but are not required for initial deployment.

---

## Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| iOS App Store rejects background location | High | Use TestFlight permanently; clear privacy justification |
| Battery drain complaints | Medium | Configurable interval; clear battery usage docs |
| GPS accuracy issues indoors | Medium | Document expected accuracy; accept cellular-assisted location |
| Supabase rate limits | Low | 25 users with 5-min interval = 300 points/hour (well within limits) |
| Offline sync conflicts | Medium | Clear conflict resolution strategy (latest wins) |

---

## Next Steps

1. **Create Supabase Project**: Set up at supabase.com
2. **Run `/speckit.specify`**: Start with Spec 001
3. **Create Developer Accounts**: Apple Developer ($99) + Google Play ($25)
4. **Begin Implementation**: Follow Speckit workflow

---

## Appendix: Spec Dependencies Graph

```
001-Foundation
      │
      ▼
002-Auth ─────────────────┐
      │                   │
      ▼                   │
003-Shift ────────────────┼──► 006-History
      │                   │
      ▼                   │
004-GPS ◄─────────────────┘
      │
      ▼
005-Offline
```

**Legend**:
- Solid arrows (│▼) = Must complete before
- Dashed lines (─) = Can start in parallel after dependency met
