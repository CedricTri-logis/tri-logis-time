import 'package:flutter/foundation.dart';

import 'device_location_status.dart';
import 'dismissible_warning_type.dart';
import 'location_permission_state.dart';
import 'permission_guard_status.dart';

/// Comprehensive state for the permission guard feature,
/// combining multiple status signals.
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

  const PermissionGuardState({
    required this.permission,
    required this.deviceStatus,
    required this.isBatteryOptimizationDisabled,
    required this.dismissedWarnings,
    required this.hasActiveShift,
    required this.lastChecked,
  });

  /// Factory: Initial state
  factory PermissionGuardState.initial() => PermissionGuardState(
        permission: LocationPermissionState.initial(),
        deviceStatus: DeviceLocationStatus.unknown,
        isBatteryOptimizationDisabled: true,
        dismissedWarnings: const {},
        hasActiveShift: false,
        lastChecked: DateTime.now(),
      );

  /// Computed: Overall status for UI display
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

  /// Computed: Whether banner should be shown
  bool get shouldShowBanner {
    if (status == PermissionGuardStatus.allGranted) return false;

    // Check if this warning type is dismissed
    final warningType = _statusToWarningType(status);
    if (warningType != null && dismissedWarnings.contains(warningType)) {
      return false;
    }

    return true;
  }

  /// Computed: Whether clock-in should be blocked
  bool get shouldBlockClockIn {
    return deviceStatus == DeviceLocationStatus.disabled ||
        !permission.hasAnyPermission;
  }

  /// Computed: Whether clock-in should show warning (but allow proceeding)
  bool get shouldWarnOnClockIn {
    return permission.level == LocationPermissionLevel.whileInUse ||
        !isBatteryOptimizationDisabled;
  }

  /// Computed: Whether real-time monitoring is needed
  bool get shouldMonitor => hasActiveShift;

  /// Copy with
  PermissionGuardState copyWith({
    LocationPermissionState? permission,
    DeviceLocationStatus? deviceStatus,
    bool? isBatteryOptimizationDisabled,
    Set<DismissibleWarningType>? dismissedWarnings,
    bool? hasActiveShift,
    DateTime? lastChecked,
  }) =>
      PermissionGuardState(
        permission: permission ?? this.permission,
        deviceStatus: deviceStatus ?? this.deviceStatus,
        isBatteryOptimizationDisabled:
            isBatteryOptimizationDisabled ?? this.isBatteryOptimizationDisabled,
        dismissedWarnings: dismissedWarnings ?? this.dismissedWarnings,
        hasActiveShift: hasActiveShift ?? this.hasActiveShift,
        lastChecked: lastChecked ?? this.lastChecked,
      );

  /// Helper: Map status to dismissible warning type
  DismissibleWarningType? _statusToWarningType(PermissionGuardStatus status) {
    return switch (status) {
      PermissionGuardStatus.partialPermission =>
        DismissibleWarningType.partialPermission,
      PermissionGuardStatus.batteryOptimizationRequired =>
        DismissibleWarningType.batteryOptimization,
      _ => null, // Critical statuses cannot be dismissed
    };
  }
}
