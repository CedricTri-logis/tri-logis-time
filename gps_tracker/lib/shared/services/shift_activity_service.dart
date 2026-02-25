import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:live_activities/live_activities.dart';

import '../../features/shifts/models/shift.dart';
import '../models/diagnostic_event.dart';
import 'diagnostic_logger.dart';

/// Cross-platform service for shift status indicators:
/// - iOS: Live Activity on Lock Screen + Dynamic Island
/// - Android: no-op (foreground notification already handled by GPSTrackingHandler)
class ShiftActivityService {
  ShiftActivityService._();
  static final ShiftActivityService instance = ShiftActivityService._();

  DiagnosticLogger? get _logger =>
      DiagnosticLogger.isInitialized ? DiagnosticLogger.instance : null;

  LiveActivities? _liveActivities;
  String? _currentActivityId;
  DateTime? _activityStartedAt;

  /// Initialize the Live Activities plugin. No-op on Android.
  Future<void> initialize() async {
    if (!Platform.isIOS) return;

    try {
      debugPrint('[ShiftActivityService] Initializing Live Activities...');
      _liveActivities = LiveActivities();
      await _liveActivities!.init(
        appGroupId: 'group.com.cedriclajoie.gpstracker.liveactivities',
      );
      debugPrint('[ShiftActivityService] Init SUCCESS');

      // Check if Live Activities are enabled in iOS Settings
      final enabled = await _liveActivities!.areActivitiesEnabled();
      debugPrint('[ShiftActivityService] areActivitiesEnabled = $enabled');
      if (!enabled) {
        _logger?.lifecycle(Severity.warn, 'Live Activities disabled in iOS Settings');
      }
    } catch (e, stack) {
      debugPrint('[ShiftActivityService] Init FAILED: $e');
      debugPrint('[ShiftActivityService] Stack: $stack');
      _logger?.lifecycle(Severity.warn, 'Live Activities init failed', metadata: {'error': e.toString()});
      _liveActivities = null;
    }
  }

  /// Start a Live Activity for the given shift. No-op on Android.
  Future<void> startActivity(Shift shift) async {
    debugPrint('[ShiftActivityService] startActivity called — iOS=${Platform.isIOS}, plugin=${_liveActivities != null}');
    if (!Platform.isIOS || _liveActivities == null) return;

    try {
      // Check if activities are enabled before creating
      final enabled = await _liveActivities!.areActivitiesEnabled();
      debugPrint('[ShiftActivityService] areActivitiesEnabled = $enabled');
      if (!enabled) {
        _logger?.shift(Severity.warn, 'Live Activities disabled — cannot start');
        return;
      }

      // End any stale activity first
      await _endAllActivities();

      final data = {
        'clockedInAtMs': shift.clockedInAt.millisecondsSinceEpoch,
        'status': 'active',
      };
      debugPrint('[ShiftActivityService] Creating activity with data: $data');

      final activityId = await _liveActivities!.createActivity(
        data,
        removeWhenAppIsKilled: true,
      );

      _currentActivityId = activityId;
      _activityStartedAt = DateTime.now();

      debugPrint('[ShiftActivityService] Activity created — id=$activityId');
      _logger?.shift(Severity.info, 'Live Activity started', metadata: {
        'activity_id': activityId,
        'shift_id': shift.id,
      },);
    } catch (e, stack) {
      debugPrint('[ShiftActivityService] startActivity FAILED: $e');
      debugPrint('[ShiftActivityService] Stack: $stack');
      _logger?.shift(Severity.warn, 'Failed to start Live Activity', metadata: {'error': e.toString()});
    }
  }

  /// Update the GPS status on the Live Activity. No-op on Android.
  Future<void> updateStatus(String status) async {
    if (!Platform.isIOS || _liveActivities == null || _currentActivityId == null) return;

    try {
      await _liveActivities!.updateActivity(
        _currentActivityId!,
        {
          'status': status,
        },
      );
    } catch (e) {
      _logger?.shift(Severity.warn, 'Failed to update Live Activity', metadata: {'error': e.toString()});
    }
  }

  /// End the current Live Activity. No-op on Android.
  Future<void> endActivity() async {
    if (!Platform.isIOS || _liveActivities == null) return;

    try {
      await _endAllActivities();
      _currentActivityId = null;
      _activityStartedAt = null;
    } catch (e) {
      _logger?.shift(Severity.warn, 'Failed to end Live Activity', metadata: {'error': e.toString()});
    }
  }

  /// Check if the Live Activity needs to be restarted (Apple 8h limit).
  /// Should be called periodically (e.g. on heartbeat).
  Future<void> checkAndRestartIfNeeded(Shift shift) async {
    if (!Platform.isIOS || _liveActivities == null || _activityStartedAt == null) return;

    final elapsed = DateTime.now().difference(_activityStartedAt!);
    // Restart at 7h45m to stay under Apple's 8h limit
    if (elapsed >= const Duration(hours: 7, minutes: 45)) {
      _logger?.shift(Severity.info, 'Restarting Live Activity (approaching 8h limit)');
      await endActivity();
      await startActivity(shift);
    }
  }

  /// Safety net: end all activities.
  Future<void> _endAllActivities() async {
    try {
      await _liveActivities!.endAllActivities();
    } catch (e) {
      debugPrint('[ShiftActivityService] endAllActivities failed: $e');
    }
  }
}
