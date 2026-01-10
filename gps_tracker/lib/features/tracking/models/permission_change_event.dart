import 'package:flutter/foundation.dart';

import 'location_permission_state.dart';

/// Represents a detected change in permission status during an active shift.
@immutable
class PermissionChangeEvent {
  /// The previous permission state.
  final LocationPermissionState previousState;

  /// The new permission state.
  final LocationPermissionState newState;

  /// When the change was detected.
  final DateTime detectedAt;

  const PermissionChangeEvent({
    required this.previousState,
    required this.newState,
    required this.detectedAt,
  });

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
}
