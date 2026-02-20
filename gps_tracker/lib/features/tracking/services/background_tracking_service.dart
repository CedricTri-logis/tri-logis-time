import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';

import '../models/location_permission_state.dart';
import '../models/tracking_config.dart';
import 'gps_tracking_handler.dart';

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
class BackgroundTrackingService {
  static bool _isInitialized = false;

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
    TrackingConfig config = const TrackingConfig(),
  }) async {
    // Check if already tracking
    if (await FlutterForegroundTask.isRunningService) {
      return const TrackingAlreadyActive();
    }

    // Check permissions
    final permissionState = await checkPermissions();
    if (!permissionState.hasAnyPermission) {
      return const TrackingPermissionDenied();
    }

    try {
      // Store shift context for the background task
      await FlutterForegroundTask.saveData(key: 'shift_id', value: shiftId);
      await FlutterForegroundTask.saveData(key: 'employee_id', value: employeeId);
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

      // Start the foreground service
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
        return const TrackingSuccess();
      } else {
        return const TrackingServiceError('Failed to start tracking service');
      }
    } catch (e) {
      return TrackingServiceError(e.toString());
    }
  }

  /// Stop background GPS tracking.
  static Future<void> stopTracking() async {
    await FlutterForegroundTask.stopService();
    await FlutterForegroundTask.removeData(key: 'shift_id');
    await FlutterForegroundTask.removeData(key: 'employee_id');
    await FlutterForegroundTask.removeData(key: 'config');
    await FlutterForegroundTask.removeData(key: 'active_interval_seconds');
    await FlutterForegroundTask.removeData(key: 'stationary_interval_seconds');
    await FlutterForegroundTask.removeData(key: 'distance_filter_meters');
  }

  /// Check if background tracking is currently active.
  static Future<bool> get isTracking async {
    return await FlutterForegroundTask.isRunningService;
  }

  /// Request all required permissions for background tracking.
  static Future<LocationPermissionState> requestPermissions() async {
    // Request notification permission (Android 13+)
    if (Platform.isAndroid) {
      await FlutterForegroundTask.requestNotificationPermission();
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
          await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      if (!isIgnoring) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    }

    return _mapPermission(permission);
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
        await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (isIgnoring) return true;

    return await FlutterForegroundTask.requestIgnoreBatteryOptimization();
  }

  /// Check if battery optimization is disabled for the app.
  static Future<bool> get isBatteryOptimizationDisabled async {
    if (!Platform.isAndroid) return true;
    return await FlutterForegroundTask.isIgnoringBatteryOptimizations;
  }
}

/// Callback to start the task handler in background isolate.
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(GPSTrackingHandler());
}
