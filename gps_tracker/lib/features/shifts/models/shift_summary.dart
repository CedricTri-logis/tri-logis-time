import 'package:flutter/foundation.dart';

import 'shift.dart';
import 'shift_enums.dart';

/// Aggregated view for history display (computed from Shift).
@immutable
class ShiftSummary {
  final String id;
  final DateTime date;
  final Duration duration;
  final String? locationSummary;
  final ShiftStatus status;

  const ShiftSummary({
    required this.id,
    required this.date,
    required this.duration,
    this.locationSummary,
    required this.status,
  });

  /// Format the duration as "Xh Ym".
  String get formattedDuration {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    if (hours == 0) {
      return '${minutes}m';
    }
    return '${hours}h ${minutes}m';
  }

  /// Format the duration as "HH:MM:SS".
  String get formattedDurationLong {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// Create a ShiftSummary from a Shift model.
  factory ShiftSummary.fromShift(Shift shift) {
    return ShiftSummary(
      id: shift.id,
      date: shift.clockedInAt.toLocal(),
      duration: shift.duration,
      locationSummary: shift.clockInLocation != null ? 'Location recorded' : null,
      status: shift.status,
    );
  }
}
