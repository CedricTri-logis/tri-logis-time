import 'geo_point.dart';
import 'shift.dart';
import 'shift_enums.dart';

/// Local shift model for SQLite storage with sync tracking.
class LocalShift {
  final String id;
  final String employeeId;
  final String? requestId;
  final String status;
  final DateTime clockedInAt;
  final double? clockInLatitude;
  final double? clockInLongitude;
  final double? clockInAccuracy;
  final DateTime? clockedOutAt;
  final double? clockOutLatitude;
  final double? clockOutLongitude;
  final double? clockOutAccuracy;
  final String syncStatus;
  final DateTime? lastSyncAttempt;
  final String? syncError;
  final String? serverId;
  final DateTime createdAt;
  final DateTime updatedAt;

  LocalShift({
    required this.id,
    required this.employeeId,
    this.requestId,
    required this.status,
    required this.clockedInAt,
    this.clockInLatitude,
    this.clockInLongitude,
    this.clockInAccuracy,
    this.clockedOutAt,
    this.clockOutLatitude,
    this.clockOutLongitude,
    this.clockOutAccuracy,
    required this.syncStatus,
    this.lastSyncAttempt,
    this.syncError,
    this.serverId,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Convert to SQLite map format.
  Map<String, dynamic> toMap() => {
        'id': id,
        'employee_id': employeeId,
        'request_id': requestId,
        'status': status,
        'clocked_in_at': clockedInAt.toUtc().toIso8601String(),
        'clock_in_latitude': clockInLatitude,
        'clock_in_longitude': clockInLongitude,
        'clock_in_accuracy': clockInAccuracy,
        'clocked_out_at': clockedOutAt?.toUtc().toIso8601String(),
        'clock_out_latitude': clockOutLatitude,
        'clock_out_longitude': clockOutLongitude,
        'clock_out_accuracy': clockOutAccuracy,
        'sync_status': syncStatus,
        'last_sync_attempt': lastSyncAttempt?.toUtc().toIso8601String(),
        'sync_error': syncError,
        'server_id': serverId,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  /// Create from SQLite map format.
  factory LocalShift.fromMap(Map<String, dynamic> map) => LocalShift(
        id: map['id'] as String,
        employeeId: map['employee_id'] as String,
        requestId: map['request_id'] as String?,
        status: map['status'] as String,
        clockedInAt: DateTime.parse(map['clocked_in_at'] as String),
        clockInLatitude: map['clock_in_latitude'] as double?,
        clockInLongitude: map['clock_in_longitude'] as double?,
        clockInAccuracy: map['clock_in_accuracy'] as double?,
        clockedOutAt: map['clocked_out_at'] != null
            ? DateTime.parse(map['clocked_out_at'] as String)
            : null,
        clockOutLatitude: map['clock_out_latitude'] as double?,
        clockOutLongitude: map['clock_out_longitude'] as double?,
        clockOutAccuracy: map['clock_out_accuracy'] as double?,
        syncStatus: map['sync_status'] as String,
        lastSyncAttempt: map['last_sync_attempt'] != null
            ? DateTime.parse(map['last_sync_attempt'] as String)
            : null,
        syncError: map['sync_error'] as String?,
        serverId: map['server_id'] as String?,
        createdAt: DateTime.parse(map['created_at'] as String),
        updatedAt: DateTime.parse(map['updated_at'] as String),
      );

  /// Convert to Shift model for UI display.
  Shift toShift() => Shift(
        id: id,
        employeeId: employeeId,
        requestId: requestId,
        status: ShiftStatus.fromJson(status),
        clockedInAt: clockedInAt,
        clockInLocation: clockInLatitude != null && clockInLongitude != null
            ? GeoPoint(latitude: clockInLatitude!, longitude: clockInLongitude!)
            : null,
        clockInAccuracy: clockInAccuracy,
        clockedOutAt: clockedOutAt,
        clockOutLocation: clockOutLatitude != null && clockOutLongitude != null
            ? GeoPoint(
                latitude: clockOutLatitude!, longitude: clockOutLongitude!)
            : null,
        clockOutAccuracy: clockOutAccuracy,
        syncStatus: SyncStatus.fromJson(syncStatus),
        serverId: serverId,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );

  /// Create LocalShift from Shift model.
  factory LocalShift.fromShift(Shift shift) => LocalShift(
        id: shift.id,
        employeeId: shift.employeeId,
        requestId: shift.requestId,
        status: shift.status.toJson(),
        clockedInAt: shift.clockedInAt,
        clockInLatitude: shift.clockInLocation?.latitude,
        clockInLongitude: shift.clockInLocation?.longitude,
        clockInAccuracy: shift.clockInAccuracy,
        clockedOutAt: shift.clockedOutAt,
        clockOutLatitude: shift.clockOutLocation?.latitude,
        clockOutLongitude: shift.clockOutLocation?.longitude,
        clockOutAccuracy: shift.clockOutAccuracy,
        syncStatus: shift.syncStatus.toJson(),
        createdAt: shift.createdAt,
        updatedAt: shift.updatedAt,
      );

  LocalShift copyWith({
    String? id,
    String? employeeId,
    String? requestId,
    String? status,
    DateTime? clockedInAt,
    double? clockInLatitude,
    double? clockInLongitude,
    double? clockInAccuracy,
    DateTime? clockedOutAt,
    double? clockOutLatitude,
    double? clockOutLongitude,
    double? clockOutAccuracy,
    String? syncStatus,
    DateTime? lastSyncAttempt,
    String? syncError,
    String? serverId,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      LocalShift(
        id: id ?? this.id,
        employeeId: employeeId ?? this.employeeId,
        requestId: requestId ?? this.requestId,
        status: status ?? this.status,
        clockedInAt: clockedInAt ?? this.clockedInAt,
        clockInLatitude: clockInLatitude ?? this.clockInLatitude,
        clockInLongitude: clockInLongitude ?? this.clockInLongitude,
        clockInAccuracy: clockInAccuracy ?? this.clockInAccuracy,
        clockedOutAt: clockedOutAt ?? this.clockedOutAt,
        clockOutLatitude: clockOutLatitude ?? this.clockOutLatitude,
        clockOutLongitude: clockOutLongitude ?? this.clockOutLongitude,
        clockOutAccuracy: clockOutAccuracy ?? this.clockOutAccuracy,
        syncStatus: syncStatus ?? this.syncStatus,
        lastSyncAttempt: lastSyncAttempt ?? this.lastSyncAttempt,
        syncError: syncError ?? this.syncError,
        serverId: serverId ?? this.serverId,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
