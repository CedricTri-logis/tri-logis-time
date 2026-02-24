import '../../shifts/models/shift_enums.dart';

/// Status of a maintenance session.
enum MaintenanceSessionStatus {
  inProgress,
  completed,
  autoClosed,
  manuallyClosed;

  String toJson() {
    switch (this) {
      case MaintenanceSessionStatus.inProgress:
        return 'in_progress';
      case MaintenanceSessionStatus.completed:
        return 'completed';
      case MaintenanceSessionStatus.autoClosed:
        return 'auto_closed';
      case MaintenanceSessionStatus.manuallyClosed:
        return 'manually_closed';
    }
  }

  static MaintenanceSessionStatus fromJson(String json) {
    switch (json) {
      case 'completed':
        return MaintenanceSessionStatus.completed;
      case 'auto_closed':
        return MaintenanceSessionStatus.autoClosed;
      case 'manually_closed':
        return MaintenanceSessionStatus.manuallyClosed;
      default:
        return MaintenanceSessionStatus.inProgress;
    }
  }

  String get displayName {
    switch (this) {
      case MaintenanceSessionStatus.inProgress:
        return 'En cours';
      case MaintenanceSessionStatus.completed:
        return 'Terminé';
      case MaintenanceSessionStatus.autoClosed:
        return 'Auto-fermé';
      case MaintenanceSessionStatus.manuallyClosed:
        return 'Fermé manuellement';
    }
  }

  bool get isActive => this == MaintenanceSessionStatus.inProgress;
}

/// Represents a maintenance session for a building/apartment.
class MaintenanceSession {
  final String id;
  final String employeeId;
  final String shiftId;
  final String buildingId;
  final String? apartmentId;
  final MaintenanceSessionStatus status;
  final DateTime startedAt;
  final DateTime? completedAt;
  final double? durationMinutes;
  final String? notes;
  final SyncStatus syncStatus;

  // GPS capture at start/end
  final double? startLatitude;
  final double? startLongitude;
  final double? startAccuracy;
  final double? endLatitude;
  final double? endLongitude;
  final double? endAccuracy;

  // Denormalized for display
  final String buildingName;
  final String? unitNumber;

  const MaintenanceSession({
    required this.id,
    required this.employeeId,
    required this.shiftId,
    required this.buildingId,
    this.apartmentId,
    required this.status,
    required this.startedAt,
    this.completedAt,
    this.durationMinutes,
    this.notes,
    this.syncStatus = SyncStatus.pending,
    this.startLatitude,
    this.startLongitude,
    this.startAccuracy,
    this.endLatitude,
    this.endLongitude,
    this.endAccuracy,
    required this.buildingName,
    this.unitNumber,
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
    if (unitNumber != null) {
      return '$unitNumber — $buildingName';
    }
    return buildingName;
  }

  MaintenanceSession copyWith({
    String? id,
    String? employeeId,
    String? shiftId,
    String? buildingId,
    String? apartmentId,
    MaintenanceSessionStatus? status,
    DateTime? startedAt,
    DateTime? completedAt,
    double? durationMinutes,
    String? notes,
    SyncStatus? syncStatus,
    double? startLatitude,
    double? startLongitude,
    double? startAccuracy,
    double? endLatitude,
    double? endLongitude,
    double? endAccuracy,
    String? buildingName,
    String? unitNumber,
    bool clearCompletedAt = false,
    bool clearApartmentId = false,
  }) {
    return MaintenanceSession(
      id: id ?? this.id,
      employeeId: employeeId ?? this.employeeId,
      shiftId: shiftId ?? this.shiftId,
      buildingId: buildingId ?? this.buildingId,
      apartmentId:
          clearApartmentId ? null : (apartmentId ?? this.apartmentId),
      status: status ?? this.status,
      startedAt: startedAt ?? this.startedAt,
      completedAt:
          clearCompletedAt ? null : (completedAt ?? this.completedAt),
      durationMinutes: durationMinutes ?? this.durationMinutes,
      notes: notes ?? this.notes,
      syncStatus: syncStatus ?? this.syncStatus,
      startLatitude: startLatitude ?? this.startLatitude,
      startLongitude: startLongitude ?? this.startLongitude,
      startAccuracy: startAccuracy ?? this.startAccuracy,
      endLatitude: endLatitude ?? this.endLatitude,
      endLongitude: endLongitude ?? this.endLongitude,
      endAccuracy: endAccuracy ?? this.endAccuracy,
      buildingName: buildingName ?? this.buildingName,
      unitNumber: unitNumber ?? this.unitNumber,
    );
  }

  factory MaintenanceSession.fromLocalDb(Map<String, dynamic> map) {
    return MaintenanceSession(
      id: map['id'] as String,
      employeeId: map['employee_id'] as String,
      shiftId: map['shift_id'] as String,
      buildingId: map['building_id'] as String,
      apartmentId: map['apartment_id'] as String?,
      status: MaintenanceSessionStatus.fromJson(map['status'] as String),
      startedAt: DateTime.parse(map['started_at'] as String),
      completedAt: map['completed_at'] != null
          ? DateTime.parse(map['completed_at'] as String)
          : null,
      durationMinutes: map['duration_minutes'] != null
          ? (map['duration_minutes'] as num).toDouble()
          : null,
      notes: map['notes'] as String?,
      syncStatus:
          SyncStatus.fromJson(map['sync_status'] as String? ?? 'pending'),
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
      buildingName: map['building_name'] as String? ?? '',
      unitNumber: map['unit_number'] as String?,
    );
  }

  Map<String, dynamic> toLocalDb() => {
        'id': id,
        'employee_id': employeeId,
        'shift_id': shiftId,
        'building_id': buildingId,
        'apartment_id': apartmentId,
        'status': status.toJson(),
        'started_at': startedAt.toUtc().toIso8601String(),
        'completed_at': completedAt?.toUtc().toIso8601String(),
        'duration_minutes': durationMinutes,
        'notes': notes,
        'sync_status': syncStatus.toJson(),
        'start_latitude': startLatitude,
        'start_longitude': startLongitude,
        'start_accuracy': startAccuracy,
        'end_latitude': endLatitude,
        'end_longitude': endLongitude,
        'end_accuracy': endAccuracy,
        'building_name': buildingName,
        'unit_number': unitNumber,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
}
