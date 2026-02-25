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

  // Extended GPS data (nullable — older builds won't populate these)
  final double? speed;
  final double? speedAccuracy;
  final double? heading;
  final double? headingAccuracy;
  final double? altitude;
  final double? altitudeAccuracy;
  final bool? isMocked;

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
    this.speed,
    this.speedAccuracy,
    this.heading,
    this.headingAccuracy,
    this.altitude,
    this.altitudeAccuracy,
    this.isMocked,
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
        'speed': speed,
        'speed_accuracy': speedAccuracy,
        'heading': heading,
        'heading_accuracy': headingAccuracy,
        'altitude': altitude,
        'altitude_accuracy': altitudeAccuracy,
        'is_mocked': isMocked == true ? 1 : (isMocked == false ? 0 : null),
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
        speed: (map['speed'] as num?)?.toDouble(),
        speedAccuracy: (map['speed_accuracy'] as num?)?.toDouble(),
        heading: (map['heading'] as num?)?.toDouble(),
        headingAccuracy: (map['heading_accuracy'] as num?)?.toDouble(),
        altitude: (map['altitude'] as num?)?.toDouble(),
        altitudeAccuracy: (map['altitude_accuracy'] as num?)?.toDouble(),
        isMocked: map['is_mocked'] == null
            ? null
            : (map['is_mocked'] == 1 || map['is_mocked'] == true),
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
        if (speed != null) 'speed': speed,
        if (speedAccuracy != null) 'speed_accuracy': speedAccuracy,
        if (heading != null) 'heading': heading,
        if (headingAccuracy != null) 'heading_accuracy': headingAccuracy,
        if (altitude != null) 'altitude': altitude,
        if (altitudeAccuracy != null) 'altitude_accuracy': altitudeAccuracy,
        if (isMocked != null) 'is_mocked': isMocked,
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
    double? speed,
    double? speedAccuracy,
    double? heading,
    double? headingAccuracy,
    double? altitude,
    double? altitudeAccuracy,
    bool? isMocked,
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
        speed: speed ?? this.speed,
        speedAccuracy: speedAccuracy ?? this.speedAccuracy,
        heading: heading ?? this.heading,
        headingAccuracy: headingAccuracy ?? this.headingAccuracy,
        altitude: altitude ?? this.altitude,
        altitudeAccuracy: altitudeAccuracy ?? this.altitudeAccuracy,
        isMocked: isMocked ?? this.isMocked,
      );
}
