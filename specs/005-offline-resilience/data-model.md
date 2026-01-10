# Data Model: Offline Resilience

**Feature**: 005-offline-resilience
**Date**: 2026-01-10
**Status**: Complete

## Overview

This document defines the data models for offline resilience functionality. The design extends existing SQLCipher tables (`local_shifts`, `local_gps_points`) with new sync metadata tables and models.

---

## Entity Relationship Diagram

```text
┌─────────────────────┐      ┌─────────────────────┐
│   sync_metadata     │      │  quarantined_records│
│   (singleton)       │      │                     │
├─────────────────────┤      ├─────────────────────┤
│ id: TEXT (PK)       │      │ id: TEXT (PK)       │
│ last_sync_attempt   │      │ record_type         │
│ last_successful_sync│      │ original_id         │
│ consecutive_failures│      │ record_data (JSON)  │
│ current_backoff_sec │      │ error_code          │
│ sync_in_progress    │      │ error_message       │
│ last_error          │      │ quarantined_at      │
│ pending_shifts_count│      │ review_status       │
│ pending_gps_points  │      │ resolution_notes    │
│ created_at          │      │ created_at          │
│ updated_at          │      └─────────────────────┘
└─────────────────────┘

┌─────────────────────┐      ┌─────────────────────┐
│   sync_log_entries  │      │   storage_metrics   │
│                     │      │   (singleton)       │
├─────────────────────┤      ├─────────────────────┤
│ id: INTEGER (PK)    │      │ id: TEXT (PK)       │
│ timestamp           │      │ total_capacity_bytes│
│ level               │      │ used_bytes          │
│ message             │      │ shifts_bytes        │
│ metadata (JSON)     │      │ gps_points_bytes    │
│ created_at          │      │ logs_bytes          │
└─────────────────────┘      │ last_calculated     │
                             │ warning_threshold   │
                             │ critical_threshold  │
                             └─────────────────────┘
```

---

## Entity Definitions

### 1. SyncMetadata (Singleton)

**Purpose**: Persist sync state across app restarts. Single row maintains current sync system state.

**SQLite Schema**:
```sql
CREATE TABLE IF NOT EXISTS sync_metadata (
  id TEXT PRIMARY KEY DEFAULT 'singleton',
  last_sync_attempt TEXT,              -- ISO8601 UTC timestamp
  last_successful_sync TEXT,           -- ISO8601 UTC timestamp
  consecutive_failures INTEGER DEFAULT 0,
  current_backoff_seconds INTEGER DEFAULT 0,
  sync_in_progress INTEGER DEFAULT 0,  -- 0 = false, 1 = true
  last_error TEXT,
  pending_shifts_count INTEGER DEFAULT 0,
  pending_gps_points_count INTEGER DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- Initialize singleton on first access
INSERT OR IGNORE INTO sync_metadata (id, created_at, updated_at)
VALUES ('singleton', datetime('now'), datetime('now'));
```

**Dart Model**:
```dart
class SyncMetadata {
  static const String tableName = 'sync_metadata';
  static const String singletonId = 'singleton';

  final String id;
  final DateTime? lastSyncAttempt;
  final DateTime? lastSuccessfulSync;
  final int consecutiveFailures;
  final int currentBackoffSeconds;
  final bool syncInProgress;
  final String? lastError;
  final int pendingShiftsCount;
  final int pendingGpsPointsCount;
  final DateTime createdAt;
  final DateTime updatedAt;

  const SyncMetadata({
    this.id = singletonId,
    this.lastSyncAttempt,
    this.lastSuccessfulSync,
    this.consecutiveFailures = 0,
    this.currentBackoffSeconds = 0,
    this.syncInProgress = false,
    this.lastError,
    this.pendingShiftsCount = 0,
    this.pendingGpsPointsCount = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get hasPendingData => pendingShiftsCount > 0 || pendingGpsPointsCount > 0;
  bool get hasError => lastError != null && lastError!.isNotEmpty;
  Duration get backoffDuration => Duration(seconds: currentBackoffSeconds);

  SyncMetadata copyWith({...});
  Map<String, dynamic> toMap();
  factory SyncMetadata.fromMap(Map<String, dynamic> map);
}
```

