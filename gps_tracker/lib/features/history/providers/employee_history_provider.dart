import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shifts/models/shift.dart';
import '../models/shift_history_filter.dart';
import '../services/history_service.dart';
import 'supervised_employees_provider.dart';

/// State for employee shift history
class EmployeeHistoryState {
  final List<Shift> shifts;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final String? error;
  final ShiftHistoryFilter filter;

  const EmployeeHistoryState({
    this.shifts = const [],
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasMore = true,
    this.error,
    this.filter = const ShiftHistoryFilter(),
  });

  EmployeeHistoryState copyWith({
    List<Shift>? shifts,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    String? error,
    ShiftHistoryFilter? filter,
    bool clearError = false,
  }) {
    return EmployeeHistoryState(
      shifts: shifts ?? this.shifts,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      error: clearError ? null : (error ?? this.error),
      filter: filter ?? this.filter,
    );
  }
}

/// Notifier for managing employee shift history state
class EmployeeHistoryNotifier extends StateNotifier<EmployeeHistoryState> {
  final HistoryService _historyService;

  EmployeeHistoryNotifier(this._historyService)
      : super(const EmployeeHistoryState());

  /// Initialize with a specific employee
  Future<void> loadForEmployee(String employeeId, {ShiftHistoryFilter? filter}) async {
    final newFilter = (filter ?? ShiftHistoryFilter.defaultFilter())
        .copyWith(employeeId: employeeId, offset: 0);

    state = state.copyWith(
      isLoading: true,
      clearError: true,
      filter: newFilter,
      shifts: [],
      hasMore: true,
    );

    try {
      final shifts = await _historyService.getEmployeeShifts(newFilter);
      state = state.copyWith(
        shifts: shifts,
        isLoading: false,
        hasMore: shifts.length >= newFilter.limit,
      );
    } on HistoryServiceException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.message,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load shift history: $e',
      );
    }
  }

  /// Load more shifts (pagination)
  Future<void> loadMore() async {
    if (state.isLoadingMore || !state.hasMore || state.filter.employeeId == null) {
      return;
    }

    state = state.copyWith(isLoadingMore: true);

    try {
      final nextFilter = state.filter.nextPage();
      final moreShifts = await _historyService.getEmployeeShifts(nextFilter);

      state = state.copyWith(
        shifts: [...state.shifts, ...moreShifts],
        filter: nextFilter,
        isLoadingMore: false,
        hasMore: moreShifts.length >= nextFilter.limit,
      );
    } on HistoryServiceException catch (e) {
      state = state.copyWith(
        isLoadingMore: false,
        error: e.message,
      );
    } catch (e) {
      state = state.copyWith(
        isLoadingMore: false,
        error: 'Failed to load more shifts: $e',
      );
    }
  }

  /// Apply a date range filter
  Future<void> applyDateFilter({DateTime? startDate, DateTime? endDate}) async {
    if (state.filter.employeeId == null) return;

    final newFilter = state.filter.copyWith(
      startDate: startDate,
      endDate: endDate,
      offset: 0,
    );

    state = state.copyWith(
      isLoading: true,
      clearError: true,
      filter: newFilter,
    );

    try {
      final shifts = await _historyService.getEmployeeShifts(newFilter);
      state = state.copyWith(
        shifts: shifts,
        isLoading: false,
        hasMore: shifts.length >= newFilter.limit,
      );
    } on HistoryServiceException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.message,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to apply filter: $e',
      );
    }
  }

  /// Clear date filters
  Future<void> clearDateFilter() async {
    if (state.filter.employeeId == null) return;

    final newFilter = state.filter.copyWith(
      clearStartDate: true,
      clearEndDate: true,
      offset: 0,
    );

    state = state.copyWith(
      isLoading: true,
      clearError: true,
      filter: newFilter,
    );

    try {
      final shifts = await _historyService.getEmployeeShifts(newFilter);
      state = state.copyWith(
        shifts: shifts,
        isLoading: false,
        hasMore: shifts.length >= newFilter.limit,
      );
    } on HistoryServiceException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.message,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to clear filter: $e',
      );
    }
  }

  /// Refresh the current view
  Future<void> refresh() async {
    if (state.filter.employeeId == null) return;
    await loadForEmployee(state.filter.employeeId!, filter: state.filter.firstPage());
  }

  /// Clear error state
  void clearError() {
    state = state.copyWith(clearError: true);
  }
}

/// Provider for employee history state
final employeeHistoryProvider =
    StateNotifierProvider<EmployeeHistoryNotifier, EmployeeHistoryState>((ref) {
  return EmployeeHistoryNotifier(ref.watch(historyServiceProvider));
});

/// Provider for checking if history is empty after loading
final hasNoHistoryProvider = Provider<bool>((ref) {
  final historyState = ref.watch(employeeHistoryProvider);
  return !historyState.isLoading &&
      historyState.shifts.isEmpty &&
      historyState.error == null;
});
