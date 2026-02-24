import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shifts/providers/shift_provider.dart';
import '../models/trip.dart';
import '../services/mileage_local_db.dart';
import '../services/trip_service.dart';

/// Shared TripService instance with offline caching.
final tripServiceProvider = Provider<TripService>((ref) {
  final localDb = ref.watch(localDatabaseProvider);
  return TripService(Supabase.instance.client, MileageLocalDb(localDb));
});

/// Provider for trips of a specific shift.
final tripsForShiftProvider =
    FutureProvider.family<List<Trip>, String>((ref, shiftId) async {
  final service = ref.read(tripServiceProvider);
  return service.getTripsForShift(shiftId);
});

/// Parameters for period-based trip queries.
class TripPeriodParams {
  final String employeeId;
  final DateTime start;
  final DateTime end;

  const TripPeriodParams({
    required this.employeeId,
    required this.start,
    required this.end,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TripPeriodParams &&
          runtimeType == other.runtimeType &&
          employeeId == other.employeeId &&
          start == other.start &&
          end == other.end;

  @override
  int get hashCode => Object.hash(employeeId, start, end);
}

/// Provider for trips in a date range for an employee.
final tripsForPeriodProvider =
    FutureProvider.family<List<Trip>, TripPeriodParams>((ref, params) async {
  final service = ref.read(tripServiceProvider);
  return service.getTripsForPeriod(params.employeeId, params.start, params.end);
});
