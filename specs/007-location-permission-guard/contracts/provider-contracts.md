# Provider Contracts: Location Permission Guard

**Feature**: 007-location-permission-guard
**Date**: 2026-01-10

## Overview

This document defines the contracts for Riverpod providers and services that power the Location Permission Guard feature. Since this is a client-side only feature, there are no REST/GraphQL API contracts.

---

## Provider: permissionGuardProvider

**Location**: `lib/features/tracking/providers/permission_guard_provider.dart`

### Contract

```dart
/// Main provider for permission guard state management.
final permissionGuardProvider =
    StateNotifierProvider<PermissionGuardNotifier, PermissionGuardState>(
  (ref) => PermissionGuardNotifier(ref),
);
```

### State: PermissionGuardState

| Field | Type | Description |
|-------|------|-------------|
| permission | `LocationPermissionState` | Current app-level permission |
| deviceStatus | `DeviceLocationStatus` | Device GPS services status |
| isBatteryOptimizationDisabled | `bool` | Battery optimization status (Android) |
| dismissedWarnings | `Set<DismissibleWarningType>` | Session-dismissed warnings |
| hasActiveShift | `bool` | Whether shift is active |
| lastChecked | `DateTime` | Last status check timestamp |

### Methods

#### `checkStatus()`

Performs a full permission and device status check.

```dart
Future<void> checkStatus()
```

- **Side Effects**: Updates state with current permission, device status, battery optimization
- **Timing**: Should complete within 2 seconds (per FR-001)
- **Called**: On app launch, on app resume, on explicit refresh

#### `dismissWarning(DismissibleWarningType type)`

Marks a warning as dismissed for the current session.

```dart
void dismissWarning(DismissibleWarningType type)
```

- **Input**: `type` - must be `partialPermission` or `batteryOptimization`
- **Effect**: Warning will not show in banner until app restart
- **Note**: Critical warnings (permissionRequired, permanentlyDenied, deviceServicesDisabled) cannot be dismissed

#### `setActiveShift(bool isActive)`

Updates the active shift status, triggering monitoring start/stop.

```dart
void setActiveShift(bool isActive)
```

- **Input**: `isActive` - true when shift starts, false when shift ends
- **Effect**: Starts/stops real-time permission monitoring

#### `requestPermission()`

Triggers the system permission request flow.

```dart
Future<void> requestPermission()
```

- **Effect**: Shows system permission dialog
- **Post**: State updates with new permission level

#### `openAppSettings()`

Opens device settings for the app.

```dart
Future<void> openAppSettings()
```

- **Effect**: Navigates to app settings (for permanently denied recovery)

#### `openDeviceLocationSettings()`

Opens device-level location settings.

```dart
Future<void> openDeviceLocationSettings()
```

- **Effect**: Navigates to device location services settings

#### `requestBatteryOptimization()`

Requests battery optimization exemption (Android only).

```dart
Future<void> requestBatteryOptimization()
```

- **Platform**: Android only (no-op on iOS)
- **Effect**: Shows Android battery optimization dialog

---

## Derived Providers

### `permissionGuardStatusProvider`

```dart
/// Current overall permission guard status.
final permissionGuardStatusProvider = Provider<PermissionGuardStatus>((ref) {
  return ref.watch(permissionGuardProvider).status;
});
```

### `shouldShowPermissionBannerProvider`

```dart
/// Whether the permission banner should be displayed.
final shouldShowPermissionBannerProvider = Provider<bool>((ref) {
  return ref.watch(permissionGuardProvider).shouldShowBanner;
});
```

### `shouldBlockClockInProvider`

```dart
/// Whether clock-in should be blocked due to permission issues.
final shouldBlockClockInProvider = Provider<bool>((ref) {
  return ref.watch(permissionGuardProvider).shouldBlockClockIn;
});
```

### `shouldWarnOnClockInProvider`

