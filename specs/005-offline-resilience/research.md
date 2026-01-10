# Research: Offline Resilience

**Feature**: 005-offline-resilience
**Date**: 2026-01-10
**Status**: Complete

## Research Summary

This document consolidates research findings for implementing comprehensive offline resilience in the GPS Tracker app. All clarification questions from the specification have been resolved, and best practices have been identified for each technical component.

---

## 1. Exponential Backoff Strategy

### Decision
Implement exponential backoff with jitter for sync retry operations, starting at 30 seconds and capping at 15 minutes.

### Rationale
- **Battery Conservation**: Prevents rapid retry loops that drain battery during extended outages
- **Server Protection**: Reduces load on Supabase when many users reconnect simultaneously
- **User Experience**: Silent retries with increasing intervals avoid user frustration
- **Industry Standard**: Pattern used by AWS, Google, and most cloud services

### Implementation Details

```dart
// Backoff formula: min(maxDelay, baseDelay * 2^attempt + randomJitter)
class ExponentialBackoff {
  static const Duration baseDelay = Duration(seconds: 30);
  static const Duration maxDelay = Duration(minutes: 15);
  static const double jitterFactor = 0.1; // ±10% jitter

  Duration getDelay(int attempt) {
    final exponentialDelay = baseDelay * pow(2, attempt);
    final cappedDelay = exponentialDelay > maxDelay ? maxDelay : exponentialDelay;
    final jitter = (Random().nextDouble() - 0.5) * 2 * jitterFactor * cappedDelay.inMilliseconds;
    return Duration(milliseconds: cappedDelay.inMilliseconds + jitter.round());
  }
}
```

**Retry Schedule** (without jitter):
| Attempt | Delay |
|---------|-------|
| 1 | 30s |
| 2 | 1m |
| 3 | 2m |
| 4 | 4m |
| 5 | 8m |
| 6+ | 15m (capped) |

### Alternatives Considered
1. **Fixed Interval Retry**: Rejected - inefficient for prolonged outages
2. **Linear Backoff**: Rejected - too slow to reach reasonable max delay
3. **No Retry**: Rejected - requires manual user intervention

---

## 2. Sync Status Persistence Strategy

### Decision
Persist sync status metadata in SQLCipher database alongside existing local_shifts and local_gps_points tables.

### Rationale
- **Consistency**: Uses same encrypted storage as shift/GPS data
- **Atomicity**: Can use transactions to update sync status with data changes
- **Existing Infrastructure**: LocalDatabase service already handles SQLCipher operations
- **Specification Requirement**: Clarification explicitly stated "Store sync queue/status metadata in SQLCipher alongside local_gps_points"

### Schema Design

```sql
CREATE TABLE sync_metadata (
  id TEXT PRIMARY KEY DEFAULT 'singleton',
  last_sync_attempt TEXT,           -- ISO8601 timestamp
  last_successful_sync TEXT,        -- ISO8601 timestamp
  consecutive_failures INTEGER DEFAULT 0,
  current_backoff_seconds INTEGER DEFAULT 0,
  sync_in_progress INTEGER DEFAULT 0,  -- boolean
  last_error TEXT,
  pending_shifts_count INTEGER DEFAULT 0,
  pending_gps_points_count INTEGER DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

### Alternatives Considered
1. **SharedPreferences**: Rejected - not encrypted, separate from main data
2. **In-memory only**: Rejected - doesn't survive app restart
3. **Separate SQLite DB**: Rejected - adds complexity, sync needed between DBs

---

## 3. Structured Logging for Sync Operations

### Decision
Implement structured logging with four levels (error, warn, info, debug), stored locally with automatic rotation at 1MB file size, retaining last 5 log files.

### Rationale
- **Specification Requirement**: FR-021 requires "structured logging with configurable levels"
- **Debugging**: Essential for diagnosing sync issues in field environments
- **Storage Efficiency**: Rotation prevents unbounded log growth
- **Privacy**: Logs stored locally only, no remote transmission

### Implementation Design

```dart
enum SyncLogLevel { debug, info, warn, error }

class SyncLogger {
  static SyncLogLevel currentLevel = SyncLogLevel.info;  // Configurable

