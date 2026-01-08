import 'package:flutter/foundation.dart';

/// Value object representing a GPS coordinate pair.
@immutable
class GeoPoint {
  final double latitude;
  final double longitude;

  const GeoPoint({
    required this.latitude,
    required this.longitude,
  })  : assert(latitude >= -90.0 && latitude <= 90.0,
            'Latitude must be between -90.0 and 90.0'),
        assert(longitude >= -180.0 && longitude <= 180.0,
            'Longitude must be between -180.0 and 180.0');

  factory GeoPoint.fromJson(Map<String, dynamic> json) => GeoPoint(
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GeoPoint &&
          runtimeType == other.runtimeType &&
          latitude == other.latitude &&
          longitude == other.longitude;

  @override
  int get hashCode => latitude.hashCode ^ longitude.hashCode;

  @override
  String toString() => 'GeoPoint(lat: $latitude, lng: $longitude)';
}
