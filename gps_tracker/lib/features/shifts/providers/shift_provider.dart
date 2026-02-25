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
      _checkServerShiftStatus();
    }
  }

  /// Query the server to verify the active shift is still open.
  ///
  /// If the local DB thinks a shift is active but the server says it's
  /// completed (midnight cleanup, admin action, dashboard close), update
  /// local state to match.
  Future<void> _checkServerShiftStatus() async {
    final activeShift = state.activeShift;
    if (activeShift == null) return;

    final serverId = activeShift.serverId;
    if (serverId == null) return; // Not synced yet, skip

    try {
      final client = _ref.read(supabaseClientProvider);
      if (client.auth.currentUser == null) return;

      final response = await client
          .from('shifts')
          .select('id, status, clock_out_reason')
          .eq('id', serverId)
          .maybeSingle();

      if (response == null) {
        // Shift not found on server — treat as closed
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

  /// Load the current active shift.
  Future<void> _loadActiveShift() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final shift = await _shiftService.getActiveShift();
      state = state.copyWith(
        activeShift: shift,
        isLoading: false,
        clearActiveShift: shift == null,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load active shift',
      );
    }
  }

  /// Refresh the active shift state.
  Future<void> refresh() async {
    await _loadActiveShift();
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
