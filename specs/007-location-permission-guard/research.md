# Research: Location Permission Guard

**Feature**: 007-location-permission-guard
**Date**: 2026-01-10

## Overview

This document captures research findings for implementing the Location Permission Guard feature, resolving all technical unknowns and documenting design decisions.

## Existing Infrastructure Analysis

### Current Permission System

**Location**: `lib/features/tracking/`

The codebase already has a robust permission handling system:

1. **LocationPermissionState** (`models/location_permission_state.dart`)
   - Enum `LocationPermissionLevel`: notDetermined, denied, deniedForever, whileInUse, always
   - Computed properties: `canTrackInBackground`, `hasAnyPermission`, `canRequestPermission`
   - Immutable state with `copyWith` support

2. **LocationPermissionNotifier** (`providers/location_permission_provider.dart`)
   - StateNotifier-based provider
   - Methods: `checkPermissions()`, `requestPermissions()`, `requestBatteryOptimization()`
   - Derived providers: `canTrackInBackgroundProvider`, `hasLocationPermissionProvider`, etc.

3. **BackgroundTrackingService** (`services/background_tracking_service.dart`)
   - Static methods for permission checking and requesting
   - Maps `geolocator.LocationPermission` to internal `LocationPermissionState`
   - Handles Android notification permission and battery optimization

4. **UI Components** (`widgets/`)
   - `PermissionExplanationDialog`: Educational dialog before requesting permissions
   - `SettingsGuidanceDialog`: Platform-specific instructions for permanently denied permissions

### Current Gaps (What Spec 007 Will Add)

| Gap | Current State | Spec 007 Requirement |
|-----|---------------|---------------------|
| Dashboard banner | No visual indicator | Persistent top banner showing permission status |
| Pre-clock-in blocking | Shows dialog on failure | Block/warn BEFORE attempting clock-in |
| Active shift monitoring | No monitoring | Detect permission changes during shift |
| Session acknowledgment | None | Dismiss warnings, persist within session |
| Device services detection | Not checked | Detect device-level location services disabled |
| Debounced state | Immediate updates | Debounce rapid permission changes |

---

## Research Topic 1: Flutter App Lifecycle Monitoring

### Question
How to detect when the app returns to foreground to re-check permissions?

### Decision
Use `WidgetsBindingObserver.didChangeAppLifecycleState()` - already implemented in `ShiftDashboardScreen`.

### Rationale
- Built-in Flutter API, no additional dependencies
- Already used in the codebase for shift state refresh
- Reliable across iOS and Android

### Implementation
```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) {
    ref.read(locationPermissionProvider.notifier).checkPermissions();
  }
}
```

### Alternatives Considered
- Timer-based polling: Rejected - wasteful battery consumption
- Platform channels: Rejected - over-engineered for this use case

---

## Research Topic 2: Device Location Services Detection

### Question
How to distinguish between app permission denied vs device-level location services disabled?

### Decision
Use `Geolocator.isLocationServiceEnabled()` before checking app permission.

### Rationale
- `geolocator` package (already a dependency) provides this API
- Returns `false` when device GPS/location services are turned off globally
- Works on both iOS and Android

### Implementation
```dart
Future<LocationGuardState> checkFullStatus() async {
  final serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) {
    return LocationGuardState.deviceServicesDisabled;
  }

  final permission = await Geolocator.checkPermission();
  // Map to appropriate state...
}
```

### Alternatives Considered
- Catching exceptions on location requests: Rejected - reactive rather than proactive
- Platform-specific APIs: Rejected - geolocator abstracts this already

---

## Research Topic 3: Session-Scoped State Persistence

### Question
How to persist dismissed warnings within a session but reset on app restart?

### Decision
Use in-memory state in a Riverpod provider (not persisted to storage).

### Rationale
- Spec explicitly states: "Reset once per app session"
- In-memory state naturally resets on process restart
- Simpler than shared_preferences or local database

### Implementation
```dart
class PermissionGuardNotifier extends StateNotifier<PermissionGuardState> {
  final Set<WarningType> _dismissedWarnings = {};

  void dismissWarning(WarningType type) {
    _dismissedWarnings.add(type);
    _updateState();
  }

  bool isWarningDismissed(WarningType type) => _dismissedWarnings.contains(type);
}
```

### Alternatives Considered
- SharedPreferences with session ID: Rejected - over-engineered
- SQLite/SQLCipher: Rejected - spec explicitly wants session scope only

---

## Research Topic 4: Debouncing Permission State Changes

### Question
How to handle rapid permission toggles without UI flicker?

### Decision
Use `Timer` with 500ms debounce on permission state updates.

### Rationale
- Prevents UI flicker when user rapidly toggles permissions
- 500ms is imperceptible delay but filters rapid changes
- Standard debounce pattern in Dart

### Implementation
```dart
Timer? _debounceTimer;

void _onPermissionChanged(LocationPermissionState newState) {
  _debounceTimer?.cancel();
  _debounceTimer = Timer(const Duration(milliseconds: 500), () {
    state = state.copyWith(permission: newState);
  });
}
```

### Alternatives Considered
- No debouncing: Rejected - causes UI flicker per spec edge case
- Longer debounce (1s+): Rejected - perceptible delay affects UX

---

## Research Topic 5: Banner UI Pattern

### Question
What Flutter pattern best implements a persistent, dismissible top banner?

