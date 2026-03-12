import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../shared/services/local_database.dart';

/// Service for syncing diagnostic events to the server.
///
/// Batch-syncs pending diagnostic events via the `sync_diagnostic_logs` RPC.
/// Designed to piggyback on the existing sync cycle as the lowest-priority step.
class DiagnosticSyncService {
  final SupabaseClient _supabase;
  final LocalDatabase _localDb;

  static const int _batchSize = 200;

  DiagnosticSyncService(this._supabase, this._localDb);

  /// Sync pending diagnostic events to the server.
  ///
  /// Returns the number of events successfully synced.
  /// Never throws — failures are logged and events remain pending for next cycle.
  Future<int> syncDiagnosticEvents() async {
    int totalSynced = 0;

    try {
      // Get current authenticated user ID for employee_id resolution
      final currentUserId = _supabase.auth.currentUser?.id;
      if (currentUserId == null) return 0; // Not authenticated — skip sync

      while (true) {
        final pending = await _localDb.getPendingDiagnosticEvents(
          limit: _batchSize,
        );

        if (pending.isEmpty) break;

        // Build JSON, replacing non-UUID employee_id with authenticated user's ID
        final eventsJson = pending.map((e) {
          final json = e.toJson();
          // If employee_id is not a valid UUID (e.g., deviceId from pre-auth collection),
          // replace with the current authenticated user's ID
          final employeeId = json['employee_id'] as String?;
          if (employeeId != null && !_isValidUuid(employeeId)) {
            json['employee_id'] = currentUserId;
          }
          return json;
        }).toList();

        try {
          final result = await _supabase.rpc<Map<String, dynamic>>(
            'sync_diagnostic_logs',
            params: {'p_events': eventsJson},
          );

          if (result['status'] == 'success') {
            final inserted = result['inserted'] as int? ?? 0;
            final duplicates = result['duplicates'] as int? ?? 0;
            totalSynced += inserted + duplicates;

            // Mark all events in this batch as synced
            final ids = pending.map((e) => e.id).toList();
            await _localDb.markDiagnosticEventsSynced(ids);
          } else {
            // Server returned error — stop and retry next cycle
            debugPrint('[DiagSync] Server error: ${result['message']}');
            break;
          }
        } catch (e) {
          // Network error — stop and retry next cycle
          debugPrint('[DiagSync] Sync failed: $e');
          break;
        }
      }

      // Prune old synced events to stay under storage limit
      await _localDb.pruneDiagnosticEvents();
    } catch (e) {
      debugPrint('[DiagSync] Unexpected error: $e');
    }

    return totalSynced;
  }

  /// Check if a string is a valid UUID v4 format.
  static bool _isValidUuid(String s) {
    return RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      caseSensitive: false,
    ).hasMatch(s);
  }
}
