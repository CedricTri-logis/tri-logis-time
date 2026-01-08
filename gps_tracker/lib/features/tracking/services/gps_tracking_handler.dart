import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:uuid/uuid.dart';

/// Task handler running in background isolate for GPS tracking.
class GPSTrackingHandler extends TaskHandler {
  StreamSubscription<Position>? _positionSubscription;
  String? _shiftId;
  String? _employeeId;
  int _activeIntervalSeconds = 300;
  int _stationaryIntervalSeconds = 600;
  int _distanceFilterMeters = 10;
  int _pointCount = 0;
  DateTime? _lastCaptureTime;
  Position? _lastPosition;
  bool _isStationary = false;
  DateTime? _stationaryCheckTime;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Load shift context
    _shiftId = await FlutterForegroundTask.getData<String>(key: 'shift_id');
    _employeeId = await FlutterForegroundTask.getData<String>(key: 'employee_id');
    _activeIntervalSeconds =
        await FlutterForegroundTask.getData<int>(key: 'active_interval_seconds') ?? 300;
    _stationaryIntervalSeconds =
        await FlutterForegroundTask.getData<int>(key: 'stationary_interval_seconds') ?? 600;
    _distanceFilterMeters =
        await FlutterForegroundTask.getData<int>(key: 'distance_filter_meters') ?? 10;

    // If started by system (boot), verify we have an active shift
    if (starter == TaskStarter.system && _shiftId == null) {
      await FlutterForegroundTask.stopService();
      return;
    }

    // If we don't have shift context, stop
    if (_shiftId == null || _employeeId == null) {
      await FlutterForegroundTask.stopService();
      return;
    }

    // Configure platform-specific location settings
    final locationSettings = _createLocationSettings();

    // Start position stream
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      _onPosition,
      onError: _onPositionError,
    );

    // Notify main isolate that tracking has started
    FlutterForegroundTask.sendDataToMain({
      'type': 'started',
      'shift_id': _shiftId,
    });
  }

  LocationSettings _createLocationSettings() {
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: _distanceFilterMeters,
        forceLocationManager: false,
        intervalDuration: Duration(seconds: _activeIntervalSeconds),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'GPS Tracking Active',
          notificationText: 'Tracking your location during shift',
          enableWakeLock: true,
        ),
      );
    } else if (Platform.isIOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: _distanceFilterMeters,
        activityType: ActivityType.otherNavigation,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    }
    return LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: _distanceFilterMeters,
    );
  }

  void _onPosition(Position position) {
    final now = DateTime.now();

    // Check for stationary state
    _checkStationaryState(position, now);

    // Determine current interval based on movement state
    final currentInterval = _isStationary
        ? Duration(seconds: _stationaryIntervalSeconds)
        : Duration(seconds: _activeIntervalSeconds);

    // Check if we should capture based on interval
    if (_lastCaptureTime != null) {
      final timeSinceLast = now.difference(_lastCaptureTime!);
      if (timeSinceLast < currentInterval) {
        // Not enough time has passed
        _lastPosition = position;
        return;
      }
    }

    // Capture this position
    _capturePosition(position, now);
  }

  void _checkStationaryState(Position position, DateTime now) {
    if (_lastPosition == null) {
      _stationaryCheckTime = now;
      _lastPosition = position;
      return;
    }

    // Calculate distance from last position
    final distance = Geolocator.distanceBetween(
      _lastPosition!.latitude,
      _lastPosition!.longitude,
      position.latitude,
      position.longitude,
    );

    // If moved more than 10m, reset stationary check
    if (distance > 10) {
      _isStationary = false;
      _stationaryCheckTime = now;
      _lastPosition = position;
      return;
    }

    // If haven't moved much for 30 seconds, mark as stationary
    if (_stationaryCheckTime != null) {
      final stationaryDuration = now.difference(_stationaryCheckTime!);
      if (stationaryDuration.inSeconds >= 30) {
        _isStationary = true;
      }
    }
  }

  void _capturePosition(Position position, DateTime now) {
    _lastCaptureTime = now;
    _lastPosition = position;
    _pointCount++;

    // Generate a unique ID for this point
    final pointId = const Uuid().v4();

    // Send position data to main isolate
    FlutterForegroundTask.sendDataToMain({
      'type': 'position',
      'point': {
        'id': pointId,
        'shift_id': _shiftId,
        'employee_id': _employeeId,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        'captured_at': position.timestamp.toUtc().toIso8601String(),
        'sync_status': 'pending',
        'created_at': now.toUtc().toIso8601String(),
      },
    });

    // Update notification
    FlutterForegroundTask.updateService(
      notificationTitle: 'GPS Tracking Active',
      notificationText:
          'Points: $_pointCount | Last: ${_formatTime(now)}${_isStationary ? ' (Stationary)' : ''}',
    );
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  void _onPositionError(dynamic error) {
    FlutterForegroundTask.sendDataToMain({
      'type': 'error',
      'message': error.toString(),
    });
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Health check - called every 30 seconds
    FlutterForegroundTask.sendDataToMain({
      'type': 'heartbeat',
      'timestamp': timestamp.millisecondsSinceEpoch,
      'point_count': _pointCount,
      'is_stationary': _isStationary,
      'last_capture': _lastCaptureTime?.toIso8601String(),
    });

    // Ensure position stream is still active
    if (_positionSubscription == null) {
      // Try to restart the stream
      final locationSettings = _createLocationSettings();
      _positionSubscription = Geolocator.getPositionStream(
        locationSettings: locationSettings,
      ).listen(
        _onPosition,
        onError: _onPositionError,
      );
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;

    FlutterForegroundTask.sendDataToMain({
      'type': 'stopped',
      'point_count': _pointCount,
    });
  }

  @override
  void onReceiveData(Object data) {
    if (data is Map<String, dynamic>) {
      final command = data['command'];
      if (command == 'updateConfig') {
        _activeIntervalSeconds = data['active_interval_seconds'] as int? ?? _activeIntervalSeconds;
        _stationaryIntervalSeconds =
            data['stationary_interval_seconds'] as int? ?? _stationaryIntervalSeconds;
        _distanceFilterMeters = data['distance_filter_meters'] as int? ?? _distanceFilterMeters;
      } else if (command == 'getStatus') {
        FlutterForegroundTask.sendDataToMain({
          'type': 'status',
          'is_tracking': true,
          'point_count': _pointCount,
          'is_stationary': _isStationary,
          'last_capture': _lastCaptureTime?.toIso8601String(),
        });
      }
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'stop') {
      FlutterForegroundTask.stopService();
    }
  }

  @override
  void onNotificationPressed() {
    // Bring app to foreground when notification is tapped
    FlutterForegroundTask.launchApp('/');
  }

  @override
  void onNotificationDismissed() {
    // Notification was dismissed - service continues running
  }
}
