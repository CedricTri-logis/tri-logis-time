import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../shared/models/diagnostic_event.dart';
import '../../../shared/services/diagnostic_logger.dart';
import '../../../shared/services/local_database.dart';
import '../../../shared/services/notification_service.dart';
import '../../shifts/models/local_gps_gap.dart';
import '../../shifts/models/local_gps_point.dart';
import '../../shifts/models/shift.dart';
import '../../shifts/providers/shift_provider.dart';
import '../../shifts/providers/sync_provider.dart';
import '../models/tracking_config.dart';
import '../models/tracking_state.dart';
import '../models/tracking_status.dart';
import '../services/background_execution_service.dart';
import '../services/background_tracking_service.dart';
import '../services/significant_location_service.dart';
import '../services/thermal_state_service.dart';
import '../../../shared/services/shift_activity_service.dart';

/// Manages UI state for background GPS tracking.
class TrackingNotifier extends StateNotifier<TrackingState> {
  final Ref _ref;
  ProviderSubscription<ShiftState>? _shiftSubscription;

  /// Guarded access to the diagnostic logger singleton.
  DiagnosticLogger? get _logger =>
      DiagnosticLogger.isInitialized ? DiagnosticLogger.instance : null;

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

  /// Whether the midnight warning notification has been shown this shift.
  bool _midnightWarningShown = false;

  /// Whether SLC is currently active (deferred activation — only after GPS loss).
  bool _significantLocationActive = false;

  /// Timer to verify that background tracking actually starts producing GPS points.
  Timer? _verificationTimer;
  DateTime? _trackingStartRequestedAt;
  int _trackingStartAttempt = 0;

