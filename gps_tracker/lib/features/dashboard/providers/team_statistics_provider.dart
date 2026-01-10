import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/supabase_provider.dart';
import '../../history/models/history_statistics.dart';
import '../models/team_dashboard_state.dart';
import 'dashboard_provider.dart';

/// Notifier for managing team statistics state.
///
/// Handles:
/// - Loading aggregate team statistics
/// - Date range filtering with presets
/// - Loading employee hours for chart
/// - Caching for offline access
class TeamStatisticsNotifier extends StateNotifier<TeamStatisticsState> {
  final Ref _ref;
  bool _initialized = false;

  TeamStatisticsNotifier(this._ref) : super(TeamStatisticsState.loading()) {
    _initialize();
  }

  /// Initialize with default date range (this month).
  Future<void> _initialize() async {
    if (_initialized) return;
    _initialized = true;

    await load();
  }

  /// Load statistics for current date range.
  Future<void> load() async {
    final userId = _ref.read(currentUserProvider)?.id;
    if (userId == null) {
      state = TeamStatisticsState.error('Not authenticated');
      return;
    }

    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final service = _ref.read(dashboardServiceProvider);
      final result = await service.loadTeamStatisticsWithChart(
        dateRange: state.dateRange,
      );

      state = state.copyWith(
        statistics: result.statistics,
        employeeHours: result.employeeHours,
        isLoading: false,
      );

      // Cache the data
      await _cacheData(userId);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  /// Cache current statistics data.
  Future<void> _cacheData(String userId) async {
    try {
      final cacheService = _ref.read(dashboardCacheServiceProvider);
      await cacheService.cacheTeamStatistics(userId, state);
    } catch (e) {
      // Ignore cache errors
    }
  }

  /// Update date range using preset.
  Future<void> selectPreset(DateRangePreset preset) async {
    if (preset == DateRangePreset.custom) return;

    state = state.copyWith(
      dateRangePreset: preset,
      dateRange: preset.toDateRange(),
    );

    await load();
  }

  /// Update date range with custom range.
  Future<void> selectCustomRange(DateTimeRange range) async {
    state = state.copyWith(
      dateRangePreset: DateRangePreset.custom,
      dateRange: range,
    );

    await load();
  }

  /// Refresh statistics with current date range.
  Future<void> refresh() async => load();
}

/// Provider for team statistics state.
final teamStatisticsProvider =
    StateNotifierProvider<TeamStatisticsNotifier, TeamStatisticsState>((ref) {
  return TeamStatisticsNotifier(ref);
});

/// Provider for team statistics data.
final teamStatsDataProvider = Provider<TeamStatistics>((ref) {
  return ref.watch(teamStatisticsProvider).statistics;
});

/// Provider for employee hours chart data.
final employeeHoursChartDataProvider = Provider<List<EmployeeHoursData>>((ref) {
  return ref.watch(teamStatisticsProvider).employeeHours;
});

/// Provider for selected date range preset.
final teamStatsDateRangePresetProvider = Provider<DateRangePreset>((ref) {
  return ref.watch(teamStatisticsProvider).dateRangePreset;
});

/// Provider for selected date range.
final teamStatsDateRangeProvider = Provider<DateTimeRange>((ref) {
  return ref.watch(teamStatisticsProvider).dateRange;
});

/// Provider for checking if team statistics is loading.
final isTeamStatisticsLoadingProvider = Provider<bool>((ref) {
  return ref.watch(teamStatisticsProvider).isLoading;
});
