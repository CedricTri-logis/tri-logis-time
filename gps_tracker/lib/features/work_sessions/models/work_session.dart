import '../../shifts/models/shift_enums.dart';
import 'activity_type.dart';

/// Status of a work session.
enum WorkSessionStatus {
  inProgress,
  completed,
  autoClosed,
  manuallyClosed;

  String toJson() {
    switch (this) {
      case WorkSessionStatus.inProgress:
        return 'in_progress';
      case WorkSessionStatus.completed:
        return 'completed';
      case WorkSessionStatus.autoClosed:
        return 'auto_closed';
      case WorkSessionStatus.manuallyClosed:
        return 'manually_closed';
    }
  }

  static WorkSessionStatus fromJson(String json) {
    switch (json) {
      case 'completed':
        return WorkSessionStatus.completed;
      case 'auto_closed':
        return WorkSessionStatus.autoClosed;
      case 'manually_closed':
        return WorkSessionStatus.manuallyClosed;
      default:
        return WorkSessionStatus.inProgress;
    }
  }

  String get displayName {
    switch (this) {
      case WorkSessionStatus.inProgress:
        return 'En cours';
      case WorkSessionStatus.completed:
        return 'Terminé';
      case WorkSessionStatus.autoClosed:
        return 'Auto-fermé';
      case WorkSessionStatus.manuallyClosed:
        return 'Fermé manuellement';
    }
  }

  bool get isActive => this == WorkSessionStatus.inProgress;
}

/// Unified work session model replacing CleaningSession + MaintenanceSession.
class WorkSession {
  final String id;
  final String employeeId;
  final String shiftId;
  final ActivityType activityType;
  final String? locationType;
  final WorkSessionStatus status;

  // Location references
  final String? studioId;
  final String? buildingId;
  final String? apartmentId;

  // Denormalized display fields
  final String? buildingName;
  final String? studioNumber;
  final String? unitNumber;
  final String? studioType;

  // Timing
  final DateTime startedAt;
  final DateTime? completedAt;
  final double? durationMinutes;

  // Cleaning-specific flags
  final bool isFlagged;
  final String? flagReason;

  // Maintenance-specific
  final String? notes;

  // GPS capture
  final double? startLatitude;
  final double? startLongitude;
  final double? startAccuracy;
  final double? endLatitude;
  final double? endLongitude;
  final double? endAccuracy;

  // Sync
  final SyncStatus syncStatus;
  final String? serverId;

  const WorkSession({
    required this.id,
    required this.employeeId,
    required this.shiftId,
    required this.activityType,
    required this.status,
    required this.startedAt,
    this.locationType,
    this.studioId,
    this.buildingId,
    this.apartmentId,
    this.buildingName,
    this.studioNumber,
    this.unitNumber,
    this.studioType,
    this.completedAt,
    this.durationMinutes,
    this.isFlagged = false,
    this.flagReason,
    this.notes,
    this.startLatitude,
    this.startLongitude,
    this.startAccuracy,
    this.endLatitude,
    this.endLongitude,
    this.endAccuracy,
    this.syncStatus = SyncStatus.pending,
    this.serverId,
  });

  /// Live duration from start until now (for active sessions).
  Duration get duration {
    if (completedAt != null) {
      return completedAt!.difference(startedAt);
    }
    return DateTime.now().difference(startedAt);
  }

  /// Duration in minutes (computed or stored).
  double get computedDurationMinutes {
    if (durationMinutes != null) return durationMinutes!;
    return duration.inSeconds / 60.0;
  }

  /// Display label for the location.
  String get locationLabel {
    switch (activityType) {
      case ActivityType.cleaning:
        if (studioNumber != null && buildingName != null) {
          return '$studioNumber — $buildingName';
        }
        return studioNumber ?? studioId ?? '';
      case ActivityType.maintenance:
        if (unitNumber != null && buildingName != null) {
          return '$unitNumber — $buildingName';
        }
        return buildingName ?? '';
      case ActivityType.admin:
        return 'Administration';
    }
  }

