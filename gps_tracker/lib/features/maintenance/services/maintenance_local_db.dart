import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../../shared/services/local_database.dart';
import '../../../shared/services/local_database_exception.dart';
import '../models/apartment.dart';
import '../models/maintenance_session.dart';
import '../models/property_building.dart';

/// Extension for maintenance-related local database operations.
/// Creates tables on first use (lazy migration for feature modules).
class MaintenanceLocalDb {
  final LocalDatabase _localDb;
  bool _tablesCreated = false;

  MaintenanceLocalDb(this._localDb);

  /// Ensure maintenance tables exist.
  Future<void> ensureTables() async {
    if (_tablesCreated) return;

    try {
      await _localDb.transaction((txn) async {
        // Migrate: drop old table if it has the legacy studio_id column
        final cols = await txn.rawQuery(
            "PRAGMA table_info(local_maintenance_sessions)");
        if (cols.isNotEmpty) {
          final hasStudioId =
              cols.any((c) => c['name'] == 'studio_id');
          if (hasStudioId) {
            await txn.execute(
                'DROP TABLE IF EXISTS local_maintenance_sessions');
          }
        }

        // Maintenance sessions table (apartment_id/unit_number instead of studio_id/studio_number)
        await txn.execute('''
          CREATE TABLE IF NOT EXISTS local_maintenance_sessions (
            id TEXT PRIMARY KEY,
            employee_id TEXT NOT NULL,
            shift_id TEXT NOT NULL,
            building_id TEXT NOT NULL,
            building_name TEXT NOT NULL,
            apartment_id TEXT,
            unit_number TEXT,
            status TEXT NOT NULL DEFAULT 'in_progress',
            started_at TEXT NOT NULL,
            completed_at TEXT,
            duration_minutes REAL,
            notes TEXT,
            sync_status TEXT NOT NULL DEFAULT 'pending',
            server_id TEXT,
            start_latitude REAL,
            start_longitude REAL,
            start_accuracy REAL,
            end_latitude REAL,
            end_longitude REAL,
            end_accuracy REAL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');

        // Add GPS columns to existing tables (safe to run multiple times)
        for (final col in ['start_latitude', 'start_longitude', 'start_accuracy',
                           'end_latitude', 'end_longitude', 'end_accuracy']) {
          try {
            await txn.execute(
              'ALTER TABLE local_maintenance_sessions ADD COLUMN $col REAL');
          } catch (_) {
            // Column already exists
          }
        }

        await txn.execute('''
          CREATE INDEX IF NOT EXISTS idx_local_ms_employee_status
          ON local_maintenance_sessions(employee_id, status)
        ''');

        await txn.execute('''
          CREATE INDEX IF NOT EXISTS idx_local_ms_shift
          ON local_maintenance_sessions(shift_id)
        ''');

        await txn.execute('''
          CREATE INDEX IF NOT EXISTS idx_local_ms_building
          ON local_maintenance_sessions(building_id)
        ''');

        await txn.execute('''
          CREATE INDEX IF NOT EXISTS idx_local_ms_sync
          ON local_maintenance_sessions(sync_status)
        ''');

        // Property buildings cache table
        await txn.execute('''
          CREATE TABLE IF NOT EXISTS local_property_buildings (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            address TEXT NOT NULL,
            city TEXT NOT NULL,
            is_active INTEGER DEFAULT 1,
            updated_at TEXT
          )
        ''');

        // Apartments cache table
        await txn.execute('''
          CREATE TABLE IF NOT EXISTS local_apartments (
            id TEXT PRIMARY KEY,
            building_id TEXT NOT NULL,
            apartment_name TEXT NOT NULL,
            unit_number TEXT,
            apartment_category TEXT DEFAULT 'Residential',
            is_active INTEGER DEFAULT 1,
            updated_at TEXT
          )
        ''');

        await txn.execute('''
          CREATE INDEX IF NOT EXISTS idx_local_apartments_building
          ON local_apartments(building_id)
        ''');
      });

      _tablesCreated = true;
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to create maintenance tables',
        operation: 'ensureTables',
        originalError: e,
      );
    }
  }

  // ============ SHIFT ID RESOLUTION ============

  /// Resolve a local shift ID to its Supabase server ID.
  Future<String?> resolveServerShiftId(String localShiftId) async {
    try {
      final results = await _localDb.transaction((txn) async {
        return await txn.query(
          'local_shifts',
          columns: ['server_id'],
          where: 'id = ?',
          whereArgs: [localShiftId],
          limit: 1,
        );
      });
      if (results.isEmpty) return null;
      return results.first['server_id'] as String?;
    } catch (_) {
      return null;
    }
  }

  // ============ PROPERTY CACHE OPERATIONS ============

  /// Upsert property buildings into local cache.
  Future<void> upsertBuildings(List<PropertyBuilding> buildings) async {
    await ensureTables();
    try {
      await _localDb.transaction((txn) async {
        for (final building in buildings) {
          await txn.insert(
            'local_property_buildings',
            building.toLocalDb(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to upsert buildings',
        operation: 'upsertBuildings',
        originalError: e,
      );
    }
  }

  /// Upsert apartments into local cache.
  Future<void> upsertApartments(List<Apartment> apartments) async {
    await ensureTables();
    try {
      await _localDb.transaction((txn) async {
        for (final apartment in apartments) {
          await txn.insert(
            'local_apartments',
            apartment.toLocalDb(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to upsert apartments',
        operation: 'upsertApartments',
        originalError: e,
      );
    }
  }

  /// Get all active property buildings from cache.
  Future<List<PropertyBuilding>> getAllBuildings() async {
    await ensureTables();
    try {
      final results = await _localDb.transaction((txn) async {
        return await txn.query(
          'local_property_buildings',
          where: 'is_active = ?',
          whereArgs: [1],
          orderBy: 'address ASC',
        );
      });
      return results
          .map((map) => PropertyBuilding.fromLocalDb(map))
          .toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get buildings',
        operation: 'getAllBuildings',
        originalError: e,
      );
    }
  }

  /// Get all active apartments for a building from cache.
  Future<List<Apartment>> getApartmentsForBuilding(String buildingId) async {
    await ensureTables();
    try {
      final results = await _localDb.transaction((txn) async {
        return await txn.query(
          'local_apartments',
          where: 'building_id = ? AND is_active = ?',
          whereArgs: [buildingId, 1],
          orderBy: 'unit_number ASC, apartment_name ASC',
        );
      });
      return results.map((map) => Apartment.fromLocalDb(map)).toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get apartments for building',
        operation: 'getApartmentsForBuilding',
        originalError: e,
      );
    }
  }

  // ============ MAINTENANCE SESSION OPERATIONS ============

  /// Insert a new maintenance session.
  Future<void> insertMaintenanceSession(MaintenanceSession session) async {
    await ensureTables();
    try {
      await _localDb.transaction((txn) async {
        await txn.insert(
          'local_maintenance_sessions',
          session.toLocalDb(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      });
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to insert maintenance session',
        operation: 'insertMaintenanceSession',
        originalError: e,
      );
    }
  }

  /// Update a maintenance session.
  Future<void> updateMaintenanceSession(MaintenanceSession session) async {
    await ensureTables();
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _localDb.transaction((txn) async {
        final values = <String, dynamic>{
            'status': session.status.toJson(),
            'completed_at': session.completedAt?.toUtc().toIso8601String(),
            'duration_minutes': session.durationMinutes,
            'notes': session.notes,
            'sync_status': session.syncStatus.toJson(),
            'updated_at': now,
          };
        if (session.startLatitude != null) {
          values['start_latitude'] = session.startLatitude;
          values['start_longitude'] = session.startLongitude;
          values['start_accuracy'] = session.startAccuracy;
        }
        if (session.endLatitude != null) {
          values['end_latitude'] = session.endLatitude;
          values['end_longitude'] = session.endLongitude;
          values['end_accuracy'] = session.endAccuracy;
        }
        await txn.update(
          'local_maintenance_sessions',
          values,
          where: 'id = ?',
          whereArgs: [session.id],
        );
      });
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to update maintenance session',
        operation: 'updateMaintenanceSession',
        originalError: e,
      );
    }
  }

  /// Get the active maintenance session for an employee.
  Future<MaintenanceSession?> getActiveSessionForEmployee(
    String employeeId,
  ) async {
    await ensureTables();
    try {
      final results = await _localDb.transaction((txn) async {
        return await txn.query(
          'local_maintenance_sessions',
          where: 'employee_id = ? AND status = ?',
          whereArgs: [employeeId, 'in_progress'],
          orderBy: 'started_at DESC',
          limit: 1,
        );
      });

      if (results.isEmpty) return null;
      return MaintenanceSession.fromLocalDb(results.first);
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get active maintenance session',
        operation: 'getActiveSessionForEmployee',
        originalError: e,
      );
    }
  }

  /// Get all sessions for a shift.
  Future<List<MaintenanceSession>> getSessionsForShift(String shiftId) async {
    await ensureTables();
    try {
      final results = await _localDb.transaction((txn) async {
        return await txn.query(
          'local_maintenance_sessions',
          where: 'shift_id = ?',
          whereArgs: [shiftId],
          orderBy: 'started_at DESC',
        );
      });
      return results
          .map((map) => MaintenanceSession.fromLocalDb(map))
          .toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get sessions for shift',
        operation: 'getSessionsForShift',
        originalError: e,
      );
    }
  }

  /// Get all pending sessions needing sync.
  Future<List<MaintenanceSession>> getPendingMaintenanceSessions(
    String employeeId,
  ) async {
    await ensureTables();
    try {
      final results = await _localDb.transaction((txn) async {
        return await txn.query(
          'local_maintenance_sessions',
          where: 'employee_id = ? AND sync_status = ?',
          whereArgs: [employeeId, 'pending'],
          orderBy: 'created_at ASC',
        );
      });
      return results
          .map((map) => MaintenanceSession.fromLocalDb(map))
          .toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get pending maintenance sessions',
        operation: 'getPendingMaintenanceSessions',
        originalError: e,
      );
    }
  }

  /// Mark a maintenance session as synced.
  Future<void> markMaintenanceSessionSynced(String sessionId,
      {String? serverId}) async {
    await ensureTables();
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _localDb.transaction((txn) async {
        await txn.update(
          'local_maintenance_sessions',
          {
            'sync_status': 'synced',
            'server_id': serverId,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [sessionId],
        );
      });
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to mark maintenance session synced',
        operation: 'markMaintenanceSessionSynced',
        originalError: e,
      );
    }
  }

  /// Mark a maintenance session sync as errored.
  Future<void> markMaintenanceSessionSyncError(String sessionId) async {
    await ensureTables();
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _localDb.transaction((txn) async {
        await txn.update(
          'local_maintenance_sessions',
          {
            'sync_status': 'error',
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [sessionId],
        );
      });
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to mark maintenance session sync error',
        operation: 'markMaintenanceSessionSyncError',
        originalError: e,
      );
    }
  }

  /// Get all in-progress sessions for a shift (for auto-close).
  Future<List<MaintenanceSession>> getInProgressSessionsForShift(
    String shiftId,
    String employeeId,
  ) async {
    await ensureTables();
    try {
      final results = await _localDb.transaction((txn) async {
        return await txn.query(
          'local_maintenance_sessions',
          where: 'shift_id = ? AND employee_id = ? AND status = ?',
          whereArgs: [shiftId, employeeId, 'in_progress'],
        );
      });
      return results
          .map((map) => MaintenanceSession.fromLocalDb(map))
          .toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get in-progress maintenance sessions',
        operation: 'getInProgressSessionsForShift',
        originalError: e,
      );
    }
  }
}
