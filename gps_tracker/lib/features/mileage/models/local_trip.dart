import 'trip.dart';

/// Local SQLCipher representation of a trip for offline caching.
class LocalTrip {
  final String id;
  final String shiftId;
  final String employeeId;
  final String startedAt;
  final String endedAt;
  final double startLatitude;
  final double startLongitude;
  final String? startAddress;
  final double endLatitude;
  final double endLongitude;
  final String? endAddress;
  final double distanceKm;
  final int durationMinutes;
  final String classification;
  final double confidenceScore;
  final int gpsPointCount;
  final bool synced;
  final String createdAt;

  const LocalTrip({
    required this.id,
    required this.shiftId,
    required this.employeeId,
    required this.startedAt,
    required this.endedAt,
    required this.startLatitude,
    required this.startLongitude,
    this.startAddress,
    required this.endLatitude,
    required this.endLongitude,
    this.endAddress,
    required this.distanceKm,
    required this.durationMinutes,
    this.classification = 'business',
    this.confidenceScore = 1.0,
    this.gpsPointCount = 0,
    this.synced = false,
    required this.createdAt,
  });

  Trip toTrip() => Trip(
        id: id,
        shiftId: shiftId,
        employeeId: employeeId,
        startedAt: DateTime.parse(startedAt),
        endedAt: DateTime.parse(endedAt),
        startLatitude: startLatitude,
        startLongitude: startLongitude,
        startAddress: startAddress,
        endLatitude: endLatitude,
        endLongitude: endLongitude,
        endAddress: endAddress,
        distanceKm: distanceKm,
        durationMinutes: durationMinutes,
        classification: TripClassification.fromJson(classification),
        confidenceScore: confidenceScore,
        gpsPointCount: gpsPointCount,
        lowAccuracySegments: 0,
        detectionMethod: TripDetectionMethod.auto,
        createdAt: DateTime.parse(createdAt),
        updatedAt: DateTime.parse(createdAt),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'shift_id': shiftId,
        'employee_id': employeeId,
        'started_at': startedAt,
        'ended_at': endedAt,
        'start_latitude': startLatitude,
        'start_longitude': startLongitude,
        'start_address': startAddress,
        'end_latitude': endLatitude,
        'end_longitude': endLongitude,
        'end_address': endAddress,
        'distance_km': distanceKm,
        'duration_minutes': durationMinutes,
        'classification': classification,
        'confidence_score': confidenceScore,
        'gps_point_count': gpsPointCount,
        'synced': synced ? 1 : 0,
        'created_at': createdAt,
      };

  factory LocalTrip.fromMap(Map<String, dynamic> map) => LocalTrip(
        id: map['id'] as String,
        shiftId: map['shift_id'] as String,
        employeeId: map['employee_id'] as String,
        startedAt: map['started_at'] as String,
        endedAt: map['ended_at'] as String,
        startLatitude: (map['start_latitude'] as num).toDouble(),
        startLongitude: (map['start_longitude'] as num).toDouble(),
        startAddress: map['start_address'] as String?,
        endLatitude: (map['end_latitude'] as num).toDouble(),
        endLongitude: (map['end_longitude'] as num).toDouble(),
        endAddress: map['end_address'] as String?,
        distanceKm: (map['distance_km'] as num).toDouble(),
        durationMinutes: (map['duration_minutes'] as num).toInt(),
        classification: map['classification'] as String? ?? 'business',
        confidenceScore: (map['confidence_score'] as num?)?.toDouble() ?? 1.0,
        gpsPointCount: (map['gps_point_count'] as num?)?.toInt() ?? 0,
        synced: (map['synced'] as num?)?.toInt() == 1,
        createdAt: map['created_at'] as String,
      );

  factory LocalTrip.fromTrip(Trip trip) => LocalTrip(
        id: trip.id,
        shiftId: trip.shiftId,
        employeeId: trip.employeeId,
        startedAt: trip.startedAt.toUtc().toIso8601String(),
        endedAt: trip.endedAt.toUtc().toIso8601String(),
        startLatitude: trip.startLatitude,
        startLongitude: trip.startLongitude,
        startAddress: trip.startAddress,
        endLatitude: trip.endLatitude,
        endLongitude: trip.endLongitude,
        endAddress: trip.endAddress,
        distanceKm: trip.distanceKm,
        durationMinutes: trip.durationMinutes,
        classification: trip.classification.toJson(),
        confidenceScore: trip.confidenceScore,
        gpsPointCount: trip.gpsPointCount,
        synced: true,
        createdAt: trip.createdAt.toUtc().toIso8601String(),
      );
}
