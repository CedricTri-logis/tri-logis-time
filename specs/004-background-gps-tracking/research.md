# Research: Background GPS Tracking

**Feature**: 004-background-gps-tracking
**Date**: 2026-01-08
**Status**: Complete

## Overview

This document consolidates research findings for implementing background GPS tracking in the GPS Tracker Flutter application. All technical unknowns have been resolved.

---

## Decision 1: Background Service Architecture

### Decision
Use `flutter_foreground_task 8.0.0` as the primary background service manager combined with `geolocator 12.0.0` for location capture.

### Rationale
- `flutter_foreground_task` is already in the project's pubspec.yaml
- Provides unified API for both iOS and Android background execution
- Handles Android foreground service requirements (Android 14+ compliance)
- Supports auto-restart on device boot via `autoRunOnBoot: true`
- Provides bidirectional communication between foreground task and main isolate
- Battle-tested with location services specifically

### Alternatives Considered
| Alternative | Rejected Because |
|-------------|------------------|
| `geolocator` built-in foreground service | Less control over notification, no boot restart support |
| `background_locator_2` | Abandoned package, no recent updates |
| `flutter_background_geolocation` | Commercial license required for production |
| Native platform channels | Increases maintenance burden, violates Constitution Principle I |

---

## Decision 2: iOS Background Strategy

### Decision
Use geolocator's `AppleSettings` with `allowBackgroundLocationUpdates: true` combined with flutter_foreground_task for task management. Accept iOS limitations.

### Rationale
iOS has fundamental limitations that cannot be bypassed:
1. Force-closing the app immediately terminates all background tasks
2. Background execution limited to ~30 seconds every ~15 minutes via BGTaskScheduler
3. Cannot auto-start on device boot
4. Apple requires "Always" location permission for true background tracking

The geolocator package with `allowBackgroundLocationUpdates: true` uses iOS's native location background mode which is more reliable than timer-based approaches.

### Configuration
```dart
AppleSettings(
  accuracy: LocationAccuracy.high,
  distanceFilter: 10,
  activityType: ActivityType.otherNavigation,
  pauseLocationUpdatesAutomatically: false,
  showBackgroundLocationIndicator: true,  // Blue bar shows tracking active
  allowBackgroundLocationUpdates: true,
)
```

### User Communication
Users must be informed that:
- iOS will show a blue bar when tracking is active
- Force-closing the app stops tracking (unlike Android)
- Location permission must be set to "Always" for full functionality

---

## Decision 3: Android Foreground Service Configuration

### Decision
Use `foregroundServiceType="location"` with LOW importance notification channel.

### Rationale
- Android 14+ requires explicit foreground service type declaration
- `location` type is specifically permitted and appropriate for GPS tracking
- LOW importance prevents notification sounds/vibrations while remaining visible
- Persistent notification is required by Constitution Principle II and FR-012

### Configuration
```xml
<!-- AndroidManifest.xml -->
<service
    android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
    android:foregroundServiceType="location"
    android:stopWithTask="false"
    android:exported="false" />
```

```dart
AndroidNotificationOptions(
  channelId: 'gps_tracking_channel',
  channelName: 'GPS Tracking',
  channelDescription: 'Tracks your location during active shifts',
  channelImportance: NotificationChannelImportance.LOW,
  priority: NotificationPriority.LOW,
  onlyAlertOnce: true,
  isSticky: true,
)
```

---

## Decision 4: GPS Polling Strategy

### Decision
Use event-driven position stream with adaptive polling based on movement state.

### Rationale
Pure interval-based polling wastes battery when stationary. The geolocator position stream with distance filter provides natural movement-based updates. We supplement with interval checks for health monitoring.

### Strategy
| State | Detection | Polling Interval | Accuracy |
|-------|-----------|------------------|----------|
| Moving (driving) | speed > 5 m/s | 5 seconds | Best |
| Moving (walking) | speed 1-5 m/s | 30 seconds | High |
| Stationary | < 10m movement for 30s | 2 minutes | Medium |

