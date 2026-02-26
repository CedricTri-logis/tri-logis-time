import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../history/models/history_statistics.dart';
import 'employee_work_status.dart';

/// Date range filter presets for team statistics.
enum DateRangePreset {
  today('Today'),
  thisWeek('This Week'),
  thisMonth('This Month'),
  custom('Custom Range');

  final String label;
  const DateRangePreset(this.label);

  /// Convert preset to date range.
  DateTimeRange toDateRange() {
    final now = DateTime.now();
    switch (this) {
      case DateRangePreset.today:
        return DateTimeRange(
          start: DateTime(now.year, now.month, now.day),
          end: now,
        );
      case DateRangePreset.thisWeek:
        // Week starts on Sunday (weekday 7 in Dart)
        final weekStart = now.subtract(Duration(days: now.weekday % 7));
        return DateTimeRange(
          start: DateTime(weekStart.year, weekStart.month, weekStart.day),
          end: now,
        );
      case DateRangePreset.thisMonth:
        return DateTimeRange(
          start: DateTime(now.year, now.month, 1),
          end: now,
        );
      case DateRangePreset.custom:
        throw StateError('Custom preset requires explicit date range');
    }
  }
}

/// Manager's team overview state.
@immutable
class TeamDashboardState {
  final List<TeamEmployeeStatus> employees;
  final String searchQuery;
  final DateTime? lastUpdated;
  final bool isLoading;
  final String? error;

  const TeamDashboardState({
    this.employees = const [],
    this.searchQuery = '',
    this.lastUpdated,
    this.isLoading = false,
    this.error,
  });

  /// Initial loading state.
  factory TeamDashboardState.loading() =>
      const TeamDashboardState(isLoading: true);

  /// Error state.
  factory TeamDashboardState.error(String message) =>
      TeamDashboardState(error: message);

  /// Count of currently clocked-in employees.
  int get activeCount => employees.where((e) => e.isActive).length;

  /// Total employee count.
  int get totalCount => employees.length;

  /// Whether there are supervised employees.
  bool get hasEmployees => employees.isNotEmpty;

  /// Whether dashboard has loaded successfully.
  bool get isLoaded => !isLoading && error == null;

  /// Employees filtered by search query.
  List<TeamEmployeeStatus> get filteredEmployees {
    if (searchQuery.isEmpty) return employees;

    final lowerQuery = searchQuery.toLowerCase();
    return employees.where((employee) {
      return employee.displayName.toLowerCase().contains(lowerQuery) ||
          (employee.employeeNumber?.toLowerCase().contains(lowerQuery) ??
              false) ||
          employee.email.toLowerCase().contains(lowerQuery);
    }).toList();
  }

  TeamDashboardState copyWith({
    List<TeamEmployeeStatus>? employees,
    String? searchQuery,
    DateTime? lastUpdated,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return TeamDashboardState(
      employees: employees ?? this.employees,
      searchQuery: searchQuery ?? this.searchQuery,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TeamDashboardState &&
        listEquals(other.employees, employees) &&
        other.searchQuery == searchQuery &&
        other.lastUpdated == lastUpdated &&
        other.isLoading == isLoading &&
        other.error == error;
  }

  @override
  int get hashCode => Object.hash(
        Object.hashAll(employees),
        searchQuery,
        lastUpdated,
        isLoading,
        error,
      );
}

/// Team aggregate statistics with date filtering.
@immutable
class TeamStatisticsState {
  final DateTimeRange dateRange;
  final DateRangePreset dateRangePreset;
  final TeamStatistics statistics;
  final List<EmployeeHoursData> employeeHours;
  final bool isLoading;
  final String? error;

  TeamStatisticsState({
    DateTimeRange? dateRange,
    this.dateRangePreset = DateRangePreset.thisMonth,
    TeamStatistics? statistics,
    this.employeeHours = const [],
    this.isLoading = false,
    this.error,
  })  : dateRange = dateRange ?? DateRangePreset.thisMonth.toDateRange(),
        statistics = statistics ?? TeamStatistics.empty;

  /// Initial loading state with this month preset.
  factory TeamStatisticsState.loading() =>
      TeamStatisticsState(isLoading: true);

  /// Error state.
  factory TeamStatisticsState.error(String message) =>
      TeamStatisticsState(error: message);

  /// Whether statistics have loaded successfully.
  bool get isLoaded => !isLoading && error == null;

  /// Whether there is chart data to display.
  bool get hasChartData => employeeHours.isNotEmpty;

  /// Maximum hours for chart scaling.
  double get maxHours {
    if (employeeHours.isEmpty) return 0;
    return employeeHours.map((e) => e.totalHours).reduce((a, b) => a > b ? a : b);
  }

  TeamStatisticsState copyWith({
    DateTimeRange? dateRange,
    DateRangePreset? dateRangePreset,
    TeamStatistics? statistics,
    List<EmployeeHoursData>? employeeHours,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return TeamStatisticsState(
      dateRange: dateRange ?? this.dateRange,
      dateRangePreset: dateRangePreset ?? this.dateRangePreset,
      statistics: statistics ?? this.statistics,
      employeeHours: employeeHours ?? this.employeeHours,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TeamStatisticsState &&
        other.dateRange == dateRange &&
        other.dateRangePreset == dateRangePreset &&
        other.statistics == statistics &&
        listEquals(other.employeeHours, employeeHours) &&
        other.isLoading == isLoading &&
        other.error == error;
  }

  @override
  int get hashCode => Object.hash(
        dateRange,
        dateRangePreset,
        statistics,
        Object.hashAll(employeeHours),
        isLoading,
        error,
      );
}

/// Single employee data point for bar chart.
@immutable
class EmployeeHoursData {
  final String employeeId;
  final String displayName;
  final double totalHours;

  const EmployeeHoursData({
    required this.employeeId,
    required this.displayName,
    required this.totalHours,
  });

  factory EmployeeHoursData.fromJson(Map<String, dynamic> json) {
    return EmployeeHoursData(
      employeeId: json['employee_id'] as String,
      displayName: json['display_name'] as String,
      totalHours: (json['total_hours'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'employee_id': employeeId,
        'display_name': displayName,
        'total_hours': totalHours,
      };

  /// Format hours for display.
  String get formattedHours {
    if (totalHours == 0) return '0h';
    final hours = totalHours.truncate();
    final minutes = ((totalHours - hours) * 60).round();
    if (minutes == 0) return '${hours}h';
    return '${hours}h ${minutes}m';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is EmployeeHoursData &&
        other.employeeId == employeeId &&
        other.displayName == displayName &&
        other.totalHours == totalHours;
  }

  @override
  int get hashCode => Object.hash(employeeId, displayName, totalHours);
}
