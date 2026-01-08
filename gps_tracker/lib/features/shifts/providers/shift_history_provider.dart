import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/shift.dart';
import 'shift_provider.dart';

/// State for shift history with pagination.
class ShiftHistoryState {
  final List<Shift> shifts;
  final bool isLoading;
  final bool hasMore;
  final String? error;
  final int offset;

  const ShiftHistoryState({
    this.shifts = const [],
    this.isLoading = false,
    this.hasMore = true,
    this.error,
    this.offset = 0,
  });

  ShiftHistoryState copyWith({
    List<Shift>? shifts,
    bool? isLoading,
    bool? hasMore,
    String? error,
    int? offset,
    bool clearError = false,
  }) {
    return ShiftHistoryState(
      shifts: shifts ?? this.shifts,
      isLoading: isLoading ?? this.isLoading,
      hasMore: hasMore ?? this.hasMore,
      error: clearError ? null : (error ?? this.error),
      offset: offset ?? this.offset,
    );
  }
}

/// Notifier for managing shift history state with pagination.
class ShiftHistoryNotifier extends StateNotifier<ShiftHistoryState> {
  final Ref _ref;
  static const int _pageSize = 50;

  ShiftHistoryNotifier(this._ref) : super(const ShiftHistoryState()) {
    loadInitial();
  }

  /// Load initial shift history.
  Future<void> loadInitial() async {
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final shiftService = _ref.read(shiftServiceProvider);
      final shifts = await shiftService.getShiftHistory(
        limit: _pageSize,
        offset: 0,
      );

      state = state.copyWith(
        shifts: shifts,
        isLoading: false,
        hasMore: shifts.length >= _pageSize,
        offset: shifts.length,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load shift history',
      );
    }
  }

  /// Load more shifts (pagination).
  Future<void> loadMore() async {
    if (state.isLoading || !state.hasMore) return;

    state = state.copyWith(isLoading: true);

    try {
      final shiftService = _ref.read(shiftServiceProvider);
      final newShifts = await shiftService.getShiftHistory(
        limit: _pageSize,
        offset: state.offset,
      );

      state = state.copyWith(
        shifts: [...state.shifts, ...newShifts],
        isLoading: false,
        hasMore: newShifts.length >= _pageSize,
        offset: state.offset + newShifts.length,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load more shifts',
      );
    }
  }

  /// Refresh the history from the beginning.
  Future<void> refresh() async {
    state = const ShiftHistoryState();
    await loadInitial();
  }
}

/// Provider for shift history state.
final shiftHistoryProvider =
    StateNotifierProvider<ShiftHistoryNotifier, ShiftHistoryState>((ref) {
  return ShiftHistoryNotifier(ref);
});
