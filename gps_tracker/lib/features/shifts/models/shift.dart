import 'package:flutter/foundation.dart';

import 'geo_point.dart';
import 'shift_enums.dart';

/// Represents a work session for an employee from clock-in to clock-out.
@immutable
class Shift {
  final String id;
  final String employeeId;
  final String? requestId;
  final ShiftStatus status;
  final DateTime clockedInAt;
  final GeoPoint? clockInLocation;
  final double? clockInAccuracy;
  final DateTime? clockedOutAt;
  final GeoPoint? clockOutLocation;
  final double? clockOutAccuracy;
  final SyncStatus syncStatus;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Shift({
    required this.id,
    required this.employeeId,
    this.requestId,
    required this.status,
    required this.clockedInAt,
    this.clockInLocation,
    this.clockInAccuracy,
    this.clockedOutAt,
    this.clockOutLocation,
    this.clockOutAccuracy,
    this.syncStatus = SyncStatus.synced,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Computed duration of the shift.
  Duration get duration {
    if (clockedOutAt == null) {
      return DateTime.now().difference(clockedInAt);
    }
    return clockedOutAt!.difference(clockedInAt);
  }

  /// Whether the shift is currently active.
  bool get isActive => status == ShiftStatus.active;

  /// Whether the shift has been completed.
  bool get isCompleted => status == ShiftStatus.completed;

  factory Shift.fromJson(Map<String, dynamic> json) => Shift(
        id: json['id'] as String,
        employeeId: json['employee_id'] as String,
        requestId: json['request_id'] as String?,
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
            ? GeoPoint.fromJson(json['clock_out_location'] as Map<String, dynamic>)
            : null,
        clockOutAccuracy: (json['clock_out_accuracy'] as num?)?.toDouble(),
        syncStatus: json['sync_status'] != null
            ? SyncStatus.fromJson(json['sync_status'] as String)
            : SyncStatus.synced,
        createdAt: DateTime.parse(json['created_at'] as String),
        updatedAt: DateTime.parse(json['updated_at'] as String),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'employee_id': employeeId,
        'request_id': requestId,
        'status': status.toJson(),
        'clocked_in_at': clockedInAt.toUtc().toIso8601String(),
        'clock_in_location': clockInLocation?.toJson(),
        'clock_in_accuracy': clockInAccuracy,
        'clocked_out_at': clockedOutAt?.toUtc().toIso8601String(),
        'clock_out_location': clockOutLocation?.toJson(),
        'clock_out_accuracy': clockOutAccuracy,
        'sync_status': syncStatus.toJson(),
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  Shift copyWith({
    String? id,
    String? employeeId,
    String? requestId,
    ShiftStatus? status,
    DateTime? clockedInAt,
    GeoPoint? clockInLocation,
    double? clockInAccuracy,
    DateTime? clockedOutAt,
    GeoPoint? clockOutLocation,
    double? clockOutAccuracy,
    SyncStatus? syncStatus,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      Shift(
        id: id ?? this.id,
        employeeId: employeeId ?? this.employeeId,
        requestId: requestId ?? this.requestId,
        status: status ?? this.status,
        clockedInAt: clockedInAt ?? this.clockedInAt,
        clockInLocation: clockInLocation ?? this.clockInLocation,
        clockInAccuracy: clockInAccuracy ?? this.clockInAccuracy,
        clockedOutAt: clockedOutAt ?? this.clockedOutAt,
        clockOutLocation: clockOutLocation ?? this.clockOutLocation,
        clockOutAccuracy: clockOutAccuracy ?? this.clockOutAccuracy,
        syncStatus: syncStatus ?? this.syncStatus,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Shift && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'Shift(id: $id, status: $status, clockedInAt: $clockedInAt)';
}