### Implementation Pattern
```dart
// Primary: Distance-filtered stream
_positionSubscription = Geolocator.getPositionStream(
  locationSettings: LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 10, // Only update when moved 10m
  ),
).listen(_handlePosition);

// Secondary: Periodic health check (30 seconds)
_healthTimer = Timer.periodic(Duration(seconds: 30), (_) {
  _capturePositionIfNeeded();
});
```

---

## Decision 5: Battery Optimization Handling

### Decision
Request battery optimization exemption at shift start, with user guidance for OEM-specific settings.

### Rationale
- Android aggressively kills background apps without exemption
- Constitution Principle II requires informing users of battery expectations
- OEM-specific optimizations (Xiaomi MIUI, Samsung One UI, etc.) require manual user intervention

### Implementation
```dart
// Check and request system exemption
if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
  await FlutterForegroundTask.requestIgnoreBatteryOptimization();
}

// For problematic OEMs, use disable_battery_optimization package
await DisableBatteryOptimization.showDisableManufacturerBatteryOptimizationSettings(
  "GPS Tracking",
  "Please follow the steps to ensure location tracking works reliably during your shifts."
);
```

---

## Decision 6: Device Restart Handling

### Decision
Enable `autoRunOnBoot: true` with shift state persistence in SharedPreferences.

### Rationale
- FR-014 requires automatic resume after device restart
- Constitution requires tracking only during active shifts
- Must verify shift is still valid before resuming tracking

### Implementation Pattern
```dart
ForegroundTaskOptions(
  autoRunOnBoot: true,
  autoRunOnMyPackageReplaced: true,
  // ...
)

// In TaskHandler.onStart:
@override
Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
  if (starter == TaskStarter.system) {
    // Started after boot - verify active shift exists
    final shiftId = await FlutterForegroundTask.getData(key: 'active_shift_id');
    if (shiftId == null) {
      // No active shift - stop service
      await FlutterForegroundTask.stopService();
      return;
    }
    // Resume tracking for active shift
  }
  // Normal startup flow
}
```

---

## Decision 7: Location Permission Flow

### Decision
Request permissions progressively: "While Using" first, then prompt for "Always" with explanation.

### Rationale
- Users more likely to grant "While Using" initially
- FR-011 requires clear explanations of why background access is needed
- Platform stores require progressive permission requests (not immediate "Always")

### Flow
1. Check current permission status
2. If denied, request "While Using" permission
3. If "While Using" granted, explain need for "Always" permission
4. Request "Always" permission with clear justification
5. If "Always" denied, show guidance for enabling in settings
6. Display degraded functionality warning if only "While Using"

### User-Facing Explanations
```dart
const locationPermissionExplanation = '''
GPS tracking helps verify your work location during shifts.

To track your location while you work (including when your phone is locked):
- iOS: Select "Always" when prompted
- Android: Select "Allow all the time"

Your location is only tracked during active shifts and stops automatically when you clock out.
''';
```

---

## Decision 8: Offline Storage Strategy

### Decision
Use existing `local_gps_points` SQLCipher table with 48-hour retention.

### Rationale
- FR-016 requires 48 hours of local storage capacity
- Existing infrastructure already supports GPS point storage
- SQLCipher provides encryption at rest (Constitution Principle IV)
- Existing SyncService handles batch sync when connectivity returns

### Storage Calculation
- 5-minute intervals = 12 points/hour
- 48 hours = 576 points maximum
- Each point ≈ 200 bytes = ~115 KB for 48 hours
- Well within device storage constraints

### Retention Policy
```dart
// Clean up old synced points (keep 48 hours of pending)
await _db.deleteOldSyncedGpsPoints(
  olderThan: DateTime.now().subtract(Duration(hours: 48)),
);
```

---

## Decision 9: Map Visualization Library

### Decision
Use `flutter_map` with OpenStreetMap tiles for route visualization.

### Rationale
- Free and open source (no API key required)
- Lightweight compared to Google Maps
- Sufficient for displaying tracked routes
- Follows Constitution Principle V (simplicity, minimal dependencies)

