import 'shift_enums.dart';

class LunchBreak {
  final String id;
  final String shiftId;
  final String employeeId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final SyncStatus syncStatus;
  final String? serverId;
  final DateTime createdAt;

  const LunchBreak({
    required this.id,
    required this.shiftId,
    required this.employeeId,
    required this.startedAt,
    this.endedAt,
    this.syncStatus = SyncStatus.pending,
    this.serverId,
    required this.createdAt,
  });

  bool get isActive => endedAt == null;

  Duration? get duration =>
      endedAt != null ? endedAt!.difference(startedAt) : null;

  factory LunchBreak.fromMap(Map<String, dynamic> map) {
    return LunchBreak(
      id: map['id'] as String,
      shiftId: map['shift_id'] as String,
      employeeId: map['employee_id'] as String,
      startedAt: DateTime.parse(map['started_at'] as String),
      endedAt: map['ended_at'] != null
          ? DateTime.parse(map['ended_at'] as String)
          : null,
      syncStatus:
          SyncStatus.fromJson(map['sync_status'] as String? ?? 'pending'),
      serverId: map['server_id'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  LunchBreak copyWith({
    DateTime? endedAt,
    SyncStatus? syncStatus,
    String? serverId,
  }) {
    return LunchBreak(
      id: id,
      shiftId: shiftId,
      employeeId: employeeId,
      startedAt: startedAt,
      endedAt: endedAt ?? this.endedAt,
      syncStatus: syncStatus ?? this.syncStatus,
      serverId: serverId ?? this.serverId,
      createdAt: createdAt,
    );
  }
}
