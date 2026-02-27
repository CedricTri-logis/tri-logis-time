import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../features/shifts/models/shift.dart';
import '../models/diagnostic_event.dart';
import 'diagnostic_logger.dart';

/// Cross-platform service for shift status indicators:
/// - iOS: Live Activity on Lock Screen + Dynamic Island (via native method channel)
/// - Android: no-op (foreground notification already handled by GPSTrackingHandler)
class ShiftActivityService {
  ShiftActivityService._();
  static final ShiftActivityService instance = ShiftActivityService._();

  static const _channel = MethodChannel('shift_live_activity');

  DiagnosticLogger? get _logger =>
      DiagnosticLogger.isInitialized ? DiagnosticLogger.instance : null;

  String? _currentActivityId;
  DateTime? _activityStartedAt;
  int? _clockedInAtMs;
  String? _currentSessionType;
  String? _currentSessionLocation;

  /// Initialize the service. No-op on Android.
  Future<void> initialize() async {
    // No initialization needed — the native plugin is registered in AppDelegate
  }

  /// Start a Live Activity for the given shift. No-op on Android.
  Future<void> startActivity(Shift shift) async {
    if (!Platform.isIOS) return;

    try {
      final enabled = await _channel.invokeMethod<bool>('areActivitiesEnabled');
      debugPrint('[ShiftActivityService] areActivitiesEnabled = $enabled');
      if (enabled != true) {
        _logger?.shift(Severity.warn, 'Live Activities disabled — cannot start');
        return;
      }

      // End any stale activities first
      await endActivity();

      final clockedInAtMs = shift.clockedInAt.millisecondsSinceEpoch;
      debugPrint('[ShiftActivityService] Creating activity — clockedInAtMs=$clockedInAtMs');

      final activityId = await _channel.invokeMethod<String>('createActivity', {
        'clockedInAtMs': clockedInAtMs,
        'status': 'active',
        'removeWhenAppIsKilled': true,
      });

      _currentActivityId = activityId;
      _activityStartedAt = DateTime.now();
      _clockedInAtMs = clockedInAtMs;

      debugPrint('[ShiftActivityService] Activity created — id=$activityId');
      _logger?.shift(Severity.info, 'Live Activity started', metadata: {
        'activity_id': activityId,
        'shift_id': shift.id,
      });
    } catch (e, stack) {
      debugPrint('[ShiftActivityService] startActivity FAILED: $e');
      debugPrint('[ShiftActivityService] Stack: $stack');
      _logger?.shift(
        Severity.warn,
        'Failed to start Live Activity',
        metadata: {'error': e.toString()},
      );
    }
  }

  /// Update the GPS status on the Live Activity. No-op on Android.
  Future<void> updateStatus(String status) async {
    if (!Platform.isIOS || _currentActivityId == null || _clockedInAtMs == null) return;

    try {
      await _channel.invokeMethod<void>('updateActivity', {
        'activityId': _currentActivityId!,
        'clockedInAtMs': _clockedInAtMs!,
        'status': status,
        if (_currentSessionType != null) 'sessionType': _currentSessionType,
        if (_currentSessionLocation != null)
          'sessionLocation': _currentSessionLocation,
      });
    } catch (e) {
      _logger?.shift(
        Severity.warn,
        'Failed to update Live Activity',
        metadata: {'error': e.toString()},
      );
    }
  }

  /// Update session info on the Live Activity. No-op on Android.
  /// Pass null values to clear session info.
  Future<void> updateSessionInfo({
    String? sessionType,
    String? sessionLocation,
  }) async {
    _currentSessionType = sessionType;
    _currentSessionLocation = sessionLocation;

    if (!Platform.isIOS || _currentActivityId == null || _clockedInAtMs == null) return;

    try {
      await _channel.invokeMethod<void>('updateActivity', {
        'activityId': _currentActivityId!,
        'clockedInAtMs': _clockedInAtMs!,
        'status': 'active',
        if (sessionType != null) 'sessionType': sessionType,
        if (sessionLocation != null) 'sessionLocation': sessionLocation,
      });
      _logger?.shift(Severity.info, 'Live Activity session info updated', metadata: {
        'session_type': sessionType,
        'session_location': sessionLocation,
      });
    } catch (e) {
      _logger?.shift(
        Severity.warn,
        'Failed to update Live Activity session info',
        metadata: {'error': e.toString()},
      );
    }
  }

  /// End the current Live Activity. No-op on Android.
  Future<void> endActivity() async {
    if (!Platform.isIOS) return;

    try {
      await _channel.invokeMethod<void>('endAllActivities');
      _currentActivityId = null;
      _activityStartedAt = null;
      _clockedInAtMs = null;
      _currentSessionType = null;
      _currentSessionLocation = null;
    } catch (e) {
      _logger?.shift(
        Severity.warn,
        'Failed to end Live Activity',
        metadata: {'error': e.toString()},
      );
    }
  }

  /// Check if the Live Activity needs to be restarted (Apple 8h limit).
  Future<void> checkAndRestartIfNeeded(Shift shift) async {
    if (!Platform.isIOS || _activityStartedAt == null) return;

    final elapsed = DateTime.now().difference(_activityStartedAt!);
    if (elapsed >= const Duration(hours: 7, minutes: 45)) {
      _logger?.shift(Severity.info, 'Restarting Live Activity (approaching 8h limit)');
      await endActivity();
      await startActivity(shift);
    }
  }
}