```dart
/// Whether clock-in should show a warning (but allow proceeding).
final shouldWarnOnClockInProvider = Provider<bool>((ref) {
  return ref.watch(permissionGuardProvider).shouldWarnOnClockIn;
});
```

---

## Service: PermissionMonitorService

**Location**: `lib/features/tracking/services/permission_monitor_service.dart`

### Contract

```dart
/// Service for real-time permission monitoring during active shifts.
class PermissionMonitorService {
  /// Start monitoring for permission changes.
  ///
  /// [onChanged] is called when permission state changes.
  /// Polls every [intervalSeconds] (default: 30).
  void startMonitoring({
    required void Function(PermissionChangeEvent) onChanged,
    int intervalSeconds = 30,
  });

  /// Stop monitoring.
  void stopMonitoring();

  /// Whether monitoring is currently active.
  bool get isMonitoring;
}
```

### Callback: PermissionChangeEvent

When a permission change is detected:

```dart
void onChanged(PermissionChangeEvent event) {
  // event.previousState - state before change
  // event.newState - state after change
  // event.isDowngrade - true if permission was revoked/reduced
  // event.isUpgrade - true if permission was granted/increased
  // event.affectsTracking - true if tracking capability changed
}
```

### Provider

```dart
/// Provider for permission monitor service.
final permissionMonitorProvider = Provider<PermissionMonitorService>((ref) {
  final service = PermissionMonitorService();
  ref.onDispose(() => service.stopMonitoring());
  return service;
});
```

---

## Integration Points

### With ShiftProvider

The permission guard must be notified when shift state changes:

```dart
// In shift_provider.dart or via listener
ref.listen(shiftProvider, (previous, next) {
  final hadActiveShift = previous?.activeShift != null;
  final hasActiveShift = next.activeShift != null;

  if (hadActiveShift != hasActiveShift) {
    ref.read(permissionGuardProvider.notifier).setActiveShift(hasActiveShift);
  }
});
```

### With App Lifecycle

The permission guard must re-check on app resume:

```dart
// In widget with WidgetsBindingObserver
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) {
    ref.read(permissionGuardProvider.notifier).checkStatus();
  }
}
```

### With Clock-In Flow

The shift dashboard should check guard state before clock-in:

```dart
Future<void> _handleClockIn() async {
  final guardState = ref.read(permissionGuardProvider);

  if (guardState.shouldBlockClockIn) {
    // Show blocking dialog and return
    await _showPermissionRequiredDialog();
    return;
  }

  if (guardState.shouldWarnOnClockIn) {
    // Show warning but allow proceeding
    final proceed = await _showPermissionWarningDialog();
    if (!proceed) return;
  }

  // Continue with clock-in...
}
```

---

## Error Handling

### Permission Check Failures

If `Geolocator.checkPermission()` throws:

```dart
try {
  final permission = await Geolocator.checkPermission();
  // ...
} catch (e) {
  // Set to unknown/error state
  state = state.copyWith(
    deviceStatus: DeviceLocationStatus.unknown,
  );
}
```

### Device Service Check Failures

If `Geolocator.isLocationServiceEnabled()` throws:

```dart
try {
  final enabled = await Geolocator.isLocationServiceEnabled();
  // ...
} catch (e) {
  // Default to enabled to avoid blocking user
  state = state.copyWith(
    deviceStatus: DeviceLocationStatus.enabled,
  );
}
```

---

## Performance Requirements

| Operation | Max Duration | Measured From |
|-----------|--------------|---------------|
| `checkStatus()` | 2 seconds | Method call to state update |
| Banner display | 3 seconds | App launch to visible banner |
| Permission change detection | 5 seconds | Settings change to UI update |
| Tracking resume after restore | 10 seconds | Permission granted to tracking active |

---

## Thread Safety

- All provider state updates must happen on the main isolate
- `PermissionMonitorService` timer callback must dispatch to main isolate
- Platform calls (`Geolocator.*`) are async and safe to call from main isolate
