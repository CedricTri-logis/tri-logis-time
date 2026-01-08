# Contract: BackgroundTrackingService

**Feature**: 004-background-gps-tracking
**Date**: 2026-01-08
**Type**: Internal Service Contract

---

## Overview

`BackgroundTrackingService` manages the lifecycle of background GPS tracking. It coordinates with `flutter_foreground_task` for background execution and `geolocator` for location capture.

---

## Service Interface

### File Location
`lib/features/tracking/services/background_tracking_service.dart`

### Dependencies
- `flutter_foreground_task: ^8.0.0`
- `geolocator: ^12.0.0`
- `LocalDatabase` (existing)
- `LocationService` (existing)

---

## Methods

### initialize()

**Purpose**: Initialize the foreground task service. Must be called once during app startup.

**Signature**:
```dart
static Future<void> initialize() async
```

**Preconditions**:
- Called before any other service methods
- Called after `FlutterForegroundTask.initCommunicationPort()`

**Postconditions**:
- Foreground task options configured
- Notification channel created (Android)
- Ready to start/stop tracking

**Error Handling**:
- Logs initialization errors but does not throw (app should still function)

---

### startTracking()

**Purpose**: Begin background GPS tracking for an active shift.

**Signature**:
```dart
Future<TrackingResult> startTracking({
  required String shiftId,
  required String employeeId,
  TrackingConfig config = const TrackingConfig(),
}) async
```

**Parameters**:
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `shiftId` | `String` | Yes | UUID of the active shift |
| `employeeId` | `String` | Yes | UUID of the employee |
| `config` | `TrackingConfig` | No | Tracking configuration (default: 5-min interval) |

**Preconditions**:
- Service initialized via `initialize()`
- Location permission granted (at least "while in use")
- No other tracking session active

**Postconditions**:
- Foreground service started
- Notification displayed (Android)
- GPS position stream active
- Shift ID persisted for boot recovery

**Returns**:
```dart
sealed class TrackingResult {
  factory TrackingResult.success() = TrackingSuccess;
  factory TrackingResult.permissionDenied() = TrackingPermissionDenied;
  factory TrackingResult.serviceError(String message) = TrackingServiceError;
  factory TrackingResult.alreadyTracking() = TrackingAlreadyActive;
}
```

**Error Handling**:
| Error Condition | Result |
|-----------------|--------|
| Permission denied | `TrackingResult.permissionDenied()` |
| Service already running | `TrackingResult.alreadyTracking()` |
| Platform exception | `TrackingResult.serviceError(message)` |

---

### stopTracking()

**Purpose**: Stop background GPS tracking.

**Signature**:
```dart
Future<void> stopTracking() async
```

**Preconditions**:
- None (safe to call even if not tracking)

**Postconditions**:
- Foreground service stopped
- Notification removed
- GPS stream cancelled
- Persisted shift ID cleared

---

### isTracking

**Purpose**: Check if background tracking is currently active.

**Signature**:
```dart
Future<bool> get isTracking async
```

**Returns**: `true` if foreground service is running, `false` otherwise.

---

### requestPermissions()

**Purpose**: Request all required permissions for background tracking.

**Signature**:
```dart
Future<LocationPermissionState> requestPermissions() async
```

**Flow**:
1. Request notification permission (Android 13+)
2. Request location permission ("while in use")
3. If granted, request "always" permission
4. Request battery optimization exemption

**Returns**: Updated `LocationPermissionState` reflecting current permissions.

---

### checkPermissions()

**Purpose**: Check current permission status without requesting.

**Signature**:
```dart
Future<LocationPermissionState> checkPermissions() async
```

**Returns**: Current `LocationPermissionState`.

---

## Callback Handler

### GPSTrackingHandler

**Purpose**: Task handler running in background isolate.

**Lifecycle Methods**:

| Method | When Called | Action |
|--------|-------------|--------|
| `onStart` | Service starts | Initialize position stream |
| `onRepeatEvent` | Every 30 seconds | Health check, ensure stream active |
| `onDestroy` | Service stops | Cancel streams, cleanup |
| `onReceiveData` | Data from main | Handle config updates |
| `onNotificationButtonPressed` | Notification action | Handle "Stop" button |
| `onNotificationPressed` | Notification tap | Bring app to foreground |

