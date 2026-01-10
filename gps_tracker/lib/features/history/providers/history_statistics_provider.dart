import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/history_statistics.dart';
import '../services/statistics_service.dart';

/// State for employee statistics
class EmployeeStatisticsState {
  final bool isLoading;
  final HistoryStatistics? statistics;
  final String? error;
  final String? employeeId;
  final DateTime? startDate;
  final DateTime? endDate;

  const EmployeeStatisticsState({
    this.isLoading = false,
    this.statistics,
    this.error,
    this.employeeId,
    this.startDate,
    this.endDate,
  });

  EmployeeStatisticsState copyWith({
    bool? isLoading,
    HistoryStatistics? statistics,
    String? error,
    String? employeeId,
    DateTime? startDate,
    DateTime? endDate,
    bool clearError = false,
    bool clearStatistics = false,
  }) {
    return EmployeeStatisticsState(
      isLoading: isLoading ?? this.isLoading,
      statistics: clearStatistics ? null : (statistics ?? this.statistics),
      error: clearError ? null : (error ?? this.error),
      employeeId: employeeId ?? this.employeeId,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
    );
  }
}

/// Notifier for employee statistics
class EmployeeStatisticsNotifier extends StateNotifier<EmployeeStatisticsState> {
  final StatisticsService _statisticsService;

  EmployeeStatisticsNotifier(this._statisticsService)
      : super(const EmployeeStatisticsState());

  /// Load statistics for a specific employee
  Future<void> loadForEmployee(
    String employeeId, {
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      employeeId: employeeId,
      startDate: startDate,
      endDate: endDate,
    );

    try {
      final statistics = await _statisticsService.getEmployeeStatistics(
        employeeId: employeeId,
        startDate: startDate,
        endDate: endDate,
      );

      state = state.copyWith(
        isLoading: false,
        statistics: statistics,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  /// Apply date filter and reload
  Future<void> applyDateFilter({
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    if (state.employeeId == null) return;

    await loadForEmployee(
      state.employeeId!,
      startDate: startDate,
      endDate: endDate,
    );
  }

  /// Refresh current statistics
  Future<void> refresh() async {
    if (state.employeeId == null) return;

    await loadForEmployee(
      state.employeeId!,
      startDate: state.startDate,
      endDate: state.endDate,
    );
  }

  /// Clear statistics
  void clear() {
    state = const EmployeeStatisticsState();
  }
}

/// State for team statistics
class TeamStatisticsState {
  final bool isLoading;
  final TeamStatistics? statistics;
  final String? error;
  final DateTime? startDate;
  final DateTime? endDate;

  const TeamStatisticsState({
    this.isLoading = false,
    this.statistics,
    this.error,
    this.startDate,
    this.endDate,
  });

  TeamStatisticsState copyWith({
    bool? isLoading,
    TeamStatistics? statistics,
    String? error,
    DateTime? startDate,
    DateTime? endDate,
    bool clearError = false,
    bool clearStatistics = false,
  }) {
    return TeamStatisticsState(
      isLoading: isLoading ?? this.isLoading,
      statistics: clearStatistics ? null : (statistics ?? this.statistics),
      error: clearError ? null : (error ?? this.error),
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
    );
  }
}

/// Notifier for team statistics
class TeamStatisticsNotifier extends StateNotifier<TeamStatisticsState> {
  final StatisticsService _statisticsService;

  TeamStatisticsNotifier(this._statisticsService)
      : super(const TeamStatisticsState());

  /// Load team statistics for the current manager
  Future<void> load({
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      startDate: startDate,
      endDate: endDate,
    );

    try {
      final statistics = await _statisticsService.getTeamStatistics(
        startDate: startDate,
        endDate: endDate,
      );

      state = state.copyWith(
        isLoading: false,
        statistics: statistics,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  /// Apply date filter and reload
  Future<void> applyDateFilter({
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    await load(startDate: startDate, endDate: endDate);
  }

  /// Refresh current statistics
  Future<void> refresh() async {
    await load(startDate: state.startDate, endDate: state.endDate);
  }

  /// Clear statistics
  void clear() {
    state = const TeamStatisticsState();
  }
}

// Provider for statistics service
final statisticsServiceProvider = Provider<StatisticsService>((ref) {
  return StatisticsService(Supabase.instance.client);
});

// Provider for employee statistics
final employeeStatisticsProvider =
    StateNotifierProvider<EmployeeStatisticsNotifier, EmployeeStatisticsState>(
        (ref) {
  final service = ref.watch(statisticsServiceProvider);
  return EmployeeStatisticsNotifier(service);
});

// Provider for team statistics
final teamStatisticsProvider =
    StateNotifierProvider<TeamStatisticsNotifier, TeamStatisticsState>((ref) {
  final service = ref.watch(statisticsServiceProvider);
  return TeamStatisticsNotifier(service);
});
