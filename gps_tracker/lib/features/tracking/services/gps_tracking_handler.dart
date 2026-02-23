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
  int _activeIntervalSeconds = 60;
  int _stationaryIntervalSeconds = 300;
  int _distanceFilterMeters = 0;
  int _pointCount = 0;
  DateTime? _lastCaptureTime;
  Position? _lastPosition;
  bool _isStationary = false;
  DateTime? _stationaryCheckTime;
  bool _isCapturing = false; // Prevent duplicate captures

  // GPS loss detection
  DateTime? _lastSuccessfulPositionAt;
  bool _gpsLostNotified = false;
  static const _gpsLostThreshold = Duration(minutes: 2);

  // GPS gap tracking
  DateTime? _gpsGapStartedAt;

  // Stream recovery (unlimited attempts with exponential backoff)
  int _streamRecoveryAttempts = 0;
  DateTime? _lastRecoveryAttemptAt;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Load shift context
    _shiftId = await FlutterForegroundTask.getData<String>(key: 'shift_id');
    _employeeId = await FlutterForegroundTask.getData<String>(key: 'employee_id');
    _activeIntervalSeconds =
        await FlutterForegroundTask.getData<int>(key: 'active_interval_seconds') ?? 60;
    _stationaryIntervalSeconds =
        await FlutterForegroundTask.getData<int>(key: 'stationary_interval_seconds') ?? 300;
    _distanceFilterMeters =
        await FlutterForegroundTask.getData<int>(key: 'distance_filter_meters') ?? 0;

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

    // Capture initial position immediately (don't rely on stream's first event)
    try {
      final initialPosition = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );
      _onPosition(initialPosition);
    } catch (_) {
      // Stream will deliver the first position shortly
    }

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
        // intervalDuration controls how often FusedLocationProvider delivers.
        // Use a short interval so Android batches are frequent enough.
        intervalDuration: Duration(seconds: _activeIntervalSeconds),
        // No foregroundNotificationConfig — flutter_foreground_task manages
        // the foreground service already (background_tracking_service.dart).
      );
    } else if (Platform.isIOS) {
      // CRITICAL: distanceFilter MUST be 0 on iOS to keep the position stream
      // alive when stationary. With distanceFilter > 0, iOS stops delivering
      // positions when the user doesn't move, which causes iOS to suspend the
      // app in background — killing GPS tracking entirely.
      // Our _onPosition interval logic filters the high-frequency updates.
      return AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
        activityType: ActivityType.other,
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

    // Update GPS loss tracking — we got a valid position
    _lastSuccessfulPositionAt = now;
    _streamRecoveryAttempts = 0; // Reset recovery counter on success

    if (_gpsLostNotified) {
      _gpsLostNotified = false;

      // Record the GPS gap end
      final gapStart = _gpsGapStartedAt;
      _gpsGapStartedAt = null;

      // Restore normal notification
      FlutterForegroundTask.updateService(
        notificationTitle: 'Suivi de position actif',
        notificationText: 'Points: $_pointCount | GPS restauré',
      );

      // Notify main isolate with gap data
      FlutterForegroundTask.sendDataToMain({
        'type': 'gps_restored',
        if (gapStart != null) 'gap_started_at': gapStart.toUtc().toIso8601String(),
        'gap_ended_at': now.toUtc().toIso8601String(),
        if (gapStart != null)
          'gap_duration_seconds': now.difference(gapStart).inSeconds,
      });
    }

    // Check for stationary state
    _checkStationaryState(position, now);

    // Skip if already capturing
    if (_isCapturing) {
      _lastPosition = position;
      return;
    }

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
      notificationTitle: 'Suivi de position actif',
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

    // GPS loss detection
    _checkGpsLoss(timestamp);

    // Stream health check — detects silently dead streams
    _checkStreamHealth(timestamp);

    // Force capture when stationary and interval has passed (iOS fix)
    // iOS distance filter prevents updates when not moving
    if (_lastCaptureTime != null && _lastPosition != null) {
      final now = DateTime.now();
      final timeSinceLast = now.difference(_lastCaptureTime!);
      final currentInterval = _isStationary
          ? Duration(seconds: _stationaryIntervalSeconds)
          : Duration(seconds: _activeIntervalSeconds);

      if (timeSinceLast >= currentInterval) {
        // Get current position and capture it
        _forceCapture();
      }
    }
  }

  /// Check if stream is silently dead (no positions for too long)
  /// and attempt recovery with exponential backoff (no attempt cap).
  void _checkStreamHealth(DateTime now) {
    final lastSuccess = _lastSuccessfulPositionAt;
    if (lastSuccess == null) return;

    // Need at least 2 minutes of silence before attempting recovery.
    if (now.difference(lastSuccess) < const Duration(minutes: 2)) return;

    // Exponential backoff between recovery attempts: 2, 4, 8, 16, 30 min cap.
    final backoffMin = (2 * (1 << _streamRecoveryAttempts.clamp(0, 4))).clamp(2, 30);
    if (_lastRecoveryAttemptAt != null &&
        now.difference(_lastRecoveryAttemptAt!) < Duration(minutes: backoffMin)) {
      return;
    }

    _streamRecoveryAttempts++;
    _lastRecoveryAttemptAt = now;
    _recoverPositionStream();

    // Every 5th failed attempt, notify main isolate that recovery is struggling
    if (_streamRecoveryAttempts >= 5 && _streamRecoveryAttempts % 5 == 0) {
      FlutterForegroundTask.sendDataToMain({
        'type': 'stream_recovery_failing',
        'attempts': _streamRecoveryAttempts,
        'gap_minutes': now.difference(lastSuccess).inMinutes,
      });
    }
  }

  /// Cancel and recreate the position stream.
  Future<void> _recoverPositionStream() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;

    final settings = _createLocationSettings();
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen(
      _onPosition,
      onError: _onPositionError,
    );

    FlutterForegroundTask.sendDataToMain({
      'type': 'stream_recovered',
      'attempt': _streamRecoveryAttempts,
    });
  }

  void _checkGpsLoss(DateTime now) {
    final lastSuccess = _lastSuccessfulPositionAt;
    if (lastSuccess == null) return; // No position yet — still initializing

    final elapsed = now.difference(lastSuccess);

    // 2-minute threshold: notify GPS lost (no auto clock-out)
    if (elapsed >= _gpsLostThreshold && !_gpsLostNotified) {
      _gpsLostNotified = true;
      _gpsGapStartedAt = lastSuccess; // Gap started when we last had GPS

      FlutterForegroundTask.updateService(
        notificationTitle: 'GPS PERDU',
        notificationText: 'Le suivi continue mais sans points GPS',
      );
      FlutterForegroundTask.sendDataToMain({
        'type': 'gps_lost',
        'gap_started_at': lastSuccess.toUtc().toIso8601String(),
      });
    } else if (_gpsLostNotified) {
      // Update notification with elapsed time
      final lostMinutes = elapsed.inMinutes;
      FlutterForegroundTask.updateService(
        notificationTitle: 'GPS PERDU',
        notificationText: 'Signal perdu depuis $lostMinutes min — le quart continue',
      );
    }
  }

  /// Force-capture a position when stationary (iOS distance filter workaround).
  /// Uses getLastKnownPosition() instead of getCurrentPosition() to avoid
  /// killing the active position stream on iOS (geolocator Issue #1122).
  Future<void> _forceCapture() async {
    if (_isCapturing) return;
    _isCapturing = true;

    try {
      // Use getLastKnownPosition — reads OS cache without interfering
      // with the active position stream (unlike getCurrentPosition).
      final position = await Geolocator.getLastKnownPosition();
      if (position != null) {
        _capturePosition(position, DateTime.now());
      } else if (_lastPosition != null) {
        _capturePosition(_lastPosition!, DateTime.now());
      }
    } catch (e) {
      // If we can't get position, use last known
      if (_lastPosition != null) {
        _capturePosition(_lastPosition!, DateTime.now());
      }
    } finally {
      _isCapturing = false;
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
      } else if (command == 'recoverStream') {
        // Main isolate detected GPS gap — force one immediate recovery attempt
        _lastRecoveryAttemptAt = null; // Allow immediate attempt
        _recoverPositionStream();
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
