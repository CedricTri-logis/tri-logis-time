import 'dart:convert';

import '../../../shared/services/local_database.dart';
import '../models/dashboard_state.dart';
import '../models/team_dashboard_state.dart';

/// Service for managing dashboard cache in local database.
///
/// Provides offline-first caching for dashboard data with 7-day TTL.
class DashboardCacheService {
  final LocalDatabase _localDb;

  /// Cache TTL in days.
  static const int cacheTtlDays = 7;

  DashboardCacheService(this._localDb);

  /// Initialize cache table if needed.
  Future<void> initialize() async {
    await _localDb.ensureDashboardCacheTable();
  }

  // ============ EMPLOYEE DASHBOARD CACHE ============

  /// Generate cache key for employee dashboard.
  String _employeeCacheKey(String employeeId) => 'employee_$employeeId';

  /// Cache employee dashboard state.
  Future<void> cacheEmployeeDashboard(
    String employeeId,
    EmployeeDashboardState state,
  ) async {
    final data = {
      'current_shift_status': state.currentShiftStatus.toJson(),
      'today_stats': state.todayStats.toJson(),
      'monthly_stats': state.monthlyStats.toJson(),
      'recent_shifts': state.recentShifts.map((s) => s.toJson()).toList(),
    };

    await _localDb.cacheDashboardData(
      cacheId: _employeeCacheKey(employeeId),
      cacheType: 'employee',
      employeeId: employeeId,
      cachedData: jsonEncode(data),
      ttlDays: cacheTtlDays,
    );
  }

  /// Get cached employee dashboard state.
  Future<EmployeeDashboardCacheResult?> getCachedEmployeeDashboard(
    String employeeId,
  ) async {
    final cached = await _localDb.getCachedDashboard(
      _employeeCacheKey(employeeId),
    );

    if (cached == null) return null;

    try {
      final data = jsonDecode(cached['cached_data'] as String);
      final lastUpdated = DateTime.parse(cached['last_updated'] as String);

      return EmployeeDashboardCacheResult(
        data: data as Map<String, dynamic>,
        lastUpdated: lastUpdated,
      );
    } catch (e) {
      // Invalid cache data, return null
      return null;
    }
  }

  /// Get cache last updated time for employee dashboard.
  Future<DateTime?> getEmployeeDashboardLastUpdated(String employeeId) async {
    return _localDb.getDashboardCacheLastUpdated(
      _employeeCacheKey(employeeId),
    );
  }

  // ============ TEAM DASHBOARD CACHE ============

  /// Generate cache key for team dashboard.
  String _teamCacheKey(String managerId) => 'team_$managerId';

  /// Cache team dashboard state.
  Future<void> cacheTeamDashboard(
    String managerId,
    TeamDashboardState state,
  ) async {
    final data = {
      'employees': state.employees.map((e) => e.toJson()).toList(),
    };

    await _localDb.cacheDashboardData(
      cacheId: _teamCacheKey(managerId),
      cacheType: 'team',
      employeeId: managerId,
      cachedData: jsonEncode(data),
      ttlDays: cacheTtlDays,
    );
  }

  /// Get cached team dashboard state.
  Future<TeamDashboardCacheResult?> getCachedTeamDashboard(
    String managerId,
  ) async {
    final cached = await _localDb.getCachedDashboard(
      _teamCacheKey(managerId),
    );

    if (cached == null) return null;

    try {
      final data = jsonDecode(cached['cached_data'] as String);
      final lastUpdated = DateTime.parse(cached['last_updated'] as String);

      return TeamDashboardCacheResult(
        data: data as Map<String, dynamic>,
        lastUpdated: lastUpdated,
      );
    } catch (e) {
      return null;
    }
  }

  // ============ TEAM STATISTICS CACHE ============

  /// Generate cache key for team statistics.
  String _teamStatsCacheKey(String managerId, String dateRangeHash) =>
      'team_stats_${managerId}_$dateRangeHash';

  /// Hash date range for cache key.
  String _hashDateRange(DateTime start, DateTime end) {
    return '${start.millisecondsSinceEpoch}_${end.millisecondsSinceEpoch}';
  }

  /// Cache team statistics state.
  Future<void> cacheTeamStatistics(
    String managerId,
    TeamStatisticsState state,
  ) async {
    final dateRangeHash = _hashDateRange(
      state.dateRange.start,
      state.dateRange.end,
    );

    final data = {
      'date_range_preset': state.dateRangePreset.name,
      'date_range_start': state.dateRange.start.toIso8601String(),
      'date_range_end': state.dateRange.end.toIso8601String(),
      'statistics': state.statistics.toJson(),
      'employee_hours': state.employeeHours.map((e) => e.toJson()).toList(),
    };

    await _localDb.cacheDashboardData(
      cacheId: _teamStatsCacheKey(managerId, dateRangeHash),
      cacheType: 'team_stats',
      employeeId: managerId,
      cachedData: jsonEncode(data),
      ttlDays: cacheTtlDays,
    );
  }

  /// Get cached team statistics state.
  Future<TeamStatisticsCacheResult?> getCachedTeamStatistics(
    String managerId,
    DateTime start,
    DateTime end,
  ) async {
    final dateRangeHash = _hashDateRange(start, end);
    final cached = await _localDb.getCachedDashboard(
      _teamStatsCacheKey(managerId, dateRangeHash),
    );

    if (cached == null) return null;

    try {
      final data = jsonDecode(cached['cached_data'] as String);
      final lastUpdated = DateTime.parse(cached['last_updated'] as String);

      return TeamStatisticsCacheResult(
        data: data as Map<String, dynamic>,
        lastUpdated: lastUpdated,
      );
    } catch (e) {
      return null;
    }
  }

  // ============ CACHE CLEANUP ============

  /// Clear expired cache entries.
  Future<int> clearExpiredCache() async {
    return _localDb.clearExpiredDashboardCache();
  }

  /// Clear all cache for an employee/manager.
  Future<void> clearUserCache(String userId) async {
    await _localDb.clearEmployeeDashboardCache(userId);
  }
}

/// Result container for employee dashboard cache.
class EmployeeDashboardCacheResult {
  final Map<String, dynamic> data;
  final DateTime lastUpdated;

  const EmployeeDashboardCacheResult({
    required this.data,
    required this.lastUpdated,
  });
}

/// Result container for team dashboard cache.
class TeamDashboardCacheResult {
  final Map<String, dynamic> data;
  final DateTime lastUpdated;

  const TeamDashboardCacheResult({
    required this.data,
    required this.lastUpdated,
  });
}

/// Result container for team statistics cache.
class TeamStatisticsCacheResult {
  final Map<String, dynamic> data;
  final DateTime lastUpdated;

  const TeamStatisticsCacheResult({
    required this.data,
    required this.lastUpdated,
  });
}
