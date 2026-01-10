# Data Model: Location Permission Guard

**Feature**: 007-location-permission-guard
**Date**: 2026-01-10

## Overview

This document defines the data models and state structures for the Location Permission Guard feature. All models are client-side only (no database changes required).

---

## Entity: LocationPermissionLevel (Existing - No Changes)

**Location**: `lib/features/tracking/models/location_permission_state.dart`

Represents the app-specific location permission level.

```dart
enum LocationPermissionLevel {
  notDetermined,  // Permission has not been requested
  denied,         // User denied permission (can request again)
  deniedForever,  // User permanently denied (requires settings)
  whileInUse,     // Permission granted while app is in use
  always,         // Permission granted always (background capable)
}
```

---

## Entity: LocationPermissionState (Existing - No Changes)

**Location**: `lib/features/tracking/models/location_permission_state.dart`

Tracks the current location permission status from the geolocator package.

```dart
@immutable
class LocationPermissionState {
  final LocationPermissionLevel level;
  final DateTime lastChecked;

  // Computed properties (existing)
  bool get canTrackInBackground;
  bool get hasAnyPermission;
  bool get canRequestPermission;
}
```

---

## Entity: DeviceLocationStatus (New)

**Location**: `lib/features/tracking/models/device_location_status.dart`

Represents the device-level location services status (separate from app permission).

```dart
/// Status of device-level location services.
enum DeviceLocationStatus {
  /// Location services are enabled at device level.
  enabled,

  /// Location services are disabled at device level.
  disabled,

  /// Status could not be determined (error state).
  unknown,
}
```

---

## Entity: PermissionGuardStatus (New)

**Location**: `lib/features/tracking/models/permission_guard_status.dart`

High-level status categories for the permission guard UI.

```dart
/// Overall status for the permission guard UI.
enum PermissionGuardStatus {
  /// All permissions granted, no action needed.
  allGranted,

  /// Partial permissions (while-in-use only) - warning but functional.
  partialPermission,

  /// No app permission granted - action required.
  permissionRequired,

  /// Permission permanently denied - requires settings navigation.
  permanentlyDenied,

  /// Device location services disabled - requires device settings.
  deviceServicesDisabled,

  /// Battery optimization enabled (Android) - optional action.
  batteryOptimizationRequired,
}
```

---

## Entity: PermissionGuardState (New)

**Location**: `lib/features/tracking/models/permission_guard_state.dart`

Comprehensive state for the permission guard feature, combining multiple status signals.

```dart
@immutable
class PermissionGuardState {
  /// The app-level location permission state.
  final LocationPermissionState permission;

  /// Device-level location services status.
  final DeviceLocationStatus deviceStatus;

  /// Whether battery optimization is disabled (Android only, always true on iOS).
  final bool isBatteryOptimizationDisabled;

  /// Set of warning types the user has dismissed this session.
  final Set<DismissibleWarningType> dismissedWarnings;

  /// Whether an active shift is in progress (affects monitoring behavior).
  final bool hasActiveShift;

  /// Timestamp of last full status check.
  final DateTime lastChecked;

  // Constructor
  const PermissionGuardState({
    required this.permission,
    required this.deviceStatus,
    required this.isBatteryOptimizationDisabled,
    required this.dismissedWarnings,
    required this.hasActiveShift,
    required this.lastChecked,
  });

  // Factory: Initial state
  factory PermissionGuardState.initial() => PermissionGuardState(
    permission: LocationPermissionState.initial(),
    deviceStatus: DeviceLocationStatus.unknown,
    isBatteryOptimizationDisabled: true,
    dismissedWarnings: const {},
    hasActiveShift: false,
    lastChecked: DateTime.now(),
  );

  // Computed: Overall status for UI display
  PermissionGuardStatus get status {
    // Priority order: device services > no permission > permanent denial > partial > battery > all good
    if (deviceStatus == DeviceLocationStatus.disabled) {
      return PermissionGuardStatus.deviceServicesDisabled;
    }
    if (permission.level == LocationPermissionLevel.deniedForever) {
      return PermissionGuardStatus.permanentlyDenied;
    }
    if (!permission.hasAnyPermission) {
      return PermissionGuardStatus.permissionRequired;
    }
    if (permission.level == LocationPermissionLevel.whileInUse) {
      return PermissionGuardStatus.partialPermission;
    }
    if (!isBatteryOptimizationDisabled) {
      return PermissionGuardStatus.batteryOptimizationRequired;
    }
    return PermissionGuardStatus.allGranted;
  }

  // Computed: Whether banner should be shown
  bool get shouldShowBanner {
    if (status == PermissionGuardStatus.allGranted) return false;

    // Check if this warning type is dismissed
    final warningType = _statusToWarningType(status);
    if (warningType != null && dismissedWarnings.contains(warningType)) {
      return false;
    }

    return true;
  }

  // Computed: Whether clock-in should be blocked
  bool get shouldBlockClockIn {
    return deviceStatus == DeviceLocationStatus.disabled ||
           !permission.hasAnyPermission;
  }

  // Computed: Whether clock-in should show warning (but allow proceeding)
  bool get shouldWarnOnClockIn {
    return permission.level == LocationPermissionLevel.whileInUse ||
           !isBatteryOptimizationDisabled;
  }

  // Computed: Whether real-time monitoring is needed
  bool get shouldMonitor => hasActiveShift;

  // Copy with
  PermissionGuardState copyWith({
    LocationPermissionState? permission,
    DeviceLocationStatus? deviceStatus,
    bool? isBatteryOptimizationDisabled,
    Set<DismissibleWarningType>? dismissedWarnings,
    bool? hasActiveShift,
    DateTime? lastChecked,
  }) => PermissionGuardState(
    permission: permission ?? this.permission,
    deviceStatus: deviceStatus ?? this.deviceStatus,
    isBatteryOptimizationDisabled: isBatteryOptimizationDisabled ?? this.isBatteryOptimizationDisabled,
    dismissedWarnings: dismissedWarnings ?? this.dismissedWarnings,
    hasActiveShift: hasActiveShift ?? this.hasActiveShift,
    lastChecked: lastChecked ?? this.lastChecked,
  );

  // Helper: Map status to dismissible warning type
  DismissibleWarningType? _statusToWarningType(PermissionGuardStatus status) {
    return switch (status) {
      PermissionGuardStatus.partialPermission => DismissibleWarningType.partialPermission,
      PermissionGuardStatus.batteryOptimizationRequired => DismissibleWarningType.batteryOptimization,
      _ => null, // Critical statuses cannot be dismissed
    };
  }
}
```

