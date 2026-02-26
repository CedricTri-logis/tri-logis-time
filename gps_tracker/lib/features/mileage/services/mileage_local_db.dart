import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../../shared/services/local_database.dart';
import '../../../shared/services/local_database_exception.dart';
import '../models/local_trip.dart';

/// Local SQLCipher database operations for mileage trip caching.
/// Creates tables on first use (lazy migration for feature modules).
class MileageLocalDb {
  final LocalDatabase _localDb;
  bool _tablesCreated = false;

  MileageLocalDb(this._localDb);

  /// Ensure mileage tables exist.
  Future<void> ensureTables() async {
    if (_tablesCreated) return;

    try {
      await _localDb.transaction((txn) async {
        await txn.execute('''
          CREATE TABLE IF NOT EXISTS local_trips (
            id TEXT PRIMARY KEY,
            shift_id TEXT NOT NULL,
            employee_id TEXT NOT NULL,
            started_at TEXT NOT NULL,
            ended_at TEXT NOT NULL,
            start_latitude REAL NOT NULL,
            start_longitude REAL NOT NULL,
            start_address TEXT,
            end_latitude REAL NOT NULL,
            end_longitude REAL NOT NULL,
            end_address TEXT,
            distance_km REAL NOT NULL,
            duration_minutes INTEGER NOT NULL,
            classification TEXT NOT NULL DEFAULT 'business',
            confidence_score REAL NOT NULL DEFAULT 1.0,
            gps_point_count INTEGER NOT NULL DEFAULT 0,
            synced INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            route_geometry TEXT,
            road_distance_km REAL,
            match_status TEXT NOT NULL DEFAULT 'pending',
            match_confidence REAL
          )
        ''');

        // Add route matching columns to existing tables (schema migration)
        await txn.execute('''
          CREATE TABLE IF NOT EXISTS _mileage_schema_version (version INTEGER)
        ''');
        final versionResult = await txn.query('_mileage_schema_version');
        final currentVersion = versionResult.isEmpty ? 0 : (versionResult.first['version'] as num?)?.toInt() ?? 0;
        if (currentVersion < 1) {
          // Add columns if they don't exist (for existing databases)
          try { await txn.execute('ALTER TABLE local_trips ADD COLUMN route_geometry TEXT'); } catch (_) {}
          try { await txn.execute('ALTER TABLE local_trips ADD COLUMN road_distance_km REAL'); } catch (_) {}
          try { await txn.execute('ALTER TABLE local_trips ADD COLUMN match_status TEXT NOT NULL DEFAULT \'pending\''); } catch (_) {}
          try { await txn.execute('ALTER TABLE local_trips ADD COLUMN match_confidence REAL'); } catch (_) {}
          await txn.execute('INSERT OR REPLACE INTO _mileage_schema_version (version) VALUES (1)');
        }

        await txn.execute('''
          CREATE INDEX IF NOT EXISTS idx_local_trips_shift
          ON local_trips(shift_id)
        ''');

        await txn.execute('''
          CREATE INDEX IF NOT EXISTS idx_local_trips_employee
          ON local_trips(employee_id)
        ''');

        await txn.execute('''
          CREATE INDEX IF NOT EXISTS idx_local_trips_synced
          ON local_trips(synced)
        ''');
      });

      _tablesCreated = true;
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to create mileage tables',
        operation: 'ensureTables',
        originalError: e,
      );
    }
  }

  /// Upsert trips from Supabase into local cache.
  Future<void> upsertTrips(List<LocalTrip> trips) async {
    await ensureTables();
    try {
      await _localDb.transaction((txn) async {
        for (final trip in trips) {
          await txn.insert(
            'local_trips',
            trip.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to upsert trips',
        operation: 'upsertTrips',
        originalError: e,
      );
    }
  }

  /// Get all cached trips for a shift.
  Future<List<LocalTrip>> getTripsForShift(String shiftId) async {
    await ensureTables();
    try {
      final results = await _localDb.transaction((txn) async {
        return await txn.query(
          'local_trips',
          where: 'shift_id = ?',
          whereArgs: [shiftId],
          orderBy: 'started_at ASC',
        );
      });
      return results.map((map) => LocalTrip.fromMap(map)).toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get trips for shift',
        operation: 'getTripsForShift',
        originalError: e,
      );
    }
  }

  /// Get all cached trips for an employee in a date range.
  Future<List<LocalTrip>> getTripsForPeriod(
    String employeeId,
    DateTime start,
    DateTime end,
  ) async {
    await ensureTables();
    try {
      final results = await _localDb.transaction((txn) async {
        return await txn.query(
          'local_trips',
          where: 'employee_id = ? AND started_at >= ? AND started_at < ?',
          whereArgs: [
            employeeId,
            start.toUtc().toIso8601String(),
            end.toUtc().toIso8601String(),
          ],
          orderBy: 'started_at DESC',
        );
      });
      return results.map((map) => LocalTrip.fromMap(map)).toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get trips for period',
        operation: 'getTripsForPeriod',
        originalError: e,
      );
    }
  }

  /// Update trip classification locally.
  Future<void> updateTripClassification(
      String tripId, String classification) async {
    await ensureTables();
    try {
      await _localDb.transaction((txn) async {
        await txn.update(
          'local_trips',
          {
            'classification': classification,
            'synced': 0,
          },
          where: 'id = ?',
          whereArgs: [tripId],
        );
      });
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to update trip classification',
        operation: 'updateTripClassification',
        originalError: e,
      );
    }
  }

  /// Get trips with pending classification changes.
  Future<List<LocalTrip>> getPendingClassificationChanges() async {
    await ensureTables();
    try {
      final results = await _localDb.transaction((txn) async {
        return await txn.query(
          'local_trips',
          where: 'synced = ?',
          whereArgs: [0],
        );
      });
      return results.map((map) => LocalTrip.fromMap(map)).toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get pending changes',
        operation: 'getPendingClassificationChanges',
        originalError: e,
      );
    }
  }

  /// Mark a trip as synced.
  Future<void> markTripSynced(String tripId) async {
    await ensureTables();
    try {
      await _localDb.transaction((txn) async {
        await txn.update(
          'local_trips',
          {'synced': 1},
          where: 'id = ?',
          whereArgs: [tripId],
        );
      });
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to mark trip synced',
        operation: 'markTripSynced',
        originalError: e,
      );
    }
  }

  /// Delete all cached trips for a shift (before re-caching).
  Future<void> deleteTripsForShift(String shiftId) async {
    await ensureTables();
    try {
      await _localDb.transaction((txn) async {
        await txn.delete(
          'local_trips',
          where: 'shift_id = ?',
          whereArgs: [shiftId],
        );
      });
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to delete trips for shift',
        operation: 'deleteTripsForShift',
        originalError: e,
      );
    }
  }
}