### Alternatives Considered
| Alternative | Rejected Because |
|-------------|------------------|
| Google Maps | Requires API key, billing account, adds complexity |
| Mapbox | Requires API key, commercial licensing |
| Apple Maps | iOS only, platform-specific code required |

### Implementation
```dart
dependencies:
  flutter_map: ^6.0.0
  latlong2: ^0.9.0
```

---

## Decision 10: Low-Accuracy Point Handling

### Decision
Store all GPS points with accuracy metadata; flag low-accuracy points (>100m) visually but include in route.

### Rationale
- FR-015 requires graceful handling of GPS signal loss
- Some data is better than no data for work verification
- Users should understand data quality limitations
- SC-003 targets 95% of points with <50m accuracy (allows 5% low-accuracy)

### Implementation
```dart
class LocalGpsPoint {
  // ... existing fields
  final double accuracy;  // Already exists

  bool get isLowAccuracy => accuracy > 100;
  bool get isHighAccuracy => accuracy <= 50;
}

// In route visualization:
PointMarker(
  color: point.isLowAccuracy ? Colors.orange : Colors.green,
  // ...
)
```

---

## Decision 11: Tracking Session Model

### Decision
Tracking session is implicit from shift; no separate TrackingSession entity needed.

### Rationale
- Spec defines TrackingSession as tied 1:1 with shift
- Shift already has `clockedInAt` and `clockedOutAt` timestamps
- GPS points are already associated with `shiftId`
- Adding separate entity would violate Constitution Principle V (YAGNI)

### Implementation
Track session state in provider, not database:
```dart
class TrackingState {
  final bool isTracking;
  final String? activeShiftId;
  final int pointsCaptured;
  final DateTime? lastCaptureTime;
  final TrackingStatus status; // running, paused, stopped, error
}
```

---

## Decision 12: Communication Between Isolates

### Decision
Use flutter_foreground_task's built-in data passing via `sendDataToMain` and `sendDataToTask`.

### Rationale
- Background task runs in separate isolate
- Cannot directly access Riverpod providers or Flutter widgets
- flutter_foreground_task provides type-safe communication channel
- Data must be serializable (primitives, Map, List)

### Pattern
```dart
// Task -> Main (position updates)
FlutterForegroundTask.sendDataToMain({
  'type': 'position',
  'latitude': position.latitude,
  'longitude': position.longitude,
  'accuracy': position.accuracy,
  'timestamp': position.timestamp.millisecondsSinceEpoch,
});

// Main -> Task (configuration changes)
FlutterForegroundTask.sendDataToTask({
  'command': 'updateInterval',
  'intervalMs': 60000,
});
```

---

## Technical Constraints Identified

### Android-Specific
1. Android 14+ requires `android:foregroundServiceType="location"` in manifest
2. Android 13+ requires runtime POST_NOTIFICATIONS permission
3. Android 15+ limits DataSync service to 6 hours per 24 hours (location type not affected)
4. OEM battery optimizations may still kill app despite exemption request

### iOS-Specific
1. Force-closing app terminates all background execution immediately
2. No auto-start on device boot
3. BGTaskScheduler timing is unpredictable (iOS controls scheduling)
4. "Always" location permission requires explanation in Info.plist

### Cross-Platform
1. Background task handler must be top-level function with `@pragma('vm:entry-point')`
2. Position stream may pause when app force-closed on iOS
3. Network connectivity may not be available during background execution
4. Local storage must be used for all captures, sync when possible

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| OEM kills background service | Guide users to whitelist app in battery settings |
| iOS force-close stops tracking | Inform users; resume on app reopen |
| GPS signal unavailable | Store last known position with low-accuracy flag |
| Device storage full | Prune oldest synced points first; warn at 75% capacity |
| Boot restart fails to resume | Health check on app open; manual resume prompt |

---

## Next Steps

1. **Phase 1 - Data Model**: Define TrackingConfig, TrackingState models
2. **Phase 1 - Contracts**: Document internal service contracts
3. **Phase 1 - Quickstart**: Setup instructions for development
4. **Phase 2 - Tasks**: Implementation task breakdown
