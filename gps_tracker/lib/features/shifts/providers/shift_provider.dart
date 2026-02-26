import 'dart:async';

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
import '../../../shared/services/shift_activity_service.dart';
import '../models/geo_point.dart';
import '../models/local_gps_point.dart';
import '../models/shift.dart';
import '../../auth/services/device_info_service.dart';
import '../../tracking/providers/tracking_provider.dart';
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

  const ShiftState({
    this.activeShift,
    this.isLoading = false,
    this.error,
    this.isClockingIn = false,
    this.isClockingOut = false,
  });

  ShiftState copyWith({
    Shift? activeShift,
    bool? isLoading,
    String? error,
    bool? isClockingIn,
    bool? isClockingOut,
    bool clearActiveShift = false,
    bool clearError = false,
  }) {
    return ShiftState(
      activeShift: clearActiveShift ? null : (activeShift ?? this.activeShift),
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      isClockingIn: isClockingIn ?? this.isClockingIn,
      isClockingOut: isClockingOut ?? this.isClockingOut,
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

    // If the active shift was closed server-side (admin, midnight cleanup, etc.)
    if (shiftId == activeShift.serverId && newStatus == 'completed') {
      final reason = record['clock_out_reason'] as String? ?? 'server_closed';
      _logger?.shift(Severity.warn, 'Shift closed by server', metadata: {
        'shift_id': shiftId,
        'reason': reason,
        'source': 'realtime',
      },);
      _closeShiftLocally(activeShift, reason);
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
          .select('id, status, clock_out_reason')
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
          await client.auth.refreshSession();
          final retryResponse = await client
              .from('shifts')
              .select('id, status, clock_out_reason')
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
      }

      state = state.copyWith(
        activeShift: shift,
        isLoading: false,
        clearActiveShift: shift == null,
      );

      // If resuming an active shift, start token refresh timer
      if (shift != null) {
        _startTokenRefreshTimer();
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
  /// Returns true if the session is valid (either already fresh or successfully
  /// refreshed). Returns false only if the refresh fails — caller should
  /// handle this as a degraded-auth scenario, not block the operation.
  Future<bool> _ensureFreshToken({int thresholdMinutes = 10}) async {
    try {
      final client = _ref.read(supabaseClientProvider);
      final session = client.auth.currentSession;
      if (session == null) return false;

      final expiresAt = session.expiresAt;
      if (expiresAt == null) return true;

      final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final remainingSeconds = expiresAt - nowEpoch;

      if (remainingSeconds < thresholdMinutes * 60) {
        await client.auth.refreshSession();
        _logger?.auth(Severity.info, 'Token refreshed proactively', metadata: {
          'remaining_seconds_before': remainingSeconds,
          'trigger': 'shift_lifecycle',
        },);
      }
      return true;
    } catch (e) {
      _logger?.auth(Severity.warn, 'Proactive token refresh failed', metadata: {
        'error': e.toString(),
      },);
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
        },);
        state = state.copyWith(
          isClockingIn: false,
          error: result.errorMessage,
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
final shiftProvider = StateNotifierProvider<ShiftNotifier, ShiftState>((ref) {
  // Watch auth state stream so provider rebuilds on login/logout
  ref.watch(authStateChangesProvider);
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
