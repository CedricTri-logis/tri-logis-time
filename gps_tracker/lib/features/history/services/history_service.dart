import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/employee_summary.dart';
import '../models/history_statistics.dart';
import '../models/shift_history_filter.dart';
import '../../shifts/models/geo_point.dart';
import '../../shifts/models/shift.dart';
import '../../shifts/models/shift_enums.dart';

/// Service for fetching employee history data from Supabase
///
/// Provides methods for managers to access supervised employee data
/// and for employees to access their own enhanced history.
class HistoryService {
  final SupabaseClient _supabase;

  HistoryService(this._supabase);

  /// Get list of employees supervised by the current manager
  ///
  /// Returns employee summaries with basic profile info and this month's stats.
  /// Throws [HistoryServiceException] on error.
  Future<List<EmployeeSummary>> getSupervisedEmployees() async {
    try {
      final response = await _supabase.rpc('get_supervised_employees');

      if (response == null) {
        return [];
      }

      final List<dynamic> data = response as List<dynamic>;
      return data
          .map((json) => EmployeeSummary.fromJson(json as Map<String, dynamic>))
          .toList();
    } on PostgrestException catch (e) {
      throw HistoryServiceException(
        'Failed to load supervised employees: ${e.message}',
        code: e.code,
      );
    } catch (e) {
      throw HistoryServiceException('Failed to load supervised employees: $e');
    }
  }

  /// Get shift history for a specific employee
  ///
  /// Requires either that the caller is the employee themselves,
  /// or that the caller is a manager with active supervision.
  /// Returns a list of shifts matching the filter criteria.
  Future<List<Shift>> getEmployeeShifts(ShiftHistoryFilter filter) async {
    if (filter.employeeId == null) {
      throw HistoryServiceException('Employee ID is required');
    }

    try {
      final response = await _supabase.rpc(
        'get_employee_shifts',
        params: filter.toQueryParams(),
      );

      if (response == null) {
        return [];
      }

      final List<dynamic> data = response as List<dynamic>;
      return data
          .map((json) => _shiftFromHistoryJson(json as Map<String, dynamic>))
          .toList();
    } on PostgrestException catch (e) {
      if (e.message?.contains('Access denied') == true) {
        throw HistoryServiceException(
          'You do not have permission to view this employee\'s history',
          code: 'ACCESS_DENIED',
        );
      }
      throw HistoryServiceException(
        'Failed to load shift history: ${e.message}',
        code: e.code,
      );
    } catch (e) {
      throw HistoryServiceException('Failed to load shift history: $e');
    }
  }

  /// Get GPS points for a specific shift
  ///
  /// Returns the GPS route data for displaying on a map.
  Future<List<GpsPointData>> getShiftGpsPoints(String shiftId) async {
    try {
      final response = await _supabase.rpc(
        'get_shift_gps_points',
        params: {'p_shift_id': shiftId},
      );

      if (response == null) {
        return [];
      }

      final List<dynamic> data = response as List<dynamic>;
      return data
          .map((json) => GpsPointData.fromJson(json as Map<String, dynamic>))
          .toList();
    } on PostgrestException catch (e) {
      if (e.message?.contains('Access denied') == true) {
        throw HistoryServiceException(
          'You do not have permission to view this shift\'s GPS data',
          code: 'ACCESS_DENIED',
        );
      }
      throw HistoryServiceException(
        'Failed to load GPS points: ${e.message}',
        code: e.code,
      );
    } catch (e) {
      throw HistoryServiceException('Failed to load GPS points: $e');
    }
  }

  /// Get statistics for a specific employee
  ///
  /// Returns aggregated shift statistics over the given date range.
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
        throw HistoryServiceException(
          'You do not have permission to view this employee\'s statistics',
          code: 'ACCESS_DENIED',
        );
      }
      throw HistoryServiceException(
        'Failed to load statistics: ${e.message}',
        code: e.code,
      );
    } catch (e) {
      throw HistoryServiceException('Failed to load statistics: $e');
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
      throw HistoryServiceException(
        'Failed to load team statistics: ${e.message}',
        code: e.code,
      );
    } catch (e) {
      throw HistoryServiceException('Failed to load team statistics: $e');
    }
  }

  /// Get the current user's own shift history
  ///
  /// Returns a list of shifts for the currently authenticated user.
  /// This is a convenience method that uses the current user's ID.
  Future<List<Shift>> getMyShifts(ShiftHistoryFilter filter) async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) {
      throw HistoryServiceException('Not authenticated');
    }

    return getEmployeeShifts(filter.copyWith(employeeId: userId));
  }

  /// Get the current user's ID
  ///
  /// Returns null if not authenticated.
  String? get currentUserId => _supabase.auth.currentUser?.id;

  /// Get the current user's profile
  ///
  /// Returns the employee profile for the authenticated user.
  Future<EmployeeSummary?> getCurrentUserProfile() async {
    final userId = currentUserId;
    if (userId == null) return null;

    try {
      final response = await _supabase
          .from('employee_profiles')
          .select()
          .eq('id', userId)
          .maybeSingle();

      if (response == null) return null;

      return EmployeeSummary.fromJson(response);
    } catch (e) {
      throw HistoryServiceException('Failed to load profile: $e');
    }
  }

  /// Convert history RPC response to Shift model
  Shift _shiftFromHistoryJson(Map<String, dynamic> json) {
    // Map the RPC response fields to Shift model
    return Shift(
      id: json['id'] as String,
      employeeId: json['employee_id'] as String,
      status: ShiftStatus.fromJson(json['status'] as String),
      clockedInAt: DateTime.parse(json['clocked_in_at'] as String),
      clockInLocation: json['clock_in_location'] != null
          ? GeoPoint.fromJson(json['clock_in_location'] as Map<String, dynamic>)
          : null,
      clockInAccuracy: (json['clock_in_accuracy'] as num?)?.toDouble(),
      clockedOutAt: json['clocked_out_at'] != null
          ? DateTime.parse(json['clocked_out_at'] as String)
          : null,
      clockOutLocation: json['clock_out_location'] != null
          ? GeoPoint.fromJson(
              json['clock_out_location'] as Map<String, dynamic>)
          : null,
      clockOutAccuracy: (json['clock_out_accuracy'] as num?)?.toDouble(),
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['created_at'] as String),
      // Additional fields from RPC
      gpsPointCount: json['gps_point_count'] as int?,
    );
  }
}

/// GPS point data for route display
class GpsPointData {
  final String id;
  final double latitude;
  final double longitude;
  final double? accuracy;
  final DateTime capturedAt;

  const GpsPointData({
    required this.id,
    required this.latitude,
    required this.longitude,
    this.accuracy,
    required this.capturedAt,
  });

  factory GpsPointData.fromJson(Map<String, dynamic> json) {
    return GpsPointData(
      id: json['id'] as String,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      accuracy: (json['accuracy'] as num?)?.toDouble(),
      capturedAt: DateTime.parse(json['captured_at'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'captured_at': capturedAt.toIso8601String(),
      };
}

/// Exception thrown by HistoryService operations
class HistoryServiceException implements Exception {
  final String message;
  final String? code;

  const HistoryServiceException(this.message, {this.code});

  @override
  String toString() => 'HistoryServiceException: $message';
}
