/// Local model for GPS gap records tracked during a shift.
class LocalGpsGap {
  final String id;
  final String shiftId;
  final String employeeId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String reason;
  final String syncStatus;

  LocalGpsGap({
    required this.id,
    required this.shiftId,
    required this.employeeId,
    required this.startedAt,
    this.endedAt,
    this.reason = 'signal_loss',
    this.syncStatus = 'pending',
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'shift_id': shiftId,
        'employee_id': employeeId,
        'started_at': startedAt.toUtc().toIso8601String(),
        'ended_at': endedAt?.toUtc().toIso8601String(),
        'reason': reason,
        'sync_status': syncStatus,
      };

  factory LocalGpsGap.fromMap(Map<String, dynamic> map) => LocalGpsGap(
        id: map['id'] as String,
        shiftId: map['shift_id'] as String,
        employeeId: map['employee_id'] as String,
        startedAt: DateTime.parse(map['started_at'] as String),
        endedAt: map['ended_at'] != null
            ? DateTime.parse(map['ended_at'] as String)
            : null,
        reason: map['reason'] as String? ?? 'signal_loss',
        syncStatus: map['sync_status'] as String? ?? 'pending',
      );

  /// Convert to JSON for Supabase RPC sync.
  Map<String, dynamic> toJson() => {
        'client_id': id,
        'started_at': startedAt.toUtc().toIso8601String(),
        'ended_at': endedAt?.toUtc().toIso8601String(),
        'reason': reason,
      };
}