  /// Current device thermal level for GPS frequency adaptation.
  ThermalLevel _currentThermalLevel = ThermalLevel.normal;
  StreamSubscription<ThermalLevel>? _thermalSubscription;

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
        // Load actual point count from local DB so the counter survives app restarts
        int pointCount = 0;
        try {
          pointCount = await LocalDatabase().getGpsPointCountForShift(shiftId);
        } catch (e) {
          _logger?.gps(Severity.error, 'Failed to load point count from DB', metadata: {'error': e.toString()});
        }
        state = state.copyWith(
          status: TrackingStatus.running,
          activeShiftId: shiftId,
          pointsCaptured: pointCount,
        );
      }
    } else {
      // Service not running at startup — if there's an active shift, restart tracking.
      // This handles the case where iOS killed the app and it's relaunched.
      // Use a short delay to let shiftProvider initialize from local DB first.
      Future.delayed(const Duration(seconds: 2), () async {
        final shift = _ref.read(shiftProvider).activeShift;
        if (shift != null && state.status != TrackingStatus.running) {
          // Calculate how long the tracking was dead
          DateTime? lastPointTime;
          try {
            final db = LocalDatabase();
            final points = await db.getGpsPointsForShift(shift.id);
            if (points.isNotEmpty) {
              lastPointTime = points.last.capturedAt; // ordered ASC, last = most recent
            }
          } catch (_) {}

          final deadDuration = lastPointTime != null
              ? DateTime.now().difference(lastPointTime)
              : null;

          _logger?.lifecycle(Severity.error, 'iOS killed app while tracking — restarting', metadata: {
            'shift_id': shift.id,
            'shift_started_at': shift.clockedInAt.toUtc().toIso8601String(),
            if (lastPointTime != null) 'last_gps_point_at': lastPointTime.toUtc().toIso8601String(),
            if (deadDuration != null) 'dead_duration_minutes': deadDuration.inMinutes,
          },);
          startTracking();
        }
      });
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
        _logger?.gps(Severity.info, 'GPS stream recovered', metadata: {'attempt': data['attempt']});
      case 'stream_recovery_failing':
        _logger?.gps(Severity.warn, 'GPS stream recovery failing', metadata: {'attempts': data['attempts'], 'gap_minutes': data['gap_minutes']});
      case 'diagnostic':
        _handleDiagnosticMessage(data);
      default:
        _logger?.lifecycle(Severity.debug, 'Unknown background message type', metadata: {'type': type});
    }
  }

  void _handleGpsLost(Map<String, dynamic> data) {
    state = state.copyWith(gpsSignalLost: true);

    // Update iOS Live Activity to show GPS lost status
    ShiftActivityService.instance.updateStatus('gps_lost');

    // SLC should already be active from clock-in, but ensure it's running
    if (!_significantLocationActive) {
      SignificantLocationService.startMonitoring();
      _significantLocationActive = true;
      _logger?.gps(Severity.warn, 'GPS lost — SLC activated as fallback');
    }

    // Start recording the gap
    _startGpsGap(data);
  }

  void _handleGpsRestored(Map<String, dynamic> data) {
    state = state.copyWith(gpsSignalLost: false);

    // Update iOS Live Activity to show active status
    ShiftActivityService.instance.updateStatus('active');

    // Deactivate SLC now that GPS stream is alive again
    if (_significantLocationActive) {
      SignificantLocationService.stopMonitoring();
      _significantLocationActive = false;
      _logger?.gps(Severity.info, 'GPS restored — SLC deactivated');
    }

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
      _logger?.gps(Severity.error, 'Failed to insert GPS point', metadata: {'error': e.toString(), 'shift_id': point.shiftId});
      // Don't return — still update UI state and trigger sync
    }

    // Cancel verification timer on first GPS point
    if (!state.trackingVerified) {
      _verificationTimer?.cancel();
      _verificationTimer = null;
      final startRequestedAt = _trackingStartRequestedAt;
      final delayMs = startRequestedAt != null
          ? DateTime.now().difference(startRequestedAt).inMilliseconds
          : null;
      _logger?.gps(
        Severity.info,
        'Tracking verified: first GPS point received',
        metadata: {
          'shift_id': point.shiftId,
          'tracking_start_attempt': _trackingStartAttempt,
          if (delayMs != null) 'first_point_delay_ms': delayMs,
          'point_accuracy': point.accuracy,
        },
      );
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
    // Sync point count from background handler to keep UI accurate after restarts
    final bgPointCount = data['point_count'] as int?;
    state = state.copyWith(
      isStationary: isStationary,
      pointsCaptured: bgPointCount != null && bgPointCount > state.pointsCaptured
          ? bgPointCount
          : null,
    );

    // Track last capture time from background handler
    final lastCapture = data['last_capture'] as String?;
    if (lastCapture != null) {
      _lastBackgroundCapture = DateTime.tryParse(lastCapture);
    }

    // Trigger sync check on every heartbeat (debounced by 5s delay in sync provider)
    _ref.read(syncProvider.notifier).notifyPendingData();

    // Check if iOS Live Activity needs restart (8h Apple limit)
    final shift = _ref.read(shiftProvider).activeShift;
    if (shift != null) {
      ShiftActivityService.instance.checkAndRestartIfNeeded(shift);
    }

    // App-level server heartbeat — independent of GPS points.
    // Sends every 3rd heartbeat (~90s) so the server knows the app is alive
    // even if GPS stream dies. Prevents false zombie cleanup.
    _heartbeatCounter++;
    if (_heartbeatCounter % 3 == 0) {
      _sendServerHeartbeat();
    }

    // GPS self-healing: if no capture in 3+ minutes, ask background to recover
    _checkGpsSelfHealing();

    // Midnight auto clock-out: warn at 23:55, detect closure after midnight
    _checkMidnightClosure();
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
      _logger?.sync(Severity.warn, 'Server heartbeat failed', metadata: {'error': e.toString()});
      _heartbeatFailures++;

      // After 10 consecutive failures (~15min), proactively check shift status
      if (_heartbeatFailures >= 10) {
        _logger?.sync(Severity.error, 'Heartbeat escalation: 10 consecutive failures', metadata: {'failure_count': _heartbeatFailures});
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
        _logger?.shift(Severity.warn, 'Shift closed by server', metadata: {'shift_id': serverId});
        _ref.read(shiftProvider.notifier).refresh();
      }
    } catch (_) {
      // Fail-open: if we can't reach the server, keep tracking
    }
  }

  /// If GPS hasn't produced a point in 2+ minutes, tell the background
  /// handler to recover its position stream. Rate-limited to once per 2 min (C2).
  /// The background handler manages its own recovery with backoff,
  /// so this is a last-resort nudge from the main isolate.
  void _checkGpsSelfHealing() {
    final lastCapture = _lastBackgroundCapture;
    if (lastCapture == null) return;

    final now = DateTime.now();
    final gap = now.difference(lastCapture);
    if (gap > const Duration(minutes: 2)) {
      // Rate-limit: don't send recovery more than once per 2 minutes
      if (_lastSelfHealingAt != null &&
          now.difference(_lastSelfHealingAt!) < const Duration(minutes: 2)) {
        return;
      }
      _logger?.gps(Severity.warn, 'GPS gap detected, requesting stream recovery', metadata: {
        'gap_seconds': gap.inSeconds,
        'last_background_capture_at': lastCapture.toUtc().toIso8601String(),
        'actual_gap_seconds': gap.inSeconds,
      },);
      FlutterForegroundTask.sendDataToTask({'command': 'recoverStream'});
      _lastSelfHealingAt = now;
    }
  }

  /// Check for midnight auto clock-out:
  /// - At 23:55–23:59, show a warning notification.
  /// - After midnight, immediately validate shift status with the server
  ///   (the server closes all shifts at midnight via pg_cron).
  void _checkMidnightClosure() {
    final now = DateTime.now();
    final hour = now.hour;
    final minute = now.minute;

    // 23:55 – 23:59: show warning (once per shift)
    if (hour == 23 && minute >= 55 && !_midnightWarningShown) {
      _midnightWarningShown = true;
      NotificationService().showMidnightWarningNotification();
      _logger?.shift(Severity.info, 'Midnight warning notification shown');
    }

    // 00:00 – 00:05: server should have closed the shift, verify immediately
    if (hour == 0 && minute < 5 && _midnightWarningShown) {
      _midnightWarningShown = false;
      NotificationService().cancelMidnightWarningNotification();
      _logger?.shift(Severity.info, 'Post-midnight shift validation triggered');
      _validateShiftStatus();
    }
  }

  /// Forward diagnostic messages from the background isolate to DiagnosticLogger.
  void _handleDiagnosticMessage(Map<String, dynamic> data) {
    if (!DiagnosticLogger.isInitialized) return;

    final categoryStr = data['category'] as String? ?? 'gps';
    final severityStr = data['severity'] as String? ?? 'info';
    final message = data['message'] as String? ?? '';
    final metadata = data['metadata'] as Map<String, dynamic>?;

    final category = EventCategory.values.firstWhere(
      (e) => e.value == categoryStr,
      orElse: () => EventCategory.gps,
    );
    final severity = Severity.values.firstWhere(
      (e) => e.value == severityStr,
      orElse: () => Severity.info,
    );

    DiagnosticLogger.instance.log(
      category: category,
      severity: severity,
      message: message,
      metadata: metadata,
    );
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

    // Auto-stop on clock out — but guard against transient null from provider rebuild.
    // When authStateChangesProvider triggers a shiftProvider rebuild (e.g. token refresh),
    // the new ShiftNotifier starts with activeShift=null before async DB load completes.
    // We must verify the shift is truly completed in SQLCipher before stopping tracking.
    if (previous?.activeShift != null && next.activeShift == null) {
      _verifyAndStopTracking(previous!.activeShift!.id);
    }
  }

  /// Verify the shift is truly completed in the local DB before stopping tracking.
  /// Prevents false stops caused by Riverpod provider rebuilds.
  Future<void> _verifyAndStopTracking(String shiftId) async {
    try {
      final shift = await LocalDatabase().getShiftById(shiftId);
      if (shift == null || shift.status == 'completed') {
        // Shift is truly gone or completed — stop tracking
        _logger?.gps(Severity.info, 'Shift confirmed completed, stopping tracking', metadata: {'shift_id': shiftId});
        stopTracking(reason: 'clock_out');
        _activeGpsGapId = null;
        _midnightWarningShown = false;
        NotificationService().cancelMidnightWarningNotification();
      } else {
        // Shift still active in DB — this was a transient provider rebuild
        _logger?.gps(Severity.warn, 'Ignoring transient shift null (shift still active in DB)', metadata: {'shift_id': shiftId, 'shift_status': shift.status});
      }
    } catch (e) {
      // If DB check fails, err on the side of stopping (fail-safe)
      _logger?.gps(Severity.error, 'DB check failed during shift verify, stopping tracking', metadata: {'error': e.toString()});
      stopTracking(reason: 'clock_out');
      _activeGpsGapId = null;
      _midnightWarningShown = false;
      NotificationService().cancelMidnightWarningNotification();
    }
  }

  /// Post-start setup shared by fresh start and restart paths.
  /// Initializes Live Activity, SLC, background execution, lifecycle observer,
  /// and thermal monitoring.
  void _onTrackingStarted({
    required Shift shift,
    required TrackingConfig trackingConfig,
  }) {
    state = state.copyWith(
      status: TrackingStatus.running,
      config: trackingConfig,
    );
    // Start iOS Live Activity (no-op on Android)
    ShiftActivityService.instance.startActivity(shift);
    // Register SLC callback and start monitoring immediately at clock-in.
    // SLC can relaunch the app after iOS terminates it (~500m movement).
    SignificantLocationService.onWokenByLocationChange =
        _onWokenByLocationChange;
    SignificantLocationService.startMonitoring();
    _significantLocationActive = true;
    // Register FGS death callback for auto-restart on resume
    BackgroundTrackingService.onForegroundServiceDied =
        _onForegroundServiceDied;
    // Start CLBackgroundActivitySession (iOS 17+, no-op on Android/older iOS)
    BackgroundExecutionService.startBackgroundSession();
    // Start lifecycle observer for beginBackgroundTask + FGS health checks
    BackgroundTrackingService.startLifecycleObserver();
    // Subscribe to thermal state changes for GPS frequency adaptation
    _startThermalMonitoring();
    // Start verification timer to detect tracking start failures
    _startTrackingVerification();
  }

  /// Start a 15-second timer to verify that background tracking is producing GPS points.
  /// If no point is received within the timeout, marks tracking as failed.
  void _startTrackingVerification() {
    _verificationTimer?.cancel();
    _verificationTimer = Timer(const Duration(seconds: 15), () {
      if (state.status == TrackingStatus.running && !state.trackingVerified) {
        state = state.copyWith(trackingStartFailed: true);
        _logger?.gps(
          Severity.error,
          'Tracking verification failed: no GPS point received within 15s',
          metadata: {'shift_id': state.activeShiftId},
        );
      }
    });
  }

  /// Handle a [TrackingResult] from either startTracking or restartTracking.
  /// Returns true if tracking is now running.
  bool _handleTrackingResult({
    required TrackingResult result,
    required Shift shift,
    required TrackingConfig trackingConfig,
    required String logAction,
  }) {
    switch (result) {
      case TrackingSuccess():
        _onTrackingStarted(shift: shift, trackingConfig: trackingConfig);
        _logger?.gps(
          Severity.info,
          'Tracking $logAction',
          metadata: {'shift_id': shift.id},
        );
        return true;
      case TrackingPermissionDenied():
        _logger?.permission(
          Severity.warn,
          'Location permission denied for tracking',
        );
        state = state.withError('Location permission required');
        return false;
      case TrackingServiceError(:final message):
        _logger?.gps(
          Severity.error,
          'Tracking service error',
          metadata: {'message': message},
        );
        state = state.withError(message);
        return false;
      case TrackingAlreadyActive():
        // Should not happen after restart, but handle gracefully
        _logger?.gps(
          Severity.warn,
          'Tracking still active after $logAction attempt',
        );
        state = state.copyWith(status: TrackingStatus.running);
        return true;
    }
  }

  /// Begin background tracking for the active shift.
  Future<void> startTracking({TrackingConfig? config}) async {
    final shiftState = _ref.read(shiftProvider);
    final shift = shiftState.activeShift;
    if (shift == null) return;
    int existingPointCount = 0;
    try {
      existingPointCount = await LocalDatabase().getGpsPointCountForShift(shift.id);
    } catch (e) {
      _logger?.gps(Severity.warn, 'Failed to load existing point count before start', metadata: {
        'shift_id': shift.id,
        'error': e.toString(),
      });
    }
    _trackingStartRequestedAt = DateTime.now();
    _trackingStartAttempt++;
    _logger?.gps(
      Severity.info,
      'startTracking invoked',
      metadata: {
        'shift_id': shift.id,
        'attempt': _trackingStartAttempt,
        'current_status': state.status.name,
        'current_active_shift_id': state.activeShiftId,
      },
    );

    // Determine if we need a restart (old shift still tracked)
    var needsRestart = false;

    if (state.status == TrackingStatus.running ||
        state.status == TrackingStatus.starting) {
      if (state.activeShiftId == shift.id) {
        // Already tracking the same shift — nothing to do
        _logger?.gps(
          Severity.debug,
          'startTracking skipped: already tracking same shift',
          metadata: {'shift_id': shift.id},
        );
        return;
      }
      // Tracking a different shift — need to restart
      needsRestart = true;
      _logger?.gps(
        Severity.warn,
        'startTracking: different shift detected, will restart',
        metadata: {
          'old_shift_id': state.activeShiftId,
          'new_shift_id': shift.id,
        },
      );
    }

    state = state.startTracking(shift.id).copyWith(pointsCaptured: existingPointCount);

    final trackingConfig = config ?? state.config;

    if (needsRestart) {
      // Stop old service, wait, then start new one
      final result = await BackgroundTrackingService.restartTracking(
        shiftId: shift.id,
        employeeId: shift.employeeId,
        clockedInAt: shift.clockedInAt,
        initialPointCount: existingPointCount,
        config: trackingConfig,
      );
      _handleTrackingResult(
        result: result,
        shift: shift,
        trackingConfig: trackingConfig,
        logAction: 'restarted (different shift)',
      );
      return;
    }

    final result = await BackgroundTrackingService.startTracking(
      shiftId: shift.id,
      employeeId: shift.employeeId,
      clockedInAt: shift.clockedInAt,
      initialPointCount: existingPointCount,
      config: trackingConfig,
    );

    switch (result) {
      case TrackingAlreadyActive():
        // Foreground service still alive from a previous shift — restart it
        _logger?.gps(
          Severity.warn,
          'Foreground service still running, restarting for new shift',
          metadata: {'shift_id': shift.id},
        );
        final restartResult = await BackgroundTrackingService.restartTracking(
          shiftId: shift.id,
          employeeId: shift.employeeId,
          clockedInAt: shift.clockedInAt,
          initialPointCount: existingPointCount,
          config: trackingConfig,
        );
        _handleTrackingResult(
          result: restartResult,
          shift: shift,
          trackingConfig: trackingConfig,
          logAction: 'restarted (service was active)',
        );
      default:
        _handleTrackingResult(
          result: result,
          shift: shift,
          trackingConfig: trackingConfig,
          logAction: 'started',
        );
    }
  }

  /// Stop background tracking.
  ///
  /// [reason] indicates why tracking stopped:
  /// - `clock_out` — user clocked out normally
  /// - `force_logout` — force-logged out by another device
  /// - `app_close` — app was closed
  /// - `shift_closed_by_server` — server closed the shift
  Future<void> stopTracking({String? reason}) async {
    _verificationTimer?.cancel();
    _verificationTimer = null;
    _trackingStartRequestedAt = null;
    _trackingStartAttempt = 0;
    _logger?.gps(Severity.info, 'Tracking stopped', metadata: {
      if (reason != null) 'reason': reason,
    },);
    await BackgroundTrackingService.stopTracking();
    // End iOS Live Activity (no-op on Android)
    ShiftActivityService.instance.endActivity();
    // Stop SLC if it was activated during GPS loss
    if (_significantLocationActive) {
      SignificantLocationService.stopMonitoring();
      _significantLocationActive = false;
    }
    // Stop CLBackgroundActivitySession
    BackgroundExecutionService.stopBackgroundSession();
    // Stop lifecycle observer and clear callbacks
    BackgroundTrackingService.onForegroundServiceDied = null;
    BackgroundTrackingService.stopLifecycleObserver();
    // Stop thermal monitoring
    _stopThermalMonitoring();
    state = state.stopTracking();
  }

  /// Called when the foreground service is detected as dead on app resume.
  /// Restarts tracking automatically (safe from foreground context on Android 12+).
  void _onForegroundServiceDied() {
    final shift = _ref.read(shiftProvider).activeShift;
    if (shift == null) return;

    _logger?.gps(Severity.error, 'Foreground service died — auto-restarting');
    state = state.copyWith(status: TrackingStatus.stopped);
    startTracking();
  }

  /// Called when iOS relaunches the app after a significant location change.
  /// Validates shift is still active on server before restarting tracking.
  Future<void> _onWokenByLocationChange() async {
    _logger?.gps(Severity.info, 'App woken by significant location change');
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
            _logger?.shift(Severity.info, 'iOS relaunch: shift already closed on server', metadata: {'shift_id': serverId});
            _ref.read(shiftProvider.notifier).refresh();
            return;
          }
        } catch (_) {
          // Network unavailable — start tracking anyway (fail-open for field workers)
          _logger?.gps(Severity.warn, 'iOS relaunch: could not validate shift, starting anyway');
        }
      }

      _logger?.gps(Severity.info, 'Restarting GPS tracking after iOS relaunch');
      // Re-create CLBackgroundActivitySession before restarting tracking
      BackgroundExecutionService.startBackgroundSession();
      startTracking();
    }
  }

  /// Start listening for thermal state changes and adapting GPS config.
  void _startThermalMonitoring() {
    _thermalSubscription?.cancel();
    _currentThermalLevel = ThermalLevel.normal;
    _thermalSubscription = ThermalStateService.levelStream.listen(
      (level) {
        if (level != _currentThermalLevel) {
          _currentThermalLevel = level;
          _applyThermalConfig(level);
        }
      },
      onError: (Object error) {
        _logger?.thermal(Severity.warn, 'Thermal stream error', metadata: {'error': error.toString()});
      },
    );
  }

  /// Stop thermal monitoring and reset to normal.
  void _stopThermalMonitoring() {
    _thermalSubscription?.cancel();
    _thermalSubscription = null;
    _currentThermalLevel = ThermalLevel.normal;
  }

  /// Apply GPS config changes based on thermal level.
  /// Uses a multiplier approach: speed-based intervals are multiplied by the
  /// thermal factor, so adaptive frequency is preserved at all thermal levels.
  void _applyThermalConfig(ThermalLevel level) {
    final thermalMultiplier = switch (level) {
      ThermalLevel.normal => 1,
      ThermalLevel.elevated => 2,
      ThermalLevel.critical => 4,
    };

    _logger?.thermal(Severity.info, 'Thermal adaptation applied', metadata: {
      'level': level.name,
      'multiplier': thermalMultiplier,
    },);

    if (state.status == TrackingStatus.running) {
      FlutterForegroundTask.sendDataToTask({
        'command': 'updateConfig',
        'active_interval_seconds': state.config.activeIntervalSeconds,
        'stationary_interval_seconds': state.config.stationaryIntervalSeconds,
        'distance_filter_meters': state.config.distanceFilterMeters,
        'thermal_multiplier': thermalMultiplier,
      });
    }
  }

  /// Update tracking configuration.
  void updateConfig(TrackingConfig config) {
    state = state.copyWith(config: config);

    // Send config to background task if running
    if (state.status == TrackingStatus.running) {
      final thermalMultiplier = switch (_currentThermalLevel) {
        ThermalLevel.normal => 1,
        ThermalLevel.elevated => 2,
        ThermalLevel.critical => 4,
      };
      FlutterForegroundTask.sendDataToTask({
        'command': 'updateConfig',
        'active_interval_seconds': config.activeIntervalSeconds,
        'stationary_interval_seconds': config.stationaryIntervalSeconds,
        'distance_filter_meters': config.distanceFilterMeters,
        'thermal_multiplier': thermalMultiplier,
      });
    }
  }

  /// Sync state with actual service status.
  Future<void> refreshState() async {
    final isRunning = await BackgroundTrackingService.isTracking;

    if (isRunning) {
      // Request status from background task
      FlutterForegroundTask.sendDataToTask({'command': 'getStatus'});
    } else {
      // Service is not running — check if there's an active shift that needs tracking
      final shift = _ref.read(shiftProvider).activeShift;
      if (shift != null) {
        // Active shift but tracking died (iOS killed the app/service).
        // Restart tracking automatically.
        _logger?.gps(Severity.error, 'Service dead but shift active — restarting');
        state = state.copyWith(status: TrackingStatus.stopped);
        startTracking();
      } else if (state.status == TrackingStatus.running) {
        // No active shift and no service — clean up state
        state = state.stopTracking();
      }
    }
  }

  /// Clear error state.
  void clearError() {
    state = state.copyWith(clearError: true);
  }

  @override
  void dispose() {
    _verificationTimer?.cancel();
    FlutterForegroundTask.removeTaskDataCallback(_handleTaskData);
    _shiftSubscription?.close();
    _thermalSubscription?.cancel();
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
