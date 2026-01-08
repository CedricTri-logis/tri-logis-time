# Contract: TrackingProvider

**Feature**: 004-background-gps-tracking
**Date**: 2026-01-08
**Type**: State Management Contract (Riverpod)

---

## Overview

`TrackingProvider` manages UI state for background GPS tracking. It coordinates with `BackgroundTrackingService` and `ShiftProvider` to maintain consistent tracking state.

---

## Provider Definition

### File Location
`lib/features/tracking/providers/tracking_provider.dart`

### Provider Type
```dart
final trackingProvider = StateNotifierProvider<TrackingNotifier, TrackingState>((ref) {
  return TrackingNotifier(ref);
});
```

---

## TrackingNotifier

### Constructor

```dart
class TrackingNotifier extends StateNotifier<TrackingState> {
  final Ref _ref;
  StreamSubscription<dynamic>? _taskDataSubscription;

  TrackingNotifier(this._ref) : super(const TrackingState()) {
    _initializeListeners();
  }
}
```

### Initialization

```dart
void _initializeListeners() {
  // Listen for data from background task
  FlutterForegroundTask.receivePort?.listen(_handleTaskData);

  // Listen for shift state changes
  _ref.listen<ShiftState>(shiftProvider, (previous, next) {
    _handleShiftStateChange(previous, next);
  });
}
```

---

## Public Methods

### startTracking()

**Purpose**: Begin background tracking for the active shift.

**Signature**:
```dart
Future<void> startTracking() async
```

**Preconditions**:
- Active shift exists (`shiftProvider.state.activeShift != null`)
- Not already tracking (`state.status != TrackingStatus.running`)

**State Transitions**:
```
stopped -> starting -> running
```

**Implementation**:
```dart
Future<void> startTracking() async {
  final shift = _ref.read(shiftProvider).activeShift;
  if (shift == null) return;

  state = state.startTracking(shift.id);

  final result = await BackgroundTrackingService.startTracking(
    shiftId: shift.id,
    employeeId: shift.employeeId,
    config: state.config,
  );

  switch (result) {
    case TrackingSuccess():
      state = state.copyWith(status: TrackingStatus.running);
    case TrackingPermissionDenied():
      state = state.withError('Location permission required');
    case TrackingServiceError(:final message):
      state = state.withError(message);
    case TrackingAlreadyActive():
      state = state.copyWith(status: TrackingStatus.running);
  }
}
```

---

### stopTracking()

**Purpose**: Stop background tracking.

**Signature**:
```dart
Future<void> stopTracking() async
```

**Postconditions**:
- Background service stopped
- State reset to initial

**State Transitions**:
```
any -> stopped
```

---

### updateConfig()

**Purpose**: Update tracking configuration.

**Signature**:
```dart
void updateConfig(TrackingConfig config)
```

**Effect**:
- Updates `state.config`
- Sends config to background task if running

---

### refreshState()

**Purpose**: Sync state with actual service status.

**Signature**:
```dart
Future<void> refreshState() async
```

**Use Case**: Called on app resume to ensure UI matches background service state.

---

## Private Methods

### _handleTaskData()

**Purpose**: Process messages from background task.

```dart
void _handleTaskData(dynamic data) {
  if (data is! Map<String, dynamic>) return;

  switch (data['type']) {
    case 'position':
      _handlePositionUpdate(data['point']);
    case 'error':
      _handleTrackingError(data['message']);
    case 'heartbeat':
      _handleHeartbeat(data);
  }
}
```

### _handlePositionUpdate()

**Purpose**: Store GPS point and update state.

```dart
Future<void> _handlePositionUpdate(Map<String, dynamic> pointData) async {
  final point = LocalGpsPoint.fromMap(pointData);

  // Store in local database
  await _ref.read(localDatabaseProvider).insertGpsPoint(point);

  // Update state
  state = state.recordPoint(
    latitude: point.latitude,
    longitude: point.longitude,
    accuracy: point.accuracy,
    capturedAt: point.capturedAt,
  );

  // Trigger sync if connected
  _ref.read(syncProvider.notifier).syncPendingData();
}
```

### _handleShiftStateChange()

**Purpose**: Auto-start/stop tracking based on shift state.

```dart
void _handleShiftStateChange(ShiftState? previous, ShiftState next) {
  // Auto-start on clock in
  if (previous?.activeShift == null && next.activeShift != null) {
    startTracking();
  }

  // Auto-stop on clock out
  if (previous?.activeShift != null && next.activeShift == null) {
    stopTracking();
  }
}
```

---

## Derived Providers

### isTrackingProvider

```dart
final isTrackingProvider = Provider<bool>((ref) {
  return ref.watch(trackingProvider.select((s) => s.isTracking));
});
```

### trackingStatusProvider

```dart
final trackingStatusProvider = Provider<TrackingStatus>((ref) {
  return ref.watch(trackingProvider.select((s) => s.status));
});
```

### lastPositionProvider

```dart
final lastPositionProvider = Provider<({double? lat, double? lng, DateTime? time})>((ref) {
  final state = ref.watch(trackingProvider);
  return (
    lat: state.lastLatitude,
    lng: state.lastLongitude,
    time: state.lastCaptureTime,
  );
});
```

### pointsCapturedProvider

```dart
final pointsCapturedProvider = Provider<int>((ref) {
  return ref.watch(trackingProvider.select((s) => s.pointsCaptured));
});
```

---

## State Flow Diagram

```
                    +------------+
                    |  stopped   |
                    +-----+------+
                          |
                    clock in
                          |
                    +-----v------+
                    |  starting  |
                    +-----+------+
                          |
                    first point
                          |
                    +-----v------+
            +------>|  running   |<------+
            |       +-----+------+       |
            |             |              |
       GPS restored   GPS error    clock out
            |             |              |
            |       +-----v------+       |
            +-------|  paused    |       |
                    +------------+       |
                                         |
                    +------------+       |
                    |  stopped   |<------+
                    +------------+
```

---

## Error Handling

| Error | State Update | User Action |
|-------|--------------|-------------|
| Permission denied | `withError('Location permission required')` | Show permission dialog |
| Service start failed | `withError(message)` | Show error snackbar |
| GPS unavailable | `status: paused` | Show "GPS unavailable" indicator |
| Task communication lost | Detected via heartbeat timeout | Auto-refresh state |

---

## Lifecycle Considerations

### App Lifecycle

| Event | Action |
|-------|--------|
| App resumed | `refreshState()` to sync with service |
| App paused | No action (service continues) |
| App terminated | Service continues (Android) / stops (iOS) |

### Integration with ShiftProvider

```dart
// In ShiftNotifier.clockIn():
Future<void> clockIn() async {
  // ... existing clock in logic ...

  // Tracking auto-starts via listener in TrackingNotifier
}

// In ShiftNotifier.clockOut():
Future<void> clockOut() async {
  // ... existing clock out logic ...

  // Tracking auto-stops via listener in TrackingNotifier
}
```

---

## Testing Requirements

| Test Case | Type | Verification |
|-----------|------|--------------|
| Start tracking updates state | Unit | State transitions correctly |
| Stop tracking resets state | Unit | State is `TrackingState.initial` |
| Position updates recorded | Unit | `pointsCaptured` increments |
| Auto-start on clock in | Integration | Tracking starts when shift becomes active |
| Auto-stop on clock out | Integration | Tracking stops when shift ends |
| Error state on permission denied | Unit | State has error message |