### Decision
Use a `Column` with conditional banner widget at the top of the dashboard layout.

### Rationale
- Simpler than `SliverAppBar` or `MaterialBanner` for this use case
- Pushes content down as specified in FR-001
- Easy to animate with `AnimatedSize` or `AnimatedCrossFade`

### Implementation
```dart
Column(
  children: [
    if (showPermissionBanner)
      PermissionStatusBanner(
        status: permissionStatus,
        onDismiss: () => ref.read(guardProvider.notifier).dismissBanner(),
        onAction: () => _handlePermissionAction(),
      ),
    Expanded(child: /* rest of dashboard */),
  ],
)
```

### Alternatives Considered
- `MaterialBanner` via `ScaffoldMessenger`: Rejected - designed for transient messages, not persistent status
- `AppBar` bottom widget: Rejected - part of AppBar, not content area
- Overlay: Rejected - doesn't push content down as specified

---

## Research Topic 6: Real-Time Monitoring During Active Shift

### Question
How to detect permission revocation during an active shift?

### Decision
Poll permission status on a timer when shift is active (every 30 seconds) + check on app resume.

### Rationale
- No platform API for permission change callbacks exists
- 30s interval balances responsiveness vs battery (matches tracking heartbeat interval)
- Existing app lifecycle observer handles foreground resume

### Implementation
```dart
class PermissionMonitorService {
  Timer? _monitorTimer;

  void startMonitoring(void Function(LocationPermissionState) onChanged) {
    _monitorTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      final state = await BackgroundTrackingService.checkPermissions();
      onChanged(state);
    });
  }

  void stopMonitoring() {
    _monitorTimer?.cancel();
    _monitorTimer = null;
  }
}
```

### Alternatives Considered
- Continuous polling (every 5s): Rejected - unnecessary battery drain
- No polling, rely on location errors: Rejected - reactive, not proactive per spec

---

## Research Topic 7: Platform-Specific Settings Navigation

### Question
How to deep-link to app permission settings?

### Decision
Use `Geolocator.openAppSettings()` (app settings) and `Geolocator.openLocationSettings()` (device location services).

### Rationale
- `geolocator` package (already a dependency) provides both APIs
- Works reliably on iOS and Android
- Existing `SettingsGuidanceDialog` already uses this pattern

### Implementation
```dart
// For app-specific permission settings
await Geolocator.openAppSettings();

// For device-level location services
await Geolocator.openLocationSettings();
```

### Alternatives Considered
- Platform channels with native code: Rejected - geolocator already provides this
- `url_launcher` with settings:// URLs: Rejected - fragile, platform-specific URL schemes

---

## Research Topic 8: Battery Optimization Handling (Android)

### Question
How to detect and prompt for battery optimization exemption?

### Decision
Use existing `FlutterForegroundTask` APIs already in `BackgroundTrackingService`.

### Rationale
- Already implemented in `requestBatteryOptimization()` and `isBatteryOptimizationDisabled`
- Part of the foreground task package (already a dependency)
- Works with Android's exact battery optimization system

### Implementation (already exists)
```dart
// Check status
final isIgnoring = await FlutterForegroundTask.isIgnoringBatteryOptimizations;

// Request exemption
await FlutterForegroundTask.requestIgnoreBatteryOptimization();
```

### Enhancement Needed
- Add battery optimization status to `PermissionGuardState`
- Show warning in banner if not exempted (Android only)

---

## Research Topic 9: In-App Notification vs Push Notification

### Question
How to notify user of permission changes when app is backgrounded?

### Decision
Use in-app alert when returning to foreground; local notification not required.

### Rationale
- If user revokes permission while backgrounded, the foreground service notification already provides awareness
- On resume, the permission banner immediately shows the issue
- Push notifications would require server-side infrastructure not in scope
- Local notifications could be annoying for a status change the user initiated

### Implementation
- When app resumes and shift is active, check permission
- If permission downgraded, show in-app alert dialog (not just banner)
- Banner provides persistent reminder; dialog provides immediate attention

### Alternatives Considered
- Local push notification: Rejected - user intentionally changed permission, immediate alert is intrusive
- No notification: Rejected - spec requires communication within 5 seconds (on resume)

---

## Summary of Key Decisions

| Area | Decision | Package/API |
|------|----------|-------------|
| App lifecycle | `WidgetsBindingObserver` | Flutter built-in |
| Device services check | `Geolocator.isLocationServiceEnabled()` | geolocator 12.0.0 |
| Session state | In-memory Riverpod provider | flutter_riverpod 2.5.0 |
| Debouncing | 500ms Timer | dart:async |
| Banner UI | Column with conditional widget | Flutter built-in |
| Real-time monitoring | 30s polling Timer | dart:async |
| Settings navigation | `Geolocator.openAppSettings()` | geolocator 12.0.0 |
| Battery optimization | `FlutterForegroundTask` APIs | flutter_foreground_task 8.0.0 |
| Background notification | In-app alert on resume | Flutter built-in |

---

## No New Dependencies Required

All functionality can be implemented using existing dependencies:
- `geolocator: ^12.0.0` - permission checking, settings navigation
- `flutter_riverpod: ^2.5.0` - state management
- `flutter_foreground_task: ^8.0.0` - battery optimization (Android)
- Flutter SDK - UI components, lifecycle observer
