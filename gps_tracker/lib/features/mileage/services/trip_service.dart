import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../shared/models/diagnostic_event.dart';
import '../../../shared/services/diagnostic_logger.dart';
import '../models/local_trip.dart';
import '../models/trip.dart';
import 'mileage_local_db.dart';

/// Service for trip detection and retrieval via Supabase,
/// with offline caching through SQLCipher local database.
class TripService {
  final SupabaseClient _supabase;
  final MileageLocalDb? _localDb;

  TripService(this._supabase, [this._localDb]);

  DiagnosticLogger? get _logger => DiagnosticLogger.isInitialized ? DiagnosticLogger.instance : null;

  /// Trigger trip detection for a completed shift.
  /// Returns the list of detected trips.
  /// This is idempotent — re-running deletes previous trips and re-detects.
  Future<List<Trip>> detectTrips(String shiftId) async {
    try {
      final response = await _supabase.rpc(
        'detect_trips',
        params: {'p_shift_id': shiftId},
      );

      if (response == null) return [];

      final List<dynamic> rows = response is List ? response : [response];
      final trips = rows.map((row) {
        final map = row as Map<String, dynamic>;
        return Trip(
          id: map['trip_id'] as String,
          shiftId: shiftId,
          employeeId: _supabase.auth.currentUser?.id ?? '',
          startedAt: DateTime.parse(map['started_at'] as String),
          endedAt: DateTime.parse(map['ended_at'] as String),
          startLatitude: (map['start_latitude'] as num).toDouble(),
          startLongitude: (map['start_longitude'] as num).toDouble(),
          endLatitude: (map['end_latitude'] as num).toDouble(),
          endLongitude: (map['end_longitude'] as num).toDouble(),
          distanceKm: (map['distance_km'] as num).toDouble(),
          durationMinutes: (map['duration_minutes'] as num).toInt(),
          confidenceScore: (map['confidence_score'] as num).toDouble(),
          gpsPointCount: (map['gps_point_count'] as num).toInt(),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
      }).toList();

      // Cache detected trips locally
      await _cacheTrips(trips);

      return trips;
    } catch (e) {
      _logger?.sync(Severity.warn, 'Trip detection failed', metadata: {'shift_id': shiftId, 'error': e.toString()});
      return [];
    }
  }

  /// Trigger trip detection without waiting for results (fire-and-forget).
  void detectTripsAsync(String shiftId) {
    detectTrips(shiftId).then((_) {
      _logger?.sync(Severity.debug, 'Trip detection completed', metadata: {'shift_id': shiftId});
    }).catchError((e) {
      _logger?.sync(Severity.warn, 'Trip detection failed', metadata: {'shift_id': shiftId, 'error': e.toString()});
    });
  }

  /// Get all trips for a specific shift.
  /// Falls back to local cache when offline.
  Future<List<Trip>> getTripsForShift(String shiftId) async {
    try {
      final response = await _supabase
          .from('trips')
          .select()
          .eq('shift_id', shiftId)
          .order('started_at', ascending: true);

      final trips = (response as List)
          .map((row) => Trip.fromJson(row as Map<String, dynamic>))
          .toList();

      // Cache for offline use
      await _cacheTrips(trips);

      return trips;
    } catch (e) {
      _logger?.sync(Severity.warn, 'Failed to fetch trips for shift', metadata: {'shift_id': shiftId, 'error': e.toString()});
      // Try local cache
      return _getLocalTripsForShift(shiftId);
    }
  }

  /// Get all trips for an employee in a date range.
  /// Falls back to local cache when offline.
  Future<List<Trip>> getTripsForPeriod(
    String employeeId,
    DateTime start,
    DateTime end,
  ) async {
    try {
      final response = await _supabase
          .from('trips')
          .select()
          .eq('employee_id', employeeId)
          .gte('started_at', start.toUtc().toIso8601String())
          .lt('started_at', end.toUtc().toIso8601String())
          .order('started_at', ascending: false);

      final trips = (response as List)
          .map((row) => Trip.fromJson(row as Map<String, dynamic>))
          .toList();

      // Cache for offline use
      await _cacheTrips(trips);

      return trips;
    } catch (e) {
      _logger?.sync(Severity.warn, 'Failed to fetch trips for period', metadata: {'error': e.toString()});
      // Try local cache
      return _getLocalTripsForPeriod(employeeId, start, end);
    }
  }

  /// Update trip classification (business/personal).
  /// Saves locally if Supabase is unreachable.
  Future<bool> updateTripClassification(
    String tripId,
    TripClassification classification,
  ) async {
    try {
      await _supabase
          .from('trips')
          .update({'classification': classification.toJson()})
          .eq('id', tripId);

      // Update local cache
      await _localDb?.updateTripClassification(
        tripId,
        classification.toJson(),
      );
      await _localDb?.markTripSynced(tripId);

      return true;
    } catch (e) {
      _logger?.sync(Severity.warn, 'Trip classification update failed', metadata: {'trip_id': tripId, 'error': e.toString()});
      // Save locally for sync later
      try {
        await _localDb?.updateTripClassification(
          tripId,
          classification.toJson(),
        );
        return true;
      } catch (_) {
        return false;
      }
    }
  }

  /// Sync pending classification changes to Supabase.
  Future<int> syncPendingClassifications() async {
    if (_localDb == null) return 0;

    try {
      final pending = await _localDb!.getPendingClassificationChanges();
      int synced = 0;

      for (final localTrip in pending) {
        try {
          await _supabase
              .from('trips')
              .update({'classification': localTrip.classification})
              .eq('id', localTrip.id);
          await _localDb!.markTripSynced(localTrip.id);
          synced++;
        } catch (e) {
          _logger?.sync(Severity.warn, 'Failed to sync classification for trip', metadata: {'trip_id': localTrip.id, 'error': e.toString()});
        }
      }

      return synced;
    } catch (e) {
      _logger?.sync(Severity.warn, 'Failed to sync pending classifications', metadata: {'error': e.toString()});
      return 0;
    }
  }

  /// Update trip address (after reverse geocoding).
  Future<void> updateTripAddress({
    required String tripId,
    String? startAddress,
    String? endAddress,
  }) async {
    try {
      final updates = <String, dynamic>{};
      if (startAddress != null) updates['start_address'] = startAddress;
      if (endAddress != null) updates['end_address'] = endAddress;
      if (updates.isEmpty) return;

      await _supabase.from('trips').update(updates).eq('id', tripId);
    } catch (e) {
      _logger?.sync(Severity.warn, 'Failed to update trip address', metadata: {'trip_id': tripId, 'error': e.toString()});
    }
  }

  /// Cache trips locally for offline access.
  Future<void> _cacheTrips(List<Trip> trips) async {
    if (_localDb == null || trips.isEmpty) return;
    try {
      final localTrips = trips.map((t) => LocalTrip.fromTrip(t)).toList();
      await _localDb!.upsertTrips(localTrips);
    } catch (e) {
      _logger?.sync(Severity.warn, 'Failed to cache trips locally', metadata: {'error': e.toString()});
    }
  }

  /// Get trips from local cache for a shift.
  Future<List<Trip>> _getLocalTripsForShift(String shiftId) async {
    if (_localDb == null) return [];
    try {
      final local = await _localDb!.getTripsForShift(shiftId);
      return local.map((lt) => lt.toTrip()).toList();
    } catch (e) {
      _logger?.sync(Severity.warn, 'Failed to get local trips for shift', metadata: {'shift_id': shiftId, 'error': e.toString()});
      return [];
    }
  }

  /// Get trips from local cache for a period.
  Future<List<Trip>> _getLocalTripsForPeriod(
    String employeeId,
    DateTime start,
    DateTime end,
  ) async {
    if (_localDb == null) return [];
    try {
      final local = await _localDb!.getTripsForPeriod(employeeId, start, end);
      return local.map((lt) => lt.toTrip()).toList();
    } catch (e) {
      _logger?.sync(Severity.warn, 'Failed to get local trips for period', metadata: {'error': e.toString()});
      return [];
    }
  }
}
