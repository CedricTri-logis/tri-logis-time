import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:uuid/uuid.dart';

/// Task handler running in background isolate for GPS tracking.
class GPSTrackingHandler extends TaskHandler {
  StreamSubscription<Position>? _positionSubscription;
  String? _shiftId;
  String? _employeeId;
  int _activeIntervalSeconds = 10;
  int _stationaryIntervalSeconds = 120;
  int _distanceFilterMeters = 0;
  int _pointCount = 0;
  DateTime? _lastCaptureTime;
  Position? _lastPosition;
  bool _isStationary = false;
  DateTime? _stationaryCheckTime;
  bool _isCapturing = false; // Prevent duplicate captures

  // Thermal multiplier (received from main isolate)
  int _thermalMultiplier = 1;

  // Activity recognition state (received from main isolate)
  String? _currentActivity;

  // GPS loss detection — 45s threshold for faster SLC activation (C1)
  DateTime? _lastSuccessfulPositionAt;
  bool _gpsLostNotified = false;
  static const _gpsLostThreshold = Duration(seconds: 45);

  // GPS gap tracking
  DateTime? _gpsGapStartedAt;

  // Stream recovery (unlimited attempts with exponential backoff)
  int _streamRecoveryAttempts = 0;
  DateTime? _lastRecoveryAttemptAt;

  // Grace period post-restart: inhibit GPS loss detection for 60s (A5)
  DateTime? _trackingStartedAt;
  static const _gracePeriod = Duration(seconds: 60);

  // Shift clock-in time for elapsed display in notifications
  DateTime? _clockedInAt;

