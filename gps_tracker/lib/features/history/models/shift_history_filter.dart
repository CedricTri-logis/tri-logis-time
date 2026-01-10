import 'package:flutter/foundation.dart';

/// Filter criteria for shift history queries
///
/// Provides filtering by employee, date range, and search query
/// with pagination support.
@immutable
class ShiftHistoryFilter {
  final String? employeeId;
  final DateTime? startDate;
  final DateTime? endDate;
  final String? searchQuery;
  final int limit;
  final int offset;

  const ShiftHistoryFilter({
    this.employeeId,
    this.startDate,
    this.endDate,
    this.searchQuery,
    this.limit = 50,
    this.offset = 0,
  });

  /// Default filter for last 30 days
  factory ShiftHistoryFilter.defaultFilter({String? employeeId}) {
    final now = DateTime.now();
    return ShiftHistoryFilter(
      employeeId: employeeId,
      startDate: DateTime(now.year, now.month, now.day)
          .subtract(const Duration(days: 30)),
      endDate: DateTime(now.year, now.month, now.day, 23, 59, 59),
    );
  }

  /// Filter for current month
  factory ShiftHistoryFilter.currentMonth({String? employeeId}) {
    final now = DateTime.now();
    return ShiftHistoryFilter(
      employeeId: employeeId,
      startDate: DateTime(now.year, now.month, 1),
      endDate: DateTime(now.year, now.month + 1, 0, 23, 59, 59),
    );
  }

  /// Filter for all history (no date restriction)
  factory ShiftHistoryFilter.allHistory({String? employeeId}) {
    return ShiftHistoryFilter(
      employeeId: employeeId,
    );
  }

  /// Whether any filters are currently active
  bool get hasFilters =>
      startDate != null || endDate != null || searchQuery?.isNotEmpty == true;

  /// Description of the current date range filter
  String get dateRangeDescription {
    if (startDate == null && endDate == null) return 'All time';
    if (startDate != null && endDate != null) {
      return '${_formatDate(startDate!)} - ${_formatDate(endDate!)}';
    }
    if (startDate != null) return 'From ${_formatDate(startDate!)}';
    return 'Until ${_formatDate(endDate!)}';
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }

  ShiftHistoryFilter copyWith({
    String? employeeId,
    DateTime? startDate,
    DateTime? endDate,
    String? searchQuery,
    int? limit,
    int? offset,
    bool clearStartDate = false,
    bool clearEndDate = false,
    bool clearSearchQuery = false,
  }) {
    return ShiftHistoryFilter(
      employeeId: employeeId ?? this.employeeId,
      startDate: clearStartDate ? null : (startDate ?? this.startDate),
      endDate: clearEndDate ? null : (endDate ?? this.endDate),
      searchQuery:
          clearSearchQuery ? null : (searchQuery ?? this.searchQuery),
      limit: limit ?? this.limit,
      offset: offset ?? this.offset,
    );
  }

  /// Next page of results
  ShiftHistoryFilter nextPage() => copyWith(offset: offset + limit);

  /// Reset to first page
  ShiftHistoryFilter firstPage() => copyWith(offset: 0);

  /// Clear all filters except employee
  ShiftHistoryFilter clearFilters() => ShiftHistoryFilter(
        employeeId: employeeId,
        limit: limit,
        offset: 0,
      );

  /// Convert to query parameters for Supabase RPC
  Map<String, dynamic> toQueryParams() {
    final params = <String, dynamic>{
      'p_limit': limit,
      'p_offset': offset,
    };

    if (employeeId != null) {
      params['p_employee_id'] = employeeId;
    }
    if (startDate != null) {
      params['p_start_date'] = startDate!.toUtc().toIso8601String();
    }
    if (endDate != null) {
      params['p_end_date'] = endDate!.toUtc().toIso8601String();
    }

    return params;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ShiftHistoryFilter &&
        other.employeeId == employeeId &&
        other.startDate == startDate &&
        other.endDate == endDate &&
        other.searchQuery == searchQuery &&
        other.limit == limit &&
        other.offset == offset;
  }

  @override
  int get hashCode {
    return Object.hash(
      employeeId,
      startDate,
      endDate,
      searchQuery,
      limit,
      offset,
    );
  }

  @override
  String toString() {
    return 'ShiftHistoryFilter(employeeId: $employeeId, dateRange: $dateRangeDescription, limit: $limit, offset: $offset)';
  }
}
