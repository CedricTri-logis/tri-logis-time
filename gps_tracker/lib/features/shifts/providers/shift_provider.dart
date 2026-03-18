import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:uuid/uuid.dart';

import '../../../shared/models/diagnostic_event.dart';
import '../../../shared/providers/supabase_provider.dart';
import '../../../shared/services/diagnostic_logger.dart';
import '../../../shared/services/local_database.dart';
import '../../../shared/services/realtime_service.dart';
import '../../cleaning/providers/cleaning_session_provider.dart';
import '../../maintenance/providers/maintenance_provider.dart';
import '../../work_sessions/providers/work_session_provider.dart';
import '../../../shared/services/shift_activity_service.dart';
import '../models/geo_point.dart';
import '../models/local_gps_point.dart';
import '../models/local_shift.dart';
import '../models/shift.dart';
import '../../auth/services/device_info_service.dart';
import '../../tracking/providers/gps_health_guard_provider.dart';
import '../../tracking/providers/tracking_provider.dart';
import '../../tracking/services/android_battery_health_service.dart';
import '../../tracking/services/background_tracking_service.dart';
import '../providers/sync_provider.dart';
import '../services/shift_service.dart';

/// Provider for the LocalDatabase instance.
final localDatabaseProvider = Provider<LocalDatabase>((ref) {
  return LocalDatabase();
});

/// Provider for ShiftService.
final shiftServiceProvider = Provider<ShiftService>((ref) {
  final supabase = ref.watch(supabaseClientProvider);
  final localDb = ref.watch(localDatabaseProvider);
  return ShiftService(supabase, localDb);
});

/// State for shift operations.
class ShiftState {
  final Shift? activeShift;
  final bool isLoading;
  final String? error;
  final bool isClockingIn;
  final bool isClockingOut;
  final bool versionTooOld;
  final bool isStartingLunch;
  final bool isEndingLunch;

  const ShiftState({
    this.activeShift,
    this.isLoading = false,
    this.error,
    this.isClockingIn = false,
    this.isClockingOut = false,
    this.versionTooOld = false,
    this.isStartingLunch = false,
    this.isEndingLunch = false,
  });

  ShiftState copyWith({
    Shift? activeShift,
    bool? isLoading,
    String? error,
    bool? isClockingIn,
    bool? isClockingOut,
    bool? versionTooOld,
    bool? isStartingLunch,
    bool? isEndingLunch,
    bool clearActiveShift = false,
    bool clearError = false,
  }) {
    return ShiftState(
      activeShift: clearActiveShift ? null : (activeShift ?? this.activeShift),
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      isClockingIn: isClockingIn ?? this.isClockingIn,
      isClockingOut: isClockingOut ?? this.isClockingOut,
      versionTooOld: clearError ? false : (versionTooOld ?? this.versionTooOld),
      isStartingLunch: isStartingLunch ?? this.isStartingLunch,
      isEndingLunch: isEndingLunch ?? this.isEndingLunch,
    );
  }
}

