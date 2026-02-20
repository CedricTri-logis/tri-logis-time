import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

/// Manages UI state for background GPS tracking.
class TrackingNotifier extends StateNotifier<TrackingState> {
  final Ref _ref;
  ProviderSubscription<ShiftState>? _shiftSubscription;

  /// ID of the currently open GPS gap (if any).
  String? _activeGpsGapId;

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
        // Stream was recovered — no action needed, just log
        break;
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

    // Store in local database
    await LocalDatabase().insertGpsPoint(point);

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

    // Trigger sync check on every heartbeat (debounced by 5s delay in sync provider)
    _ref.read(syncProvider.notifier).notifyPendingData();
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
    state = state.stopTracking();
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
