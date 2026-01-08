import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/location_permission_state.dart';
import '../services/background_tracking_service.dart';

/// Manages location permission state for tracking.
class LocationPermissionNotifier extends StateNotifier<LocationPermissionState> {
  LocationPermissionNotifier() : super(LocationPermissionState.initial()) {
    checkPermissions();
  }

  /// Check current permission status without requesting.
  Future<void> checkPermissions() async {
    final permissionState = await BackgroundTrackingService.checkPermissions();
    state = permissionState;
  }

  /// Request all required permissions for background tracking.
  Future<LocationPermissionState> requestPermissions() async {
    final permissionState = await BackgroundTrackingService.requestPermissions();
    state = permissionState;
    return permissionState;
  }

  /// Request battery optimization exemption.
  Future<bool> requestBatteryOptimization() async {
    return await BackgroundTrackingService.requestBatteryOptimization();
  }
}

/// Provider for location permission state management.
final locationPermissionProvider =
    StateNotifierProvider<LocationPermissionNotifier, LocationPermissionState>(
  (ref) => LocationPermissionNotifier(),
);

/// Provider for checking if background tracking is possible.
final canTrackInBackgroundProvider = Provider<bool>((ref) {
  return ref.watch(locationPermissionProvider).canTrackInBackground;
});

/// Provider for checking if any location permission is granted.
final hasLocationPermissionProvider = Provider<bool>((ref) {
  return ref.watch(locationPermissionProvider).hasAnyPermission;
});

/// Provider for checking if permission can be requested.
final canRequestPermissionProvider = Provider<bool>((ref) {
  return ref.watch(locationPermissionProvider).canRequestPermission;
});

/// Provider for the current permission level.
final permissionLevelProvider = Provider<LocationPermissionLevel>((ref) {
  return ref.watch(locationPermissionProvider).level;
});
