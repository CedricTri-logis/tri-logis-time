import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';

import '../../../shared/models/diagnostic_event.dart';
import '../../../shared/services/diagnostic_logger.dart';
import '../models/location_permission_state.dart';
import '../models/tracking_config.dart';
import 'android_battery_health_service.dart';
import 'background_execution_service.dart';
import 'gps_tracking_handler.dart';
import 'tracking_watchdog_service.dart';

/// Result of a tracking operation.
sealed class TrackingResult {
  const TrackingResult();
}

class TrackingSuccess extends TrackingResult {
  const TrackingSuccess();
}

class TrackingPermissionDenied extends TrackingResult {
  const TrackingPermissionDenied();
}

class TrackingServiceError extends TrackingResult {
  final String message;
  const TrackingServiceError(this.message);
}

class TrackingAlreadyActive extends TrackingResult {
  const TrackingAlreadyActive();
}

/// Manages the lifecycle of background GPS tracking.
///
/// Also observes app lifecycle to call beginBackgroundTask/endBackgroundTask
/// on iOS for the foreground-to-background transition protection.
class BackgroundTrackingService with WidgetsBindingObserver {
  static DiagnosticLogger? get _logger =>
      DiagnosticLogger.isInitialized ? DiagnosticLogger.instance : null;

  static bool _isInitialized = false;
  static BackgroundTrackingService? _lifecycleInstance;

  /// Initialize the foreground task service. Must be called once during app startup.
  static Future<void> initialize() async {
    if (_isInitialized) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'gps_tracking_channel',
        channelName: 'Suivi de position',
        channelDescription: 'Background location tracking during shifts',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(30000), // 30s heartbeat
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    _isInitialized = true;
  }

  /// Begin background GPS tracking for an active shift.
  static Future<TrackingResult> startTracking({
    required String shiftId,
    required String employeeId,
    DateTime? clockedInAt,
    int initialPointCount = 0,
    TrackingConfig config = const TrackingConfig(),
  }) async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    bool? batteryOptimizationDisabled;
    if (Platform.isAndroid) {
      batteryOptimizationDisabled =
          await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    }
    _logger?.gps(
      Severity.info,
      'Background startTracking requested',
      metadata: {
        'shift_id': shiftId,
        'platform': Platform.isIOS ? 'ios' : 'android',
        'service_enabled': serviceEnabled,
        'battery_optimization_disabled': batteryOptimizationDisabled,
        'active_interval_seconds': config.activeIntervalSeconds,
        'stationary_interval_seconds': config.stationaryIntervalSeconds,
        'distance_filter_meters': config.distanceFilterMeters,
      },
    );

    // Check if already tracking
    if (await FlutterForegroundTask.isRunningService) {
      _logger?.gps(
        Severity.warn,
        'startTracking aborted: foreground service already running',
        metadata: {'shift_id': shiftId},
      );
      return const TrackingAlreadyActive();
    }

    // Check permissions
    final permissionState = await checkPermissions();
    if (!permissionState.hasAnyPermission) {
      _logger?.permission(
        Severity.warn,
        'startTracking denied: no location permission',
        metadata: {
          'shift_id': shiftId,
          'permission_level': permissionState.level.name
        },
      );
      return const TrackingPermissionDenied();
    }