---

## Entity: DismissibleWarningType (New)

**Location**: `lib/features/tracking/models/permission_guard_state.dart` (same file)

Types of warnings that can be dismissed within a session.

```dart
/// Warning types that can be dismissed by the user within a session.
enum DismissibleWarningType {
  /// "While in use" permission warning (partial permission).
  partialPermission,

  /// Battery optimization warning (Android only).
  batteryOptimization,
}
```

Note: Critical statuses (permissionRequired, permanentlyDenied, deviceServicesDisabled) cannot be dismissed.

---

## Entity: PermissionChangeEvent (New)

**Location**: `lib/features/tracking/models/permission_change_event.dart`

Represents a detected change in permission status during an active shift.

```dart
@immutable
class PermissionChangeEvent {
  /// The previous permission state.
  final LocationPermissionState previousState;

  /// The new permission state.
  final LocationPermissionState newState;

  /// When the change was detected.
  final DateTime detectedAt;

  /// Whether this is a downgrade (less permission than before).
  bool get isDowngrade {
    return newState.level.index < previousState.level.index;
  }

  /// Whether this is an upgrade (more permission than before).
  bool get isUpgrade {
    return newState.level.index > previousState.level.index;
  }

  /// Whether tracking capability is affected.
  bool get affectsTracking {
    final hadTracking = previousState.hasAnyPermission;
    final hasTracking = newState.hasAnyPermission;
    return hadTracking != hasTracking;
  }

  const PermissionChangeEvent({
    required this.previousState,
    required this.newState,
    required this.detectedAt,
  });
}
```

---

## State Relationships Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    PermissionGuardState                         │
│                   (Comprehensive UI State)                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌───────────────────────┐    ┌────────────────────────┐       │
│  │ LocationPermissionState│    │ DeviceLocationStatus    │       │
│  │ (App Permission)       │    │ (Device GPS Service)    │       │
│  │ - level               │    │ - enabled/disabled      │       │
│  │ - lastChecked         │    └────────────────────────┘       │
│  └───────────────────────┘                                      │
│                                                                 │
│  ┌───────────────────────┐    ┌────────────────────────┐       │
│  │ isBatteryOptDisabled  │    │ dismissedWarnings       │       │
│  │ (Android-specific)    │    │ (Session-scoped Set)    │       │
│  └───────────────────────┘    └────────────────────────┘       │
│                                                                 │
│                     ↓ Computes ↓                                │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │ PermissionGuardStatus (enum)                               │ │
│  │ - allGranted | partialPermission | permissionRequired      │ │
│  │ - permanentlyDenied | deviceServicesDisabled | batteryOpt  │ │
│  └───────────────────────────────────────────────────────────┘ │
│                                                                 │
│                     ↓ Drives ↓                                  │
│                                                                 │
│  shouldShowBanner | shouldBlockClockIn | shouldWarnOnClockIn   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Validation Rules

### LocationPermissionLevel (Existing)
- Must be one of the five defined enum values
- Mapping from `geolocator.LocationPermission` handled in `BackgroundTrackingService._mapPermission()`

### DeviceLocationStatus
- Updated via `Geolocator.isLocationServiceEnabled()` call
- `unknown` only used during initial state before first check

### PermissionGuardState
- `dismissedWarnings` must only contain `DismissibleWarningType` values
- `lastChecked` must be updated on every status check
- `hasActiveShift` must be synced with `shiftProvider` state

### PermissionChangeEvent
- `previousState` and `newState` must have different `level` values
- `detectedAt` must be set to current time when event is created

---

## State Transitions

### Permission Flow

```
notDetermined ──(request)──► denied
                           └──► deniedForever
                           └──► whileInUse ──(request)──► always
                                            └──► denied (downgrade via settings)
always ──(revoke via settings)──► whileInUse
                                └──► denied
                                └──► deniedForever
```

### Guard Status Flow

```
[App Launch]
    │
    ▼
Check device services ──(disabled)──► deviceServicesDisabled
    │ (enabled)
    ▼
Check app permission
    │
    ├──(deniedForever)──► permanentlyDenied
    ├──(notDetermined|denied)──► permissionRequired
    ├──(whileInUse)──► partialPermission
    └──(always)──► Check battery optimization
                        │
                        ├──(not disabled, Android)──► batteryOptimizationRequired
                        └──(disabled or iOS)──► allGranted
```

---

## No Database Changes

This feature is entirely client-side:
- No Supabase tables added or modified
- No migrations required
- State is session-scoped (in-memory only)
- Existing `LocationPermissionState` unchanged
