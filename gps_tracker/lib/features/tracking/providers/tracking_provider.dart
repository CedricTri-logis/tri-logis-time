import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../shared/services/local_database.dart';
import '../../../shared/services/notification_service.dart';
import '../../shifts/models/local_gps_gap.dart';
import '../../shifts/models/local_gps_point.dart';
import '../../shifts/providers/shift_provider.dart';
import '../../shifts/providers/sync_provider.dart';
import '../models/tracking_config.dart';
import '../models/tracking_state.dart';
import '../models/tracking_status.dart';
import '../services/background_tracking_service.dart';
import '../services/significant_location_service.dart';

/// Manages UI state for background GPS tracking.
class TrackingNotifier extends StateNotifier<TrackingState> {
  final Ref _ref;
  ProviderSubscription<ShiftState>? _shiftSubscription;

  /// ID of the currently open GPS gap (if any).
  String? _activeGpsGapId;

  /// Counter for throttling server heartbeat (every 3rd background heartbeat = ~90s).
  int _heartbeatCounter = 0;

  /// Last time the background handler reported a GPS capture, for self-healing.
  DateTime? _lastBackgroundCapture;

  /// Last time we sent a recoverStream command to the background handler.
  DateTime? _lastSelfHealingAt;

  /// Consecutive server heartbeat failures (for shift validation escalation).
  int _heartbeatFailures = 0;

  TrackingNotifier(this._ref) : super(const TrackingState()) {
    _initializeListeners();
  }

  void _initializeListeners() {
    // Listen for data from background task using addTaskDataCallback
    FlutterForegroundTask.addTaskDataCallback(_handleTaskData);

    // Listen for shift state changes
    _shiftSubscription = _ref.listen<ShiftState>(
      shiftProvider,
      (previous, next) {
        _handleShiftStateChange(previous, next);
      },
    );

    // Check if service is already running (app restart scenario)
    _refreshServiceState();
  }

  Future<void> _refreshServiceState() async {
    final isRunning = await BackgroundTrackingService.isTracking;
    if (isRunning) {
      final shiftId = await FlutterForegroundTask.getData<String>(key: 'shift_id');
      if (shiftId != null) {
        state = state.copyWith(
          status: TrackingStatus.running,
          activeShiftId: shiftId,
        );
      }
    }
  }

  void _handleTaskData(dynamic data) {
    if (data is! Map<String, dynamic>) return;

    final type = data['type'];
    switch (type) {
      case 'position':
        _handlePositionUpdate(data['point'] as Map<String, dynamic>);
      case 'error':
        _handleTrackingError(data['message'] as String);
      case 'heartbeat':
        _handleHeartbeat(data);
      case 'started':
        state = state.copyWith(
          status: TrackingStatus.running,
          activeShiftId: data['shift_id'] as String?,
        );
      case 'stopped':
        state = state.stopTracking();
      case 'status':
        _handleStatusUpdate(data);
      case 'gps_lost':
        _handleGpsLost(data);
      case 'gps_restored':
        _handleGpsRestored(data);
      case 'stream_recovered':
        debugPrint('[Tracking] GPS stream recovered (attempt ${data['attempt']})');
      case 'stream_recovery_failing':
        debugPrint('[Tracking] GPS stream recovery struggling: '
            '${data['attempts']} attempts, ${data['gap_minutes']}min gap');
      default:
        debugPrint('[Tracking] Unknown message type: $type');
    }
  }

  void _handleGpsLost(Map<String, dynamic> data) {
    state = state.copyWith(gpsSignalLost: true);

    // Show local notification
    NotificationService().showGpsLostNotification();

    // Start recording the gap
    _startGpsGap(data);
  }

  void _handleGpsRestored(Map<String, dynamic> data) {
    state = state.copyWith(gpsSignalLost: false);

    // Cancel the persistent GPS lost notification and show brief restore
    NotificationService().cancelGpsLostNotification();
    NotificationService().showGpsRestoredNotification();

    // Close the GPS gap record
    _closeGpsGap(data);
  }