    try {
      // Store shift context for the background task
      await FlutterForegroundTask.saveData(key: 'shift_id', value: shiftId);
      await FlutterForegroundTask.saveData(
          key: 'employee_id', value: employeeId);
      await FlutterForegroundTask.saveData(
        key: 'config',
        value: config.toJson().toString(),
      );
      await FlutterForegroundTask.saveData(
        key: 'active_interval_seconds',
        value: config.activeIntervalSeconds,
      );
      await FlutterForegroundTask.saveData(
        key: 'stationary_interval_seconds',
        value: config.stationaryIntervalSeconds,
      );
      await FlutterForegroundTask.saveData(
        key: 'distance_filter_meters',
        value: config.distanceFilterMeters,
      );
      await FlutterForegroundTask.saveData(
        key: 'initial_point_count',
        value: initialPointCount,
      );
      if (clockedInAt != null) {
        await FlutterForegroundTask.saveData(
          key: 'clocked_in_at_ms',
          value: clockedInAt.millisecondsSinceEpoch,
        );
      }

      // Start the foreground service with retry (up to 3 attempts).
      // Transient failures on Android (resource exhaustion, timing) are common
      // on Samsung/Android 14+ devices — a retry usually succeeds.
      for (int attempt = 1; attempt <= 3; attempt++) {
        final result = await FlutterForegroundTask.startService(
          notificationTitle: 'Suivi de position actif',
          notificationText: 'Suivi de votre position pendant le quart',
          notificationIcon: null,
          notificationButtons: [
            const NotificationButton(id: 'stop', text: 'Stop'),
          ],
          callback: startCallback,
        );

        if (result is ServiceRequestSuccess) {
          _logger?.gps(
            Severity.info,
            'Foreground service start success',
            metadata: {'shift_id': shiftId, 'attempt': attempt},
          );
          await TrackingWatchdogService.startAlarm();
          return const TrackingSuccess();
        }

        _logger?.gps(
          Severity.warn,
          'Foreground service start failed, attempt $attempt/3',
          metadata: {
            'shift_id': shiftId,
            'result': result.runtimeType.toString(),
          },
        );

        if (attempt < 3) {
          await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
        }
      }

      _logger?.gps(
        Severity.error,
        'Foreground service start failed after 3 attempts',
        metadata: {'shift_id': shiftId},
      );
      return const TrackingServiceError('Failed to start tracking service after 3 attempts');
    } catch (e) {
      _logger?.gps(
        Severity.error,
        'Foreground service start threw exception',
        metadata: {'shift_id': shiftId, 'error': e.toString()},
      );
      return TrackingServiceError(e.toString());
    }
  }

  /// Stop background GPS tracking.
  static Future<void> stopTracking() async {
    await TrackingWatchdogService.stopAlarm();
    await FlutterForegroundTask.stopService();
    await FlutterForegroundTask.removeData(key: 'shift_id');
    await FlutterForegroundTask.removeData(key: 'employee_id');
    await FlutterForegroundTask.removeData(key: 'config');
    await FlutterForegroundTask.removeData(key: 'active_interval_seconds');
    await FlutterForegroundTask.removeData(key: 'stationary_interval_seconds');
    await FlutterForegroundTask.removeData(key: 'distance_filter_meters');
    await FlutterForegroundTask.removeData(key: 'initial_point_count');
    await FlutterForegroundTask.removeData(key: 'clocked_in_at_ms');
  }

  /// Restart background GPS tracking (stop old service, start new one).
  ///
  /// Handles the race condition where the old shift's foreground service
  /// is still running when a new shift tries to start tracking.
  static Future<TrackingResult> restartTracking({
    required String shiftId,
    required String employeeId,
    DateTime? clockedInAt,
    int initialPointCount = 0,
    TrackingConfig config = const TrackingConfig(),
  }) async {
    _logger?.gps(
      Severity.info,
      'Restart tracking: stopping old service before starting new one',
      metadata: {'new_shift_id': shiftId},
    );

    // Stop the old service if it's still running
    if (await FlutterForegroundTask.isRunningService) {
      await stopTracking();
      // Wait for iOS to fully release the foreground service
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    // Start tracking with the new shift params
    return startTracking(
      shiftId: shiftId,
      employeeId: employeeId,
      clockedInAt: clockedInAt,
      initialPointCount: initialPointCount,
      config: config,
    );
  }

  /// Check if background tracking is currently active.
  static Future<bool> get isTracking async {
    return await FlutterForegroundTask.isRunningService;
  }

  /// Request all required permissions for background tracking.
  static Future<LocationPermissionState> requestPermissions() async {
    String? notificationPermissionResult;
    // Request notification permission (Android 13+)
    if (Platform.isAndroid) {
      final result =
          await FlutterForegroundTask.requestNotificationPermission();
      notificationPermissionResult = result.toString();
    }

    // Check current location permission
    var permission = await Geolocator.checkPermission();

    // Request location permission if not granted
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    // If "while in use" granted, try to get "always" permission
    if (permission == LocationPermission.whileInUse) {
      permission = await Geolocator.requestPermission();
    }

    // Request battery optimization exemption (Android)
    if (Platform.isAndroid) {
      final isIgnoring =
          await AndroidBatteryHealthService.isBatteryOptimizationDisabled;
      if (!isIgnoring) {
        await AndroidBatteryHealthService.requestIgnoreBatteryOptimization();
      }
    }

    final mapped = _mapPermission(permission);
    _logger?.permission(
      Severity.info,
      'Background permission request completed',
      metadata: {
        'platform': Platform.isIOS ? 'ios' : 'android',
        'location_permission': permission.name,
        'mapped_level': mapped.level.name,
        'notification_permission': notificationPermissionResult,
        if (Platform.isAndroid)
          'battery_optimization_disabled':
              await AndroidBatteryHealthService.isBatteryOptimizationDisabled,
      },
    );
    return mapped;
  }

  /// Check current permission status without requesting.
  static Future<LocationPermissionState> checkPermissions() async {
    final permission = await Geolocator.checkPermission();
    return _mapPermission(permission);
  }

  /// Map geolocator permission to our permission state.
  static LocationPermissionState _mapPermission(LocationPermission permission) {
    final level = switch (permission) {
      LocationPermission.denied => LocationPermissionLevel.denied,
      LocationPermission.deniedForever => LocationPermissionLevel.deniedForever,
      LocationPermission.whileInUse => LocationPermissionLevel.whileInUse,
      LocationPermission.always => LocationPermissionLevel.always,
      LocationPermission.unableToDetermine =>
        LocationPermissionLevel.notDetermined,
    };

    return LocationPermissionState(
      level: level,
      lastChecked: DateTime.now(),
    );
  }

  /// Request battery optimization exemption.
  static Future<bool> requestBatteryOptimization() async {
    if (!Platform.isAndroid) return true;

    final isIgnoring =
        await AndroidBatteryHealthService.isBatteryOptimizationDisabled;
    if (isIgnoring) return true;

    return AndroidBatteryHealthService.requestIgnoreBatteryOptimization();
  }

  /// Check if battery optimization is disabled for the app.
  static Future<bool> get isBatteryOptimizationDisabled async {
    if (!Platform.isAndroid) return true;
    return AndroidBatteryHealthService.isBatteryOptimizationDisabled;
  }

  /// Callback invoked when the foreground service is detected as dead on resume.
  /// Set by TrackingNotifier to trigger auto-restart.
  static VoidCallback? onForegroundServiceDied;

  /// Start observing app lifecycle for iOS background task protection
  /// and Android foreground service health checks.
  static void startLifecycleObserver() {
    if (_lifecycleInstance != null) return;
    _lifecycleInstance = BackgroundTrackingService._();
    WidgetsBinding.instance.addObserver(_lifecycleInstance!);
  }

  /// Stop observing app lifecycle.
  static void stopLifecycleObserver() {
    if (_lifecycleInstance != null) {
      WidgetsBinding.instance.removeObserver(_lifecycleInstance!);
      _lifecycleInstance = null;
    }
  }

  BackgroundTrackingService._();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && Platform.isIOS) {
      // iOS: request ~30s of transition protection
      BackgroundExecutionService.beginBackgroundTask(
        name: 'gps_tracking_background',
      );
    } else if (state == AppLifecycleState.resumed) {
      if (Platform.isIOS) {
        // iOS: end background task
        BackgroundExecutionService.endBackgroundTask();
      }
      // Both platforms: check if foreground service died while backgrounded
      _checkForegroundServiceHealth();
    }
  }

  /// Check if the foreground service is still running. If not, notify the
  /// TrackingNotifier to restart it (safe from foreground context on Android 12+).
  Future<void> _checkForegroundServiceHealth() async {
    try {
      final isRunning = await FlutterForegroundTask.isRunningService;
      if (!isRunning) {
        _logger?.gps(
            Severity.error, 'Foreground service died — notifying for restart');
        onForegroundServiceDied?.call();
      }
    } catch (e) {
      _logger?.gps(Severity.error, 'Failed to check foreground service health',
          metadata: {'error': e.toString()});
    }
  }
}

/// Callback to start the task handler in background isolate.
@pragma('vm:entry-point')
Future<void> startCallback() async {
  FlutterForegroundTask.setTaskHandler(GPSTrackingHandler());
}
