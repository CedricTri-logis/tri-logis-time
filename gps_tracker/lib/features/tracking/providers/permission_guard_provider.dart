import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../models/device_location_status.dart';
import '../models/dismissible_warning_type.dart';
import '../models/permission_guard_state.dart';
import '../models/permission_guard_status.dart';
import '../services/background_tracking_service.dart';

/// Manages permission guard state for tracking.
class PermissionGuardNotifier extends StateNotifier<PermissionGuardState> {
  Timer? _debounceTimer;

  PermissionGuardNotifier() : super(PermissionGuardState.initial()) {
    checkStatus();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }

  /// Performs a full permission and device status check.
  Future<void> checkStatus() async {
    try {
      // Check device services
      DeviceLocationStatus deviceStatus;
      try {
        final serviceEnabled = await Geolocator.isLocationServiceEnabled();
        deviceStatus = serviceEnabled
            ? DeviceLocationStatus.enabled
            : DeviceLocationStatus.disabled;
      } catch (e) {
        // Default to enabled to avoid blocking user
        deviceStatus = DeviceLocationStatus.enabled;
      }

      // Check app permission
      final permission = await BackgroundTrackingService.checkPermissions();

      // Check battery optimization (Android)
      final batteryOpt =
          await BackgroundTrackingService.isBatteryOptimizationDisabled;

      // Debounced update to prevent UI flicker
      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 500), () {
        if (mounted) {
          state = state.copyWith(
            permission: permission,
            deviceStatus: deviceStatus,
            isBatteryOptimizationDisabled: batteryOpt,
            lastChecked: DateTime.now(),
          );
        }
      });
    } catch (e) {
      // Set to unknown/error state
      state = state.copyWith(
        deviceStatus: DeviceLocationStatus.unknown,
      );
    }
  }

  /// Marks a warning as dismissed for the current session.
  void dismissWarning(DismissibleWarningType type) {
    state = state.copyWith(
      dismissedWarnings: {...state.dismissedWarnings, type},
    );
  }

  /// Updates the active shift status, triggering monitoring start/stop.
  void setActiveShift(bool isActive) {
    state = state.copyWith(hasActiveShift: isActive);
  }

  /// Triggers the system permission request flow.
  Future<void> requestPermission() async {
    await BackgroundTrackingService.requestPermissions();
    await checkStatus();
  }

  /// Opens device settings for the app.
  Future<void> openAppSettings() async {
    await Geolocator.openAppSettings();
  }

  /// Opens device-level location settings.
  Future<void> openDeviceLocationSettings() async {
    await Geolocator.openLocationSettings();
  }

  /// Requests battery optimization exemption (Android only).
  Future<void> requestBatteryOptimization() async {
    if (!Platform.isAndroid) return;
    await BackgroundTrackingService.requestBatteryOptimization();
    await checkStatus();
  }
}

/// Main provider for permission guard state management.
final permissionGuardProvider =
    StateNotifierProvider<PermissionGuardNotifier, PermissionGuardState>(
  (ref) => PermissionGuardNotifier(),
);

/// Current overall permission guard status.
final permissionGuardStatusProvider = Provider<PermissionGuardStatus>((ref) {
  return ref.watch(permissionGuardProvider).status;
});

/// Whether the permission banner should be displayed.
final shouldShowPermissionBannerProvider = Provider<bool>((ref) {
  return ref.watch(permissionGuardProvider).shouldShowBanner;
});

/// Whether clock-in should be blocked due to permission issues.
final shouldBlockClockInProvider = Provider<bool>((ref) {
  return ref.watch(permissionGuardProvider).shouldBlockClockIn;
});

/// Whether clock-in should show a warning (but allow proceeding).
final shouldWarnOnClockInProvider = Provider<bool>((ref) {
  return ref.watch(permissionGuardProvider).shouldWarnOnClockIn;
});