**Validation Rules**:
- `consecutiveFailures` must be >= 0
- `currentBackoffSeconds` must be >= 0 and <= 900 (15 minutes)
- `pendingShiftsCount` and `pendingGpsPointsCount` must be >= 0

---

### 2. QuarantinedRecord

**Purpose**: Store invalid or rejected sync records for later review without losing data.

**SQLite Schema**:
```sql
CREATE TABLE IF NOT EXISTS quarantined_records (
  id TEXT PRIMARY KEY,
  record_type TEXT NOT NULL,           -- 'shift' or 'gps_point'
  original_id TEXT NOT NULL,           -- ID from original record
  record_data TEXT NOT NULL,           -- Full JSON of original record
  error_code TEXT,                     -- HTTP status or error code
  error_message TEXT,                  -- Human-readable error
  quarantined_at TEXT NOT NULL,        -- ISO8601 UTC timestamp
  review_status TEXT DEFAULT 'pending', -- pending, resolved, discarded
  resolution_notes TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_quarantined_record_type ON quarantined_records(record_type);
CREATE INDEX IF NOT EXISTS idx_quarantined_review_status ON quarantined_records(review_status);
```

**Dart Model**:
```dart
enum RecordType { shift, gpsPoint }
enum ReviewStatus { pending, resolved, discarded }

class QuarantinedRecord {
  static const String tableName = 'quarantined_records';

  final String id;
  final RecordType recordType;
  final String originalId;
  final Map<String, dynamic> recordData;
  final String? errorCode;
  final String? errorMessage;
  final DateTime quarantinedAt;
  final ReviewStatus reviewStatus;
  final String? resolutionNotes;
  final DateTime createdAt;

  const QuarantinedRecord({
    required this.id,
    required this.recordType,
    required this.originalId,
    required this.recordData,
    this.errorCode,
    this.errorMessage,
    required this.quarantinedAt,
    this.reviewStatus = ReviewStatus.pending,
    this.resolutionNotes,
    required this.createdAt,
  });

  QuarantinedRecord copyWith({...});
  Map<String, dynamic> toMap();
  factory QuarantinedRecord.fromMap(Map<String, dynamic> map);
}
```

**Validation Rules**:
- `recordType` must be valid enum value
- `originalId` must not be empty
- `recordData` must be valid JSON
- `reviewStatus` must be valid enum value

---

### 3. SyncLogEntry

**Purpose**: Store structured log entries for sync operations with automatic rotation.

**SQLite Schema**:
```sql
CREATE TABLE IF NOT EXISTS sync_log_entries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp TEXT NOT NULL,             -- ISO8601 UTC timestamp
  level TEXT NOT NULL,                 -- 'debug', 'info', 'warn', 'error'
  message TEXT NOT NULL,
  metadata TEXT,                       -- JSON object for structured data
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sync_log_timestamp ON sync_log_entries(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_sync_log_level ON sync_log_entries(level);
```

**Dart Model**:
```dart
enum SyncLogLevel { debug, info, warn, error }

class SyncLogEntry {
  static const String tableName = 'sync_log_entries';
  static const int maxEntries = 10000;  // Rotate after this many entries

  final int? id;
  final DateTime timestamp;
  final SyncLogLevel level;
  final String message;
  final Map<String, dynamic>? metadata;
  final DateTime createdAt;

  const SyncLogEntry({
    this.id,
    required this.timestamp,
    required this.level,
    required this.message,
    this.metadata,
    required this.createdAt,
  });

  String get formattedEntry =>
    '[${timestamp.toIso8601String()}] ${level.name.toUpperCase()}: $message';

  Map<String, dynamic> toMap();
  factory SyncLogEntry.fromMap(Map<String, dynamic> map);
}
```

**Validation Rules**:
- `level` must be valid enum value
- `message` must not be empty
- `metadata` if present must be valid JSON serializable

---

### 4. StorageMetrics (Singleton)

**Purpose**: Track local storage usage for capacity monitoring and warnings.

