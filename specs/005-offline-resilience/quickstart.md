# Quickstart: Offline Resilience

**Feature**: 005-offline-resilience
**Date**: 2026-01-10

## Overview

This guide provides a quick reference for implementing offline resilience in the GPS Tracker app. It covers the key components, patterns, and integration points.

---

## Prerequisites

Ensure these are complete before starting:

- [ ] Spec 001-004 implemented (project foundation, auth, shifts, background GPS)
- [ ] SQLCipher local database operational
- [ ] Connectivity service detecting network changes
- [ ] Sync service processing batches
- [ ] Flutter development environment ready

---

## Implementation Order

### Phase 1: Core Infrastructure (2-3 days)

1. **Database Migration**
   ```dart
   // Add to local_database.dart
   await _createSyncMetadataTable();
   await _createQuarantinedRecordsTable();
   await _createSyncLogEntriesTable();
   await _createStorageMetricsTable();
   ```

2. **Data Models**
   - Create `SyncMetadata` model with persistence
   - Create `QuarantinedRecord` model
   - Create `SyncLogEntry` model
   - Create `StorageMetrics` model
   - Enhance existing `SyncState` with new fields

3. **Sync Logger Service**
   ```dart
   class SyncLogger {
     SyncLogLevel level = SyncLogLevel.info;

     void info(String message, {Map<String, dynamic>? metadata}) {
       if (level.index <= SyncLogLevel.info.index) {
         _writeLog(SyncLogLevel.info, message, metadata);
       }
     }
     // ... other log methods
   }
   ```

### Phase 2: Sync Enhancement (2-3 days)

4. **Exponential Backoff**
   ```dart
   // Add to sync_service.dart
   Duration _calculateBackoff(int attempt) {
     const baseMs = 30000;  // 30 seconds
     const maxMs = 900000;  // 15 minutes
     final delayMs = min(baseMs * pow(2, attempt).toInt(), maxMs);
     final jitter = (Random().nextDouble() - 0.5) * 0.2 * delayMs;
     return Duration(milliseconds: (delayMs + jitter).round());
   }
   ```

5. **Progress Tracking**
   ```dart
   // Add to sync_service.dart
   final _progressController = StreamController<SyncProgress>.broadcast();
   Stream<SyncProgress> get progressStream => _progressController.stream;

   Future<SyncResult> syncAll({void Function(SyncProgress)? onProgress}) async {
     // Emit progress after each batch
     _progressController.add(SyncProgress(...));
     onProgress?.call(progress);
   }
   ```

6. **Quarantine Service**
   ```dart
   Future<void> quarantineRecord(LocalShift shift, String error) async {
     await _localDb.insertQuarantinedRecord(
       QuarantinedRecord(
         id: const Uuid().v4(),
         recordType: RecordType.shift,
         originalId: shift.id,
         recordData: shift.toMap(),
         errorMessage: error,
         quarantinedAt: DateTime.now().toUtc(),
         createdAt: DateTime.now().toUtc(),
       ),
     );
   }
   ```

### Phase 3: State Persistence (1-2 days)

7. **Sync State Persistence**
   ```dart
   // In sync_provider.dart
   Future<void> _loadPersistedState() async {
     final metadata = await _localDb.getSyncMetadata();
     state = SyncState.fromMetadata(metadata);
   }

   Future<void> _persistState() async {
     await _localDb.updateSyncMetadata(state.toMetadata());
   }
   ```

8. **App Launch Sync**
   ```dart
   // In main.dart, after initialization
   final syncNotifier = ref.read(syncProvider.notifier);
   await syncNotifier.refreshPendingCounts();
   if (await connectivityService.isConnected()) {
     syncNotifier.syncPendingData();
   }
   ```

### Phase 4: Storage Monitoring (1 day)

9. **Storage Monitor**
   ```dart
   Future<StorageMetrics> calculateMetrics() async {
     final shiftsBytes = await _calculateTableSize('local_shifts');
     final gpsBytes = await _calculateTableSize('local_gps_points');
     final logsBytes = await _calculateTableSize('sync_log_entries');

     return StorageMetrics(
       usedBytes: shiftsBytes + gpsBytes + logsBytes,
       shiftsBytes: shiftsBytes,
       gpsPointsBytes: gpsBytes,
       logsBytes: logsBytes,
       lastCalculated: DateTime.now().toUtc(),
     );
   }
   ```

10. **Storage Warning UI**
    ```dart
    // In dashboard
    Consumer(
      builder: (context, ref, _) {
        final metrics = ref.watch(storageMetricsProvider);
        if (metrics.isWarning) {
          return StorageWarningBanner(
            message: 'Storage ${metrics.usagePercent.toStringAsFixed(0)}% full',
          );
        }
        return const SizedBox.shrink();
      },
    )
    ```

### Phase 5: UI Components (1-2 days)

11. **Enhanced Sync Status Indicator**
    ```dart
    // Update sync_status_indicator.dart
    Widget build(BuildContext context) {
      final syncState = ref.watch(syncProvider);

      return GestureDetector(
        onTap: () => _showSyncDetailSheet(context),
        child: Stack(
          children: [
            Icon(_getSyncIcon(syncState.status)),
            if (syncState.totalPending > 0)
              Positioned(
                right: 0,
                top: 0,
                child: Badge(label: Text('${syncState.totalPending}')),
              ),
          ],
        ),
      );
    }
    ```

