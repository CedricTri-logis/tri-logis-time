import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../shared/models/diagnostic_event.dart';
import '../../../shared/services/diagnostic_logger.dart';
import '../models/carpool_info.dart';
import '../models/local_trip.dart';
import '../models/trip.dart';
import 'mileage_local_db.dart';
import 'route_match_service.dart';

/// Service for trip detection and retrieval via Supabase,
/// with offline caching through SQLCipher local database.
class TripService {
  final SupabaseClient _supabase;
  final MileageLocalDb? _localDb;
  RouteMatchService? _routeMatchService;

  TripService(this._supabase, [this._localDb]);

  /// Set the route match service for triggering matching after detection.
  set routeMatchService(RouteMatchService? service) =>
      _routeMatchService = service;

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

      // Trigger route matching asynchronously (fire-and-forget)
      if (_routeMatchService != null && trips.isNotEmpty) {
        final tripIds = trips.map((t) => t.id).toList();
        _routeMatchService!.matchTripsForShift(shiftId, tripIds).catchError((e) {
          _logger?.sync(Severity.warn, 'Route matching failed for shift', metadata: {'shift_id': shiftId, 'error': e.toString()});
        });
      }

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

  /// Re-fetch a single trip from Supabase to get updated match results.
  Future<Trip?> refreshTrip(String tripId) async {
    try {
      final response = await _supabase
          .from('trips')
          .select()
          .eq('id', tripId)
          .maybeSingle();

      if (response == null) return null;

      final trip = Trip.fromJson(response as Map<String, dynamic>);
      await _cacheTrips([trip]);
      return trip;
    } catch (e) {
      _logger?.sync(Severity.warn, 'Failed to refresh trip', metadata: {'trip_id': tripId, 'error': e.toString()});
      return null;
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

  /// Get carpool info for a list of trip IDs.
  /// Returns a map keyed by trip_id with carpool details.
  Future<Map<String, CarpoolInfo>> getCarpoolInfoForTrips(List<String> tripIds) async {
    if (tripIds.isEmpty) return {};

    try {
      // Fetch carpool_members for these trips
      final membersResponse = await _supabase
          .from('carpool_members')
          .select()
          .inFilter('trip_id', tripIds);

      final members = membersResponse as List;
      if (members.isEmpty) return {};

      // Get unique group IDs
      final groupIds = members.map((m) => m['carpool_group_id'] as String).toSet().toList();

      // Fetch all members for these groups (to get co-members)
      final allMembersResponse = await _supabase
          .from('carpool_members')
          .select()
          .inFilter('carpool_group_id', groupIds);

      final allMembers = (allMembersResponse as List?) ?? [];

      // Fetch employee names
      final employeeIds = allMembers.map((m) => m['employee_id'] as String).toSet().toList();
      final employeesResponse = await _supabase
          .from('employee_profiles')
          .select('id, name')
          .inFilter('id', employeeIds);

      final employeeMap = <String, String>{};
      for (final ep in (employeesResponse as List)) {
        employeeMap[ep['id'] as String] = ep['name'] as String? ?? 'Inconnu';
      }

      // Fetch carpool_groups for driver info
      final groupsResponse = await _supabase
          .from('carpool_groups')
          .select()
          .inFilter('id', groupIds);

      final groupMap = <String, Map<String, dynamic>>{};
      for (final g in (groupsResponse as List)) {
        groupMap[g['id'] as String] = g as Map<String, dynamic>;
      }

      // Build result map
      final result = <String, CarpoolInfo>{};

      for (final member in members) {
        final tripId = member['trip_id'] as String;
        final groupId = member['carpool_group_id'] as String;
        final group = groupMap[groupId];
        final driverEmployeeId = group?['driver_employee_id'] as String?;
        final driverName = driverEmployeeId != null ? employeeMap[driverEmployeeId] : null;

        // Get all members of this group
        final groupMembers = allMembers
            .where((m) => m['carpool_group_id'] == groupId)
            .map((m) => CarpoolMemberInfo(
                  employeeId: m['employee_id'] as String,
                  employeeName: employeeMap[m['employee_id'] as String] ?? 'Inconnu',
                  role: CarpoolRole.fromJson(m['role'] as String? ?? 'unassigned'),
                ),)
            .toList();

        result[tripId] = CarpoolInfo(
          groupId: groupId,
          myRole: CarpoolRole.fromJson(member['role'] as String? ?? 'unassigned'),
          driverName: driverName,
          members: groupMembers,
        );
      }

      return result;
    } catch (e) {
      _logger?.sync(Severity.warn, 'Failed to fetch carpool info', metadata: {'error': e.toString()});
      return {};
    }
  }

  /// Check if employee has an active company vehicle period in the given date range.
  Future<bool> hasCompanyVehicleInRange(String employeeId, DateTime start, DateTime end) async {
    try {
      final response = await _supabase
          .from('employee_vehicle_periods')
          .select('id')
          .eq('employee_id', employeeId)
          .eq('vehicle_type', 'company')
          .lte('started_at', end.toIso8601String().substring(0, 10))
          .or('ended_at.is.null,ended_at.gte.${start.toIso8601String().substring(0, 10)}')
          .limit(1);

      return (response as List).isNotEmpty;
    } catch (e) {
      _logger?.sync(Severity.warn, 'Failed to check company vehicle', metadata: {'error': e.toString()});
      return false;
    }
  }

  /// Get active company vehicle dates for an employee in a period.
  /// Returns set of ISO date strings (YYYY-MM-DD) where company vehicle is active.
  Future<Set<String>> getCompanyVehicleDates(String employeeId, DateTime start, DateTime end) async {
    try {
      final response = await _supabase
          .from('employee_vehicle_periods')
          .select('started_at, ended_at')
          .eq('employee_id', employeeId)
          .eq('vehicle_type', 'company')
          .lte('started_at', end.toIso8601String().substring(0, 10))
          .or('ended_at.is.null,ended_at.gte.${start.toIso8601String().substring(0, 10)}');

      final periods = response as List;
      final dates = <String>{};

      for (final period in periods) {
        final pStart = DateTime.parse(period['started_at'] as String);
        final pEnd = period['ended_at'] != null
            ? DateTime.parse(period['ended_at'] as String)
            : end;
        final effectiveStart = pStart.isAfter(start) ? pStart : start;
        final effectiveEnd = pEnd.isBefore(end) ? pEnd : end;

        for (var d = effectiveStart; !d.isAfter(effectiveEnd); d = d.add(const Duration(days: 1))) {
          dates.add(d.toIso8601String().substring(0, 10));
        }
      }

      return dates;
    } catch (e) {
      _logger?.sync(Severity.warn, 'Failed to get company vehicle dates', metadata: {'error': e.toString()});
      return {};
    }
  }
}
