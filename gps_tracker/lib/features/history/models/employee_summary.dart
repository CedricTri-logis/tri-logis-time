import 'package:flutter/foundation.dart';

/// Summary view of an employee for the supervised employees list
///
/// Contains basic profile info plus aggregate shift statistics
/// for quick display in the employee list.
@immutable
class EmployeeSummary {
  final String id;
  final String email;
  final String? fullName;
  final String? employeeId;
  final String status;
  final String role;
  final DateTime? lastShiftAt;
  final int totalShiftsThisMonth;
  final Duration totalHoursThisMonth;

  const EmployeeSummary({
    required this.id,
    required this.email,
    this.fullName,
    this.employeeId,
    this.status = 'active',
    this.role = 'employee',
    this.lastShiftAt,
    this.totalShiftsThisMonth = 0,
    this.totalHoursThisMonth = Duration.zero,
  });

  /// Display name for the employee (full name or email fallback)
  String get displayName => fullName ?? email;

  /// Whether the employee is currently active
  bool get isActive => status == 'active';

  /// Format total hours as a human-readable string
  String get formattedTotalHours {
    final hours = totalHoursThisMonth.inHours;
    final minutes = totalHoursThisMonth.inMinutes.remainder(60);
    if (hours == 0 && minutes == 0) return '0h';
    if (minutes == 0) return '${hours}h';
    return '${hours}h ${minutes}m';
  }

  factory EmployeeSummary.fromJson(Map<String, dynamic> json) {
    // Handle total_hours_this_month which comes as seconds from DB
    final totalSeconds = json['total_hours_this_month'] as int? ?? 0;

    return EmployeeSummary(
      id: json['id'] as String,
      email: json['email'] as String,
      fullName: json['full_name'] as String?,
      employeeId: json['employee_id'] as String?,
      status: json['status'] as String? ?? 'active',
      role: json['role'] as String? ?? 'employee',
      lastShiftAt: json['last_shift_at'] != null
          ? DateTime.parse(json['last_shift_at'] as String)
          : null,
      totalShiftsThisMonth: json['total_shifts_this_month'] as int? ?? 0,
      totalHoursThisMonth: Duration(seconds: totalSeconds),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'full_name': fullName,
        'employee_id': employeeId,
        'status': status,
        'role': role,
        'last_shift_at': lastShiftAt?.toIso8601String(),
        'total_shifts_this_month': totalShiftsThisMonth,
        'total_hours_this_month': totalHoursThisMonth.inSeconds,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is EmployeeSummary &&
        other.id == id &&
        other.email == email &&
        other.fullName == fullName &&
        other.employeeId == employeeId &&
        other.status == status &&
        other.role == role &&
        other.lastShiftAt == lastShiftAt &&
        other.totalShiftsThisMonth == totalShiftsThisMonth &&
        other.totalHoursThisMonth == totalHoursThisMonth;
  }

  @override
  int get hashCode {
    return Object.hash(
      id,
      email,
      fullName,
      employeeId,
      status,
      role,
      lastShiftAt,
      totalShiftsThisMonth,
      totalHoursThisMonth,
    );
  }

  @override
  String toString() {
    return 'EmployeeSummary(id: $id, displayName: $displayName, shiftsThisMonth: $totalShiftsThisMonth)';
  }
}
