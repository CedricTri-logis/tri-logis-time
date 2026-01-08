import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../features/shifts/models/local_gps_point.dart';
import '../../features/shifts/models/local_shift.dart';
import 'local_database_exception.dart';

/// Local SQLite database service with encrypted storage.
class LocalDatabase {
  static const String _databaseName = 'gps_tracker.db';
  static const int _databaseVersion = 1;
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
  Future<void> initialize() async {
    if (_database != null) return;

    try {
      // Get or create encryption key
      String? encryptionKey = await _secureStorage.read(key: _encryptionKeyKey);
      if (encryptionKey == null) {
        // Generate a new encryption key (32 bytes hex = 64 chars)
        encryptionKey = _generateEncryptionKey();
        await _secureStorage.write(key: _encryptionKeyKey, value: encryptionKey);
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
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to initialize database',
        operation: 'initialize',
        originalError: e,
      );
    }
  }

  /// Generate a random encryption key.
  String _generateEncryptionKey() {
    final random = DateTime.now().microsecondsSinceEpoch;
    return random.toRadixString(16).padLeft(64, '0').substring(0, 64);
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
        FOREIGN KEY (shift_id) REFERENCES local_shifts(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_local_gps_shift ON local_gps_points(shift_id)
    ''');

    await db.execute('''
      CREATE INDEX idx_local_gps_sync ON local_gps_points(sync_status)
    ''');
  }

  /// Handle database upgrades.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Handle migrations here when needed
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
}
