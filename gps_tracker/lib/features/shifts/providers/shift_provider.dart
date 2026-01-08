import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/supabase_provider.dart';
import '../../../shared/services/local_database.dart';
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

  ShiftNotifier(this._shiftService) : super(const ShiftState()) {
    _loadActiveShift();
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

  /// Clock in with optional location.
  Future<bool> clockIn({
    GeoPoint? location,
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
      );

      if (result.success) {
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
final shiftProvider = StateNotifierProvider<ShiftNotifier, ShiftState>((ref) {
  final shiftService = ref.watch(shiftServiceProvider);
  return ShiftNotifier(shiftService);
});

/// Provider for checking if user has an active shift.
final hasActiveShiftProvider = Provider<bool>((ref) {
  return ref.watch(shiftProvider).activeShift != null;
});

/// Provider for the active shift.
final activeShiftProvider = Provider<Shift?>((ref) {
  return ref.watch(shiftProvider).activeShift;
});