  /// Open a GPS gap record in the local database.
  Future<void> _startGpsGap(Map<String, dynamic> data) async {
    final shiftId = state.activeShiftId;
    if (shiftId == null) return;

    final shiftState = _ref.read(shiftProvider);
    final employeeId = shiftState.activeShift?.employeeId;
    if (employeeId == null) return;

    final gapId = const Uuid().v4();
    _activeGpsGapId = gapId;

    final startedAtStr = data['gap_started_at'] as String?;
    final startedAt = startedAtStr != null
        ? DateTime.parse(startedAtStr)
        : DateTime.now().toUtc();

    final gap = LocalGpsGap(
      id: gapId,
      shiftId: shiftId,
      employeeId: employeeId,
      startedAt: startedAt,
      reason: 'signal_loss',
    );

    try {
      await LocalDatabase().insertGpsGap(gap);
    } catch (_) {
      // Best-effort — don't crash tracking if gap insert fails
    }
  }

  /// Close the active GPS gap record.
  Future<void> _closeGpsGap(Map<String, dynamic> data) async {
    final gapId = _activeGpsGapId;
    if (gapId == null) return;
    _activeGpsGapId = null;

    final endedAtStr = data['gap_ended_at'] as String?;
    final endedAt = endedAtStr != null
        ? DateTime.parse(endedAtStr)
        : DateTime.now().toUtc();

    try {
      await LocalDatabase().closeGpsGap(gapId, endedAt);
    } catch (_) {
      // Best-effort
    }

    // Trigger sync to upload the gap
    _ref.read(syncProvider.notifier).notifyPendingData();
  }

  Future<void> _handlePositionUpdate(Map<String, dynamic> pointData) async {
    final point = LocalGpsPoint.fromMap(pointData);

    try {
      // Store in local database
      await LocalDatabase().insertGpsPoint(point);
    } catch (e) {
      debugPrint('[Tracking] ERROR inserting GPS point: $e');
      // Don't return — still update UI state and trigger sync
    }

    // Update state
    state = state.recordPoint(
      latitude: point.latitude,
      longitude: point.longitude,
      accuracy: point.accuracy,
      capturedAt: point.capturedAt,
    );

    // Trigger sync if connected
    _ref.read(syncProvider.notifier).notifyPendingData();
  }

  void _handleTrackingError(String message) {
    state = state.withError(message);
  }

  void _handleHeartbeat(Map<String, dynamic> data) {
    final isStationary = data['is_stationary'] as bool? ?? false;
    state = state.copyWith(isStationary: isStationary);

    // Track last capture time from background handler
    final lastCapture = data['last_capture'] as String?;
    if (lastCapture != null) {
      _lastBackgroundCapture = DateTime.tryParse(lastCapture);
    }

    // Trigger sync check on every heartbeat (debounced by 5s delay in sync provider)
    _ref.read(syncProvider.notifier).notifyPendingData();

    // App-level server heartbeat — independent of GPS points.
    // Sends every 3rd heartbeat (~90s) so the server knows the app is alive
    // even if GPS stream dies. Prevents false zombie cleanup.
    _heartbeatCounter++;
    if (_heartbeatCounter % 3 == 0) {
      _sendServerHeartbeat();
    }

    // GPS self-healing: if no capture in 3+ minutes, ask background to recover
    _checkGpsSelfHealing();
  }

  /// Ping the server to update shift heartbeat, independent of GPS points.
  Future<void> _sendServerHeartbeat() async {
    final shift = _ref.read(shiftProvider).activeShift;
    final serverId = shift?.serverId;
    if (serverId == null) return;

    try {
      await Supabase.instance.client.rpc<void>(
        'ping_shift_heartbeat',
        params: {'p_shift_id': serverId},
      );
      _heartbeatFailures = 0;

      // Periodic shift validation: every 10th successful heartbeat (~5min)
      if (_heartbeatCounter % 10 == 0) {
        _validateShiftStatus();
      }
    } catch (e) {
      debugPrint('[Tracking] Server heartbeat failed: $e');
      _heartbeatFailures++;

      // After 10 consecutive failures (~15min), proactively check shift status
      if (_heartbeatFailures >= 10) {
        debugPrint('[Tracking] 10 consecutive heartbeat failures, validating shift status');
        _validateShiftStatus();
        _heartbeatFailures = 0; // Reset to avoid spamming
      }
    }
  }