### Position Capture Flow

```dart
@override
Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
  // 1. Load persisted shift context
  final shiftId = await FlutterForegroundTask.getData<String>(key: 'shift_id');
  if (shiftId == null && starter == TaskStarter.system) {
    // Boot recovery without active shift - stop
    await FlutterForegroundTask.stopService();
    return;
  }

  // 2. Configure platform-specific location settings
  final locationSettings = _createLocationSettings();

  // 3. Start position stream
  _positionSubscription = Geolocator.getPositionStream(
    locationSettings: locationSettings,
  ).listen(_onPosition, onError: _onPositionError);
}

void _onPosition(Position position) {
  // 1. Create LocalGpsPoint
  final point = LocalGpsPoint(
    id: Uuid().v4(),
    shiftId: _shiftId!,
    employeeId: _employeeId!,
    latitude: position.latitude,
    longitude: position.longitude,
    accuracy: position.accuracy,
    capturedAt: position.timestamp ?? DateTime.now(),
    syncStatus: 'pending',
    createdAt: DateTime.now(),
  );

  // 2. Store locally (via message passing to main isolate)
  FlutterForegroundTask.sendDataToMain({
    'type': 'position',
    'point': point.toMap(),
  });

  // 3. Update notification
  FlutterForegroundTask.updateService(
    notificationText: 'Last update: ${_formatTime(point.capturedAt)}',
  );
}
```

---

## Communication Protocol

### Main Isolate -> Task Handler

| Command | Payload | Action |
|---------|---------|--------|
| `updateConfig` | `TrackingConfig.toJson()` | Update polling settings |
| `getStatus` | None | Request current status |

### Task Handler -> Main Isolate

| Type | Payload | Handling |
|------|---------|----------|
| `position` | `LocalGpsPoint.toMap()` | Store in database, update UI |
| `error` | `{message: String}` | Update tracking state with error |
| `heartbeat` | `{timestamp: int, lastPosition: Map?}` | Health monitoring |
| `status` | `{isTracking: bool, pointCount: int}` | Response to getStatus |

---

## Platform Configuration

### Android Notification

```dart
AndroidNotificationOptions(
  channelId: 'gps_tracking_channel',
  channelName: 'GPS Tracking',
  channelDescription: 'Background location tracking during shifts',
  channelImportance: NotificationChannelImportance.LOW,
  priority: NotificationPriority.LOW,
  onlyAlertOnce: true,
  isSticky: true,
  iconData: NotificationIconData(
    resType: ResourceType.mipmap,
    resPrefix: ResourcePrefix.ic,
    name: 'launcher',
  ),
)
```

### iOS Settings

```dart
IOSNotificationOptions(
  showNotification: false,  // Use system location indicator
  playSound: false,
)
```

### Foreground Task Options

```dart
ForegroundTaskOptions(
  eventAction: ForegroundTaskEventAction.repeat(30000), // 30s heartbeat
  autoRunOnBoot: true,
  autoRunOnMyPackageReplaced: true,
  allowWakeLock: true,
  allowWifiLock: true,
)
```

---

## Error Scenarios

| Scenario | Detection | Recovery |
|----------|-----------|----------|
| GPS unavailable | `Geolocator.isLocationServiceEnabled()` returns false | Pause tracking, notify user |
| Permission revoked | Position stream error | Stop tracking, prompt for permissions |
| Service killed by OS | `onDestroy` with timeout | Auto-restart on boot (Android) |
| App force-closed (iOS) | N/A (cannot detect) | Resume on next app open |
| Low battery | N/A (not monitored) | Continue tracking unless user stops |

---

## Testing Requirements

| Test Case | Type | Verification |
|-----------|------|--------------|
| Service starts on clock-in | Integration | Service running after `startTracking()` |
| Service stops on clock-out | Integration | Service not running after `stopTracking()` |
| Points captured at interval | Integration | Points in database match interval |
| Service resumes after boot | Manual | Tracking active after device restart |
| Notification visible | Manual | Android notification present |
| Permission flow complete | Unit | All permission states handled |