**SQLite Schema**:
```sql
CREATE TABLE IF NOT EXISTS storage_metrics (
  id TEXT PRIMARY KEY DEFAULT 'singleton',
  total_capacity_bytes INTEGER DEFAULT 52428800,  -- 50 MB default
  used_bytes INTEGER DEFAULT 0,
  shifts_bytes INTEGER DEFAULT 0,
  gps_points_bytes INTEGER DEFAULT 0,
  logs_bytes INTEGER DEFAULT 0,
  last_calculated TEXT,                -- ISO8601 UTC timestamp
  warning_threshold_percent INTEGER DEFAULT 80,
  critical_threshold_percent INTEGER DEFAULT 95,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

INSERT OR IGNORE INTO storage_metrics (id, created_at, updated_at)
VALUES ('singleton', datetime('now'), datetime('now'));
```

**Dart Model**:
```dart
class StorageMetrics {
  static const String tableName = 'storage_metrics';
  static const String singletonId = 'singleton';
  static const int defaultCapacity = 52428800;  // 50 MB

  final String id;
  final int totalCapacityBytes;
  final int usedBytes;
  final int shiftsBytes;
  final int gpsPointsBytes;
  final int logsBytes;
  final DateTime? lastCalculated;
  final int warningThresholdPercent;
  final int criticalThresholdPercent;
  final DateTime createdAt;
  final DateTime updatedAt;

  const StorageMetrics({
    this.id = singletonId,
    this.totalCapacityBytes = defaultCapacity,
    this.usedBytes = 0,
    this.shiftsBytes = 0,
    this.gpsPointsBytes = 0,
    this.logsBytes = 0,
    this.lastCalculated,
    this.warningThresholdPercent = 80,
    this.criticalThresholdPercent = 95,
    required this.createdAt,
    required this.updatedAt,
  });

  int get availableBytes => totalCapacityBytes - usedBytes;
  double get usagePercent => (usedBytes / totalCapacityBytes) * 100;
  bool get isWarning => usagePercent >= warningThresholdPercent;
  bool get isCritical => usagePercent >= criticalThresholdPercent;

  StorageMetrics copyWith({...});
  Map<String, dynamic> toMap();
  factory StorageMetrics.fromMap(Map<String, dynamic> map);
}
```

**Validation Rules**:
- `totalCapacityBytes` must be > 0
- `usedBytes` must be >= 0 and <= `totalCapacityBytes`
- `warningThresholdPercent` must be between 0-100
- `criticalThresholdPercent` must be between `warningThresholdPercent`-100

---

### 5. SyncProgress (Transient)

**Purpose**: Track real-time sync progress for UI updates. Not persisted.

**Dart Model**:
```dart
class SyncProgress {
  final int syncedShifts;
  final int totalShifts;
  final int syncedGpsPoints;
  final int totalGpsPoints;
  final DateTime startedAt;
  final String? currentOperation;  // e.g., "Syncing GPS batch 3 of 12"

  const SyncProgress({
    this.syncedShifts = 0,
    this.totalShifts = 0,
    this.syncedGpsPoints = 0,
    this.totalGpsPoints = 0,
    required this.startedAt,
    this.currentOperation,
  });

  int get totalItems => totalShifts + totalGpsPoints;
  int get syncedItems => syncedShifts + syncedGpsPoints;
  double get percentage => totalItems > 0 ? (syncedItems / totalItems) * 100 : 0;
  bool get isComplete => syncedItems >= totalItems;

  SyncProgress copyWith({...});
}
```

---

### 6. SyncState (Enhanced)

**Purpose**: Extend existing SyncState with persistence and progress tracking. Replaces current in-memory only state.