  Future<void> log(SyncLogLevel level, String message, {Map<String, dynamic>? metadata});
  Future<List<LogEntry>> getRecentLogs({int limit = 100});
  Future<void> exportLogs(String path);  // For support purposes
}
```

**Log Entry Format**:
```json
{
  "timestamp": "2026-01-10T14:30:00.000Z",
  "level": "info",
  "message": "Batch sync completed",
  "metadata": {
    "batchSize": 100,
    "duration_ms": 2340,
    "remaining": 250
  }
}
```

### Alternatives Considered
1. **Console print only**: Rejected - no persistence for debugging
2. **Remote logging**: Rejected - requires connectivity, adds complexity
3. **Full database logging**: Rejected - too heavy, logs should be separate from business data

---

## 4. Storage Capacity Monitoring

### Decision
Monitor storage usage and warn at 80% capacity threshold, with emergency pruning at 95%.

### Rationale
- **Specification Requirement**: SC-007 states "warning appears when local storage exceeds 80%"
- **Data Preservation**: FR-014 requires prioritizing recent data if pruning needed
- **User Trust**: Proactive warnings prevent unexpected data loss

### Capacity Calculations

Based on codebase analysis:
- **Per shift**: ~260 bytes
- **Per GPS point**: ~140 bytes
- **7-day normal operation**: ~106 KB total
- **Allocated quota**: 50 MB (assumption from spec)
- **Warning threshold**: 40 MB (80%)
- **Critical threshold**: 47.5 MB (95%)

### Pruning Strategy

```dart
// Priority order for pruning (lowest priority first)
1. Synced GPS points older than 30 days (already implemented)
2. Synced GPS points older than 14 days
3. Synced GPS points older than 7 days
4. Synced shifts older than 30 days (keep summary only)
// Never prune unsynced data
```

### Alternatives Considered
1. **No monitoring**: Rejected - user would lose data silently
2. **User-initiated cleanup**: Rejected - too technical for target users
3. **50% threshold**: Rejected - too aggressive, unnecessary warnings

---

## 5. Conflict Resolution Strategy

### Decision
Use timestamp-based "last-write-wins" with client preference for ties, using idempotency keys to prevent duplicates.

### Rationale
- **Specification Requirement**: FR-015 states "prefer the most recent timestamp or user data"
- **Simplicity**: Avoids complex merge logic for MVP
- **Existing Pattern**: Current implementation uses UUID v4 idempotency (request_id)
- **User Intent**: Employee's recorded data should be preserved

### Resolution Rules

| Scenario | Resolution |
|----------|------------|
| Local shift, no server record | Upload local shift |
| Server shift, no local record | Keep server record (already synced) |
| Both exist, same data | No action (idempotent) |
| Both exist, different data | Prefer record with latest `updated_at` timestamp |
| Both exist, same timestamp | Prefer local (client-generated) data |

### Conflict Detection

```dart
// During sync, check for conflicts using idempotency key
final serverShift = await supabase
  .from('shifts')
  .select()
  .eq('request_id', localShift.requestId)
  .maybeSingle();

if (serverShift != null && serverShift['updated_at'] > localShift.updatedAt) {
  // Server has newer data - mark local as synced, use server version
} else {
  // Local is newer or equal - upsert to server
}
```

### Alternatives Considered
1. **Merge fields**: Rejected - complex, undefined behavior for partial updates
2. **Always server wins**: Rejected - could lose employee work data
3. **Manual resolution**: Rejected - too disruptive for simple time tracking

---

## 6. Batch Processing Optimization

### Decision
Maintain current 100-point batch size with parallel processing for independent operations.

### Rationale
- **Existing Implementation**: Current batch size of 100 works well
- **Performance**: SC-005 requires "≤60 seconds per batch of 100 GPS points"
- **Memory**: Keeps memory footprint manageable on mobile devices
- **Error Isolation**: Failures affect only one batch, not entire sync

### Optimizations

1. **Parallel Shift Sync**: Sync multiple pending shifts concurrently (limit: 5)
2. **Resume on Failure**: Track last successfully synced batch to resume
3. **Progress Reporting**: Emit progress events every batch completion

### Implementation Pattern

```dart
Future<void> _syncGpsPointsWithProgress() async {
  int totalSynced = 0;
  int totalPending = await _localDb.getPendingGpsPointCount();

  while (true) {
    final batch = await _localDb.getPendingGpsPoints(limit: 100);
    if (batch.isEmpty) break;

    await _syncBatch(batch);
    totalSynced += batch.length;

    // Emit progress
    _progressController.add(SyncProgress(
      synced: totalSynced,
      total: totalPending,
      percentage: (totalSynced / totalPending * 100).round(),
    ));
  }
}
```

---

## 7. UI Sync Status Display

### Decision
Persistent status indicator on dashboard with badge for pending count; detailed view accessible via single tap.

### Rationale
- **Specification Requirement**: SC-006 requires "0 taps (visible on dashboard) with detailed view within 1 tap"
- **Non-Intrusive**: Users shouldn't need to think about sync during normal operation
- **Transparency**: Detailed view available for those who want it

### UI Components

1. **Dashboard Indicator** (existing `sync_status_indicator.dart`):
   - Icon: Cloud with checkmark (synced), cloud with arrow (syncing), cloud with X (error)
   - Badge: Pending count if > 0
   - Tap action: Open detail sheet

2. **Detail Sheet** (new `sync_detail_sheet.dart`):
   - Last sync timestamp
   - Pending shifts count
   - Pending GPS points count
   - Progress bar during active sync
   - Error message if applicable
   - Manual "Sync Now" button

### Alternatives Considered
1. **Full-screen sync view**: Rejected - too prominent for background operation
2. **No persistent indicator**: Rejected - users need confidence data is safe
3. **Toast notifications only**: Rejected - too transient, easy to miss

---

## 8. Supabase Batch Upsert API

### Decision
Use Supabase REST/PostgREST API with batch upsert via ON CONFLICT for sync operations.

### Rationale
- **Specification Clarification**: "Standard REST/PostgREST API with batch upsert operations"
- **Idempotency**: ON CONFLICT with idempotency key prevents duplicates
- **Existing Pattern**: Current `sync_gps_points` RPC already uses this approach

### API Patterns

**GPS Points Batch Upsert**:
```dart
// Current implementation uses RPC - continue this pattern
await supabase.rpc('sync_gps_points', params: {
  'p_points': points.map((p) => p.toJson()).toList(),
});

