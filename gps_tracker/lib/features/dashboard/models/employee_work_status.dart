import 'package:flutter/foundation.dart';

/// Single employee row in team dashboard list.
///
/// Represents an employee's current work status and statistics
/// for display in the manager's team dashboard.
@immutable
class TeamEmployeeStatus {
  final String employeeId;
  final String displayName;
  final String email;
  final String? employeeNumber;
  final bool isActive;
  final DateTime? currentShiftStartedAt;
  final Duration todayHours;
  final Duration weeklyHours;
  final int weeklyShiftCount;
  final DateTime? latestGpsCapturedAt;

  const TeamEmployeeStatus({
    required this.employeeId,
    required this.displayName,
    required this.email,
    this.employeeNumber,
    this.isActive = false,
    this.currentShiftStartedAt,
    this.todayHours = Duration.zero,
    this.weeklyHours = Duration.zero,
    this.weeklyShiftCount = 0,
    this.latestGpsCapturedAt,
  });

  /// Current shift duration if active.
  Duration get currentShiftDuration {
    if (!isActive || currentShiftStartedAt == null) return Duration.zero;
    return DateTime.now().difference(currentShiftStartedAt!);
  }

  /// Format today's hours for display.
  String get formattedTodayHours {
    final hours = todayHours.inHours;
    final minutes = todayHours.inMinutes.remainder(60);
    if (hours == 0 && minutes == 0) return '0h';
    if (minutes == 0) return '${hours}h';
    return '${hours}h ${minutes}m';
  }

  /// Format weekly hours for display.
  String get formattedWeeklyHours {
    final hours = weeklyHours.inHours;
    final minutes = weeklyHours.inMinutes.remainder(60);
    if (hours == 0 && minutes == 0) return '0h';
    if (minutes == 0) return '${hours}h';
    return '${hours}h ${minutes}m';
  }

  /// Status display text.
  String get statusText {
    if (!isActive) return 'Not clocked in';
    final duration = currentShiftDuration;
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    if (hours == 0) return 'Active ${minutes}m';
    return 'Active ${hours}h ${minutes}m';
  }

  factory TeamEmployeeStatus.fromJson(Map<String, dynamic> json) {
    return TeamEmployeeStatus(
      employeeId: json['employee_id'] as String,
      displayName: json['display_name'] as String,
      email: json['email'] as String,
      employeeNumber: json['employee_number'] as String?,
      isActive: json['is_active'] as bool? ?? false,
      currentShiftStartedAt: json['current_shift_started_at'] != null
          ? DateTime.parse(json['current_shift_started_at'] as String)
          : null,
      todayHours: Duration(
        seconds: (json['today_hours_seconds'] as num?)?.toInt() ?? 0,
      ),
      weeklyHours: Duration(
        seconds: (json['weekly_hours_seconds'] as num?)?.toInt() ?? 0,
      ),
      weeklyShiftCount: json['weekly_shift_count'] as int? ?? 0,
      latestGpsCapturedAt: json['latest_gps_captured_at'] != null
          ? DateTime.parse(json['latest_gps_captured_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'employee_id': employeeId,
        'display_name': displayName,
        'email': email,
        'employee_number': employeeNumber,
        'is_active': isActive,
        'current_shift_started_at': currentShiftStartedAt?.toIso8601String(),
        'today_hours_seconds': todayHours.inSeconds,
        'weekly_hours_seconds': weeklyHours.inSeconds,
        'weekly_shift_count': weeklyShiftCount,
        'latest_gps_captured_at': latestGpsCapturedAt?.toIso8601String(),
      };

  TeamEmployeeStatus copyWith({
    String? employeeId,
    String? displayName,
    String? email,
    String? employeeNumber,
    bool? isActive,
    DateTime? currentShiftStartedAt,
    Duration? todayHours,
    Duration? weeklyHours,
    int? weeklyShiftCount,
    DateTime? latestGpsCapturedAt,
    bool clearCurrentShift = false,
    bool clearLatestGps = false,
  }) {
    return TeamEmployeeStatus(
      employeeId: employeeId ?? this.employeeId,
      displayName: displayName ?? this.displayName,
      email: email ?? this.email,
      employeeNumber: employeeNumber ?? this.employeeNumber,
      isActive: isActive ?? this.isActive,
      currentShiftStartedAt: clearCurrentShift
          ? null
          : (currentShiftStartedAt ?? this.currentShiftStartedAt),
      todayHours: todayHours ?? this.todayHours,
      weeklyHours: weeklyHours ?? this.weeklyHours,
      weeklyShiftCount: weeklyShiftCount ?? this.weeklyShiftCount,
      latestGpsCapturedAt: clearLatestGps
          ? null
          : (latestGpsCapturedAt ?? this.latestGpsCapturedAt),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TeamEmployeeStatus &&
        other.employeeId == employeeId &&
        other.displayName == displayName &&
        other.email == email &&
        other.employeeNumber == employeeNumber &&
        other.isActive == isActive &&
        other.currentShiftStartedAt == currentShiftStartedAt &&
        other.todayHours == todayHours &&
        other.weeklyHours == weeklyHours &&
        other.weeklyShiftCount == weeklyShiftCount &&
        other.latestGpsCapturedAt == latestGpsCapturedAt;
  }

  @override
  int get hashCode => Object.hash(
        employeeId,
        displayName,
        email,
        employeeNumber,
        isActive,
        currentShiftStartedAt,
        todayHours,
        weeklyHours,
        weeklyShiftCount,
        latestGpsCapturedAt,
      );

  @override
  String toString() =>
      'TeamEmployeeStatus(name: $displayName, active: $isActive, today: $formattedTodayHours)';
}