  /// Lightweight check to confirm the shift is still active on the server.
  /// If the server says it's completed (e.g. zombie cleanup), refresh local state.
  Future<void> _validateShiftStatus() async {
    final shift = _ref.read(shiftProvider).activeShift;
    final serverId = shift?.serverId;
    if (serverId == null) return;

    try {
      final result = await Supabase.instance.client
          .from('shifts')
          .select('status')
          .eq('id', serverId)
          .maybeSingle();
      if (result != null && result['status'] == 'completed') {
        debugPrint('[Tracking] Server says shift is completed, refreshing local state');
        _ref.read(shiftProvider.notifier).refresh();
      }
    } catch (_) {
      // Fail-open: if we can't reach the server, keep tracking
    }
  }

  /// If GPS hasn't produced a point in 10+ minutes, tell the background
  /// handler to recover its position stream. Rate-limited to once per 10 min.
  /// The background handler manages its own recovery with backoff (Fix 4),
  /// so this is a last-resort nudge from the main isolate.
  void _checkGpsSelfHealing() {
    final lastCapture = _lastBackgroundCapture;
    if (lastCapture == null) return;

    final now = DateTime.now();
    final gap = now.difference(lastCapture);
    if (gap > const Duration(minutes: 10)) {
      // Rate-limit: don't send recovery more than once per 10 minutes
      if (_lastSelfHealingAt != null &&
          now.difference(_lastSelfHealingAt!) < const Duration(minutes: 10)) {
        return;
      }
      debugPrint('[Tracking] GPS gap detected (${gap.inSeconds}s), '
          'requesting stream recovery from main isolate');
      FlutterForegroundTask.sendDataToTask({'command': 'recoverStream'});
      _lastSelfHealingAt = now;
    }
  }

  void _handleStatusUpdate(Map<String, dynamic> data) {
    final pointCount = data['point_count'] as int? ?? state.pointsCaptured;
    final isStationary = data['is_stationary'] as bool? ?? state.isStationary;

    state = state.copyWith(
      pointsCaptured: pointCount,
      isStationary: isStationary,
    );
  }

  void _handleShiftStateChange(ShiftState? previous, ShiftState next) {
    // Auto-start on clock in
    if (previous?.activeShift == null && next.activeShift != null) {
      // Request notification permission at clock-in
      NotificationService().requestPermission();
      startTracking();
    }

    // Auto-stop on clock out
    if (previous?.activeShift != null && next.activeShift == null) {
      stopTracking();
      // Clean up any active GPS gap and notifications
      _activeGpsGapId = null;
      NotificationService().cancelGpsLostNotification();
    }
  }

  /// Begin background tracking for the active shift.
  Future<void> startTracking({TrackingConfig? config}) async {
    final shiftState = _ref.read(shiftProvider);
    final shift = shiftState.activeShift;
    if (shift == null) return;

    // Don't start if already tracking
    if (state.status == TrackingStatus.running ||
        state.status == TrackingStatus.starting) {
      return;
    }

    state = state.startTracking(shift.id);

    final trackingConfig = config ?? state.config;
    final result = await BackgroundTrackingService.startTracking(
      shiftId: shift.id,
      employeeId: shift.employeeId,
      config: trackingConfig,
    );

    switch (result) {
      case TrackingSuccess():
        state = state.copyWith(
          status: TrackingStatus.running,
          config: trackingConfig,
        );
        // Start iOS significant location change monitoring as safety net
        SignificantLocationService.onWokenByLocationChange = _onWokenByLocationChange;
        SignificantLocationService.startMonitoring();
      case TrackingPermissionDenied():
        state = state.withError('Location permission required');
      case TrackingServiceError(:final message):
        state = state.withError(message);
      case TrackingAlreadyActive():
        state = state.copyWith(status: TrackingStatus.running);
    }
  }