12. **Sync Detail Sheet**
    ```dart
    // New file: sync_detail_sheet.dart
    class SyncDetailSheet extends ConsumerWidget {
      @override
      Widget build(BuildContext context, WidgetRef ref) {
        final syncState = ref.watch(syncProvider);

        return BottomSheet(
          child: Column(
            children: [
              Text('Last sync: ${_formatTime(syncState.lastSyncTime)}'),
              Text('Pending shifts: ${syncState.pendingShifts}'),
              Text('Pending GPS points: ${syncState.pendingGpsPoints}'),
              if (syncState.progress != null)
                LinearProgressIndicator(value: syncState.progress!.percentage / 100),
              if (syncState.lastError != null)
                ErrorCard(message: syncState.lastError!),
              ElevatedButton(
                onPressed: syncState.canSync
                  ? () => ref.read(syncProvider.notifier).syncPendingData()
                  : null,
                child: const Text('Sync Now'),
              ),
            ],
          ),
        );
      }
    }
    ```

---

## Key Integration Points

### Connectivity Changes

```dart
// In sync_provider.dart
_connectivitySub = connectivityService.onConnectivityChanged.listen((connected) {
  state = state.copyWith(isConnected: connected);
  if (connected && state.hasPendingData) {
    _scheduleSyncWithBackoff();
  }
});
```

### Sync Failure Handling

```dart
// In sync_service.dart
try {
  await _syncShift(shift);
} on SyncException catch (e) {
  if (e.code == SyncErrorCode.validationError) {
    await _quarantineService.quarantineShift(shift, errorMessage: e.message);
    _logger.warn('Shift quarantined', metadata: {'id': shift.id});
  } else if (e.isRetryable) {
    await _localDb.markShiftSyncError(shift.id, e.message);
    _logger.info('Shift will retry', metadata: {'id': shift.id, 'error': e.message});
  }
}
```

### Progress Updates

```dart
// In UI or provider listening to sync
ref.listen(syncProvider, (prev, next) {
  if (next.progress != null && prev?.progress?.percentage != next.progress?.percentage) {
    // Update progress UI
  }
  if (prev?.status == SyncStatus.syncing && next.status == SyncStatus.synced) {
    // Show success notification
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('All data synced successfully')),
    );
  }
});
```

---

## Testing Checklist

### Unit Tests

- [ ] Exponential backoff calculation
- [ ] Sync state persistence round-trip
- [ ] Quarantine record creation
- [ ] Log rotation
- [ ] Storage metrics calculation

### Integration Tests

- [ ] Complete offline shift (clock in → track → clock out)
- [ ] Sync on connectivity restore
- [ ] Batch processing with 100+ points
- [ ] Resume interrupted sync
- [ ] Storage warning at 80% threshold

### Manual Testing

- [ ] Airplane mode full workflow
- [ ] Network toggle during sync
- [ ] App restart with pending data
- [ ] 7-day offline simulation
- [ ] Battery usage during backoff

---

## Common Patterns

### Safe Database Update

```dart
Future<void> markSyncSuccess() async {
  await _localDb.transaction((txn) async {
    await txn.update('sync_metadata', {
      'last_successful_sync': DateTime.now().toUtc().toIso8601String(),
      'consecutive_failures': 0,
      'current_backoff_seconds': 0,
      'last_error': null,
      'sync_in_progress': 0,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, where: 'id = ?', whereArgs: ['singleton']);
  });
}
```

### Batch Processing Loop

```dart
Future<int> syncAllGpsPoints() async {
  int totalSynced = 0;
  int batchNumber = 0;

  while (true) {
    final batch = await _localDb.getPendingGpsPoints(limit: 100);
    if (batch.isEmpty) break;

    batchNumber++;
    _logger.info('Processing batch', metadata: {
      'batch': batchNumber,
      'size': batch.length,
    });

    try {
      await _syncBatch(batch);
      totalSynced += batch.length;
      await _localDb.markGpsPointsSynced(batch.map((p) => p.id).toList());
    } on SyncException catch (e) {
      if (!e.isRetryable) break;
      throw e;  // Let caller handle retry
    }
  }

  return totalSynced;
}
```

### Conflict Resolution

```dart
Future<void> resolveConflict(LocalShift local, Map<String, dynamic> server) async {
  final serverUpdated = DateTime.parse(server['updated_at']);

  if (local.updatedAt.isAfter(serverUpdated)) {
    // Local is newer - push to server
    await _pushShiftToServer(local);
  } else {
    // Server is newer - update local
    await _localDb.updateShiftFromServer(local.id, server);
  }
}
```

---

## Troubleshooting

| Symptom | Likely Cause | Solution |
|---------|--------------|----------|
| Sync never starts | Connectivity detection issue | Check connectivity_plus permissions |
| Sync starts but fails immediately | Auth token expired | Verify Supabase session |
| GPS points not syncing | No server shift ID | Ensure shift syncs before GPS |
| Rapid retries draining battery | Backoff not working | Check backoff timer initialization |
| Storage warning false positive | Stale metrics | Force recalculate metrics |
| Quarantine filling up | Systematic validation error | Check RPC input schema |

---

## File Reference

| New File | Purpose |
|----------|---------|
| `lib/features/shifts/models/sync_status.dart` | SyncMetadata, SyncProgress models |
| `lib/features/shifts/services/sync_logger.dart` | Structured logging service |
| `lib/features/shifts/services/quarantine_service.dart` | Failed record quarantine |
| `lib/features/shifts/services/storage_monitor.dart` | Storage capacity tracking |
| `lib/features/shifts/widgets/sync_detail_sheet.dart` | Detailed sync status UI |

| Modified File | Changes |
|---------------|---------|
| `lib/shared/services/local_database.dart` | Add 4 new tables, new CRUD operations |
| `lib/features/shifts/services/sync_service.dart` | Backoff, progress, quarantine |
| `lib/features/shifts/providers/sync_provider.dart` | Persistence, enhanced state |
| `lib/features/shifts/widgets/sync_status_indicator.dart` | Progress, badge, tap action |
| `lib/main.dart` | Launch sync on startup |