  WorkSession copyWith({
    String? id,
    String? employeeId,
    String? shiftId,
    ActivityType? activityType,
    String? locationType,
    WorkSessionStatus? status,
    String? studioId,
    String? buildingId,
    String? apartmentId,
    String? buildingName,
    String? studioNumber,
    String? unitNumber,
    String? studioType,
    DateTime? startedAt,
    DateTime? completedAt,
    double? durationMinutes,
    bool? isFlagged,
    String? flagReason,
    String? notes,
    double? startLatitude,
    double? startLongitude,
    double? startAccuracy,
    double? endLatitude,
    double? endLongitude,
    double? endAccuracy,
    SyncStatus? syncStatus,
    String? serverId,
    bool clearCompletedAt = false,
  }) {
    return WorkSession(
      id: id ?? this.id,
      employeeId: employeeId ?? this.employeeId,
      shiftId: shiftId ?? this.shiftId,
      activityType: activityType ?? this.activityType,
      locationType: locationType ?? this.locationType,
      status: status ?? this.status,
      studioId: studioId ?? this.studioId,
      buildingId: buildingId ?? this.buildingId,
      apartmentId: apartmentId ?? this.apartmentId,
      buildingName: buildingName ?? this.buildingName,
      studioNumber: studioNumber ?? this.studioNumber,
      unitNumber: unitNumber ?? this.unitNumber,
      studioType: studioType ?? this.studioType,
      startedAt: startedAt ?? this.startedAt,
      completedAt: clearCompletedAt ? null : (completedAt ?? this.completedAt),
      durationMinutes: durationMinutes ?? this.durationMinutes,
      isFlagged: isFlagged ?? this.isFlagged,
      flagReason: flagReason ?? this.flagReason,
      notes: notes ?? this.notes,
      startLatitude: startLatitude ?? this.startLatitude,
      startLongitude: startLongitude ?? this.startLongitude,
      startAccuracy: startAccuracy ?? this.startAccuracy,
      endLatitude: endLatitude ?? this.endLatitude,
      endLongitude: endLongitude ?? this.endLongitude,
      endAccuracy: endAccuracy ?? this.endAccuracy,
      syncStatus: syncStatus ?? this.syncStatus,
      serverId: serverId ?? this.serverId,
    );
  }

  factory WorkSession.fromLocalDb(Map<String, dynamic> map) {
    return WorkSession(
      id: map['id'] as String,
      employeeId: map['employee_id'] as String,
      shiftId: map['shift_id'] as String,
      activityType: ActivityType.fromJson(map['activity_type'] as String),
      locationType: map['location_type'] as String?,
      status: WorkSessionStatus.fromJson(map['status'] as String),
      studioId: map['studio_id'] as String?,
      buildingId: map['building_id'] as String?,
      apartmentId: map['apartment_id'] as String?,
      buildingName: map['building_name'] as String?,
      studioNumber: map['studio_number'] as String?,
      unitNumber: map['unit_number'] as String?,
      studioType: map['studio_type'] as String?,
      startedAt: DateTime.parse(map['started_at'] as String),
      completedAt: map['completed_at'] != null
          ? DateTime.parse(map['completed_at'] as String)
          : null,
      durationMinutes: map['duration_minutes'] != null
          ? (map['duration_minutes'] as num).toDouble()
          : null,
      isFlagged: (map['is_flagged'] as int?) == 1,
      flagReason: map['flag_reason'] as String?,
      notes: map['notes'] as String?,
      startLatitude: map['start_latitude'] != null
          ? (map['start_latitude'] as num).toDouble()
          : null,
      startLongitude: map['start_longitude'] != null
          ? (map['start_longitude'] as num).toDouble()
          : null,
      startAccuracy: map['start_accuracy'] != null
          ? (map['start_accuracy'] as num).toDouble()
          : null,
      endLatitude: map['end_latitude'] != null
          ? (map['end_latitude'] as num).toDouble()
          : null,
      endLongitude: map['end_longitude'] != null
          ? (map['end_longitude'] as num).toDouble()
          : null,
      endAccuracy: map['end_accuracy'] != null
          ? (map['end_accuracy'] as num).toDouble()
          : null,
      syncStatus:
          SyncStatus.fromJson(map['sync_status'] as String? ?? 'pending'),
      serverId: map['server_id'] as String?,
    );
  }

  Map<String, dynamic> toLocalDb() => {
        'id': id,
        'employee_id': employeeId,
        'shift_id': shiftId,
        'activity_type': activityType.toJson(),
        'location_type': locationType,
        'status': status.toJson(),
        'studio_id': studioId,
        'building_id': buildingId,
        'apartment_id': apartmentId,
        'building_name': buildingName,
        'studio_number': studioNumber,
        'unit_number': unitNumber,
        'studio_type': studioType,
        'started_at': startedAt.toUtc().toIso8601String(),
        'completed_at': completedAt?.toUtc().toIso8601String(),
        'duration_minutes': durationMinutes,
        'is_flagged': isFlagged ? 1 : 0,
        'flag_reason': flagReason,
        'notes': notes,
        'start_latitude': startLatitude,
        'start_longitude': startLongitude,
        'start_accuracy': startAccuracy,
        'end_latitude': endLatitude,
        'end_longitude': endLongitude,
        'end_accuracy': endAccuracy,
        'sync_status': syncStatus.toJson(),
        'server_id': serverId,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
}

/// Result of a work session operation (start, complete, close).
class WorkSessionResult {
  final bool success;
  final WorkSession? session;
  final String? errorType;
  final String? errorMessage;
  final String? warning;

  WorkSessionResult.success(this.session, {this.warning})
      : success = true,
        errorType = null,
        errorMessage = null;

  WorkSessionResult.error(this.errorType, {this.errorMessage})
      : success = false,
        session = null,
        warning = null;
}
