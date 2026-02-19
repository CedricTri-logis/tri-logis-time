import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/services/local_database.dart';
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
        state = state.copyWith(gpsSignalLost: true);
      case 'gps_restored':
        state = state.copyWith(gpsSignalLost: false);
      case 'gps_timeout':
        _handleGpsTimeout();
    }
  }

  void _handleGpsTimeout() {
    // Auto clock-out due to GPS loss timeout
    state = state.copyWith(gpsSignalLost: true);
    _ref.read(shiftProvider.notifier).clockOut();
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
      startTracking();
    }

    // Auto-stop on clock out
    if (previous?.activeShift != null && next.activeShift == null) {
      stopTracking();
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