/// Notifier for managing active shift state.
///
/// Uses a dual-layer approach for detecting server-side shift closures:
/// 1. Realtime WebSocket for instant detection (~1-2s)
/// 2. Polling every 60s + check on app resume as fallback
class ShiftNotifier extends StateNotifier<ShiftState>
    with WidgetsBindingObserver {
  final ShiftService _shiftService;
  final Ref _ref;
  Timer? _serverCheckTimer;
  Timer? _tokenRefreshTimer;

  DiagnosticLogger? get _logger =>
      DiagnosticLogger.isInitialized ? DiagnosticLogger.instance : null;

  ShiftNotifier(this._shiftService, this._ref) : super(const ShiftState()) {
    WidgetsBinding.instance.addObserver(this);
    _loadActiveShift();
    _setupRealtimeListener();
    _startServerShiftCheck();
  }

  /// Listen to Realtime shift updates from the server.
  ///
  /// Detects when a shift is closed server-side (admin action, zombie cleanup)
  /// and updates local state accordingly.
  void _setupRealtimeListener() {
    final realtimeService = _ref.read(realtimeServiceProvider);
    realtimeService.onShiftChanged = (newRecord) {
      _handleServerShiftUpdate(newRecord);
    };
  }

  void _handleServerShiftUpdate(Map<String, dynamic> record) {
    final activeShift = state.activeShift;
    if (activeShift == null) return;

    final newStatus = record['status'] as String?;
    final shiftId = record['id'] as String?;
    final clockOutReason = record['clock_out_reason'] as String?;
    final workBodyId = record['work_body_id'] as String?;

    // If the active shift was closed server-side
    if (shiftId == activeShift.serverId && newStatus == 'completed') {
      // Lunch transition — do NOT close shift, transition to new segment
      if (clockOutReason == 'lunch' || clockOutReason == 'lunch_end') {
        if (workBodyId != null) {
          _handleLunchTransition(workBodyId);
        }
        return;
      }

      final reason = clockOutReason ?? 'server_closed';
      _logger?.shift(Severity.warn, 'Shift closed by server', metadata: {
        'shift_id': shiftId,
        'reason': reason,
        'source': 'realtime',
      },);
      _closeShiftLocally(activeShift, reason);
    }

    // INSERT event: a new segment was created with the same work_body_id
    if (newStatus == 'active' && workBodyId != null) {
      final activeWorkBodyId = activeShift.workBodyId;
      if (activeWorkBodyId != null && workBodyId == activeWorkBodyId && shiftId != activeShift.serverId) {
        _handleLunchTransition(workBodyId);
      }
    }
  }

  /// Fetch the active sibling segment after a lunch transition.
  Future<void> _handleLunchTransition(String workBodyId) async {
    try {
      final client = _ref.read(supabaseClientProvider);
      final response = await client
          .from('shifts')
          .select()
          .eq('work_body_id', workBodyId)
          .eq('status', 'active')
          .maybeSingle();

      if (response != null) {
        final newShift = Shift.fromJson(response);

        // Save locally
        final localDb = _ref.read(localDatabaseProvider);
        final localSegment = LocalShift(
          id: newShift.id,
          employeeId: newShift.employeeId,
          clockedInAt: newShift.clockedInAt,
          status: 'active',
          syncStatus: 'synced',
          serverId: newShift.id,
          workBodyId: newShift.workBodyId,
          isLunch: newShift.isLunch,
          shiftType: newShift.shiftType.toJson(),
          createdAt: newShift.createdAt,
          updatedAt: newShift.updatedAt,
        );
        await localDb.insertShiftSegment(localSegment);

        state = state.copyWith(activeShift: newShift);

        // Update Live Activity and GPS based on new segment type
        if (newShift.isLunch) {
          await _ref.read(trackingProvider.notifier).pauseForLunch();
          ShiftActivityService.instance.updateStatus('lunch');
        } else {
          await _ref.read(trackingProvider.notifier).startTracking();
          ShiftActivityService.instance.updateStatus('active');
        }
      }
    } catch (e) {
      _logger?.shift(Severity.error, 'Failed to handle lunch transition', metadata: {
        'work_body_id': workBodyId,
        'error': e.toString(),
      });
    }
  }

  /// Start periodic server-side shift status checks.
  ///
  /// Mirrors the pattern used by DeviceSessionNotifier: polls every 60 seconds
  /// and checks on app resume, to catch server-side closures missed by Realtime
  /// (e.g. phone sleeping at midnight, WebSocket disconnected).
  void _startServerShiftCheck() {
    // Initial check after 10 seconds (let auth and shift load settle)
    Future.delayed(const Duration(seconds: 10), () {
      if (mounted) _checkServerShiftStatus();
    });

    // Poll every 60 seconds
    _serverCheckTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) _checkServerShiftStatus();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _logger?.shift(Severity.debug, 'App resumed, checking server shift status');
      // On iOS, Dart timers don't fire while suspended. The token refresh
      // timer (50 min) may not have fired for hours. Force a refresh before
      // any server queries to avoid stale JWT causing false "not found".
      _ensureFreshToken(thresholdMinutes: 30).then((_) {
        if (mounted) _checkServerShiftStatus();
      });
    }
  }

  /// Query the server to verify the active shift is still open.
  ///
  /// If the local DB thinks a shift is active but the server says it's
  /// completed (midnight cleanup, admin action, dashboard close), update
  /// local state to match.
  ///
  /// IMPORTANT: When the JWT is expired or the session is invalid, RLS
  /// silently returns an empty result (not a 403 error). This means
  /// `.maybeSingle()` returns null even though the shift still exists.
  /// We guard against this false positive by verifying the session is
  /// still valid before concluding "server_not_found".
  Future<void> _checkServerShiftStatus() async {
    final activeShift = state.activeShift;
    if (activeShift == null) return;

    final serverId = activeShift.serverId;
    if (serverId == null) return; // Not synced yet, skip

    try {
      final client = _ref.read(supabaseClientProvider);
      if (client.auth.currentUser == null) return;

      // Proactively refresh the token if it's close to expiry.
      // This prevents the query from running with an expired JWT,
      // which would cause RLS to return empty results.
      //
      // IMPORTANT: If the refresh fails (e.g. app was in iOS background
      // for hours and timer-based refresh never fired), we must NOT
      // proceed — an expired JWT causes RLS to silently return empty
      // results, leading to a false "server_not_found" closure.
      final tokenOk = await _ensureFreshToken(thresholdMinutes: 5);
      if (!tokenOk) {
        _logger?.shift(Severity.warn, 'Server shift check: skipping — token refresh failed', metadata: {
          'shift_id': serverId,
        },);
        return;
      }

      final response = await client
          .from('shifts')
          .select('id, status, clock_out_reason, work_body_id')
          .eq('id', serverId)
          .maybeSingle();

      if (response == null) {
        // Before closing the shift, verify that the null response is
        // genuinely "not found" and not an auth/RLS issue. If the session
        // is invalid, auth.uid() is null and RLS returns empty results.
        final session = client.auth.currentSession;
        if (session == null) {
          _logger?.shift(Severity.warn, 'Server shift check: null response but session is null — skipping (auth issue)', metadata: {
            'shift_id': serverId,
          },);
          return;
        }

        final expiresAt = session.expiresAt;
        if (expiresAt != null) {
          final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          if (nowEpoch >= expiresAt) {
            _logger?.shift(Severity.warn, 'Server shift check: null response but JWT expired — skipping (auth issue)', metadata: {
              'shift_id': serverId,
              'expired_seconds_ago': nowEpoch - expiresAt,
            },);
            // Try to refresh for next cycle
            _ensureFreshToken(thresholdMinutes: 60);
            return;
          }
        }

        // Session looks valid but shift was not found. Retry once with
        // a forced token refresh to rule out stale JWT edge cases (e.g.
        // iOS background where the cached session object has a future
        // expiresAt but the actual JWT was never refreshed server-side).
        _logger?.shift(Severity.info, 'Server shift check: null response with valid session — retrying with forced refresh', metadata: {
          'shift_id': serverId,
        },);
        try {
          await _ref.read(authServiceProvider).refreshSession(thresholdMinutes: 0);
          final retryResponse = await client
              .from('shifts')
              .select('id, status, clock_out_reason, work_body_id')
              .eq('id', serverId)
              .maybeSingle();

          if (retryResponse != null) {
            // Token was stale — shift actually exists. Process normally.
            _logger?.shift(Severity.warn, 'Server shift check: shift found after token refresh (stale JWT was the issue)', metadata: {
              'shift_id': serverId,
            },);
            final serverStatus = retryResponse['status'] as String?;
            if (serverStatus == 'completed') {
              final reason = retryResponse['clock_out_reason'] as String? ?? 'server_closed';
              // Lunch transition — do NOT close shift
              if (reason == 'lunch' || reason == 'lunch_end') {
                final workBodyId = retryResponse['work_body_id'] as String?;
                if (workBodyId != null) {
                  await _handleLunchTransition(workBodyId);
                }
                return;
              }
              _logger?.shift(Severity.warn, 'Shift closed by server', metadata: {
                'shift_id': serverId,
                'reason': reason,
                'source': 'polling_retry',
              },);
              _closeShiftLocally(activeShift, reason);
            }
            return;
          }
        } catch (e) {
          // Retry refresh failed — fail-open, don't close the shift
          _logger?.shift(Severity.warn, 'Server shift check: retry refresh failed — skipping', metadata: {
            'shift_id': serverId,
            'error': e.toString(),
          },);
          return;
        }

        // Still null after fresh token — shift is genuinely not found
        _logger?.shift(Severity.warn, 'Shift closed by server', metadata: {
          'shift_id': serverId,
          'reason': 'server_not_found',
          'source': 'polling',
        },);
        _closeShiftLocally(activeShift, 'server_not_found');
        return;
      }

      final serverStatus = response['status'] as String?;
      if (serverStatus == 'completed') {
        final reason = response['clock_out_reason'] as String? ?? 'server_closed';
        // Lunch transition — do NOT close shift
        if (reason == 'lunch' || reason == 'lunch_end') {
          final workBodyId = response['work_body_id'] as String?;
          if (workBodyId != null) {
            await _handleLunchTransition(workBodyId);
          }
          return;
        }
        _logger?.shift(Severity.warn, 'Shift closed by server', metadata: {
          'shift_id': serverId,
          'reason': reason,
          'source': 'polling',
        },);
        _closeShiftLocally(activeShift, reason);
      }
    } catch (e) {
      // Fail-open: keep local state if we can't reach the server
      _logger?.shift(Severity.warn, 'Server shift check failed', metadata: {
        'shift_id': serverId,
        'error': e.toString(),
      },);
    }
  }

  /// Close the shift in both local DB and in-memory state.
  Future<void> _closeShiftLocally(Shift shift, String reason) async {
    _stopTokenRefreshTimer();

    // End iOS Live Activity (server-side closures: midnight cleanup, admin, zombie)
    ShiftActivityService.instance.endActivity();

    // No lunch cleanup needed — lunch is now a shift segment, not a separate entity

    // Update SQLite so the closure persists across app restarts
    try {
      final localDb = _ref.read(localDatabaseProvider);
      await localDb.updateShiftClockOut(
        shiftId: shift.id,
        clockedOutAt: DateTime.now().toUtc(),
        reason: reason,
      );
      // Mark as synced since the server already knows about the closure
      await localDb.markShiftSynced(shift.id);
    } catch (e) {
      _logger?.shift(Severity.error, 'Failed to update local DB on shift close', metadata: {
        'shift_id': shift.id,
        'reason': reason,
        'error': e.toString(),
      },);
    }

    _logger?.setShiftId(null);

    // Update in-memory state
    state = state.copyWith(clearActiveShift: true);
  }

  /// Load the current active shift, reconciling with server state.
  ///
  /// On first load after startup/login, queries the server to detect
  /// orphaned shifts (app reinstalled, server-side closure missed).
  /// Fail-open: if server unreachable, uses local state only.
  Future<void> _loadActiveShift() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final reconciledShift = await _shiftService.reconcileShiftState();
      final shift = reconciledShift?.toShift();

      if (shift != null) {
        _logger?.shift(Severity.info, 'Shift reconciled', metadata: {
          'shift_id': shift.id,
          'server_id': shift.serverId,
          'status': shift.status.toJson(),
        },);

        // Post-kill restart diagnostic: if we have an active shift but
        // the foreground service is dead, the app was killed and restarted.
        if (defaultTargetPlatform == TargetPlatform.android) {
          _logPostKillDiagnostic(shift);
        }
      }

      state = state.copyWith(
        activeShift: shift,
        isLoading: false,
        clearActiveShift: shift == null,
      );

      // If resuming an active shift, start token refresh timer
      if (shift != null) {
        _startTokenRefreshTimer();

        // Restore lunch state if app was killed during offline lunch
        if (reconciledShift != null &&
            reconciledShift.syncStatus == 'lunchPending' &&
            reconciledShift.lunchStartedAt != null) {
          final lunchShift = shift.copyWith(isLunch: true);
          state = state.copyWith(activeShift: lunchShift);
          await _ref.read(trackingProvider.notifier).pauseForLunch();
          ShiftActivityService.instance.updateStatus('lunch');
        } else if (shift.isLunch) {
          // Shift itself is a lunch segment (from server)
          await _ref.read(trackingProvider.notifier).pauseForLunch();
          ShiftActivityService.instance.updateStatus('lunch');
        }
      }
    } catch (e) {
      _logger?.shift(Severity.error, 'Shift reconciliation failed', metadata: {
        'error': e.toString(),
      },);
      // Fallback: load local state only
      try {
        final shift = await _shiftService.getActiveShift();
        state = state.copyWith(
          activeShift: shift,
          isLoading: false,
          clearActiveShift: shift == null,
        );
      } catch (_) {
        state = state.copyWith(
          isLoading: false,
          error: 'Failed to load active shift',
        );
      }
    }
  }

  /// Refresh the active shift state.
  Future<void> refresh() async {
    await _loadActiveShift();
  }

  /// Proactively refresh the JWT token if it expires within [thresholdMinutes].
  ///
  /// Routes through [AuthService.refreshSession()] which uses a mutex to
  /// prevent concurrent refresh calls from racing (the root cause of
  /// unexplained logouts — two callers rotating the refresh token
  /// simultaneously, invalidating the first caller's new token).
  ///
  /// Returns true if the session is valid (either already fresh or successfully
  /// refreshed). Returns false only if the refresh fails — caller should
  /// handle this as a degraded-auth scenario, not block the operation.
  Future<bool> _ensureFreshToken({int thresholdMinutes = 10}) async {
    try {
      final client = _ref.read(supabaseClientProvider);
      if (client.auth.currentSession == null) return false;

      final result = await _ref.read(authServiceProvider).refreshSession(
        thresholdMinutes: thresholdMinutes,
      );
      return result;
    } catch (e) {
      _logger?.auth(
        Severity.warn,
        'Proactive token refresh failed',
        metadata: {
          'error': e.toString(),
        },
      );
      return false;
    }
  }

  /// Start a periodic token refresh timer for the duration of the shift.
  ///
  /// Refreshes every 50 minutes (well before the ~60-min JWT expiry) to
  /// prevent mid-shift session expiration, especially on iOS where
  /// background network access can be throttled.
  void _startTokenRefreshTimer() {
    _tokenRefreshTimer?.cancel();
    _tokenRefreshTimer = Timer.periodic(const Duration(minutes: 50), (_) {
      if (mounted && state.activeShift != null) {
        _ensureFreshToken(thresholdMinutes: 15);
      }
    });
  }

  void _stopTokenRefreshTimer() {
    _tokenRefreshTimer?.cancel();
    _tokenRefreshTimer = null;
  }

  /// Log a post-kill restart diagnostic when the app cold-starts and finds
  /// an active shift but the foreground service is dead.
  ///
  /// Combines standby bucket, gap duration, and service state into one event
  /// for forensic analysis. Exit reasons are collected separately by
  /// [ExitReasonCollector] at app startup.
  Future<void> _logPostKillDiagnostic(Shift shift) async {
    try {
      final isRunning = await BackgroundTrackingService.isTracking;
      if (isRunning) return; // Service is alive — not a post-kill restart

      // Compute gap duration from the last local GPS point
      final localDb = _ref.read(localDatabaseProvider);
      final points = await localDb.getGpsPointsForShift(shift.id);
      final lastPointTime =
          points.isNotEmpty ? points.last.capturedAt : null;
      final gapSeconds = lastPointTime != null
          ? DateTime.now().toUtc().difference(lastPointTime).inSeconds
          : null;

      // Fetch current standby bucket
      final bucketInfo =
          await AndroidBatteryHealthService.getAppStandbyBucket();

      _logger?.lifecycle(
        Severity.warn,
        'Post-kill restart diagnostic',
        metadata: {
          'shift_id': shift.serverId ?? shift.id,
          'foreground_service_was_alive': false,
          'standby_bucket': bucketInfo.bucketName,
          'standby_bucket_code': bucketInfo.bucket,
          if (gapSeconds != null) 'gap_duration_seconds': gapSeconds,
          if (lastPointTime != null)
            'last_gps_point_at': lastPointTime.toIso8601String(),
        },
      );
    } catch (_) {
      // Best-effort — never block shift load for diagnostics
    }
  }

  /// Clock in with required GPS location.
  Future<bool> clockIn({
    required GeoPoint location,
    double? accuracy,
  }) async {
    final employeeId = _ref.read(supabaseClientProvider).auth.currentUser?.id;
    _logger?.shift(Severity.info, 'Clock in attempt', metadata: {
      'employee_id': employeeId,
      'latitude': location.latitude,
      'longitude': location.longitude,
      if (accuracy != null) 'accuracy': accuracy,
    },);

    state = state.copyWith(isClockingIn: true, clearError: true);

    // Ensure we start the shift with a fresh JWT token.
    // This prevents mid-shift expiry from causing false shift closures.
    await _ensureFreshToken(thresholdMinutes: 30);

    try {
      final result = await _shiftService.clockIn(
        location: location,
        accuracy: accuracy,
      );

      if (result.success) {
        await _loadActiveShift();
        final shift = state.activeShift;
        _logger?.shift(Severity.info, 'Clock in success', metadata: {
          'shift_id': shift?.id,
          'server_id': shift?.serverId,
          'employee_id': employeeId,
        },);
        if (shift != null) {
          _logger?.setShiftId(shift.serverId ?? shift.id);
        }

        // Save clock-in location as first GPS point immediately.
        // Guarantees every shift has ≥1 GPS point even if background
        // tracking fails to start (iOS kills service, permission issue, etc.)
        if (shift != null && employeeId != null) {
          try {
            final localDb = _ref.read(localDatabaseProvider);
            final now = DateTime.now().toUtc();
            final point = LocalGpsPoint(
              id: const Uuid().v4(),
              shiftId: shift.id,
              employeeId: employeeId,
              latitude: location.latitude,
              longitude: location.longitude,
              accuracy: accuracy,
              capturedAt: now,
              syncStatus: 'pending',
              createdAt: now,
            );
            await localDb.insertGpsPoint(point);
            _logger?.gps(Severity.info, 'Clock-in GPS point saved', metadata: {
              'shift_id': shift.id,
              'accuracy': accuracy,
            },);
          } catch (e) {
            // Best-effort — don't fail clock-in if GPS point insert fails
            _logger?.gps(Severity.warn, 'Failed to save clock-in GPS point', metadata: {
              'error': e.toString(),
            },);
          }
        }

        // Log tracking state at handoff for remote diagnostics
        final trackingState = _ref.read(trackingProvider);
        bool? fgsRunning;
        try {
          fgsRunning = await BackgroundTrackingService.isTracking;
        } catch (_) {}
        _logger?.shift(Severity.info, 'Clock in — tracking state at handoff', metadata: {
          'tracking_status': trackingState.status.name,
          'tracking_shift_id': trackingState.activeShiftId,
          'foreground_service_running': fgsRunning,
        },);

        // Log device health for proactive at-risk device detection (Android only)
        if (defaultTargetPlatform == TargetPlatform.android) {
          try {
            final isExempt = await AndroidBatteryHealthService.isBatteryOptimizationDisabled;
            final bucketInfo = await AndroidBatteryHealthService.getAppStandbyBucket();
            final manufacturer = await AndroidBatteryHealthService.getManufacturer();
            final apiLevel = await AndroidBatteryHealthService.getApiLevel();

            _logger?.battery(Severity.info,
              'Device health at shift start',
              shiftId: shift?.serverId ?? shift?.id,
              metadata: {
                'battery_optimization_exempt': isExempt,
                'standby_bucket': bucketInfo.bucketName,
                'standby_bucket_code': bucketInfo.bucket,
                'manufacturer': manufacturer,
                'api_level': apiLevel,
              },
            );
          } catch (e) {
            // Best-effort — never block clock-in for diagnostics
          }
        }

        // Trigger immediate sync to flush diagnostic logs to server.
        // Normally sync is triggered by GPS points, but if tracking fails
        // to start, logs would be stuck on-device.
        try {
          _ref.read(syncProvider.notifier).notifyPendingData();
        } catch (_) {}

        DeviceInfoService(_ref.read(supabaseClientProvider)).syncDeviceInfo();

        // Start periodic token refresh to keep JWT alive during the shift
        _startTokenRefreshTimer();

        state = state.copyWith(isClockingIn: false);
        return true;
      } else {
        _logger?.shift(Severity.error, 'Clock in failed', metadata: {
          'employee_id': employeeId,
          'error': result.errorMessage,
          'error_code': result.errorCode,
        },);
        state = state.copyWith(
          isClockingIn: false,
          error: result.errorMessage,
          versionTooOld: result.isVersionTooOld,
        );
        return false;
      }
    } catch (e) {
      _logger?.shift(Severity.error, 'Clock in failed', metadata: {
        'employee_id': employeeId,
        'error': e.toString(),
      },);
      state = state.copyWith(
        isClockingIn: false,
        error: 'Failed to clock in: $e',
      );
      return false;
    }
  }

  /// Start a lunch break — closes the current work segment, opens a lunch segment.
  Future<void> startLunch() async {
    final shift = state.activeShift;
    if (shift == null || shift.isOnLunch) return;
    if (state.isStartingLunch) return; // double-tap guard

    state = state.copyWith(isStartingLunch: true, clearError: true);
    final now = DateTime.now().toUtc();
    final localDb = _ref.read(localDatabaseProvider);

    try {
      // 1. Record lunch_started_at locally (offline safety)
      await localDb.markLunchPending(shift.id, now);

      // 2. Close active work session
      try {
        _ref.read(workSessionProvider.notifier).manualClose();
      } catch (_) {}

      // 3. Pause GPS (keep resilience mechanisms alive)
      await _ref.read(trackingProvider.notifier).pauseForLunch();

      // 4. Update Live Activity
      ShiftActivityService.instance.updateStatus('lunch');

      // 5. Try RPC (online path)
      try {
        final result = await _shiftService.startLunch(shift.id, at: now);

        if (result.success && result.newShiftId != null) {
          // Create local lunch segment
          final lunchSegment = LocalShift(
            id: result.newShiftId!,
            employeeId: shift.employeeId,
            clockedInAt: result.startedAt ?? now,
            status: 'active',
            syncStatus: 'synced',
            serverId: result.newShiftId,
            workBodyId: result.workBodyId,
            isLunch: true,
            createdAt: DateTime.now().toUtc(),
            updatedAt: DateTime.now().toUtc(),
          );
          await localDb.insertShiftSegment(lunchSegment);
          // Mark the old shift as synced (it's completed on server)
          await localDb.markShiftSynced(shift.id);

          state = state.copyWith(
            activeShift: lunchSegment.toShift(),
            isStartingLunch: false,
          );
        } else {
          throw Exception(result.errorMessage ?? 'RPC failed');
        }
      } catch (e) {
        // 6. Offline fallback — UI already shows lunch state via local DB
        debugPrint('[ShiftProvider] startLunch RPC failed, offline fallback: $e');

        final offlineLunchShift = shift.copyWith(
          isLunch: true,
          workBodyId: shift.workBodyId ?? shift.id,
        );
        state = state.copyWith(
          activeShift: offlineLunchShift,
          isStartingLunch: false,
        );
      }

      // Notify sync
      _ref.read(syncProvider.notifier).notifyPendingData();
    } catch (e) {
      state = state.copyWith(isStartingLunch: false, error: e.toString());
    }
  }

  /// End a lunch break — closes the lunch segment, opens a new work segment.
  Future<void> endLunch() async {
    final shift = state.activeShift;
    if (shift == null || !shift.isOnLunch) return;
    if (state.isEndingLunch) return; // double-tap guard

    state = state.copyWith(isEndingLunch: true, clearError: true);
    final now = DateTime.now().toUtc();
    final localDb = _ref.read(localDatabaseProvider);

    try {
      // 1. Record lunch_ended_at locally (offline safety)
      await localDb.markLunchEndPending(shift.id, now);

      // 2. Try RPC (online path)
      try {
        final result = await _shiftService.endLunch(shift.id, at: now);

        if (result.success && result.newShiftId != null) {
          // Create local work segment
          final workSegment = LocalShift(
            id: result.newShiftId!,
            employeeId: shift.employeeId,
            clockedInAt: result.startedAt ?? now,
            status: 'active',
            syncStatus: 'synced',
            serverId: result.newShiftId,
            workBodyId: result.workBodyId,
            isLunch: false,
            createdAt: DateTime.now().toUtc(),
            updatedAt: DateTime.now().toUtc(),
          );
          await localDb.insertShiftSegment(workSegment);
          // Mark the old lunch shift as synced (completed on server)
          await localDb.markShiftSynced(shift.id);

          state = state.copyWith(
            activeShift: workSegment.toShift(),
            isEndingLunch: false,
          );
        } else {
          throw Exception(result.errorMessage ?? 'RPC failed');
        }
      } catch (e) {
        // 3. Offline fallback — resume GPS with same shift_id
        debugPrint('[ShiftProvider] endLunch RPC failed, offline fallback: $e');

        final offlineWorkShift = shift.copyWith(isLunch: false);
        state = state.copyWith(
          activeShift: offlineWorkShift,
          isEndingLunch: false,
        );
      }

      // 4. Resume GPS tracking
      await ensureGpsAlive(_ref, source: 'lunch_end');
      await _ref.read(trackingProvider.notifier).startTracking();

      // 5. Update Live Activity
      ShiftActivityService.instance.updateStatus('active');

      // Notify sync
      _ref.read(syncProvider.notifier).notifyPendingData();
    } catch (e) {
      state = state.copyWith(isEndingLunch: false, error: e.toString());
    }
  }

  /// Clock out from the active shift.
  Future<bool> clockOut({
    GeoPoint? location,
    double? accuracy,
    String? reason,
  }) async {
    final activeShift = state.activeShift;
    if (activeShift == null) {
      state = state.copyWith(error: 'No active shift to clock out from');
      return false;
    }

    _logger?.shift(Severity.info, 'Clock out attempt', metadata: {
      'shift_id': activeShift.id,
      'server_id': activeShift.serverId,
      if (reason != null) 'reason': reason,
    },);

    state = state.copyWith(isClockingOut: true, clearError: true);

    // Ensure GPS is alive for final position capture
    await ensureGpsAlive(_ref, source: 'shift_clock_out');

    try {
      final result = await _shiftService.clockOut(
        shiftId: activeShift.id,
        location: location,
        accuracy: accuracy,
        reason: reason,
      );

      if (result.success) {
        final durationMinutes =
            DateTime.now().toUtc().difference(activeShift.clockedInAt).inMinutes;
        _logger?.shift(Severity.info, 'Clock out success', metadata: {
          'shift_id': activeShift.id,
          'server_id': activeShift.serverId,
          'duration_minutes': durationMinutes,
          if (reason != null) 'reason': reason,
        },);
        _logger?.setShiftId(null);

        // Auto-close any open cleaning sessions for this shift
        // Use local shift ID — sessions are stored locally with this ID
        try {
          final cleaningService = _ref.read(cleaningSessionServiceProvider);
          final userId = _ref.read(supabaseClientProvider).auth.currentUser?.id;
          if (userId != null) {
            await cleaningService.autoCloseSessions(
              shiftId: activeShift.id,
              employeeId: userId,
              closedAt: DateTime.now().toUtc(),
            );
          }
        } catch (_) {
          // Don't fail clock-out if auto-close fails
        }

        // Auto-close any open maintenance sessions for this shift
        try {
          final maintenanceService =
              _ref.read(maintenanceSessionServiceProvider);
          final userId = _ref.read(supabaseClientProvider).auth.currentUser?.id;
          if (userId != null) {
            await maintenanceService.autoCloseSessions(
              shiftId: activeShift.id,
              employeeId: userId,
              closedAt: DateTime.now().toUtc(),
            );
          }
        } catch (_) {
          // Don't fail clock-out if auto-close fails
        }

        // Auto-close any open work sessions for this shift (unified sessions)
        try {
          final workSessionService =
              _ref.read(workSessionServiceProvider);
          final userId = _ref.read(supabaseClientProvider).auth.currentUser?.id;
          if (userId != null) {
            await workSessionService.autoCloseSessions(
              shiftId: activeShift.id,
              employeeId: userId,
              closedAt: DateTime.now().toUtc(),
            );
          }
        } catch (_) {
          // Don't fail clock-out if auto-close fails
        }

        _stopTokenRefreshTimer();

        state = state.copyWith(
          isClockingOut: false,
          clearActiveShift: true,
        );
        return true;
      } else {
        _logger?.shift(Severity.error, 'Clock out failed', metadata: {
          'shift_id': activeShift.id,
          'error': result.errorMessage,
        },);
        state = state.copyWith(
          isClockingOut: false,
          error: result.errorMessage,
        );
        return false;
      }
    } catch (e) {
      _logger?.shift(Severity.error, 'Clock out failed', metadata: {
        'shift_id': activeShift.id,
        'error': e.toString(),
      },);
      state = state.copyWith(
        isClockingOut: false,
        error: 'Failed to clock out: $e',
      );
      return false;
    }
  }

  /// Clear any error state.
  void clearError() {
    state = state.copyWith(clearError: true);
  }

  @override
  void dispose() {
    _serverCheckTimer?.cancel();
    _tokenRefreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// Provider for shift state management.
/// Rebuilds when the authenticated user changes (logout/login).
///
/// IMPORTANT: We select only the user ID from auth state so that token
/// refresh events do NOT trigger a provider rebuild. A rebuild during
/// clockIn() destroys the in-flight ShiftNotifier before it can set
/// activeShift, causing TrackingNotifier to never start GPS tracking.
/// See: Fabrice GPS gap bug (2026-02-26).
final shiftProvider = StateNotifierProvider<ShiftNotifier, ShiftState>((ref) {
  // Only rebuild when the user changes (login/logout), NOT on token refresh.
  // Token refresh keeps the same user.id, so .select() filters it out.
  ref.watch(
    authStateChangesProvider.select(
      (asyncValue) => asyncValue.valueOrNull?.session?.user.id,
    ),
  );
  final shiftService = ref.watch(shiftServiceProvider);
  return ShiftNotifier(shiftService, ref);
});

/// Provider for checking if user has an active shift.
final hasActiveShiftProvider = Provider<bool>((ref) {
  return ref.watch(shiftProvider).activeShift != null;
});

/// Provider for the active shift.
final activeShiftProvider = Provider<Shift?>((ref) {
  return ref.watch(shiftProvider).activeShift;
});