**Dart Model** (modified from existing):
```dart
enum SyncStatus { synced, pending, syncing, error }

class SyncState {
  final SyncStatus status;
  final int pendingShifts;
  final int pendingGpsPoints;
  final String? lastError;
  final DateTime? lastSyncTime;
  final SyncProgress? progress;        // NEW: Active sync progress
  final int consecutiveFailures;       // NEW: For backoff calculation
  final Duration? nextRetryIn;         // NEW: Time until next retry

  const SyncState({
    this.status = SyncStatus.synced,
    this.pendingShifts = 0,
    this.pendingGpsPoints = 0,
    this.lastError,
    this.lastSyncTime,
    this.progress,
    this.consecutiveFailures = 0,
    this.nextRetryIn,
  });

  bool get hasPendingData => pendingShifts > 0 || pendingGpsPoints > 0;
  int get totalPending => pendingShifts + pendingGpsPoints;
  bool get isRetrying => consecutiveFailures > 0;

  // Persistence integration
  factory SyncState.fromMetadata(SyncMetadata metadata);
  SyncMetadata toMetadata();

  SyncState copyWith({...});
}
```

---

## State Transitions

### Sync Status State Machine

```text
                    ┌────────────────┐
                    │    SYNCED      │
                    │  (all backed   │
                    │     up)        │
                    └───────┬────────┘
                            │
                   New local data created
                            │
                            ▼
                    ┌────────────────┐
          ┌────────│    PENDING     │◄────────┐
          │        │ (data waiting) │         │
          │        └───────┬────────┘         │
          │                │                   │
          │    Connectivity restored           │
          │    + 30 second delay               │
          │                │                   │
          │                ▼                   │
          │        ┌────────────────┐         │
          │        │    SYNCING     │         │
          │        │ (active sync)  │         │
          │        └───────┬────────┘         │
          │                │                   │
          │     ┌──────────┴──────────┐       │
          │     │                     │       │
          │  Success              Failure     │
          │     │                     │       │
          │     ▼                     ▼       │
          │ All data              ┌───────────┴──┐
          │  synced?              │    ERROR     │
          │     │                 │(retry queued)│
          │  ┌──┴──┐              └───────┬──────┘
          │  │     │                      │
          │ Yes    No                 Backoff
          │  │     │                  expires
          │  │     └──────────────────────┘
          │  │
          │  ▼
          │ SYNCED
          │  │
          │  └────────────────────────────────┘
          │        (new data created)
          │
   Connectivity lost
          │
          └──► Stay in PENDING (offline-capable)
```

### Review Status Transitions (QuarantinedRecord)

```text
  PENDING ─────┬────────► RESOLVED (manual fix applied)
               │
               └────────► DISCARDED (confirmed invalid)
```

---

## Database Operations

### SyncMetadata Operations

```dart
abstract class SyncMetadataOperations {
  /// Load current sync metadata (creates if not exists)
  Future<SyncMetadata> getSyncMetadata();

  /// Update sync metadata
  Future<void> updateSyncMetadata(SyncMetadata metadata);

  /// Record sync attempt start
  Future<void> markSyncStarted();

  /// Record successful sync
  Future<void> markSyncSuccess();

  /// Record failed sync with error
  Future<void> markSyncFailed(String error);

  /// Update pending counts
  Future<void> updatePendingCounts(int shifts, int gpsPoints);

  /// Reset backoff after successful sync
  Future<void> resetBackoff();

  /// Calculate next backoff duration
  Duration calculateNextBackoff(int failures);
}
```

### QuarantinedRecord Operations

```dart
abstract class QuarantineOperations {
  /// Quarantine a failed record
  Future<void> quarantineRecord({
    required RecordType type,
    required String originalId,
    required Map<String, dynamic> recordData,
    String? errorCode,
    String? errorMessage,
  });

  /// Get pending quarantined records
  Future<List<QuarantinedRecord>> getPendingQuarantined({
    RecordType? type,
    int limit = 50,
  });

  /// Mark record as resolved
  Future<void> resolveQuarantined(String id, String notes);

  /// Mark record as discarded
  Future<void> discardQuarantined(String id, String reason);

  /// Get quarantine statistics
  Future<Map<RecordType, int>> getQuarantineStats();
}
```

### SyncLog Operations

```dart
abstract class SyncLogOperations {
  /// Log a sync event
  Future<void> log(
    SyncLogLevel level,
    String message, {
    Map<String, dynamic>? metadata,
  });

  /// Get recent log entries
  Future<List<SyncLogEntry>> getRecentLogs({
    SyncLogLevel? minLevel,
    int limit = 100,
    int offset = 0,
  });

  /// Export logs to file
  Future<String> exportLogs(String directory);

  /// Rotate old logs (keep last N entries)
  Future<int> rotateOldLogs({int keepCount = 10000});

  /// Clear all logs
  Future<void> clearLogs();
}
```

