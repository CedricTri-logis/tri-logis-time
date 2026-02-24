import 'package:flutter/foundation.dart';

enum TripClassification {
  business,
  personal;

  factory TripClassification.fromJson(String value) {
    switch (value) {
      case 'business':
        return TripClassification.business;
      case 'personal':
        return TripClassification.personal;
      default:
        return TripClassification.business;
    }
  }

  String toJson() => name;
}

enum TripDetectionMethod {
  auto,
  manual;

  factory TripDetectionMethod.fromJson(String value) {
    switch (value) {
      case 'auto':
        return TripDetectionMethod.auto;
      case 'manual':
        return TripDetectionMethod.manual;
      default:
        return TripDetectionMethod.auto;
    }
  }

  String toJson() => name;
}

@immutable
class Trip {
  final String id;
  final String shiftId;
  final String employeeId;
  final DateTime startedAt;
  final DateTime endedAt;
  final double startLatitude;
  final double startLongitude;
  final String? startAddress;
  final String? startLocationId;
  final double endLatitude;
  final double endLongitude;
  final String? endAddress;
  final String? endLocationId;
  final double distanceKm;
  final int durationMinutes;
  final TripClassification classification;
  final double confidenceScore;
  final int gpsPointCount;
  final int lowAccuracySegments;
  final TripDetectionMethod detectionMethod;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Trip({
    required this.id,
    required this.shiftId,
    required this.employeeId,
    required this.startedAt,
    required this.endedAt,
    required this.startLatitude,
    required this.startLongitude,
    this.startAddress,
    this.startLocationId,
    required this.endLatitude,
    required this.endLongitude,
    this.endAddress,
    this.endLocationId,
    required this.distanceKm,
    required this.durationMinutes,
    this.classification = TripClassification.business,
    this.confidenceScore = 1.0,
    this.gpsPointCount = 0,
    this.lowAccuracySegments = 0,
    this.detectionMethod = TripDetectionMethod.auto,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isLowConfidence => confidenceScore < 0.7;
  bool get isBusiness => classification == TripClassification.business;

  String get startDisplayName =>
      startAddress ?? '${startLatitude.toStringAsFixed(4)}, ${startLongitude.toStringAsFixed(4)}';

  String get endDisplayName =>
      endAddress ?? '${endLatitude.toStringAsFixed(4)}, ${endLongitude.toStringAsFixed(4)}';

  factory Trip.fromJson(Map<String, dynamic> json) => Trip(
        id: json['id'] as String,
        shiftId: json['shift_id'] as String,
        employeeId: json['employee_id'] as String,
        startedAt: DateTime.parse(json['started_at'] as String),
        endedAt: DateTime.parse(json['ended_at'] as String),
        startLatitude: (json['start_latitude'] as num).toDouble(),
        startLongitude: (json['start_longitude'] as num).toDouble(),
        startAddress: json['start_address'] as String?,
        startLocationId: json['start_location_id'] as String?,
        endLatitude: (json['end_latitude'] as num).toDouble(),
        endLongitude: (json['end_longitude'] as num).toDouble(),
        endAddress: json['end_address'] as String?,
        endLocationId: json['end_location_id'] as String?,
        distanceKm: (json['distance_km'] as num).toDouble(),
        durationMinutes: (json['duration_minutes'] as num).toInt(),
        classification: TripClassification.fromJson(
            json['classification'] as String? ?? 'business'),
        confidenceScore: (json['confidence_score'] as num?)?.toDouble() ?? 1.0,
        gpsPointCount: (json['gps_point_count'] as num?)?.toInt() ?? 0,
        lowAccuracySegments:
            (json['low_accuracy_segments'] as num?)?.toInt() ?? 0,
        detectionMethod: TripDetectionMethod.fromJson(
            json['detection_method'] as String? ?? 'auto'),
        createdAt: DateTime.parse(json['created_at'] as String),
        updatedAt: DateTime.parse(json['updated_at'] as String),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'shift_id': shiftId,
        'employee_id': employeeId,
        'started_at': startedAt.toUtc().toIso8601String(),
        'ended_at': endedAt.toUtc().toIso8601String(),
        'start_latitude': startLatitude,
        'start_longitude': startLongitude,
        'start_address': startAddress,
        'start_location_id': startLocationId,
        'end_latitude': endLatitude,
        'end_longitude': endLongitude,
        'end_address': endAddress,
        'end_location_id': endLocationId,
        'distance_km': distanceKm,
        'duration_minutes': durationMinutes,
        'classification': classification.toJson(),
        'confidence_score': confidenceScore,
        'gps_point_count': gpsPointCount,
        'low_accuracy_segments': lowAccuracySegments,
        'detection_method': detectionMethod.toJson(),
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  Trip copyWith({
    TripClassification? classification,
    String? startAddress,
    String? endAddress,
  }) =>
      Trip(
        id: id,
        shiftId: shiftId,
        employeeId: employeeId,
        startedAt: startedAt,
        endedAt: endedAt,
        startLatitude: startLatitude,
        startLongitude: startLongitude,
        startAddress: startAddress ?? this.startAddress,
        startLocationId: startLocationId,
        endLatitude: endLatitude,
        endLongitude: endLongitude,
        endAddress: endAddress ?? this.endAddress,
        endLocationId: endLocationId,
        distanceKm: distanceKm,
        durationMinutes: durationMinutes,
        classification: classification ?? this.classification,
        confidenceScore: confidenceScore,
        gpsPointCount: gpsPointCount,
        lowAccuracySegments: lowAccuracySegments,
        detectionMethod: detectionMethod,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Trip && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'Trip(id: $id, ${startDisplayName} → ${endDisplayName}, ${distanceKm}km)';
}