// The RPC handles:
// - ON CONFLICT (client_id) DO UPDATE
// - RLS policy enforcement
// - Batch insertion
```

**Shift Upsert**:
```dart
// Use upsert with request_id as idempotency key
await supabase.from('shifts').upsert(
  shiftData,
  onConflict: 'request_id',
);
```

---

## 9. Network Quality Detection

### Decision
Use connectivity_plus for basic connectivity detection; rely on HTTP response codes for quality assessment.

### Rationale
- **Simplicity**: Avoid complex network quality monitoring
- **Battery**: Continuous quality monitoring drains battery
- **Practical**: Failed requests trigger backoff regardless of perceived quality

### Quality Indicators

| Signal | Action |
|--------|--------|
| No connectivity (connectivity_plus) | Pause sync, wait for change |
| HTTP 5xx / timeout | Trigger backoff |
| HTTP 429 (rate limit) | Extended backoff (double normal) |
| HTTP 2xx | Reset backoff counter |

### Alternatives Considered
1. **Signal strength monitoring**: Rejected - battery drain, platform-specific
2. **Latency testing**: Rejected - adds overhead, unreliable indicator
3. **Bandwidth estimation**: Rejected - complex, diminishing returns

---

## 10. Data Quarantine for Invalid Records

### Decision
Quarantine invalid records in a separate database table for later review/repair.

### Rationale
- **Specification Requirement**: FR-016 states "quarantine invalid or rejected records for review rather than deleting them"
- **Data Preservation**: Never lose employee work data
- **Debugging**: Quarantined records help identify systemic issues

### Schema

```sql
CREATE TABLE quarantined_records (
  id TEXT PRIMARY KEY,
  record_type TEXT NOT NULL,      -- 'shift' or 'gps_point'
  original_id TEXT NOT NULL,
  record_data TEXT NOT NULL,      -- JSON blob
  error_code TEXT,
  error_message TEXT,
  quarantined_at TEXT NOT NULL,
  review_status TEXT DEFAULT 'pending',  -- pending, resolved, discarded
  resolution_notes TEXT,
  created_at TEXT NOT NULL
);
```

### Alternatives Considered
1. **Mark with flag in original table**: Rejected - pollutes main data queries
2. **Delete with log entry**: Rejected - permanent data loss
3. **Immediate user prompt**: Rejected - disruptive to workflow

---

## Dependencies

No new dependencies required. All features can be implemented using existing packages:

| Package | Version | Purpose |
|---------|---------|---------|
| sqflite_sqlcipher | 3.1.0 | Encrypted local storage (existing) |
| connectivity_plus | 6.0.0 | Network detection (existing) |
| flutter_riverpod | 2.5.0 | State management (existing) |
| supabase_flutter | 2.12.0 | Backend sync (existing) |
| path_provider | existing | Log file paths |
| uuid | existing | Idempotency keys |

---

## Open Questions Resolved

All clarification questions from the specification have been answered:

| Question | Resolution |
|----------|------------|
| Where should sync queue and sync status metadata be persisted locally? | SQLCipher alongside local_gps_points |
| Where should the sync status indicator appear in the UI? | Persistent indicator on main shift dashboard (icon + badge) |
| What level of diagnostic logging for sync operations? | Structured logging with configurable levels (error/warn/info/debug) stored locally with rotation |
| How should offline-created shifts be assigned IDs? | Client-generated UUID v4 assigned immediately on creation |
| Which Supabase API approach for sync uploads? | Standard REST/PostgREST API with batch upsert operations |

---

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Storage fills up before sync | Low | High | 80% warning, auto-pruning of old synced data |
| Sync conflicts cause data loss | Low | High | Timestamp-based resolution, quarantine for edge cases |
| Battery drain from sync retries | Medium | Medium | Exponential backoff with 15-minute cap |
| Large backlog causes sync timeout | Medium | Medium | Batch processing, progress tracking, resumable sync |
| Log files grow unbounded | Low | Low | 1MB rotation, 5-file retention |
