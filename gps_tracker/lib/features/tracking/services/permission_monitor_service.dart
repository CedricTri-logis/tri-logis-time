import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/location_permission_state.dart';
import '../models/permission_change_event.dart';
import 'background_tracking_service.dart';

/// Service for real-time permission monitoring during active shifts.
class PermissionMonitorService {
  Timer? _monitorTimer;
  LocationPermissionState? _lastKnownState;

  /// Whether monitoring is currently active.
  bool get isMonitoring => _monitorTimer != null;

  /// Start monitoring for permission changes.
  ///
  /// [onChanged] is called when permission state changes.
  /// Polls every [intervalSeconds] (default: 30).
  void startMonitoring({
    required void Function(PermissionChangeEvent) onChanged,
    int intervalSeconds = 30,
  }) {
    // Initialize last known state
    _initializeState();

    _monitorTimer?.cancel();
    _monitorTimer = Timer.periodic(
      Duration(seconds: intervalSeconds),
      (_) => _checkForChanges(onChanged),
    );
  }

  /// Stop monitoring.
  void stopMonitoring() {
    _monitorTimer?.cancel();
    _monitorTimer = null;
    _lastKnownState = null;
  }

  Future<void> _initializeState() async {
    _lastKnownState = await BackgroundTrackingService.checkPermissions();
  }

  Future<void> _checkForChanges(
    void Function(PermissionChangeEvent) onChanged,
  ) async {
    final newState = await BackgroundTrackingService.checkPermissions();

    if (_lastKnownState != null &&
        newState.level != _lastKnownState!.level) {
      final event = PermissionChangeEvent(
        previousState: _lastKnownState!,
        newState: newState,
        detectedAt: DateTime.now(),
      );
      onChanged(event);
    }

    _lastKnownState = newState;
  }

  /// Manually check for permission changes (e.g., on app resume).
  Future<PermissionChangeEvent?> checkNow() async {
    final newState = await BackgroundTrackingService.checkPermissions();

    if (_lastKnownState != null &&
        newState.level != _lastKnownState!.level) {
      final event = PermissionChangeEvent(
        previousState: _lastKnownState!,
        newState: newState,
        detectedAt: DateTime.now(),
      );
      _lastKnownState = newState;
      return event;
    }

    _lastKnownState = newState;
    return null;
  }
}

/// Provider for permission monitor service.
final permissionMonitorProvider = Provider<PermissionMonitorService>((ref) {
  final service = PermissionMonitorService();
  ref.onDispose(() => service.stopMonitoring());
  return service;
});