  /// Send a diagnostic event to the main isolate for logging.
  /// Background isolate cannot use DiagnosticLogger directly.
  void _sendDiagnostic(String severity, String message, [Map<String, dynamic>? metadata]) {
    FlutterForegroundTask.sendDataToMain(jsonEncode({
      'type': 'diagnostic',
      'category': 'gps',
      'severity': severity,
      'message': message,
      if (metadata != null) 'metadata': metadata,
    }),);
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Load shift context
    _shiftId = await FlutterForegroundTask.getData<String>(key: 'shift_id');
    _employeeId = await FlutterForegroundTask.getData<String>(key: 'employee_id');
    _activeIntervalSeconds =
        await FlutterForegroundTask.getData<int>(key: 'active_interval_seconds') ?? 10;
    _stationaryIntervalSeconds =
        await FlutterForegroundTask.getData<int>(key: 'stationary_interval_seconds') ?? 120;
    _distanceFilterMeters =
        await FlutterForegroundTask.getData<int>(key: 'distance_filter_meters') ?? 0;
    _pointCount =
        await FlutterForegroundTask.getData<int>(key: 'initial_point_count') ?? 0;

    // Load clock-in time for elapsed display
    final clockedInAtMs = await FlutterForegroundTask.getData<int>(key: 'clocked_in_at_ms');
    if (clockedInAtMs != null) {
      _clockedInAt = DateTime.fromMillisecondsSinceEpoch(clockedInAtMs);
    }

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

    // Record start time for grace period (A5)
    _trackingStartedAt = DateTime.now();

    // Configure platform-specific location settings
    final locationSettings = _createLocationSettings();

    // Start position stream with retry (up to 3 attempts)
    bool streamStarted = false;
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        _positionSubscription = Geolocator.getPositionStream(
          locationSettings: locationSettings,
        ).listen(
          _onPosition,
          onError: _onPositionError,
        );
        streamStarted = true;
        if (attempt > 1) {
          _sendDiagnostic('info', 'Position stream started on retry', {'attempt': attempt});
        }
        break;
      } catch (e) {
        _sendDiagnostic('error', 'Position stream init failed', {
          'attempt': attempt,
          'error': e.toString(),
        });
        if (attempt < 3) {
          await Future<void>.delayed(Duration(seconds: attempt * 2));
        }
      }
    }

    if (!streamStarted) {
      _sendDiagnostic('error', 'Position stream failed after 3 attempts, stopping service');
      FlutterForegroundTask.sendDataToMain({
        'type': 'error',
        'message': 'GPS stream failed to start after 3 attempts',
      });
      await FlutterForegroundTask.stopService();
      return;
    }

    // Capture initial position immediately (don't rely on stream's first event)
    try {
      final initialPosition = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );
      _onPosition(initialPosition);
    } catch (_) {
      // Stream will deliver the first position shortly
      _sendDiagnostic('warn', 'Initial position capture timeout');
    }

    // Notify main isolate that tracking has started
    FlutterForegroundTask.sendDataToMain({
      'type': 'started',
      'shift_id': _shiftId,
    });

    _sendDiagnostic('info', 'GPS handler started', {'shift_id': _shiftId ?? ''});
  }

  LocationSettings _createLocationSettings() {
    if (Platform.isAndroid) {
      // On Android 14+, FusedLocationProvider treats intervalDuration as a hint
      // and may batch/delay updates aggressively for battery savings.
      // Use a shorter interval (15s) so batched deliveries arrive frequently
      // enough to keep the tracking service alive and visible.
      // The actual capture rate is still controlled by _computeInterval().
      final androidInterval = _activeIntervalSeconds > 15 ? 15 : _activeIntervalSeconds;
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: _distanceFilterMeters,
        forceLocationManager: false,
        intervalDuration: Duration(seconds: androidInterval),
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

      // Restore normal notification with elapsed time
      final elapsedStr = _formatElapsedShift(now);
      FlutterForegroundTask.updateService(
        notificationTitle: elapsedStr.isNotEmpty ? 'Quart actif — $elapsedStr' : 'Suivi de position actif',
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

    // Check for stationary state (distance-based fallback)
    _checkStationaryState(position, now);

    // Skip if already capturing
    if (_isCapturing) {
      _lastPosition = position;
      return;
    }

    // Determine current interval: speed-based adaptive or distance-based fallback
    final currentInterval = _computeInterval(position);

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

  /// Compute capture interval: 10s when active, 120s when confirmed stationary.
  /// "Recently stopped" (< 5 min at same spot) keeps 10s to capture micro-stops.
  /// Only drops to 120s after 5-minute stationary confirmation.
  /// Applies thermal multiplier.
  Duration _computeInterval(Position position) {
    // 10s for all active states (moving or recently stopped).
    // 120s only after 5-minute confirmed stationary (_checkStationaryState).
    int intervalSec = _isStationary ? _stationaryIntervalSeconds : 10;

    // Apply thermal multiplier
    intervalSec *= _thermalMultiplier;

    return Duration(seconds: intervalSec);
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

    // Movement threshold must account for GPS accuracy — a 50m jump with
    // 200m accuracy is noise, not real movement. Use the worse (larger)
    // accuracy of the two positions to avoid false movement detection.
    final worstAccuracy = position.accuracy > _lastPosition!.accuracy
        ? position.accuracy
        : _lastPosition!.accuracy;
    final movementThreshold = worstAccuracy > 10 ? worstAccuracy : 10.0;

    // If moved more than the accuracy-aware threshold, reset stationary check
    if (distance > movementThreshold) {
      _isStationary = false;
      _stationaryCheckTime = now;
      _lastPosition = position;
      return;
    }

    // Only mark as stationary after 5 minutes at the same spot — this prevents
    // premature slowdown (e.g. traffic lights, brief stops) and ensures we keep
    // capturing at 15s intervals until we're certain the person has truly stopped.
    if (_stationaryCheckTime != null) {
      final stationaryDuration = now.difference(_stationaryCheckTime!);
      if (stationaryDuration.inMinutes >= 5) {
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

    // Extract extended GPS data (B4)
    final speed = position.speed >= 0 ? position.speed : null;
    final speedAccuracy = position.speedAccuracy >= 0 ? position.speedAccuracy : null;
    final heading = position.heading >= 0 ? position.heading : null;
    final headingAccuracy = position.headingAccuracy >= 0 ? position.headingAccuracy : null;
    final altitude = position.altitude != 0 ? position.altitude : null;
    final altitudeAccuracy = position.altitudeAccuracy >= 0 ? position.altitudeAccuracy : null;

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
        if (speed != null) 'speed': speed,
        if (speedAccuracy != null) 'speed_accuracy': speedAccuracy,
        if (heading != null) 'heading': heading,
        if (headingAccuracy != null) 'heading_accuracy': headingAccuracy,
        if (altitude != null) 'altitude': altitude,
        if (altitudeAccuracy != null) 'altitude_accuracy': altitudeAccuracy,
        'is_mocked': position.isMocked ? 1 : 0,
        if (_currentActivity != null) 'activity_type': _currentActivity,
      },
    });

    // Update notification with elapsed shift time
    final elapsedStr = _formatElapsedShift(now);
    final speedKmh = speed != null ? (speed * 3.6).toStringAsFixed(0) : '?';
    FlutterForegroundTask.updateService(
      notificationTitle: elapsedStr.isNotEmpty ? 'Quart actif — $elapsedStr' : 'Suivi de position actif',
      notificationText:
          'Points: $_pointCount | ${_formatTime(now)} | $speedKmh km/h${_isStationary ? ' (S)' : ''}',
    );
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  /// Format the elapsed shift duration as "2h 34m" or "45m".
  String _formatElapsedShift(DateTime now) {
    if (_clockedInAt == null) return '';
    final elapsed = now.difference(_clockedInAt!);
    final hours = elapsed.inHours;
    final minutes = elapsed.inMinutes % 60;
    if (hours > 0) {
      return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
    }
    return '${minutes}m';
  }

  void _onPositionError(dynamic error) {
    _sendDiagnostic('warn', 'Position stream error', {'error': error.toString()});
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

    // Refresh notification title with elapsed time (even without new GPS point)
    if (!_gpsLostNotified && _clockedInAt != null) {
      final elapsedStr = _formatElapsedShift(timestamp);
      FlutterForegroundTask.updateService(
        notificationTitle: 'Quart actif — $elapsedStr',
        notificationText:
            'Points: $_pointCount | ${_formatTime(timestamp)}${_isStationary ? ' (S)' : ''}',
      );
    }

    // GPS loss detection (with grace period — A5)
    _checkGpsLoss(timestamp);

    // Stream health check — detects silently dead streams
    _checkStreamHealth(timestamp);

    // Force capture when stationary and interval has passed (iOS fix)
    // iOS distance filter prevents updates when not moving
    if (_lastCaptureTime != null && _lastPosition != null) {
      final now = DateTime.now();
      final timeSinceLast = now.difference(_lastCaptureTime!);
      final currentInterval = _computeInterval(_lastPosition!);

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

    // If we never got a single position, check against start time instead.
    // Don't wait the full grace period — if 30s passed since start with zero
    // positions, the stream likely failed silently and needs recovery.
    if (lastSuccess == null) {
      if (_trackingStartedAt != null &&
          now.difference(_trackingStartedAt!) > const Duration(seconds: 30)) {
        _sendDiagnostic('warn', 'No position received 30s after start, recovering stream');
        _streamRecoveryAttempts++;
        _lastRecoveryAttemptAt = now;
        _recoverPositionStream();
      }
      return;
    }

    // Use the same threshold as GPS loss (45s) for stream health
    if (now.difference(lastSuccess) < _gpsLostThreshold) return;

    // Grace period: only inhibit recovery if we already received at least one
    // position. If we have a lastSuccess, the stream worked initially and we
    // give it time to stabilize after restart (A5).
    if (_trackingStartedAt != null &&
        now.difference(_trackingStartedAt!) < _gracePeriod) {
      return;
    }

    // Exponential backoff between recovery attempts: 1, 2, 4, 8, 15 min cap.
    // Starts at 1 min (not 2) so first recovery is faster; caps at 15 min
    // instead of 30 to keep recovery aggressive.
    final backoffMin = (1 << _streamRecoveryAttempts.clamp(0, 4)).clamp(1, 15);
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
    _sendDiagnostic('info', 'Stream recovery attempt', {
      'attempt': _streamRecoveryAttempts,
      'last_success_ago_sec': _lastSuccessfulPositionAt != null
          ? DateTime.now().difference(_lastSuccessfulPositionAt!).inSeconds
          : null,
    });

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

    // Grace period after start: don't flag GPS loss while stream stabilizes (A5)
    if (_trackingStartedAt != null &&
        now.difference(_trackingStartedAt!) < _gracePeriod) {
      return;
    }

    final elapsed = now.difference(lastSuccess);

    // 45s threshold: notify GPS lost (C1 — reduced from 90s)
    if (elapsed >= _gpsLostThreshold && !_gpsLostNotified) {
      _gpsLostNotified = true;
      _gpsGapStartedAt = lastSuccess; // Gap started when we last had GPS

      final elapsedStr = _formatElapsedShift(now);
      FlutterForegroundTask.updateService(
        notificationTitle: elapsedStr.isNotEmpty ? 'GPS PERDU — $elapsedStr' : 'GPS PERDU',
        notificationText: 'Le suivi continue mais sans points GPS',
      );
      FlutterForegroundTask.sendDataToMain({
        'type': 'gps_lost',
        'gap_started_at': lastSuccess.toUtc().toIso8601String(),
      });
    } else if (_gpsLostNotified) {
      // Update notification with elapsed shift time + lost duration
      final lostMinutes = elapsed.inMinutes;
      final elapsedStr = _formatElapsedShift(now);
      FlutterForegroundTask.updateService(
        notificationTitle: elapsedStr.isNotEmpty ? 'GPS PERDU — $elapsedStr' : 'GPS PERDU',
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
        _sendDiagnostic('debug', 'Force capture for stationary', {
          'source': 'lastKnown',
          'is_stationary': _isStationary,
        });
        _capturePosition(position, DateTime.now());
      } else if (_lastPosition != null) {
        _sendDiagnostic('debug', 'Force capture for stationary', {
          'source': 'cached',
          'is_stationary': _isStationary,
        });
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
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;

    FlutterForegroundTask.sendDataToMain({
      'type': 'stopped',
      'point_count': _pointCount,
      'is_timeout': isTimeout,
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
        _thermalMultiplier = data['thermal_multiplier'] as int? ?? _thermalMultiplier;
      } else if (command == 'activityUpdate') {
        _currentActivity = data['activity'] as String?;
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
