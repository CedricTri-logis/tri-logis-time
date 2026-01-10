import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/supabase_provider.dart';
import '../models/employee_work_status.dart';
import '../models/team_dashboard_state.dart';
import 'dashboard_provider.dart';

/// Notifier for managing team dashboard state.
///
/// Handles:
/// - Loading team employee status from API
/// - Client-side filtering by search query
/// - Caching for offline access
class TeamDashboardNotifier extends StateNotifier<TeamDashboardState> {
  final Ref _ref;
  bool _initialized = false;

  TeamDashboardNotifier(this._ref) : super(TeamDashboardState.loading()) {
    _initialize();
  }

  /// Initialize team dashboard.
  Future<void> _initialize() async {
    if (_initialized) return;
    _initialized = true;

    // Try to load cached data first
    await _loadCachedData();

    // Then fetch fresh data
    await load();
  }

  /// Load cached team dashboard data.
  Future<void> _loadCachedData() async {
    try {
      final userId = _ref.read(currentUserProvider)?.id;
      if (userId == null) return;

      final cacheService = _ref.read(dashboardCacheServiceProvider);
      final cached = await cacheService.getCachedTeamDashboard(userId);

      if (cached != null) {
        final data = cached.data;

        final employeesData = (data['employees'] as List<dynamic>?) ?? [];
        final employees = employeesData
            .map((json) =>
                TeamEmployeeStatus.fromJson(json as Map<String, dynamic>))
            .toList();

        state = state.copyWith(
          employees: employees,
          lastUpdated: cached.lastUpdated,
          isLoading: true, // Still loading fresh data
        );
      }
    } catch (e) {
      // Ignore cache errors
    }
  }

  /// Load fresh team dashboard data from API.
  Future<void> load() async {
    final userId = _ref.read(currentUserProvider)?.id;
    if (userId == null) {
      state = TeamDashboardState.error('Not authenticated');
      return;
    }

    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final service = _ref.read(dashboardServiceProvider);
      final employees = await service.loadTeamActiveStatus();

      state = state.copyWith(
        employees: employees,
        lastUpdated: DateTime.now(),
        isLoading: false,
      );

      // Cache the data
      await _cacheData(userId);
    } catch (e) {
      if (state.lastUpdated != null) {
        state = state.copyWith(
          isLoading: false,
          error: 'Failed to refresh: ${e.toString()}',
        );
      } else {
        state = TeamDashboardState.error(e.toString());
      }
    }
  }

  /// Cache current team dashboard data.
  Future<void> _cacheData(String userId) async {
    try {
      final cacheService = _ref.read(dashboardCacheServiceProvider);
      await cacheService.cacheTeamDashboard(userId, state);
    } catch (e) {
      // Ignore cache errors
    }
  }

  /// Update search query with client-side filtering.
  void updateSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
  }

  /// Clear search query.
  void clearSearch() {
    state = state.copyWith(searchQuery: '');
  }

  /// Refresh team dashboard data.
  Future<void> refresh() async => load();
}

/// Provider for team dashboard state.
final teamDashboardProvider =
    StateNotifierProvider<TeamDashboardNotifier, TeamDashboardState>((ref) {
  return TeamDashboardNotifier(ref);
});

/// Provider for filtered employees based on search query.
final filteredTeamEmployeesProvider = Provider<List<TeamEmployeeStatus>>((ref) {
  final state = ref.watch(teamDashboardProvider);
  return state.filteredEmployees;
});

/// Provider for active employee count.
final activeEmployeeCountProvider = Provider<int>((ref) {
  final state = ref.watch(teamDashboardProvider);
  return state.activeCount;
});

/// Provider for total employee count.
final totalEmployeeCountProvider = Provider<int>((ref) {
  final state = ref.watch(teamDashboardProvider);
  return state.totalCount;
});

/// Provider for checking if team dashboard is loading.
final isTeamDashboardLoadingProvider = Provider<bool>((ref) {
  return ref.watch(teamDashboardProvider).isLoading;
});

/// Provider for team dashboard search query.
final teamSearchQueryProvider = Provider<String>((ref) {
  return ref.watch(teamDashboardProvider).searchQuery;
});
