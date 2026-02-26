import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../shared/models/diagnostic_event.dart';
import '../../../shared/services/diagnostic_logger.dart';

/// Service for triggering route matching via Supabase Edge Functions.
/// Handles single trip matching and batch matching for shifts.
class RouteMatchService {
  final SupabaseClient _supabase;

  RouteMatchService(this._supabase);

  DiagnosticLogger? get _logger =>
      DiagnosticLogger.isInitialized ? DiagnosticLogger.instance : null;

  /// Match a single trip's GPS trace to the road network.
  /// Returns the match status ('matched', 'failed', 'anomalous') or null on error.
  Future<String?> matchTrip(String tripId) async {
    try {
      final response = await _supabase.functions.invoke(
        'match-trip-route',
        body: {'trip_id': tripId},
      );

      if (response.status != 200) {
        _logger?.sync(
          Severity.warn,
          'Route match edge function returned ${response.status}',
          metadata: {'trip_id': tripId},
        );
        return null;
      }

      final data = response.data is String
          ? jsonDecode(response.data as String) as Map<String, dynamic>
          : response.data as Map<String, dynamic>;

      final success = data['success'] as bool? ?? false;
      if (!success) {
        final error = data['error'] as String? ?? 'Unknown error';
        _logger?.sync(
          Severity.warn,
          'Route match failed: $error',
          metadata: {'trip_id': tripId, 'code': data['code']},
        );
        return null;
      }

      final matchStatus = data['match_status'] as String?;
      _logger?.sync(
        matchStatus == 'matched' ? Severity.info : Severity.warn,
        'Route match result: $matchStatus',
        metadata: {
          'trip_id': tripId,
          'match_status': matchStatus,
          'road_distance_km': data['road_distance_km'],
          'match_confidence': data['match_confidence'],
          'distance_change_pct': data['distance_change_pct'],
        },
      );

      return matchStatus;
    } catch (e) {
      _logger?.sync(
        Severity.warn,
        'Route match invocation failed',
        metadata: {'trip_id': tripId, 'error': e.toString()},
      );
      return null;
    }
  }

  /// Match a single trip with retry on failure.
  /// Retries up to [maxRetries] times with exponential backoff.
  Future<String?> matchTripWithRetry(
    String tripId, {
    int maxRetries = 2,
  }) async {
    final delays = [const Duration(seconds: 30), const Duration(seconds: 120)];
    String? result = await matchTrip(tripId);
    if (result != null) return result;

    for (int attempt = 0; attempt < maxRetries; attempt++) {
      final delay = attempt < delays.length
          ? delays[attempt]
          : const Duration(seconds: 120);

      _logger?.sync(
        Severity.info,
        'Scheduling route match retry',
        metadata: {
          'trip_id': tripId,
          'attempt': attempt + 1,
          'delay_seconds': delay.inSeconds,
        },
      );

      await Future<void>.delayed(delay);
      result = await matchTrip(tripId);
      if (result != null) return result;
    }

    _logger?.sync(
      Severity.warn,
      'Route match failed after all retries',
      metadata: {'trip_id': tripId, 'total_attempts': maxRetries + 1},
    );
    return null;
  }

  /// Match all trips for a shift sequentially.
  /// Calls matchTrip for each trip ID. On failure, retries with exponential backoff.
  /// Errors are logged but don't stop processing.
  Future<void> matchTripsForShift(
    String shiftId,
    List<String> tripIds,
  ) async {
    if (tripIds.isEmpty) return;

    _logger?.sync(
      Severity.info,
      'Starting route matching for shift',
      metadata: {'shift_id': shiftId, 'trip_count': tripIds.length},
    );

    for (final tripId in tripIds) {
      final result = await matchTrip(tripId);
      // If first attempt failed, retry with backoff
      if (result == null) {
        await matchTripWithRetry(tripId);
      }
    }

    _logger?.sync(
      Severity.info,
      'Completed route matching for shift',
      metadata: {'shift_id': shiftId},
    );
  }
}

/// Riverpod provider for RouteMatchService.
final routeMatchServiceProvider = Provider<RouteMatchService>((ref) {
  return RouteMatchService(Supabase.instance.client);
});
