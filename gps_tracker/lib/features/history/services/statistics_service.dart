import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/history_statistics.dart';

/// Service for calculating and fetching shift statistics
///
/// Provides methods for individual employee statistics
/// and team-level aggregations for managers.
class StatisticsService {
  final SupabaseClient _supabase;

  StatisticsService(this._supabase);

  /// Get statistics for a specific employee
  ///
  /// Returns aggregated shift statistics over the given date range.
  /// Requires that the caller has permission to view the employee's data.
  Future<HistoryStatistics> getEmployeeStatistics({
    required String employeeId,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final params = <String, dynamic>{
        'p_employee_id': employeeId,
      };
      if (startDate != null) {
        params['p_start_date'] = startDate.toUtc().toIso8601String();
      }
      if (endDate != null) {
        params['p_end_date'] = endDate.toUtc().toIso8601String();
      }

      final response = await _supabase.rpc(
        'get_employee_statistics',
        params: params,
      );

      if (response == null || (response as List).isEmpty) {
        return HistoryStatistics.empty;
      }

      final data = (response as List).first as Map<String, dynamic>;
      return HistoryStatistics.fromJson(data);
    } on PostgrestException catch (e) {
      if (e.message?.contains('Access denied') == true) {
        throw StatisticsException(
          'You do not have permission to view this employee\'s statistics',
          code: 'ACCESS_DENIED',
        );
      }
      throw StatisticsException(
        'Failed to load statistics: ${e.message}',
        code: e.code,
      );
    } catch (e) {
      throw StatisticsException('Failed to load statistics: $e');
    }
  }

  /// Get team statistics for the current manager
  ///
  /// Returns aggregated statistics across all supervised employees.
  Future<TeamStatistics> getTeamStatistics({
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final params = <String, dynamic>{};
      if (startDate != null) {
        params['p_start_date'] = startDate.toUtc().toIso8601String();
      }
      if (endDate != null) {
        params['p_end_date'] = endDate.toUtc().toIso8601String();
      }

      final response = await _supabase.rpc(
        'get_team_statistics',
        params: params.isEmpty ? null : params,
      );

      if (response == null || (response as List).isEmpty) {
        return TeamStatistics.empty;
      }

      final data = (response as List).first as Map<String, dynamic>;
      return TeamStatistics.fromJson(data);
    } on PostgrestException catch (e) {
      throw StatisticsException(
        'Failed to load team statistics: ${e.message}',
        code: e.code,
      );
    } catch (e) {
      throw StatisticsException('Failed to load team statistics: $e');
    }
  }

  /// Get statistics for the current user (self-service)
  ///
  /// Returns aggregated statistics for the currently authenticated user.
  Future<HistoryStatistics> getMyStatistics({
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        throw StatisticsException('Not authenticated');
      }

      return getEmployeeStatistics(
        employeeId: userId,
        startDate: startDate,
        endDate: endDate,
      );
    } catch (e) {
      if (e is StatisticsException) rethrow;
      throw StatisticsException('Failed to load your statistics: $e');
    }
  }
}

/// Exception thrown by StatisticsService operations
class StatisticsException implements Exception {
  final String message;
  final String? code;

  const StatisticsException(this.message, {this.code});

  @override
  String toString() => 'StatisticsException: $message';
}
