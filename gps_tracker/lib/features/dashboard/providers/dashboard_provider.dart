import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/supabase_provider.dart';
import '../../history/models/history_statistics.dart';
import '../../shifts/models/shift.dart';
import '../../shifts/providers/shift_provider.dart';
import '../../shifts/providers/sync_provider.dart';
import '../models/dashboard_state.dart';
import '../services/dashboard_cache_service.dart';
import '../services/dashboard_service.dart';

/// Provider for DashboardService.
final dashboardServiceProvider = Provider<DashboardService>((ref) {
  final supabase = ref.watch(supabaseClientProvider);
  return DashboardService(supabase);
});

/// Provider for DashboardCacheService.
final dashboardCacheServiceProvider = Provider<DashboardCacheService>((ref) {
  final localDb = ref.watch(localDatabaseProvider);
  return DashboardCacheService(localDb);
});

/// Notifier for managing employee dashboard state.
///
/// Handles:
/// - Loading dashboard data from API
/// - Caching data locally for offline access
/// - Auto-refresh on app foreground
/// - Integration with sync status
class DashboardNotifier extends StateNotifier<EmployeeDashboardState>
    with WidgetsBindingObserver {
  final Ref _ref;
  bool _initialized = false;

  DashboardNotifier(this._ref) : super(EmployeeDashboardState.loading()) {
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  /// Initialize dashboard with cached data, then fetch fresh data.
  Future<void> _initialize() async {
    if (_initialized) return;
    _initialized = true;

    // Try to load cached data first
    await _loadCachedData();

    // Then fetch fresh data
    await load();

    // Initialize cache table if needed
    final cacheService = _ref.read(dashboardCacheServiceProvider);
    await cacheService.initialize();

    // Clean up expired cache entries
    await cacheService.clearExpiredCache();
  }

  /// Load cached dashboard data.
  Future<void> _loadCachedData() async {
    try {
      final userId = _ref.read(currentUserProvider)?.id;
      if (userId == null) return;

      final cacheService = _ref.read(dashboardCacheServiceProvider);
      final cached = await cacheService.getCachedEmployeeDashboard(userId);

      if (cached != null) {
        final data = cached.data;

        // Parse cached data
        final shiftStatus = data['current_shift_status'] != null
            ? ShiftStatusInfo.fromJson(
                data['current_shift_status'] as Map<String, dynamic>)
            : const ShiftStatusInfo();

        final todayStats = data['today_stats'] != null
            ? DailyStatistics.fromJson(
                data['today_stats'] as Map<String, dynamic>)
            : DailyStatistics.today();

        final monthlyStats = data['monthly_stats'] != null
            ? HistoryStatistics.fromJson(
                data['monthly_stats'] as Map<String, dynamic>)
            : HistoryStatistics.empty;

        final recentShiftsData =
            (data['recent_shifts'] as List<dynamic>?) ?? [];
        final recentShifts = recentShiftsData
            .map((json) => Shift.fromJson(json as Map<String, dynamic>))
            .toList();

        // Update state with cached data
        state = state.copyWith(
          currentShiftStatus: shiftStatus,
          todayStats: todayStats,
          monthlyStats: monthlyStats,
          recentShifts: recentShifts,
          lastUpdated: cached.lastUpdated,
          isLoading: true, // Still loading fresh data
        );
      }
    } catch (e) {
      // Ignore cache errors, continue with fresh load
    }
  }

  /// Handle app lifecycle changes.
  @override
  void didChangeAppLifecycleState(AppLifecycleState appState) {
    if (appState == AppLifecycleState.resumed) {
      // Refresh within 3 seconds per spec SC-006
      refresh();
    }
  }

  /// Load fresh dashboard data from API.
  Future<void> load() async {
    final userId = _ref.read(currentUserProvider)?.id;
    if (userId == null) {
      state = EmployeeDashboardState.error('Not authenticated');
      return;
    }

    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final service = _ref.read(dashboardServiceProvider);
      final result = await service.loadDashboardSummary();

      // Get sync status
      final syncState = _ref.read(syncProvider);

      // Update state
      state = state.copyWith(
        currentShiftStatus: result.shiftStatus,
        todayStats: result.todayStats,
        monthlyStats: result.monthlyStats,
        recentShifts: result.recentShifts,
        syncStatus: syncState,
        lastUpdated: DateTime.now(),
        isLoading: false,
      );

      // Cache the data
      await _cacheData(userId);
    } catch (e) {
      // Check if we have cached data
      if (state.lastUpdated != null) {
        // Keep cached data but show error
        state = state.copyWith(
          isLoading: false,
          error: 'Failed to refresh: ${e.toString()}',
        );
      } else {
        state = EmployeeDashboardState.error(e.toString());
      }
    }
  }

  /// Cache current dashboard data.
  Future<void> _cacheData(String userId) async {
    try {
      final cacheService = _ref.read(dashboardCacheServiceProvider);
      await cacheService.cacheEmployeeDashboard(userId, state);
    } catch (e) {
      // Ignore cache errors
    }
  }

  /// Refresh dashboard data.
  Future<void> refresh() async => load();

  /// Update sync status from sync provider.
  void updateSyncStatus(SyncState syncStatus) {
    state = state.copyWith(syncStatus: syncStatus);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// Provider for employee dashboard state.
final dashboardProvider =
    StateNotifierProvider<DashboardNotifier, EmployeeDashboardState>((ref) {
  final notifier = DashboardNotifier(ref);

  // Listen to sync state changes
  ref.listen<SyncState>(syncProvider, (previous, next) {
    notifier.updateSyncStatus(next);
  });

  return notifier;
});

/// Provider for checking if dashboard is loading.
final isDashboardLoadingProvider = Provider<bool>((ref) {
  return ref.watch(dashboardProvider).isLoading;
});

/// Provider for dashboard error.
final dashboardErrorProvider = Provider<String?>((ref) {
  return ref.watch(dashboardProvider).error;
});

/// Provider for current shift status.
final currentShiftStatusProvider = Provider<ShiftStatusInfo>((ref) {
  return ref.watch(dashboardProvider).currentShiftStatus;
});

/// Provider for today's statistics.
final todayStatsProvider = Provider<DailyStatistics>((ref) {
  return ref.watch(dashboardProvider).todayStats;
});

/// Provider for monthly statistics.
final monthlyStatsProvider = Provider<HistoryStatistics>((ref) {
  return ref.watch(dashboardProvider).monthlyStats;
});

/// Provider for recent shifts.
final recentShiftsProvider = Provider<List<Shift>>((ref) {
  return ref.watch(dashboardProvider).recentShifts;
});
