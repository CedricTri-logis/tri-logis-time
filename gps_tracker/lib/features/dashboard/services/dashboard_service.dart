import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../history/models/history_statistics.dart';
import '../../shifts/models/shift.dart';
import '../models/dashboard_state.dart';
import '../models/employee_work_status.dart';
import '../models/team_dashboard_state.dart';

/// Service for fetching dashboard data from Supabase.
///
/// Provides methods for loading employee and team dashboard data
/// using optimized RPC functions.
class DashboardService {
  final SupabaseClient _supabase;

  DashboardService(this._supabase);

  /// Get current authenticated user ID.
  String? get _currentUserId => _supabase.auth.currentUser?.id;

  // ============ EMPLOYEE DASHBOARD ============

  /// Load employee dashboard data in a single optimized query.
  Future<DashboardSummaryResult> loadDashboardSummary({
    bool includeRecentShifts = true,
    int recentShiftsLimit = 10,
  }) async {
    final response = await _supabase.rpc(
      'get_dashboard_summary',
      params: {
        'p_include_recent_shifts': includeRecentShifts,
        'p_recent_shifts_limit': recentShiftsLimit,
      },
    );

    if (response == null) {
      throw DashboardException('No response from dashboard summary');
    }

    final data = response as Map<String, dynamic>;

    if (data.containsKey('error')) {
      throw DashboardException(data['error'] as String);
    }

    // Parse active shift
    ShiftStatusInfo shiftStatus;
    if (data['active_shift'] != null) {
      // Fetch full shift details if there's an active shift
      final activeShift = await _fetchActiveShift();
      shiftStatus = ShiftStatusInfo(
        isActive: true,
        activeShift: activeShift,
      );
    } else {
      shiftStatus = const ShiftStatusInfo(isActive: false);
    }

    // Parse today's stats
    final todayData = data['today_stats'] as Map<String, dynamic>? ?? {};
    final todayStats = DailyStatistics(
      date: DateTime.now(),
      completedShiftCount: todayData['completed_shifts'] as int? ?? 0,
      totalDuration:
          Duration(seconds: (todayData['total_seconds'] as num?)?.toInt() ?? 0),
      activeShiftDuration: Duration(
        seconds: (todayData['active_shift_seconds'] as num?)?.toInt() ?? 0,
      ),
    );

    // Parse monthly stats
    final monthData = data['month_stats'] as Map<String, dynamic>? ?? {};
    final monthlyStats = HistoryStatistics(
      totalShifts: monthData['total_shifts'] as int? ?? 0,
      totalHours:
          Duration(seconds: (monthData['total_seconds'] as num?)?.toInt() ?? 0),
      averageShiftDuration: Duration(
        seconds: (monthData['avg_duration_seconds'] as num?)?.toInt() ?? 0,
      ),
    );

    // Parse recent shifts
    final recentShiftsData =
        (data['recent_shifts'] as List<dynamic>?) ?? [];
    final recentShifts = await _fetchRecentShiftsDetails(
      recentShiftsData.cast<Map<String, dynamic>>(),
    );

    return DashboardSummaryResult(
      shiftStatus: shiftStatus,
      todayStats: todayStats,
      monthlyStats: monthlyStats,
      recentShifts: recentShifts,
    );
  }

  /// Fetch full active shift details.
  Future<Shift?> _fetchActiveShift() async {
    final userId = _currentUserId;
    if (userId == null) return null;

    final response = await _supabase
        .from('shifts')
        .select()
        .eq('employee_id', userId)
        .eq('status', 'active')
        .limit(1)
        .maybeSingle();

    if (response == null) return null;
    return Shift.fromJson(response);
  }

  /// Fetch recent shift details with full data.
  Future<List<Shift>> _fetchRecentShiftsDetails(
    List<Map<String, dynamic>> summaryData,
  ) async {
    if (summaryData.isEmpty) return [];

    final shiftIds = summaryData.map((s) => s['id'] as String).toList();

    final response = await _supabase
        .from('shifts')
        .select()
        .inFilter('id', shiftIds)
        .order('clocked_in_at', ascending: false);

    return (response as List<dynamic>)
        .map((json) => Shift.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  // ============ TEAM DASHBOARD ============

  /// Load team dashboard with employee status.
  Future<List<TeamEmployeeStatus>> loadTeamActiveStatus() async {
    final response = await _supabase.rpc('get_team_active_status');

    if (response == null) return [];

    return (response as List<dynamic>)
        .map((json) => TeamEmployeeStatus.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  // ============ TEAM STATISTICS ============

  /// Load team statistics for date range.
  Future<TeamStatistics> loadTeamStatistics({
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final response = await _supabase.rpc(
      'get_team_statistics',
      params: {
        'p_start_date': startDate?.toUtc().toIso8601String(),
        'p_end_date': endDate?.toUtc().toIso8601String(),
      },
    );

    if (response == null) return TeamStatistics.empty;
    final data = response as List<dynamic>;
    if (data.isEmpty) return TeamStatistics.empty;
    return TeamStatistics.fromJson(data.first as Map<String, dynamic>);
  }

  /// Load employee hours for bar chart.
  Future<List<EmployeeHoursData>> loadTeamEmployeeHours({
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final response = await _supabase.rpc(
      'get_team_employee_hours',
      params: {
        'p_start_date': startDate?.toUtc().toIso8601String(),
        'p_end_date': endDate?.toUtc().toIso8601String(),
      },
    );

    if (response == null) return [];

    return (response as List<dynamic>)
        .map((json) => EmployeeHoursData.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Load full team statistics state.
  Future<TeamStatisticsResult> loadTeamStatisticsWithChart({
    required DateTimeRange dateRange,
  }) async {
    final statistics = await loadTeamStatistics(
      startDate: dateRange.start,
      endDate: dateRange.end,
    );

    final employeeHours = await loadTeamEmployeeHours(
      startDate: dateRange.start,
      endDate: dateRange.end,
    );

    return TeamStatisticsResult(
      statistics: statistics,
      employeeHours: employeeHours,
    );
  }
}

/// Result container for dashboard summary.
class DashboardSummaryResult {
  final ShiftStatusInfo shiftStatus;
  final DailyStatistics todayStats;
  final HistoryStatistics monthlyStats;
  final List<Shift> recentShifts;

  const DashboardSummaryResult({
    required this.shiftStatus,
    required this.todayStats,
    required this.monthlyStats,
    required this.recentShifts,
  });
}

/// Result container for team statistics.
class TeamStatisticsResult {
  final TeamStatistics statistics;
  final List<EmployeeHoursData> employeeHours;

  const TeamStatisticsResult({
    required this.statistics,
    required this.employeeHours,
  });
}

/// Exception thrown by dashboard service.
class DashboardException implements Exception {
  final String message;

  const DashboardException(this.message);

  @override
  String toString() => 'DashboardException: $message';
}
