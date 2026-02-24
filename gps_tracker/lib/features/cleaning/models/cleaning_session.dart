import '../../shifts/models/shift_enums.dart';
import 'studio.dart';

/// Status of a cleaning session.
enum CleaningSessionStatus {
  inProgress,
  completed,
  autoClosed,
  manuallyClosed;

  String toJson() {
    switch (this) {
      case CleaningSessionStatus.inProgress:
        return 'in_progress';
      case CleaningSessionStatus.completed:
        return 'completed';
      case CleaningSessionStatus.autoClosed:
        return 'auto_closed';
      case CleaningSessionStatus.manuallyClosed:
        return 'manually_closed';
    }
  }

  static CleaningSessionStatus fromJson(String json) {
    switch (json) {
      case 'completed':
        return CleaningSessionStatus.completed;
      case 'auto_closed':
        return CleaningSessionStatus.autoClosed;
      case 'manually_closed':
        return CleaningSessionStatus.manuallyClosed;
      default:
        return CleaningSessionStatus.inProgress;
    }
  }

  String get displayName {
    switch (this) {
      case CleaningSessionStatus.inProgress:
        return 'En cours';
      case CleaningSessionStatus.completed:
        return 'Terminé';
      case CleaningSessionStatus.autoClosed:
        return 'Auto-fermé';
      case CleaningSessionStatus.manuallyClosed:
        return 'Fermé manuellement';
    }
  }

  bool get isActive => this == CleaningSessionStatus.inProgress;
}

/// Represents a cleaning session for a studio.
class CleaningSession {
  final String id;
  final String employeeId;
  final String studioId;
  final String shiftId;
  final CleaningSessionStatus status;
  final DateTime startedAt;
  final DateTime? completedAt;
  final double? durationMinutes;
  final bool isFlagged;
  final String? flagReason;
  final SyncStatus syncStatus;

  // GPS capture at start/end
  final double? startLatitude;
  final double? startLongitude;
  final double? startAccuracy;
  final double? endLatitude;
  final double? endLongitude;
  final double? endAccuracy;

  // Denormalized for display
  final String? studioNumber;
  final String? buildingName;
  final StudioType? studioType;

  const CleaningSession({
    required this.id,
    required this.employeeId,
    required this.studioId,
    required this.shiftId,
    required this.status,
    required this.startedAt,
    this.completedAt,
    this.durationMinutes,
    this.isFlagged = false,
    this.flagReason,
    this.syncStatus = SyncStatus.pending,
    this.startLatitude,
    this.startLongitude,
    this.startAccuracy,
    this.endLatitude,
    this.endLongitude,
    this.endAccuracy,
    this.studioNumber,
    this.buildingName,
    this.studioType,
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

  /// Display label for the studio.
  String get studioLabel {
    if (studioNumber != null && buildingName != null) {
      return '$studioNumber — $buildingName';
    }
    return studioNumber ?? studioId;
  }

  CleaningSession copyWith({
    String? id,
    String? employeeId,
    String? studioId,
    String? shiftId,
    CleaningSessionStatus? status,
    DateTime? startedAt,
    DateTime? completedAt,
    double? durationMinutes,
    bool? isFlagged,
    String? flagReason,
    SyncStatus? syncStatus,
    double? startLatitude,
    double? startLongitude,
    double? startAccuracy,
    double? endLatitude,
    double? endLongitude,
    double? endAccuracy,
    String? studioNumber,
    String? buildingName,
    StudioType? studioType,
    bool clearCompletedAt = false,
  }) {
    return CleaningSession(
      id: id ?? this.id,
      employeeId: employeeId ?? this.employeeId,
      studioId: studioId ?? this.studioId,
      shiftId: shiftId ?? this.shiftId,
      status: status ?? this.status,
      startedAt: startedAt ?? this.startedAt,
      completedAt: clearCompletedAt ? null : (completedAt ?? this.completedAt),
      durationMinutes: durationMinutes ?? this.durationMinutes,
      isFlagged: isFlagged ?? this.isFlagged,
      flagReason: flagReason ?? this.flagReason,
      syncStatus: syncStatus ?? this.syncStatus,
      startLatitude: startLatitude ?? this.startLatitude,
      startLongitude: startLongitude ?? this.startLongitude,
      startAccuracy: startAccuracy ?? this.startAccuracy,
      endLatitude: endLatitude ?? this.endLatitude,
      endLongitude: endLongitude ?? this.endLongitude,
      endAccuracy: endAccuracy ?? this.endAccuracy,
      studioNumber: studioNumber ?? this.studioNumber,
      buildingName: buildingName ?? this.buildingName,
      studioType: studioType ?? this.studioType,
    );
  }

  factory CleaningSession.fromLocalDb(Map<String, dynamic> map) {
    return CleaningSession(
      id: map['id'] as String,
      employeeId: map['employee_id'] as String,
      studioId: map['studio_id'] as String,
      shiftId: map['shift_id'] as String,
      status: CleaningSessionStatus.fromJson(map['status'] as String),
      startedAt: DateTime.parse(map['started_at'] as String),
      completedAt: map['completed_at'] != null
          ? DateTime.parse(map['completed_at'] as String)
          : null,
      durationMinutes: map['duration_minutes'] != null
          ? (map['duration_minutes'] as num).toDouble()
          : null,
      isFlagged: (map['is_flagged'] as int?) == 1,
      flagReason: map['flag_reason'] as String?,
      syncStatus: SyncStatus.fromJson(map['sync_status'] as String? ?? 'pending'),
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
      studioNumber: map['studio_number'] as String?,
      buildingName: map['building_name'] as String?,
      studioType: map['studio_type'] != null
          ? StudioType.fromJson(map['studio_type'] as String)
          : null,
    );
  }

  Map<String, dynamic> toLocalDb() => {
        'id': id,
        'employee_id': employeeId,
        'studio_id': studioId,
        'shift_id': shiftId,
        'status': status.toJson(),
        'started_at': startedAt.toUtc().toIso8601String(),
        'completed_at': completedAt?.toUtc().toIso8601String(),
        'duration_minutes': durationMinutes,
        'is_flagged': isFlagged ? 1 : 0,
        'flag_reason': flagReason,
        'sync_status': syncStatus.toJson(),
        'start_latitude': startLatitude,
        'start_longitude': startLongitude,
        'start_accuracy': startAccuracy,
        'end_latitude': endLatitude,
        'end_longitude': endLongitude,
        'end_accuracy': endAccuracy,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
}
