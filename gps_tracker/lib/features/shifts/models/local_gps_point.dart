/// Local GPS point model for SQLite storage with sync tracking.
class LocalGpsPoint {
  final String id;
  final String shiftId;
  final String employeeId;
  final double latitude;
  final double longitude;
  final double? accuracy;
  final DateTime capturedAt;
  final String? deviceId;
  final String syncStatus;
  final DateTime createdAt;

  LocalGpsPoint({
    required this.id,
    required this.shiftId,
    required this.employeeId,
    required this.latitude,
    required this.longitude,
    this.accuracy,
    required this.capturedAt,
    this.deviceId,
    required this.syncStatus,
    required this.createdAt,
  });

  /// Convert to SQLite map format.
  Map<String, dynamic> toMap() => {
        'id': id,
        'shift_id': shiftId,
        'employee_id': employeeId,
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'captured_at': capturedAt.toUtc().toIso8601String(),
        'device_id': deviceId,
        'sync_status': syncStatus,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  /// Create from SQLite map format.
  factory LocalGpsPoint.fromMap(Map<String, dynamic> map) => LocalGpsPoint(
        id: map['id'] as String,
        shiftId: map['shift_id'] as String,
        employeeId: map['employee_id'] as String,
        latitude: map['latitude'] as double,
        longitude: map['longitude'] as double,
        accuracy: map['accuracy'] as double?,
        capturedAt: DateTime.parse(map['captured_at'] as String),
        deviceId: map['device_id'] as String?,
        syncStatus: map['sync_status'] as String,
        createdAt: DateTime.parse(map['created_at'] as String),
      );

  /// Convert to JSON for Supabase RPC.
  Map<String, dynamic> toJson() => {
        'client_id': id,
        'shift_id': shiftId,
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'captured_at': capturedAt.toUtc().toIso8601String(),
        'device_id': deviceId,
      };

  LocalGpsPoint copyWith({
    String? id,
    String? shiftId,
    String? employeeId,
    double? latitude,
    double? longitude,
    double? accuracy,
    DateTime? capturedAt,
    String? deviceId,
    String? syncStatus,
    DateTime? createdAt,
  }) =>
      LocalGpsPoint(
        id: id ?? this.id,
        shiftId: shiftId ?? this.shiftId,
        employeeId: employeeId ?? this.employeeId,
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        accuracy: accuracy ?? this.accuracy,
        capturedAt: capturedAt ?? this.capturedAt,
        deviceId: deviceId ?? this.deviceId,
        syncStatus: syncStatus ?? this.syncStatus,
        createdAt: createdAt ?? this.createdAt,
      );
}
