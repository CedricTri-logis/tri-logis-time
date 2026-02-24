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
      while (true) {
        final pending = await _localDb.getPendingDiagnosticEvents(
          limit: _batchSize,
        );

        if (pending.isEmpty) break;

        final eventsJson = pending.map((e) => e.toJson()).toList();

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
}
