import 'package:flutter/foundation.dart';

/// Permission level for location access.
enum LocationPermissionLevel {
  /// Permission has not been requested.
  notDetermined,

  /// User denied permission.
  denied,

  /// User denied permission permanently.
  deniedForever,

  /// Permission granted while app is in use.
  whileInUse,

  /// Permission granted always (including background).
  always,
}

/// Tracks current location permission status.
@immutable
class LocationPermissionState {
  /// Current permission level.
  final LocationPermissionLevel level;

  /// When permission was last checked.
  final DateTime lastChecked;

  /// Whether background tracking is possible.
  bool get canTrackInBackground => level == LocationPermissionLevel.always;

  /// Whether any location access is available.
  bool get hasAnyPermission =>
      level == LocationPermissionLevel.whileInUse ||
      level == LocationPermissionLevel.always;

  /// Whether user can be prompted for permission.
  bool get canRequestPermission =>
      level == LocationPermissionLevel.notDetermined ||
      level == LocationPermissionLevel.denied;

  const LocationPermissionState({
    required this.level,
    required this.lastChecked,
  });

  static LocationPermissionState initial() => LocationPermissionState(
        level: LocationPermissionLevel.notDetermined,
        lastChecked: DateTime.now(),
      );

  LocationPermissionState copyWith({
    LocationPermissionLevel? level,
    DateTime? lastChecked,
  }) =>
      LocationPermissionState(
        level: level ?? this.level,
        lastChecked: lastChecked ?? this.lastChecked,
      );
}