  /// Stop background tracking.
  Future<void> stopTracking() async {
    await BackgroundTrackingService.stopTracking();
    SignificantLocationService.stopMonitoring();
    state = state.stopTracking();
  }

  /// Called when iOS relaunches the app after a significant location change.
  /// Validates shift is still active on server before restarting tracking.
  Future<void> _onWokenByLocationChange() async {
    debugPrint('[Tracking] App woken by significant location change');
    if (state.status != TrackingStatus.running) {
      final shift = _ref.read(shiftProvider).activeShift;
      if (shift == null) return;

      // Check with server if shift is still active (if we have a server ID)
      final serverId = shift.serverId;
      if (serverId != null) {
        try {
          final result = await Supabase.instance.client
              .from('shifts')
              .select('status')
              .eq('id', serverId)
              .maybeSingle();
          if (result != null && result['status'] == 'completed') {
            debugPrint('[Tracking] iOS relaunch: shift already closed on server, cleaning up');
            _ref.read(shiftProvider.notifier).refresh();
            return;
          }
        } catch (_) {
          // Network unavailable — start tracking anyway (fail-open for field workers)
          debugPrint('[Tracking] iOS relaunch: could not validate shift, starting anyway');
        }
      }

      debugPrint('[Tracking] Restarting GPS tracking after iOS relaunch');
      startTracking();
    }
  }

  /// Update tracking configuration.
  void updateConfig(TrackingConfig config) {
    state = state.copyWith(config: config);

    // Send config to background task if running
    if (state.status == TrackingStatus.running) {
      FlutterForegroundTask.sendDataToTask({
        'command': 'updateConfig',
        'active_interval_seconds': config.activeIntervalSeconds,
        'stationary_interval_seconds': config.stationaryIntervalSeconds,
        'distance_filter_meters': config.distanceFilterMeters,
      });
    }
  }

  /// Sync state with actual service status.
  Future<void> refreshState() async {
    final isRunning = await BackgroundTrackingService.isTracking;

    if (isRunning) {
      // Request status from background task
      FlutterForegroundTask.sendDataToTask({'command': 'getStatus'});
    } else if (state.status == TrackingStatus.running) {
      // Service stopped unexpectedly
      state = state.stopTracking();
    }
  }

  /// Clear error state.
  void clearError() {
    state = state.copyWith(clearError: true);
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_handleTaskData);
    _shiftSubscription?.close();
    super.dispose();
  }
}

/// Provider for tracking state management.
final trackingProvider =
    StateNotifierProvider<TrackingNotifier, TrackingState>((ref) {
  return TrackingNotifier(ref);
});

/// Provider for checking if tracking is active.
final isTrackingProvider = Provider<bool>((ref) {
  return ref.watch(trackingProvider.select((s) => s.isTracking));
});

/// Provider for tracking status.
final trackingStatusProvider = Provider<TrackingStatus>((ref) {
  return ref.watch(trackingProvider.select((s) => s.status));
});

/// Provider for last position.
final lastPositionProvider =
    Provider<({double? lat, double? lng, DateTime? time})>((ref) {
  final state = ref.watch(trackingProvider);
  return (
    lat: state.lastLatitude,
    lng: state.lastLongitude,
    time: state.lastCaptureTime,
  );
});

/// Provider for points captured count.
final pointsCapturedProvider = Provider<int>((ref) {
  return ref.watch(trackingProvider.select((s) => s.pointsCaptured));
});

/// Provider for stationary state.
final isStationaryProvider = Provider<bool>((ref) {
  return ref.watch(trackingProvider.select((s) => s.isStationary));
});

/// Provider for GPS signal lost state (background detection).
final gpsSignalLostProvider = Provider<bool>((ref) {
  return ref.watch(trackingProvider.select((s) => s.gpsSignalLost));
});
