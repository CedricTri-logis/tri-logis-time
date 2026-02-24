import 'package:flutter/foundation.dart';

@immutable
class ReimbursementRate {
  final String id;
  final double ratePerKm;
  final int? thresholdKm;
  final double? rateAfterThreshold;
  final DateTime effectiveFrom;
  final DateTime? effectiveTo;
  final String rateSource;
  final String? notes;
  final DateTime createdAt;

  const ReimbursementRate({
    required this.id,
    required this.ratePerKm,
    this.thresholdKm,
    this.rateAfterThreshold,
    required this.effectiveFrom,
    this.effectiveTo,
    required this.rateSource,
    this.notes,
    required this.createdAt,
  });

  bool get isTiered => thresholdKm != null && rateAfterThreshold != null;

  String get displayRate {
    if (isTiered) {
      return '\$${ratePerKm.toStringAsFixed(2)}/km (first ${thresholdKm}km), '
          '\$${rateAfterThreshold!.toStringAsFixed(2)}/km after';
    }
    return '\$${ratePerKm.toStringAsFixed(2)}/km';
  }

  String get displaySource =>
      rateSource == 'cra' ? 'CRA/ARC ${effectiveFrom.year}' : 'Custom';

  /// Calculate reimbursement for given km, accounting for YTD tier threshold.
  double calculateReimbursement(double km, double ytdKm) {
    if (!isTiered) {
      return km * ratePerKm;
    }
    final remaining = (thresholdKm! - ytdKm).clamp(0.0, km);
    final excess = km - remaining;
    return (remaining * ratePerKm) + (excess * rateAfterThreshold!);
  }

  factory ReimbursementRate.fromJson(Map<String, dynamic> json) =>
      ReimbursementRate(
        id: json['id'] as String,
        ratePerKm: (json['rate_per_km'] as num).toDouble(),
        thresholdKm: (json['threshold_km'] as num?)?.toInt(),
        rateAfterThreshold:
            (json['rate_after_threshold'] as num?)?.toDouble(),
        effectiveFrom: DateTime.parse(json['effective_from'] as String),
        effectiveTo: json['effective_to'] != null
            ? DateTime.parse(json['effective_to'] as String)
            : null,
        rateSource: json['rate_source'] as String,
        notes: json['notes'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  @override
  String toString() => 'ReimbursementRate(${displayRate}, ${displaySource})';
}
