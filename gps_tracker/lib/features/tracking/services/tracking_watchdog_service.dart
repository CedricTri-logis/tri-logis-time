import 'dart:io';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:workmanager/workmanager.dart';

import '../../../shared/models/diagnostic_event.dart';
import '../../../shared/services/diagnostic_logger.dart';
import 'background_tracking_service.dart';

/// Layered watchdog service that detects and restarts the GPS foreground
/// service if Android kills it during an active shift.
///
/// Two independent mechanisms:
/// - AlarmManager: fires every 5 min (primary, faster detection)
/// - WorkManager: fires every 15 min (backup, guaranteed by Android)
class TrackingWatchdogService {
  TrackingWatchdogService._();

  static const int _alarmId = 9001;
  static const String _workManagerTaskName = 'gps_tracking_watchdog';
  static const String _workManagerUniqueId = 'ca.trilogis.gpstracker.watchdog';

  // ── Initialization (call once at app startup) ──

  /// Initialize AlarmManager and WorkManager engines.
  /// Must be called once in main() before any start/stop calls.
  /// Failures are caught so watchdog issues never block app startup.
  static Future<void> initialize() async {
    if (!Platform.isAndroid) return;

    try {
      await AndroidAlarmManager.initialize();
    } catch (e) {
      debugPrint('[Watchdog] AlarmManager init failed: $e');
    }

    try {
      await Workmanager().initialize(
        _workManagerCallbackDispatcher,
        isInDebugMode: false,
      );

      // Register WorkManager periodic task (always active, very low cost).
      // If shift_id is null the callback is a no-op.
      await Workmanager().registerPeriodicTask(
        _workManagerUniqueId,
        _workManagerTaskName,
        frequency: const Duration(minutes: 15),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        constraints: Constraints(
          networkType: NetworkType.notRequired,
          requiresBatteryNotLow: false,
          requiresCharging: false,
          requiresDeviceIdle: false,
        ),
      );
    } catch (e) {
      debugPrint('[Watchdog] WorkManager init failed: $e');
    }
  }

  // ── AlarmManager (primary, 5 min) ──

  /// Start the AlarmManager periodic watchdog. Call on clock-in.
  static Future<void> startAlarm() async {
    if (!Platform.isAndroid) return;

    await AndroidAlarmManager.periodic(
      const Duration(minutes: 5),
      _alarmId,
      _alarmCallback,
      exact: false,
      allowWhileIdle: true,
      rescheduleOnReboot: true,
    );
  }

  /// Cancel the AlarmManager watchdog. Call on clock-out.
  static Future<void> stopAlarm() async {
    if (!Platform.isAndroid) return;
    await AndroidAlarmManager.cancel(_alarmId);
  }

  // ── Shared watchdog logic ──

  /// Core watchdog check: if shift is active but service is dead, restart it.
  /// Returns true if a restart was attempted.
  ///
  /// May run in a fresh isolate (AlarmManager/WorkManager callbacks), so we
  /// ensure Flutter bindings and foreground task notification channels are ready.
  static Future<bool> _checkAndRestart(String source) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      await BackgroundTrackingService.initialize();

      final shiftId =
          await FlutterForegroundTask.getData<String>(key: 'shift_id');
      if (shiftId == null || shiftId.isEmpty) return false;

      final isRunning = await FlutterForegroundTask.isRunningService;
      if (isRunning) return false;

      // Service is dead with an active shift — restart
      final employeeId =
          await FlutterForegroundTask.getData<String>(key: 'employee_id');
      if (employeeId == null || employeeId.isEmpty) return false;

      await FlutterForegroundTask.startService(
        notificationTitle: 'Suivi de position actif',
        notificationText: 'Reprise automatique du suivi',
        callback: startCallback,
      );

      // Log the restart (fire-and-forget — logger may not be initialized in isolate)
      _tryLog(source, shiftId);
      return true;
    } catch (_) {
      // Fail silently — watchdog must never crash
      return false;
    }
  }

  static void _tryLog(String source, String shiftId) {
    try {
      if (DiagnosticLogger.isInitialized) {
        DiagnosticLogger.instance.lifecycle(
          Severity.warn,
          'Watchdog: service dead, restarting ($source)',
          metadata: {'shift_id': shiftId},
        );
      }
    } catch (_) {
      // Logging is best-effort in watchdog context
    }
  }

  // ── Callbacks ──

  @pragma('vm:entry-point')
  static Future<void> _alarmCallback() async {
    await _checkAndRestart('alarm');
  }
}

// WorkManager callback must be a top-level function
@pragma('vm:entry-point')
void _workManagerCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName == TrackingWatchdogService._workManagerTaskName) {
      await TrackingWatchdogService._checkAndRestart('workmanager');
    }
    return true;
  });
}
