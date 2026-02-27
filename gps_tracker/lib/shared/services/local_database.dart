import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../features/shifts/models/local_gps_gap.dart';
import '../../features/shifts/models/local_gps_point.dart';
import '../../features/shifts/models/local_shift.dart';
import '../../features/shifts/models/quarantined_record.dart';
import '../../features/shifts/models/storage_metrics.dart';
import '../../features/shifts/models/sync_log_entry.dart';
import '../../features/shifts/models/sync_metadata.dart';
import '../models/diagnostic_event.dart';
import 'diagnostic_logger.dart';
import 'local_database_exception.dart';

/// Local SQLite database service with encrypted storage.
class LocalDatabase {
  static const String _databaseName = 'gps_tracker.db';
  static const int _databaseVersion = 6;
  static const String _encryptionKeyKey = 'local_db_encryption_key';

  static LocalDatabase? _instance;
  Database? _database;
  final FlutterSecureStorage _secureStorage;

  LocalDatabase._internal() : _secureStorage = const FlutterSecureStorage();

  /// Get singleton instance.
  factory LocalDatabase() {
    _instance ??= LocalDatabase._internal();
    return _instance!;
  }

  /// Check if database is initialized.
  bool get isInitialized => _database != null;

  /// Initialize database with encrypted storage.
  /// If the Android Keystore encryption key is corrupted (BAD_DECRYPT),
  /// automatically wipes the local database and creates a fresh one.
  Future<void> initialize() async {
    if (_database != null) return;

    try {
      // Get or create encryption key (may throw BAD_DECRYPT on Android)
      String encryptionKey;
      bool recoveredFromBadDecrypt = false;
      try {
        final storedKey = await _secureStorage.read(key: _encryptionKeyKey);
        if (storedKey != null) {
          encryptionKey = storedKey;
        } else {
          encryptionKey = _generateEncryptionKey();
          await _secureStorage.write(key: _encryptionKeyKey, value: encryptionKey);
        }
      } on PlatformException catch (e) {
        // BAD_DECRYPT can appear in message, details, or code depending on
        // the Android version. Check the full exception string.
        final fullError = e.toString();
        if (fullError.contains('BAD_DECRYPT') ||
            fullError.contains('BadPaddingException')) {
          // Android Keystore was invalidated (app update, device change, etc.)
          // Wipe corrupt secure storage and local DB, then start fresh.
          await _recoverFromCorruptKeystore();
          encryptionKey = _generateEncryptionKey();
          await _secureStorage.write(key: _encryptionKeyKey, value: encryptionKey);
          recoveredFromBadDecrypt = true;
        } else {
          rethrow;
        }
      }

      // Get database path
      final documentsDir = await getApplicationDocumentsDirectory();
      final dbPath = path.join(documentsDir.path, _databaseName);

      // Open encrypted database
      _database = await openDatabase(
        dbPath,
        version: _databaseVersion,
        password: encryptionKey,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );

      // Safety check: ensure clock_out_reason column exists
      // (covers case where DB was created at v3 without the column)
      await _ensureClockOutReasonColumn(_database!);

      // Log BAD_DECRYPT recovery after DB is fully initialized
      // (logger uses the local database internally, so it must be ready first)
      if (recoveredFromBadDecrypt && DiagnosticLogger.isInitialized) {
        DiagnosticLogger.instance.lifecycle(
          Severity.critical,
          'Database recovery from BAD_DECRYPT',
          metadata: {
            'reason': 'bad_decrypt',
            'action': 'wipe_and_recreate',
          },
        );
      }
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to initialize database',
        operation: 'initialize',
        originalError: e,
      );
    }
  }

  /// Recover from a corrupted Android Keystore by wiping secure storage
  /// and deleting the old encrypted database file.
  Future<void> _recoverFromCorruptKeystore() async {
    // Delete all secure storage entries (the keys are unreadable anyway)
    try {
      await _secureStorage.deleteAll();
    } catch (_) {
      // Best-effort — if deleteAll also fails, we still continue
    }

    // Delete the old encrypted database file (can't decrypt it without the key)
    try {
      final documentsDir = await getApplicationDocumentsDirectory();
      final dbPath = path.join(documentsDir.path, _databaseName);
      final dbFile = File(dbPath);
      if (await dbFile.exists()) {
        await dbFile.delete();
      }
    } catch (_) {
      // Best-effort — openDatabase will create a new file anyway
    }
  }

  /// Generate a cryptographically secure random encryption key.
  String _generateEncryptionKey() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Create database tables.
  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE local_shifts (
        id TEXT PRIMARY KEY,
        employee_id TEXT NOT NULL,
        request_id TEXT UNIQUE,
        status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'completed')),
        clocked_in_at TEXT NOT NULL,
        clock_in_latitude REAL,
        clock_in_longitude REAL,
        clock_in_accuracy REAL,
        clocked_out_at TEXT,
        clock_out_latitude REAL,
        clock_out_longitude REAL,
        clock_out_accuracy REAL,
        sync_status TEXT NOT NULL DEFAULT 'pending' CHECK (sync_status IN ('pending', 'syncing', 'synced', 'error')),
        last_sync_attempt TEXT,
        sync_error TEXT,
        server_id TEXT,
        clock_out_reason TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_local_shifts_employee ON local_shifts(employee_id)
    ''');

    await db.execute('''
      CREATE INDEX idx_local_shifts_status ON local_shifts(status)
    ''');

    await db.execute('''
      CREATE INDEX idx_local_shifts_sync ON local_shifts(sync_status)
    ''');

    await db.execute('''
      CREATE TABLE local_gps_points (
        id TEXT PRIMARY KEY,
        shift_id TEXT NOT NULL,
        employee_id TEXT NOT NULL,
        latitude REAL NOT NULL CHECK (latitude >= -90.0 AND latitude <= 90.0),
        longitude REAL NOT NULL CHECK (longitude >= -180.0 AND longitude <= 180.0),
        accuracy REAL,
        captured_at TEXT NOT NULL,
        device_id TEXT,
        sync_status TEXT NOT NULL DEFAULT 'pending' CHECK (sync_status IN ('pending', 'synced')),
        created_at TEXT NOT NULL,
        speed REAL,
        speed_accuracy REAL,
        heading REAL,
        heading_accuracy REAL,
        altitude REAL,
        altitude_accuracy REAL,
        is_mocked INTEGER,
        activity_type TEXT,
        FOREIGN KEY (shift_id) REFERENCES local_shifts(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_local_gps_shift ON local_gps_points(shift_id)
    ''');

    await db.execute('''
      CREATE INDEX idx_local_gps_sync ON local_gps_points(sync_status)
    ''');

    // Create offline resilience tables
    await _createOfflineResilienceTables(db);

    // Create GPS gaps table
    await _createGpsGapsTable(db);

    // Create diagnostic events table
    await _createDiagnosticEventsTable(db);
  }

  /// Create tables for offline resilience feature.
  Future<void> _createOfflineResilienceTables(Database db) async {
    // T001: sync_metadata table (singleton for persistent sync state)
    await db.execute('''
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
      )
    ''');

    // Initialize singleton row
    await db.execute('''
      INSERT OR IGNORE INTO sync_metadata (id, created_at, updated_at)
      VALUES ('singleton', datetime('now'), datetime('now'))
    ''');

    // T002: quarantined_records table (for failed/rejected records)
    await db.execute('''
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
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_quarantined_record_type ON quarantined_records(record_type)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_quarantined_review_status ON quarantined_records(review_status)
    ''');

    // T003: sync_log_entries table (structured sync logging)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_log_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT NOT NULL,
        level TEXT NOT NULL CHECK (level IN ('debug', 'info', 'warn', 'error')),
        message TEXT NOT NULL,
        metadata TEXT,
        created_at TEXT NOT NULL DEFAULT (datetime('now'))
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sync_log_timestamp ON sync_log_entries(timestamp DESC)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sync_log_level ON sync_log_entries(level)
    ''');

    // T004: storage_metrics table (singleton for storage monitoring)
    await db.execute('''
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
      )
    ''');

    // Initialize singleton row
    await db.execute('''
      INSERT OR IGNORE INTO storage_metrics (id, created_at, updated_at)
      VALUES ('singleton', datetime('now'), datetime('now'))
    ''');
  }

  /// Create GPS gaps table for tracking GPS signal loss periods.
  Future<void> _createGpsGapsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS local_gps_gaps (
        id TEXT PRIMARY KEY,
        shift_id TEXT NOT NULL,
        employee_id TEXT NOT NULL,
        started_at TEXT NOT NULL,
        ended_at TEXT,
        reason TEXT NOT NULL DEFAULT 'signal_loss',
        sync_status TEXT NOT NULL DEFAULT 'pending' CHECK (sync_status IN ('pending', 'synced')),
        FOREIGN KEY (shift_id) REFERENCES local_shifts(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_local_gps_gaps_shift ON local_gps_gaps(shift_id)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_local_gps_gaps_sync ON local_gps_gaps(sync_status)
    ''');
  }

  /// Create diagnostic events table for structured app-wide logging.
  Future<void> _createDiagnosticEventsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS diagnostic_events (
        id TEXT PRIMARY KEY,
        employee_id TEXT NOT NULL,
        shift_id TEXT,
        device_id TEXT NOT NULL,
        event_category TEXT NOT NULL CHECK (event_category IN ('gps', 'shift', 'sync', 'auth', 'permission', 'lifecycle', 'thermal', 'error', 'network')),
        severity TEXT NOT NULL CHECK (severity IN ('debug', 'info', 'warn', 'error', 'critical')),
        message TEXT NOT NULL,
        metadata TEXT,
        app_version TEXT NOT NULL,
        platform TEXT NOT NULL,
        os_version TEXT,
        sync_status TEXT NOT NULL DEFAULT 'pending' CHECK (sync_status IN ('pending', 'synced')),
        created_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_diag_sync_status ON diagnostic_events(sync_status)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_diag_created_at ON diagnostic_events(created_at)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_diag_category_severity ON diagnostic_events(event_category, severity)
    ''');
  }

  /// Ensure clock_out_reason column exists on local_shifts.
  /// Covers edge case where DB was freshly created at v3 without the column.
  Future<void> _ensureClockOutReasonColumn(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(local_shifts)');
    final hasColumn = cols.any((c) => c['name'] == 'clock_out_reason');
    if (!hasColumn) {
      await db.execute(
        'ALTER TABLE local_shifts ADD COLUMN clock_out_reason TEXT',
      );
    }
  }

  /// Handle database upgrades.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Migration from v1 to v2: Add offline resilience tables
    if (oldVersion < 2) {
      await _createOfflineResilienceTables(db);
    }
    // Migration from v2 to v3: Add GPS gaps table + clock_out_reason
    if (oldVersion < 3) {
      await _createGpsGapsTable(db);
      await db.execute(
        'ALTER TABLE local_shifts ADD COLUMN clock_out_reason TEXT',
      );
    }
    // Migration from v3 to v4: Add diagnostic events table
    if (oldVersion < 4) {
      await _createDiagnosticEventsTable(db);
    }
    // Migration from v4 to v5: Add extended GPS data columns
    if (oldVersion < 5) {
      await _addExtendedGpsColumns(db);
    }
    // Migration from v5 to v6: Add activity_type column for activity recognition
    if (oldVersion < 6) {
      await db.execute('ALTER TABLE local_gps_points ADD COLUMN activity_type TEXT');
    }
  }

  /// Add extended GPS data columns to local_gps_points.
  Future<void> _addExtendedGpsColumns(Database db) async {
    await db.execute('ALTER TABLE local_gps_points ADD COLUMN speed REAL');
    await db.execute('ALTER TABLE local_gps_points ADD COLUMN speed_accuracy REAL');
    await db.execute('ALTER TABLE local_gps_points ADD COLUMN heading REAL');
    await db.execute('ALTER TABLE local_gps_points ADD COLUMN heading_accuracy REAL');
    await db.execute('ALTER TABLE local_gps_points ADD COLUMN altitude REAL');
    await db.execute('ALTER TABLE local_gps_points ADD COLUMN altitude_accuracy REAL');
    await db.execute('ALTER TABLE local_gps_points ADD COLUMN is_mocked INTEGER');
  }

  /// Ensure database is available.
  Database get _db {
    if (_database == null) {
      throw LocalDatabaseException(
        'Database not initialized. Call initialize() first.',
        operation: 'access',
      );
    }
    return _database!;
  }

  /// Close database connection.
  Future<void> close() async {
    await _database?.close();
    _database = null;
  }

  // ============ SHIFT OPERATIONS ============

  /// Insert a new local shift record.
  Future<void> insertShift(LocalShift shift) async {
    try {
      await _db.insert(
        'local_shifts',
        shift.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to insert shift',
        operation: 'insertShift',
        originalError: e,
      );
    }
  }

  /// Update shift with clock-out data.
  Future<void> updateShiftClockOut({
    required String shiftId,
    required DateTime clockedOutAt,
    double? latitude,
    double? longitude,
    double? accuracy,
    String? reason,
  }) async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _db.update(
        'local_shifts',
        {
          'status': 'completed',
          'clocked_out_at': clockedOutAt.toUtc().toIso8601String(),
          'clock_out_latitude': latitude,
          'clock_out_longitude': longitude,
          'clock_out_accuracy': accuracy,
          'clock_out_reason': reason ?? 'manual',
          'sync_status': 'pending',
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [shiftId],
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to update shift clock-out',
        operation: 'updateShiftClockOut',
        originalError: e,
      );
    }
  }

  /// Get the current active shift for an employee.
  Future<LocalShift?> getActiveShift(String employeeId) async {
    try {
      final results = await _db.query(
        'local_shifts',
        where: 'employee_id = ? AND status = ?',
        whereArgs: [employeeId, 'active'],
        limit: 1,
      );
      if (results.isEmpty) return null;
      return LocalShift.fromMap(results.first);
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get active shift',
        operation: 'getActiveShift',
        originalError: e,
      );
    }
  }

  /// Get all shifts pending sync.
  Future<List<LocalShift>> getPendingShifts(String employeeId) async {
    try {
      final results = await _db.query(
        'local_shifts',
        where: 'employee_id = ? AND sync_status = ?',
        whereArgs: [employeeId, 'pending'],
        orderBy: 'created_at ASC',
      );
      return results.map((map) => LocalShift.fromMap(map)).toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get pending shifts',
        operation: 'getPendingShifts',
        originalError: e,
      );
    }
  }

  /// Get completed shifts for history display.
  Future<List<LocalShift>> getShiftHistory({
    required String employeeId,
    int limit = 50,
    int offset = 0,
  }) async {
    try {
      final results = await _db.query(
        'local_shifts',
        where: 'employee_id = ? AND status = ?',
        whereArgs: [employeeId, 'completed'],
        orderBy: 'clocked_in_at DESC',
        limit: limit,
        offset: offset,
      );
      return results.map((map) => LocalShift.fromMap(map)).toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get shift history',
        operation: 'getShiftHistory',
        originalError: e,
      );
    }
  }

  /// Get a specific shift by ID.
  Future<LocalShift?> getShiftById(String shiftId) async {
    try {
      final results = await _db.query(
        'local_shifts',
        where: 'id = ?',
        whereArgs: [shiftId],
        limit: 1,
      );
      if (results.isEmpty) return null;
      return LocalShift.fromMap(results.first);
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get shift by ID',
        operation: 'getShiftById',
        originalError: e,
      );
    }
  }

  /// Mark a shift as successfully synced.
  Future<void> markShiftSynced(String shiftId, {String? serverId}) async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _db.update(
        'local_shifts',
        {
          'sync_status': 'synced',
          'sync_error': null,
          'server_id': serverId,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [shiftId],
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to mark shift synced',
        operation: 'markShiftSynced',
        originalError: e,
      );
    }
  }

  /// Delete a local shift (used when server rejects a clock-in so user can retry cleanly).
  Future<void> deleteShift(String shiftId) async {
    try {
      await _db.delete(
        'local_shifts',
        where: 'id = ?',
        whereArgs: [shiftId],
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to delete shift',
        operation: 'deleteShift',
        originalError: e,
      );
    }
  }

  /// Mark a shift sync attempt as failed.
  Future<void> markShiftSyncError(String shiftId, String error) async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _db.update(
        'local_shifts',
        {
          'sync_status': 'error',
          'sync_error': error,
          'last_sync_attempt': now,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [shiftId],
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to mark shift sync error',
        operation: 'markShiftSyncError',
        originalError: e,
      );
    }
  }

  /// Mark a shift as syncing.
  Future<void> markShiftSyncing(String shiftId) async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _db.update(
        'local_shifts',
        {
          'sync_status': 'syncing',
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [shiftId],
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to mark shift syncing',
        operation: 'markShiftSyncing',
        originalError: e,
      );
    }
  }

  // ============ GPS POINT OPERATIONS ============

  /// Insert a GPS point captured during shift.
  Future<void> insertGpsPoint(LocalGpsPoint point) async {
    try {
      await _db.insert(
        'local_gps_points',
        point.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to insert GPS point',
        operation: 'insertGpsPoint',
        originalError: e,
      );
    }
  }

  /// Get all GPS points pending sync.
  Future<List<LocalGpsPoint>> getPendingGpsPoints({
    String? shiftId,
    int limit = 100,
  }) async {
    try {
      String where = 'sync_status = ?';
      List<dynamic> whereArgs = ['pending'];

      if (shiftId != null) {
        where += ' AND shift_id = ?';
        whereArgs.add(shiftId);
      }

      final results = await _db.query(
        'local_gps_points',
        where: where,
        whereArgs: whereArgs,
        orderBy: 'captured_at ASC',
        limit: limit,
      );
      return results.map((map) => LocalGpsPoint.fromMap(map)).toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get pending GPS points',
        operation: 'getPendingGpsPoints',
        originalError: e,
      );
    }
  }

  /// Get all GPS points for a specific shift.
  Future<List<LocalGpsPoint>> getGpsPointsForShift(String shiftId) async {
    try {
      final results = await _db.query(
        'local_gps_points',
        where: 'shift_id = ?',
        whereArgs: [shiftId],
        orderBy: 'captured_at ASC',
      );
      return results.map((map) => LocalGpsPoint.fromMap(map)).toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get GPS points for shift',
        operation: 'getGpsPointsForShift',
        originalError: e,
      );
    }
  }

  /// Get GPS point count for a specific shift.
  Future<int> getGpsPointCountForShift(String shiftId) async {
    try {
      final result = await _db.rawQuery(
        'SELECT COUNT(*) as count FROM local_gps_points WHERE shift_id = ?',
        [shiftId],
      );
      return result.first['count'] as int;
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get GPS point count for shift',
        operation: 'getGpsPointCountForShift',
        originalError: e,
      );
    }
  }

  /// Mark multiple GPS points as synced.
  Future<void> markGpsPointsSynced(List<String> pointIds) async {
    if (pointIds.isEmpty) return;

    try {
      await _db.transaction((txn) async {
        for (final id in pointIds) {
          await txn.update(
            'local_gps_points',
            {'sync_status': 'synced'},
            where: 'id = ?',
            whereArgs: [id],
          );
        }
      });
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to mark GPS points synced',
        operation: 'markGpsPointsSynced',
        originalError: e,
      );
    }
  }

  /// Remove old synced GPS points to free storage.
  Future<int> deleteOldSyncedGpsPoints(DateTime olderThan) async {
    try {
      return await _db.delete(
        'local_gps_points',
        where: 'sync_status = ? AND created_at < ?',
        whereArgs: ['synced', olderThan.toUtc().toIso8601String()],
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to delete old GPS points',
        operation: 'deleteOldSyncedGpsPoints',
        originalError: e,
      );
    }
  }

  /// Execute multiple operations in a transaction.
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action) async {
    try {
      return await _db.transaction(action);
    } catch (e) {
      throw LocalDatabaseException(
        'Transaction failed',
        operation: 'transaction',
        originalError: e,
      );
    }
  }

  /// Get all shifts with error status that need retry.
  Future<List<LocalShift>> getErrorShifts(String employeeId) async {
    try {
      final results = await _db.query(
        'local_shifts',
        where: 'employee_id = ? AND sync_status = ?',
        whereArgs: [employeeId, 'error'],
        orderBy: 'created_at ASC',
      );
      return results.map((map) => LocalShift.fromMap(map)).toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get error shifts',
        operation: 'getErrorShifts',
        originalError: e,
      );
    }
  }

  // ============ SYNC METADATA OPERATIONS (T012) ============

  /// Get current sync metadata (creates if not exists).
  Future<SyncMetadata> getSyncMetadata() async {
    try {
      final results = await _db.query(
        SyncMetadata.tableName,
        where: 'id = ?',
        whereArgs: [SyncMetadata.singletonId],
        limit: 1,
      );

      if (results.isEmpty) {
        // Initialize singleton if missing
        final defaults = SyncMetadata.defaults();
        await _db.insert(SyncMetadata.tableName, defaults.toMap());
        return defaults;
      }

      return SyncMetadata.fromMap(results.first);
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get sync metadata',
        operation: 'getSyncMetadata',
        originalError: e,
      );
    }
  }

  /// Update sync metadata.
  Future<void> updateSyncMetadata(SyncMetadata metadata) async {
    try {
      final now = DateTime.now().toUtc();
      final updated = metadata.copyWith(updatedAt: now);
      await _db.update(
        SyncMetadata.tableName,
        updated.toMap(),
        where: 'id = ?',
        whereArgs: [SyncMetadata.singletonId],
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to update sync metadata',
        operation: 'updateSyncMetadata',
        originalError: e,
      );
    }
  }

  /// Record sync attempt start.
  Future<void> markSyncStarted() async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _db.update(
        SyncMetadata.tableName,
        {
          'last_sync_attempt': now,
          'sync_in_progress': 1,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [SyncMetadata.singletonId],
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to mark sync started',
        operation: 'markSyncStarted',
        originalError: e,
      );
    }
  }

  /// Record successful sync.
  Future<void> markSyncSuccess() async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _db.update(
        SyncMetadata.tableName,
        {
          'last_successful_sync': now,
          'consecutive_failures': 0,
          'current_backoff_seconds': 0,
          'sync_in_progress': 0,
          'last_error': null,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [SyncMetadata.singletonId],
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to mark sync success',
        operation: 'markSyncSuccess',
        originalError: e,
      );
    }
  }

  /// Record failed sync with error.
  Future<void> markSyncFailed(String error, int backoffSeconds) async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();

      // Get current failures
      final current = await getSyncMetadata();
      final newFailures = current.consecutiveFailures + 1;

      await _db.update(
        SyncMetadata.tableName,
        {
          'consecutive_failures': newFailures,
          'current_backoff_seconds': backoffSeconds,
          'sync_in_progress': 0,
          'last_error': error,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [SyncMetadata.singletonId],
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to mark sync failed',
        operation: 'markSyncFailed',
        originalError: e,
      );
    }
  }

  /// Update pending counts.
  Future<void> updatePendingCounts(int shifts, int gpsPoints) async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _db.update(
        SyncMetadata.tableName,
        {
          'pending_shifts_count': shifts,
          'pending_gps_points_count': gpsPoints,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [SyncMetadata.singletonId],
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to update pending counts',
        operation: 'updatePendingCounts',
        originalError: e,
      );
    }
  }

  /// Reset backoff after successful sync.
  Future<void> resetBackoff() async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _db.update(
        SyncMetadata.tableName,
        {
          'consecutive_failures': 0,
          'current_backoff_seconds': 0,
          'last_error': null,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [SyncMetadata.singletonId],
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to reset backoff',
        operation: 'resetBackoff',
        originalError: e,
      );
    }
  }

  // ============ QUARANTINED RECORD OPERATIONS (T013) ============

  /// Insert a quarantined record.
  Future<void> insertQuarantinedRecord(QuarantinedRecord record) async {
    try {
      await _db.insert(
        QuarantinedRecord.tableName,
        record.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to insert quarantined record',
        operation: 'insertQuarantinedRecord',
        originalError: e,
      );
    }
  }

  /// Get pending quarantined records.
  Future<List<QuarantinedRecord>> getPendingQuarantined({
    RecordType? type,
    int limit = 50,
  }) async {
    try {
      String where = 'review_status = ?';
      List<dynamic> whereArgs = ['pending'];

      if (type != null) {
        where += ' AND record_type = ?';
        whereArgs.add(type.value);
      }

      final results = await _db.query(
        QuarantinedRecord.tableName,
        where: where,
        whereArgs: whereArgs,
        orderBy: 'quarantined_at DESC',
        limit: limit,
      );

      return results.map((map) => QuarantinedRecord.fromMap(map)).toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get pending quarantined records',
        operation: 'getPendingQuarantined',
        originalError: e,
      );
    }
  }

  /// Get quarantine statistics by record type.
  Future<Map<RecordType, int>> getQuarantineStats() async {
    try {
      final results = await _db.rawQuery('''
        SELECT record_type, COUNT(*) as count
        FROM ${QuarantinedRecord.tableName}
        WHERE review_status = 'pending'
        GROUP BY record_type
      ''');

      final stats = <RecordType, int>{};
      for (final row in results) {
        final type = RecordType.fromString(row['record_type'] as String);
        stats[type] = row['count'] as int;
      }
      return stats;
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get quarantine stats',
        operation: 'getQuarantineStats',
        originalError: e,
      );
    }
  }

  /// Mark quarantined record as resolved.
  Future<void> resolveQuarantined(String id, String notes) async {
    try {
      await _db.update(
        QuarantinedRecord.tableName,
        {
          'review_status': 'resolved',
          'resolution_notes': notes,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to resolve quarantined record',
        operation: 'resolveQuarantined',
        originalError: e,
      );
    }
  }

  /// Mark quarantined record as discarded.
  Future<void> discardQuarantined(String id, String reason) async {
    try {
      await _db.update(
        QuarantinedRecord.tableName,
        {
          'review_status': 'discarded',
          'resolution_notes': reason,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to discard quarantined record',
        operation: 'discardQuarantined',
        originalError: e,
      );
    }
  }

  // ============ SYNC LOG OPERATIONS (T014) ============

  /// Insert a sync log entry.
  Future<void> insertSyncLog(SyncLogEntry entry) async {
    try {
      final map = entry.toMap();
      // Remove id for auto-increment
      map.remove('id');
      await _db.insert(SyncLogEntry.tableName, map);
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to insert sync log',
        operation: 'insertSyncLog',
        originalError: e,
      );
    }
  }

  /// Get recent log entries.
  Future<List<SyncLogEntry>> getRecentLogs({
    SyncLogLevel? minLevel,
    int limit = 100,
    int offset = 0,
  }) async {
    try {
      String? where;
      List<dynamic>? whereArgs;

      if (minLevel != null) {
        // Filter to include only logs at or above the minimum level
        final levels = SyncLogLevel.values
            .where((l) => l.index >= minLevel.index)
            .map((l) => "'${l.value}'")
            .join(', ');
        where = 'level IN ($levels)';
      }

      final results = await _db.query(
        SyncLogEntry.tableName,
        where: where,
        whereArgs: whereArgs,
        orderBy: 'timestamp DESC',
        limit: limit,
        offset: offset,
      );

      return results.map((map) => SyncLogEntry.fromMap(map)).toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get recent logs',
        operation: 'getRecentLogs',
        originalError: e,
      );
    }
  }

  /// Rotate old logs (keep last N entries).
  Future<int> rotateOldLogs({int keepCount = 10000}) async {
    try {
      // Get the ID threshold
      final result = await _db.rawQuery('''
        SELECT id FROM ${SyncLogEntry.tableName}
        ORDER BY id DESC
        LIMIT 1 OFFSET ?
      ''', [keepCount]);

      if (result.isEmpty) return 0;

      final thresholdId = result.first['id'] as int;

      // Delete older entries
      return await _db.delete(
        SyncLogEntry.tableName,
        where: 'id < ?',
        whereArgs: [thresholdId],
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to rotate old logs',
        operation: 'rotateOldLogs',
        originalError: e,
      );
    }
  }

  /// Get log count.
  Future<int> getLogCount() async {
    try {
      final result = await _db.rawQuery(
        'SELECT COUNT(*) as count FROM ${SyncLogEntry.tableName}',
      );
      return result.first['count'] as int;
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get log count',
        operation: 'getLogCount',
        originalError: e,
      );
    }
  }

  /// Clear all logs.
  Future<void> clearLogs() async {
    try {
      await _db.delete(SyncLogEntry.tableName);
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to clear logs',
        operation: 'clearLogs',
        originalError: e,
      );
    }
  }

  /// Export logs as JSON string.
  Future<String> exportLogs({int? limit}) async {
    try {
      final logs = await getRecentLogs(limit: limit ?? 10000);
      final logMaps = logs.map((l) => l.toMap()).toList();
      return jsonEncode(logMaps);
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to export logs',
        operation: 'exportLogs',
        originalError: e,
      );
    }
  }

  // ============ STORAGE METRICS OPERATIONS (T015) ============

  /// Get current storage metrics.
  Future<StorageMetrics> getStorageMetrics() async {
    try {
      final results = await _db.query(
        StorageMetrics.tableName,
        where: 'id = ?',
        whereArgs: [StorageMetrics.singletonId],
        limit: 1,
      );

      if (results.isEmpty) {
        // Initialize singleton if missing
        final defaults = StorageMetrics.defaults();
        await _db.insert(StorageMetrics.tableName, defaults.toMap());
        return defaults;
      }

      return StorageMetrics.fromMap(results.first);
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get storage metrics',
        operation: 'getStorageMetrics',
        originalError: e,
      );
    }
  }

  /// Update storage metrics.
  Future<void> updateStorageMetrics(StorageMetrics metrics) async {
    try {
      final now = DateTime.now().toUtc();
      final updated = metrics.copyWith(updatedAt: now);
      await _db.update(
        StorageMetrics.tableName,
        updated.toMap(),
        where: 'id = ?',
        whereArgs: [StorageMetrics.singletonId],
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to update storage metrics',
        operation: 'updateStorageMetrics',
        originalError: e,
      );
    }
  }

  /// Calculate and update storage metrics.
  Future<StorageMetrics> calculateStorageMetrics() async {
    try {
      // Calculate approximate size for each table
      // Using a rough estimate of ~260 bytes per shift, ~140 bytes per GPS point, ~200 bytes per log

      final shiftsCount = await _db.rawQuery(
        'SELECT COUNT(*) as count FROM local_shifts',
      );
      final gpsCount = await _db.rawQuery(
        'SELECT COUNT(*) as count FROM local_gps_points',
      );
      final logsCount = await _db.rawQuery(
        'SELECT COUNT(*) as count FROM ${SyncLogEntry.tableName}',
      );

      final shiftsBytes = (shiftsCount.first['count'] as int) * 260;
      final gpsPointsBytes = (gpsCount.first['count'] as int) * 140;
      final logsBytes = (logsCount.first['count'] as int) * 200;
      final usedBytes = shiftsBytes + gpsPointsBytes + logsBytes;

      final now = DateTime.now().toUtc();
      final current = await getStorageMetrics();

      final updated = current.copyWith(
        usedBytes: usedBytes,
        shiftsBytes: shiftsBytes,
        gpsPointsBytes: gpsPointsBytes,
        logsBytes: logsBytes,
        lastCalculated: now,
        updatedAt: now,
      );

      await updateStorageMetrics(updated);
      return updated;
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to calculate storage metrics',
        operation: 'calculateStorageMetrics',
        originalError: e,
      );
    }
  }

  /// Check if storage warning should be shown.
  Future<bool> shouldShowStorageWarning() async {
    try {
      final metrics = await getStorageMetrics();

      // Recalculate if stale
      if (metrics.isStale) {
        final updated = await calculateStorageMetrics();
        return updated.isWarning;
      }

      return metrics.isWarning;
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to check storage warning',
        operation: 'shouldShowStorageWarning',
        originalError: e,
      );
    }
  }

  /// Get count of pending GPS points.
  Future<int> getPendingGpsPointCount() async {
    try {
      final result = await _db.rawQuery(
        'SELECT COUNT(*) as count FROM local_gps_points WHERE sync_status = ?',
        ['pending'],
      );
      return result.first['count'] as int;
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get pending GPS point count',
        operation: 'getPendingGpsPointCount',
        originalError: e,
      );
    }
  }

  // ============ GPS GAP OPERATIONS ============

  /// Insert a GPS gap record.
  Future<void> insertGpsGap(LocalGpsGap gap) async {
    try {
      await _db.insert(
        'local_gps_gaps',
        gap.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to insert GPS gap',
        operation: 'insertGpsGap',
        originalError: e,
      );
    }
  }

  /// Close an open GPS gap by setting ended_at.
  Future<void> closeGpsGap(String gapId, DateTime endedAt) async {
    try {
      await _db.update(
        'local_gps_gaps',
        {'ended_at': endedAt.toUtc().toIso8601String()},
        where: 'id = ?',
        whereArgs: [gapId],
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to close GPS gap',
        operation: 'closeGpsGap',
        originalError: e,
      );
    }
  }

  /// Get all GPS gaps pending sync.
  Future<List<LocalGpsGap>> getPendingGpsGaps({int limit = 100}) async {
    try {
      final results = await _db.query(
        'local_gps_gaps',
        where: 'sync_status = ?',
        whereArgs: ['pending'],
        orderBy: 'started_at ASC',
        limit: limit,
      );
      return results.map((map) => LocalGpsGap.fromMap(map)).toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get pending GPS gaps',
        operation: 'getPendingGpsGaps',
        originalError: e,
      );
    }
  }

  /// Mark GPS gaps as synced.
  Future<void> markGpsGapsSynced(List<String> gapIds) async {
    if (gapIds.isEmpty) return;

    try {
      await _db.transaction((txn) async {
        for (final id in gapIds) {
          await txn.update(
            'local_gps_gaps',
            {'sync_status': 'synced'},
            where: 'id = ?',
            whereArgs: [id],
          );
        }
      });
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to mark GPS gaps synced',
        operation: 'markGpsGapsSynced',
        originalError: e,
      );
    }
  }

  // ============ DASHBOARD CACHE OPERATIONS ============

  /// Ensure dashboard cache table exists.
  Future<void> ensureDashboardCacheTable() async {
    try {
      await _db.execute('''
        CREATE TABLE IF NOT EXISTS dashboard_cache (
          id TEXT PRIMARY KEY,
          cache_type TEXT NOT NULL,
          employee_id TEXT NOT NULL,
          cached_data TEXT NOT NULL,
          last_updated TEXT NOT NULL,
          expires_at TEXT NOT NULL,
          created_at TEXT NOT NULL DEFAULT (datetime('now')),
          updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
      ''');

      await _db.execute('''
        CREATE INDEX IF NOT EXISTS idx_dashboard_cache_employee
        ON dashboard_cache(employee_id)
      ''');

      await _db.execute('''
        CREATE INDEX IF NOT EXISTS idx_dashboard_cache_type
        ON dashboard_cache(cache_type)
      ''');

      await _db.execute('''
        CREATE INDEX IF NOT EXISTS idx_dashboard_cache_expires
        ON dashboard_cache(expires_at)
      ''');
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to ensure dashboard cache table',
        operation: 'ensureDashboardCacheTable',
        originalError: e,
      );
    }
  }

  /// Insert or update cached dashboard data.
  Future<void> cacheDashboardData({
    required String cacheId,
    required String cacheType,
    required String employeeId,
    required String cachedData,
    int ttlDays = 7,
  }) async {
    try {
      final now = DateTime.now().toUtc();
      final expiresAt = now.add(Duration(days: ttlDays));

      await _db.insert(
        'dashboard_cache',
        {
          'id': cacheId,
          'cache_type': cacheType,
          'employee_id': employeeId,
          'cached_data': cachedData,
          'last_updated': now.toIso8601String(),
          'expires_at': expiresAt.toIso8601String(),
          'created_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to cache dashboard data',
        operation: 'cacheDashboardData',
        originalError: e,
      );
    }
  }

  /// Get cached dashboard data if not expired.
  Future<Map<String, dynamic>?> getCachedDashboard(String cacheId) async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final results = await _db.query(
        'dashboard_cache',
        where: 'id = ? AND expires_at > ?',
        whereArgs: [cacheId, now],
        limit: 1,
      );

      if (results.isEmpty) return null;

      final row = results.first;
      return {
        'cached_data': row['cached_data'] as String,
        'last_updated': row['last_updated'] as String,
        'expires_at': row['expires_at'] as String,
      };
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get cached dashboard',
        operation: 'getCachedDashboard',
        originalError: e,
      );
    }
  }

  /// Get last updated time for a cache entry.
  Future<DateTime?> getDashboardCacheLastUpdated(String cacheId) async {
    try {
      final results = await _db.query(
        'dashboard_cache',
        columns: ['last_updated'],
        where: 'id = ?',
        whereArgs: [cacheId],
        limit: 1,
      );

      if (results.isEmpty) return null;
      return DateTime.parse(results.first['last_updated'] as String);
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get dashboard cache last updated',
        operation: 'getDashboardCacheLastUpdated',
        originalError: e,
      );
    }
  }

  /// Delete expired dashboard cache entries.
  Future<int> clearExpiredDashboardCache() async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      return await _db.delete(
        'dashboard_cache',
        where: 'expires_at < ?',
        whereArgs: [now],
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to clear expired dashboard cache',
        operation: 'clearExpiredDashboardCache',
        originalError: e,
      );
    }
  }

  /// Delete all dashboard cache for an employee.
  Future<void> clearEmployeeDashboardCache(String employeeId) async {
    try {
      await _db.delete(
        'dashboard_cache',
        where: 'employee_id = ?',
        whereArgs: [employeeId],
      );
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to clear employee dashboard cache',
        operation: 'clearEmployeeDashboardCache',
        originalError: e,
      );
    }
  }

  // ============ DIAGNOSTIC EVENT OPERATIONS ============

  /// Insert a diagnostic event (fire-and-forget, never throws).
  Future<void> insertDiagnosticEvent(DiagnosticEvent event) async {
    try {
      await _db.insert(
        'diagnostic_events',
        event.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {
      // Fire-and-forget: never crash the app for logging failures
    }
  }

  /// Get pending diagnostic events for server sync.
  /// Excludes debug-level events (local-only).
  Future<List<DiagnosticEvent>> getPendingDiagnosticEvents({
    int limit = 200,
  }) async {
    try {
      final results = await _db.query(
        'diagnostic_events',
        where: "sync_status = ? AND severity != ?",
        whereArgs: ['pending', 'debug'],
        orderBy: 'created_at ASC',
        limit: limit,
      );
      return results.map((map) => DiagnosticEvent.fromMap(map)).toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get pending diagnostic events',
        operation: 'getPendingDiagnosticEvents',
        originalError: e,
      );
    }
  }

  /// Get count of pending diagnostic events (excluding debug-level).
  Future<int> getPendingDiagnosticEventCount() async {
    try {
      final result = await _db.rawQuery(
        "SELECT COUNT(*) as count FROM diagnostic_events "
        "WHERE sync_status = ? AND severity != ?",
        ['pending', 'debug'],
      );
      return result.first['count'] as int? ?? 0;
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get pending diagnostic event count',
        operation: 'getPendingDiagnosticEventCount',
        originalError: e,
      );
    }
  }

  /// Mark diagnostic events as synced.
  Future<void> markDiagnosticEventsSynced(List<String> ids) async {
    if (ids.isEmpty) return;

    try {
      await _db.transaction((txn) async {
        for (final id in ids) {
          await txn.update(
            'diagnostic_events',
            {'sync_status': 'synced'},
            where: 'id = ?',
            whereArgs: [id],
          );
        }
      });
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to mark diagnostic events synced',
        operation: 'markDiagnosticEventsSynced',
        originalError: e,
      );
    }
  }

  /// Prune old synced diagnostic events to stay under storage limit.
  Future<int> pruneDiagnosticEvents({int maxCount = 5000}) async {
    try {
      final countResult = await _db.rawQuery(
        'SELECT COUNT(*) as count FROM diagnostic_events',
      );
      final count = countResult.first['count'] as int;
      if (count <= maxCount) return 0;

      final excess = count - maxCount;
      // Delete oldest synced events first
      return await _db.rawDelete('''
        DELETE FROM diagnostic_events WHERE id IN (
          SELECT id FROM diagnostic_events
          WHERE sync_status = 'synced'
          ORDER BY created_at ASC
          LIMIT ?
        )
      ''', [excess]);
    } catch (_) {
      return 0; // Best-effort pruning
    }
  }

  /// Get total diagnostic event count.
  Future<int> getDiagnosticEventCount() async {
    try {
      final result = await _db.rawQuery(
        'SELECT COUNT(*) as count FROM diagnostic_events',
      );
      return result.first['count'] as int;
    } catch (_) {
      return 0;
    }
  }
}
