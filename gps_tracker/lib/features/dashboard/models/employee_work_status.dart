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
  final Duration monthlyHours;
  final int monthlyShiftCount;

  const TeamEmployeeStatus({
    required this.employeeId,
    required this.displayName,
    required this.email,
    this.employeeNumber,
    this.isActive = false,
    this.currentShiftStartedAt,
    this.todayHours = Duration.zero,
    this.monthlyHours = Duration.zero,
    this.monthlyShiftCount = 0,
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

  /// Format monthly hours for display.
  String get formattedMonthlyHours {
    final hours = monthlyHours.inHours;
    final minutes = monthlyHours.inMinutes.remainder(60);
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
      monthlyHours: Duration(
        seconds: (json['monthly_hours_seconds'] as num?)?.toInt() ?? 0,
      ),
      monthlyShiftCount: json['monthly_shift_count'] as int? ?? 0,
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
        'monthly_hours_seconds': monthlyHours.inSeconds,
        'monthly_shift_count': monthlyShiftCount,
      };

  TeamEmployeeStatus copyWith({
    String? employeeId,
    String? displayName,
    String? email,
    String? employeeNumber,
    bool? isActive,
    DateTime? currentShiftStartedAt,
    Duration? todayHours,
    Duration? monthlyHours,
    int? monthlyShiftCount,
    bool clearCurrentShift = false,
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
      monthlyHours: monthlyHours ?? this.monthlyHours,
      monthlyShiftCount: monthlyShiftCount ?? this.monthlyShiftCount,
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
        other.monthlyHours == monthlyHours &&
        other.monthlyShiftCount == monthlyShiftCount;
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
        monthlyHours,
        monthlyShiftCount,
      );

  @override
  String toString() =>
      'TeamEmployeeStatus(name: $displayName, active: $isActive, today: $formattedTodayHours)';
}
