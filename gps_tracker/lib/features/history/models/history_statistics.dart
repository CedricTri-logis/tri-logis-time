import 'package:flutter/foundation.dart';

/// Aggregated statistics for shift history
///
/// Contains calculated metrics for shift data over a given period,
/// used for dashboards and reporting.
@immutable
class HistoryStatistics {
  final int totalShifts;
  final Duration totalHours;
  final Duration averageShiftDuration;
  final DateTime? earliestShift;
  final DateTime? latestShift;
  final int totalGpsPoints;

  const HistoryStatistics({
    required this.totalShifts,
    required this.totalHours,
    required this.averageShiftDuration,
    this.earliestShift,
    this.latestShift,
    this.totalGpsPoints = 0,
  });

  /// Empty statistics (no data)
  static const empty = HistoryStatistics(
    totalShifts: 0,
    totalHours: Duration.zero,
    averageShiftDuration: Duration.zero,
  );

  /// Duration of the period covered by these statistics
  Duration get periodCovered {
    if (earliestShift == null || latestShift == null) return Duration.zero;
    return latestShift!.difference(earliestShift!);
  }

  /// Whether there is any data
  bool get hasData => totalShifts > 0;

  /// Format total hours as a human-readable string
  String get formattedTotalHours {
    final hours = totalHours.inHours;
    final minutes = totalHours.inMinutes.remainder(60);
    if (hours == 0 && minutes == 0) return '0h';
    if (minutes == 0) return '${hours}h';
    return '${hours}h ${minutes}m';
  }

  /// Format average duration as a human-readable string
  String get formattedAverageDuration {
    final hours = averageShiftDuration.inHours;
    final minutes = averageShiftDuration.inMinutes.remainder(60);
    if (hours == 0 && minutes == 0) return '0h';
    if (hours == 0) return '${minutes}m';
    if (minutes == 0) return '${hours}h';
    return '${hours}h ${minutes}m';
  }

  factory HistoryStatistics.fromJson(Map<String, dynamic> json) {
    return HistoryStatistics(
      totalShifts: json['total_shifts'] as int? ?? 0,
      totalHours:
          Duration(seconds: (json['total_seconds'] as num?)?.toInt() ?? 0),
      averageShiftDuration: Duration(
        seconds: (json['avg_duration_seconds'] as num?)?.toInt() ?? 0,
      ),
      earliestShift: json['earliest_shift'] != null
          ? DateTime.parse(json['earliest_shift'] as String)
          : null,
      latestShift: json['latest_shift'] != null
          ? DateTime.parse(json['latest_shift'] as String)
          : null,
      totalGpsPoints: (json['total_gps_points'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'total_shifts': totalShifts,
        'total_seconds': totalHours.inSeconds,
        'avg_duration_seconds': averageShiftDuration.inSeconds,
        'earliest_shift': earliestShift?.toIso8601String(),
        'latest_shift': latestShift?.toIso8601String(),
        'total_gps_points': totalGpsPoints,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is HistoryStatistics &&
        other.totalShifts == totalShifts &&
        other.totalHours == totalHours &&
        other.averageShiftDuration == averageShiftDuration &&
        other.earliestShift == earliestShift &&
        other.latestShift == latestShift &&
        other.totalGpsPoints == totalGpsPoints;
  }

  @override
  int get hashCode {
    return Object.hash(
      totalShifts,
      totalHours,
      averageShiftDuration,
      earliestShift,
      latestShift,
      totalGpsPoints,
    );
  }

  @override
  String toString() {
    return 'HistoryStatistics(shifts: $totalShifts, hours: $formattedTotalHours, avgDuration: $formattedAverageDuration)';
  }
}

/// Aggregated team statistics for a manager's view
@immutable
class TeamStatistics {
  final int totalEmployees;
  final int totalShifts;
  final Duration totalHours;
  final Duration averageShiftDuration;
  final double averageShiftsPerEmployee;

  const TeamStatistics({
    required this.totalEmployees,
    required this.totalShifts,
    required this.totalHours,
    required this.averageShiftDuration,
    required this.averageShiftsPerEmployee,
  });

  /// Empty team statistics (no data)
  static const empty = TeamStatistics(
    totalEmployees: 0,
    totalShifts: 0,
    totalHours: Duration.zero,
    averageShiftDuration: Duration.zero,
    averageShiftsPerEmployee: 0,
  );

  /// Whether there is any data
  bool get hasData => totalEmployees > 0;

  /// Format total hours as a human-readable string
  String get formattedTotalHours {
    final hours = totalHours.inHours;
    final minutes = totalHours.inMinutes.remainder(60);
    if (hours == 0 && minutes == 0) return '0h';
    if (minutes == 0) return '${hours}h';
    return '${hours}h ${minutes}m';
  }

  factory TeamStatistics.fromJson(Map<String, dynamic> json) {
    return TeamStatistics(
      totalEmployees: json['total_employees'] as int? ?? 0,
      totalShifts: json['total_shifts'] as int? ?? 0,
      totalHours:
          Duration(seconds: (json['total_seconds'] as num?)?.toInt() ?? 0),
      averageShiftDuration: Duration(
        seconds: (json['avg_duration_seconds'] as num?)?.toInt() ?? 0,
      ),
      averageShiftsPerEmployee:
          (json['avg_shifts_per_employee'] as num?)?.toDouble() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'total_employees': totalEmployees,
        'total_shifts': totalShifts,
        'total_seconds': totalHours.inSeconds,
        'avg_duration_seconds': averageShiftDuration.inSeconds,
        'avg_shifts_per_employee': averageShiftsPerEmployee,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TeamStatistics &&
        other.totalEmployees == totalEmployees &&
        other.totalShifts == totalShifts &&
        other.totalHours == totalHours &&
        other.averageShiftDuration == averageShiftDuration &&
        other.averageShiftsPerEmployee == averageShiftsPerEmployee;
  }

  @override
  int get hashCode {
    return Object.hash(
      totalEmployees,
      totalShifts,
      totalHours,
      averageShiftDuration,
      averageShiftsPerEmployee,
    );
  }

  @override
  String toString() {
    return 'TeamStatistics(employees: $totalEmployees, shifts: $totalShifts, hours: $formattedTotalHours)';
  }
}
