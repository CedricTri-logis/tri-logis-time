import 'package:flutter/foundation.dart';

@immutable
class MileageSummary {
  final double totalDistanceKm;
  final double businessDistanceKm;
  final double personalDistanceKm;
  final int tripCount;
  final int businessTripCount;
  final int personalTripCount;
  final double estimatedReimbursement;
  final double ratePerKmUsed;
  final String rateSource;
  final double ytdBusinessKm;

  const MileageSummary({
    required this.totalDistanceKm,
    required this.businessDistanceKm,
    required this.personalDistanceKm,
    required this.tripCount,
    required this.businessTripCount,
    required this.personalTripCount,
    required this.estimatedReimbursement,
    required this.ratePerKmUsed,
    required this.rateSource,
    required this.ytdBusinessKm,
  });

  bool get isEmpty => tripCount == 0;

  factory MileageSummary.fromJson(Map<String, dynamic> json) => MileageSummary(
        totalDistanceKm: (json['total_distance_km'] as num).toDouble(),
        businessDistanceKm: (json['business_distance_km'] as num).toDouble(),
        personalDistanceKm: (json['personal_distance_km'] as num).toDouble(),
        tripCount: (json['trip_count'] as num).toInt(),
        businessTripCount: (json['business_trip_count'] as num).toInt(),
        personalTripCount: (json['personal_trip_count'] as num).toInt(),
        estimatedReimbursement:
            (json['estimated_reimbursement'] as num).toDouble(),
        ratePerKmUsed: (json['rate_per_km_used'] as num).toDouble(),
        rateSource: json['rate_source'] as String,
        ytdBusinessKm: (json['ytd_business_km'] as num).toDouble(),
      );

  factory MileageSummary.empty() => const MileageSummary(
        totalDistanceKm: 0,
        businessDistanceKm: 0,
        personalDistanceKm: 0,
        tripCount: 0,
        businessTripCount: 0,
        personalTripCount: 0,
        estimatedReimbursement: 0,
        ratePerKmUsed: 0,
        rateSource: 'none',
        ytdBusinessKm: 0,
      );
}
