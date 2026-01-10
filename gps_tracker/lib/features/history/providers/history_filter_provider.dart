import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/shift_history_filter.dart';

/// State for history filter UI controls
class HistoryFilterState {
  final DateTime? startDate;
  final DateTime? endDate;
  final String searchQuery;

  const HistoryFilterState({
    this.startDate,
    this.endDate,
    this.searchQuery = '',
  });

  /// Whether any filters are active
  bool get hasFilters =>
      startDate != null || endDate != null || searchQuery.isNotEmpty;

  /// Convert to ShiftHistoryFilter for API calls
  ShiftHistoryFilter toFilter({String? employeeId}) {
    return ShiftHistoryFilter(
      employeeId: employeeId,
      startDate: startDate,
      endDate: endDate,
      searchQuery: searchQuery.isNotEmpty ? searchQuery : null,
    );
  }

  HistoryFilterState copyWith({
    DateTime? startDate,
    DateTime? endDate,
    String? searchQuery,
    bool clearStartDate = false,
    bool clearEndDate = false,
    bool clearSearch = false,
  }) {
    return HistoryFilterState(
      startDate: clearStartDate ? null : (startDate ?? this.startDate),
      endDate: clearEndDate ? null : (endDate ?? this.endDate),
      searchQuery: clearSearch ? '' : (searchQuery ?? this.searchQuery),
    );
  }

  /// Clear all filters
  HistoryFilterState clear() {
    return const HistoryFilterState();
  }
}

/// Notifier for managing history filter state
class HistoryFilterNotifier extends StateNotifier<HistoryFilterState> {
  HistoryFilterNotifier() : super(const HistoryFilterState());

  /// Set date range
  void setDateRange(DateTime? start, DateTime? end) {
    state = state.copyWith(
      startDate: start,
      endDate: end,
      clearStartDate: start == null,
      clearEndDate: end == null,
    );
  }

  /// Set search query
  void setSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
  }

  /// Clear search query
  void clearSearch() {
    state = state.copyWith(clearSearch: true);
  }

  /// Clear date range
  void clearDateRange() {
    state = state.copyWith(clearStartDate: true, clearEndDate: true);
  }

  /// Clear all filters
  void clearAll() {
    state = state.clear();
  }

  /// Set to last 7 days
  void setLast7Days() {
    final now = DateTime.now();
    state = state.copyWith(
      startDate: DateTime(now.year, now.month, now.day)
          .subtract(const Duration(days: 7)),
      endDate: DateTime(now.year, now.month, now.day, 23, 59, 59),
    );
  }

  /// Set to last 30 days
  void setLast30Days() {
    final now = DateTime.now();
    state = state.copyWith(
      startDate: DateTime(now.year, now.month, now.day)
          .subtract(const Duration(days: 30)),
      endDate: DateTime(now.year, now.month, now.day, 23, 59, 59),
    );
  }

  /// Set to current month
  void setCurrentMonth() {
    final now = DateTime.now();
    state = state.copyWith(
      startDate: DateTime(now.year, now.month, 1),
      endDate: DateTime(now.year, now.month + 1, 0, 23, 59, 59),
    );
  }

  /// Set to previous month
  void setPreviousMonth() {
    final now = DateTime.now();
    final prevMonth = DateTime(now.year, now.month - 1, 1);
    state = state.copyWith(
      startDate: prevMonth,
      endDate: DateTime(now.year, now.month, 0, 23, 59, 59),
    );
  }
}

/// Provider for history filter state
final historyFilterProvider =
    StateNotifierProvider<HistoryFilterNotifier, HistoryFilterState>((ref) {
  return HistoryFilterNotifier();
});

/// Provider for checking if filters are active
final hasActiveFiltersProvider = Provider<bool>((ref) {
  return ref.watch(historyFilterProvider).hasFilters;
});
