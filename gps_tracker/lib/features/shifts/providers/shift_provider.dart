import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/supabase_provider.dart';
import '../../../shared/services/local_database.dart';
import '../../../shared/services/realtime_service.dart';
import '../../cleaning/providers/cleaning_session_provider.dart';
import '../../maintenance/providers/maintenance_provider.dart';
import '../models/geo_point.dart';
import '../models/shift.dart';
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
class ShiftNotifier extends StateNotifier<ShiftState> {
  final ShiftService _shiftService;
  final Ref _ref;

  ShiftNotifier(this._shiftService, this._ref) : super(const ShiftState()) {
    _loadActiveShift();
    _setupRealtimeListener();
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

    // If the active shift was closed server-side (admin, zombie cleanup, etc.)
    if (shiftId == activeShift.serverId && newStatus == 'completed') {
      debugPrint(
          'ShiftNotifier: server closed shift $shiftId '
          '(reason: ${record['clock_out_reason']})');
      state = state.copyWith(clearActiveShift: true);
    }
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
    state = state.copyWith(isClockingIn: true, clearError: true);

    try {
      final result = await _shiftService.clockIn(
        location: location,
        accuracy: accuracy,
      );

      if (result.success) {
        await _loadActiveShift();
        state = state.copyWith(isClockingIn: false);
        return true;
      } else {
        state = state.copyWith(
          isClockingIn: false,
          error: result.errorMessage,
        );
        return false;
      }
    } catch (e) {
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

    state = state.copyWith(isClockingOut: true, clearError: true);

    try {
      final result = await _shiftService.clockOut(
        shiftId: activeShift.id,
        location: location,
        accuracy: accuracy,
        reason: reason,
      );

      if (result.success) {
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
        state = state.copyWith(
          isClockingOut: false,
          error: result.errorMessage,
        );
        return false;
      }
    } catch (e) {
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