### StorageMetrics Operations

```dart
abstract class StorageMetricsOperations {
  /// Calculate and update storage metrics
  Future<StorageMetrics> calculateStorageMetrics();

  /// Get current storage metrics
  Future<StorageMetrics> getStorageMetrics();

  /// Check if storage warning should be shown
  Future<bool> shouldShowStorageWarning();

  /// Prune old synced data to free space
  Future<int> pruneOldSyncedData({
    Duration olderThan = const Duration(days: 30),
  });
}
```

---

## Migration Plan

### Migration Script

```sql
-- Migration: 005_add_offline_resilience_tables
-- Version: 20260110_001

-- Sync metadata singleton
CREATE TABLE IF NOT EXISTS sync_metadata (
  id TEXT PRIMARY KEY DEFAULT 'singleton',
  last_sync_attempt TEXT,
  last_successful_sync TEXT,
  consecutive_failures INTEGER DEFAULT 0,
  current_backoff_seconds INTEGER DEFAULT 0,
  sync_in_progress INTEGER DEFAULT 0,
  last_error TEXT,
  pending_shifts_count INTEGER DEFAULT 0,
  pending_gps_points_count INTEGER DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

INSERT OR IGNORE INTO sync_metadata (id, created_at, updated_at)
VALUES ('singleton', datetime('now'), datetime('now'));

-- Quarantined records
CREATE TABLE IF NOT EXISTS quarantined_records (
  id TEXT PRIMARY KEY,
  record_type TEXT NOT NULL CHECK (record_type IN ('shift', 'gps_point')),
  original_id TEXT NOT NULL,
  record_data TEXT NOT NULL,
  error_code TEXT,
  error_message TEXT,
  quarantined_at TEXT NOT NULL,
  review_status TEXT DEFAULT 'pending' CHECK (review_status IN ('pending', 'resolved', 'discarded')),
  resolution_notes TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_quarantined_record_type ON quarantined_records(record_type);
CREATE INDEX IF NOT EXISTS idx_quarantined_review_status ON quarantined_records(review_status);

-- Sync log entries
CREATE TABLE IF NOT EXISTS sync_log_entries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp TEXT NOT NULL,
  level TEXT NOT NULL CHECK (level IN ('debug', 'info', 'warn', 'error')),
  message TEXT NOT NULL,
  metadata TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_sync_log_timestamp ON sync_log_entries(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_sync_log_level ON sync_log_entries(level);

-- Storage metrics singleton
CREATE TABLE IF NOT EXISTS storage_metrics (
  id TEXT PRIMARY KEY DEFAULT 'singleton',
  total_capacity_bytes INTEGER DEFAULT 52428800,
  used_bytes INTEGER DEFAULT 0,
  shifts_bytes INTEGER DEFAULT 0,
  gps_points_bytes INTEGER DEFAULT 0,
  logs_bytes INTEGER DEFAULT 0,
  last_calculated TEXT,
  warning_threshold_percent INTEGER DEFAULT 80,
  critical_threshold_percent INTEGER DEFAULT 95,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

INSERT OR IGNORE INTO storage_metrics (id, created_at, updated_at)
VALUES ('singleton', datetime('now'), datetime('now'));
```

---

## Capacity Estimates

| Entity | Size Per Record | 7-Day Estimate | Notes |
|--------|-----------------|----------------|-------|
| local_shifts | ~260 bytes | 1.8 KB | 7 shifts |
| local_gps_points | ~140 bytes | 94 KB | 672 points |
| sync_metadata | ~500 bytes | 500 bytes | Singleton |
| storage_metrics | ~300 bytes | 300 bytes | Singleton |
| sync_log_entries | ~200 bytes | 200 KB | 1000 entries max |
| quarantined_records | ~500 bytes | 5 KB | Rare, ~10 records |
| **Total** | - | **~302 KB** | Well under 50 MB |
