import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../../shared/services/local_database.dart';
import '../../../shared/services/local_database_exception.dart';
import '../models/work_session.dart';

/// Extension for work-session-related local database operations.
/// Creates tables on first use (lazy migration for feature modules).
class WorkSessionLocalDb {
  final LocalDatabase _localDb;
  bool _tablesCreated = false;

  WorkSessionLocalDb(this._localDb);

  /// Ensure work session tables exist and migrate from old tables.
  Future<void> ensureTables() async {
    if (_tablesCreated) return;

    try {
      await _localDb.transaction((txn) async {
        await txn.execute('''
          CREATE TABLE IF NOT EXISTS local_work_sessions (
            id TEXT PRIMARY KEY,
            employee_id TEXT NOT NULL,
            shift_id TEXT NOT NULL,
            activity_type TEXT NOT NULL,
            location_type TEXT,
            studio_id TEXT,
            studio_number TEXT,
            studio_type TEXT,
            building_id TEXT,
            building_name TEXT,
            apartment_id TEXT,
            unit_number TEXT,
            status TEXT NOT NULL DEFAULT 'in_progress',
            started_at TEXT NOT NULL,
            completed_at TEXT,
            duration_minutes REAL,
            is_flagged INTEGER NOT NULL DEFAULT 0,
            flag_reason TEXT,
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

        await txn.execute('''
          CREATE INDEX IF NOT EXISTS idx_local_ws_employee_status
          ON local_work_sessions(employee_id, status)
        ''');

        await txn.execute('''
          CREATE INDEX IF NOT EXISTS idx_local_ws_shift
          ON local_work_sessions(shift_id)
        ''');

        await txn.execute('''
          CREATE INDEX IF NOT EXISTS idx_local_ws_sync
          ON local_work_sessions(sync_status)
        ''');

        await txn.execute('''
          CREATE INDEX IF NOT EXISTS idx_local_ws_activity_type
          ON local_work_sessions(activity_type)
        ''');
      });

      // Migrate data from old tables (outside the DDL transaction)
      await _migrateOldTables();

      _tablesCreated = true;
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to create work session tables',
        operation: 'ensureTables',
        originalError: e,
      );
    }
  }

  /// Migrate data from old cleaning/maintenance tables into local_work_sessions.
  Future<void> _migrateOldTables() async {
    // 1. Check if local_cleaning_sessions exists, then migrate
    final cleaningTables = await _localDb.transaction((txn) async {
      return await txn.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='local_cleaning_sessions'",
      );
    });
    if (cleaningTables.isNotEmpty) {
      await _localDb.transaction((txn) async {
        await txn.execute('''
          INSERT OR IGNORE INTO local_work_sessions (
            id, employee_id, shift_id, activity_type, location_type,
            studio_id, status, started_at, completed_at, duration_minutes,
            is_flagged, flag_reason, sync_status, server_id,
            start_latitude, start_longitude, start_accuracy,
            end_latitude, end_longitude, end_accuracy,
            created_at, updated_at
          )
          SELECT
            id, employee_id, shift_id, 'cleaning', 'studio',
            studio_id, status, started_at, completed_at, duration_minutes,
            is_flagged, flag_reason, sync_status, server_id,
            start_latitude, start_longitude, start_accuracy,
            end_latitude, end_longitude, end_accuracy,
            created_at, updated_at
          FROM local_cleaning_sessions
        ''');
        await txn.execute('DROP TABLE IF EXISTS local_cleaning_sessions');
      });
    }

    // 2. Check if local_maintenance_sessions exists, then migrate
    final maintenanceTables = await _localDb.transaction((txn) async {
      return await txn.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='local_maintenance_sessions'",
      );
    });
    if (maintenanceTables.isNotEmpty) {
      await _localDb.transaction((txn) async {
        await txn.execute('''
          INSERT OR IGNORE INTO local_work_sessions (
            id, employee_id, shift_id, activity_type, location_type,
            building_id, building_name, apartment_id, unit_number,
            status, started_at, completed_at, duration_minutes,
            is_flagged, flag_reason, notes, sync_status, server_id,
            start_latitude, start_longitude, start_accuracy,
            end_latitude, end_longitude, end_accuracy,
            created_at, updated_at
          )
          SELECT
            id, employee_id, shift_id, 'maintenance',
            CASE WHEN apartment_id IS NOT NULL THEN 'apartment' ELSE 'building' END,
            building_id, building_name, apartment_id, unit_number,
            status, started_at, completed_at, duration_minutes,
            0, NULL, notes, sync_status, server_id,
            start_latitude, start_longitude, start_accuracy,
            end_latitude, end_longitude, end_accuracy,
            created_at, updated_at
          FROM local_maintenance_sessions
        ''');
        await txn.execute('DROP TABLE IF EXISTS local_maintenance_sessions');
      });
    }
  }

  // ============ SHIFT ID RESOLUTION ============

  /// Resolve a local shift ID to its Supabase server ID.
  /// Returns null if the shift hasn't been synced yet.
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

  // ============ WORK SESSION OPERATIONS ============

  /// Insert a new work session.
  Future<void> insertWorkSession(WorkSession session) async {
    await ensureTables();
    try {
      await _localDb.transaction((txn) async {
        await txn.insert(
          'local_work_sessions',
          session.toLocalDb(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      });
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to insert work session',
        operation: 'insertWorkSession',
        originalError: e,
      );
    }
  }

  /// Update a work session.
  Future<void> updateWorkSession(WorkSession session) async {
    await ensureTables();
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _localDb.transaction((txn) async {
        final values = <String, dynamic>{
          'status': session.status.toJson(),
          'completed_at': session.completedAt?.toUtc().toIso8601String(),
          'duration_minutes': session.durationMinutes,
          'is_flagged': session.isFlagged ? 1 : 0,
          'flag_reason': session.flagReason,
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
          'local_work_sessions',
          values,
          where: 'id = ?',
          whereArgs: [session.id],
        );
      });
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to update work session',
        operation: 'updateWorkSession',
        originalError: e,
      );
    }
  }

  /// Get the active work session for an employee.
  Future<WorkSession?> getActiveSessionForEmployee(
    String employeeId,
  ) async {
    await ensureTables();
    try {
      final results = await _localDb.transaction((txn) async {
        return await txn.rawQuery('''
          SELECT ws.*,
                 s.studio_number AS _studio_number,
                 s.building_name AS _studio_building_name,
                 s.studio_type AS _studio_type,
                 b.name AS _building_name,
                 a.unit_number AS _apartment_unit_number
          FROM local_work_sessions ws
          LEFT JOIN local_studios s ON ws.studio_id = s.id
          LEFT JOIN local_property_buildings b ON ws.building_id = b.id
          LEFT JOIN local_apartments a ON ws.apartment_id = a.id
          WHERE ws.employee_id = ? AND ws.status = ?
          ORDER BY ws.started_at DESC
          LIMIT 1
        ''', [employeeId, 'in_progress'],);
      });

      if (results.isEmpty) return null;
      return WorkSession.fromLocalDb(_enrichRow(results.first));
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get active work session',
        operation: 'getActiveSessionForEmployee',
        originalError: e,
      );
    }
  }

  /// Get all sessions for a shift.
  Future<List<WorkSession>> getSessionsForShift(String shiftId) async {
    await ensureTables();
    try {
      final results = await _localDb.transaction((txn) async {
        return await txn.rawQuery('''
          SELECT ws.*,
                 s.studio_number AS _studio_number,
                 s.building_name AS _studio_building_name,
                 s.studio_type AS _studio_type,
                 b.name AS _building_name,
                 a.unit_number AS _apartment_unit_number
          FROM local_work_sessions ws
          LEFT JOIN local_studios s ON ws.studio_id = s.id
          LEFT JOIN local_property_buildings b ON ws.building_id = b.id
          LEFT JOIN local_apartments a ON ws.apartment_id = a.id
          WHERE ws.shift_id = ?
          ORDER BY ws.started_at DESC
        ''', [shiftId],);
      });
      return results
          .map((map) => WorkSession.fromLocalDb(_enrichRow(map)))
          .toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get sessions for shift',
        operation: 'getSessionsForShift',
        originalError: e,
      );
    }
  }

  /// Get all sessions for a shift group (all segments sharing the same work_body_id).
  /// Falls back to single shift query if no sibling segments exist.
  Future<List<WorkSession>> getSessionsForShiftGroup(List<String> shiftIds) async {
    await ensureTables();
    if (shiftIds.isEmpty) return [];
    try {
      final placeholders = shiftIds.map((_) => '?').join(', ');
      final results = await _localDb.transaction((txn) async {
        return await txn.rawQuery('''
          SELECT ws.*,
                 s.studio_number AS _studio_number,
                 s.building_name AS _studio_building_name,
                 s.studio_type AS _studio_type,
                 b.name AS _building_name,
                 a.unit_number AS _apartment_unit_number
          FROM local_work_sessions ws
          LEFT JOIN local_studios s ON ws.studio_id = s.id
          LEFT JOIN local_property_buildings b ON ws.building_id = b.id
          LEFT JOIN local_apartments a ON ws.apartment_id = a.id
          WHERE ws.shift_id IN ($placeholders)
          ORDER BY ws.started_at DESC
        ''', shiftIds,);
      });
      return results
          .map((map) => WorkSession.fromLocalDb(_enrichRow(map)))
          .toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get sessions for shift group',
        operation: 'getSessionsForShiftGroup',
        originalError: e,
      );
    }
  }

  /// Get all pending sessions needing sync.
  Future<List<WorkSession>> getPendingWorkSessions(String employeeId) async {
    await ensureTables();
    try {
      final results = await _localDb.transaction((txn) async {
        return await txn.rawQuery('''
          SELECT ws.*,
                 s.studio_number AS _studio_number,
                 s.building_name AS _studio_building_name,
                 s.studio_type AS _studio_type,
                 b.name AS _building_name,
                 a.unit_number AS _apartment_unit_number
          FROM local_work_sessions ws
          LEFT JOIN local_studios s ON ws.studio_id = s.id
          LEFT JOIN local_property_buildings b ON ws.building_id = b.id
          LEFT JOIN local_apartments a ON ws.apartment_id = a.id
          WHERE ws.employee_id = ? AND ws.sync_status = ?
          ORDER BY ws.created_at ASC
        ''', [employeeId, 'pending'],);
      });
      return results
          .map((map) => WorkSession.fromLocalDb(_enrichRow(map)))
          .toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get pending work sessions',
        operation: 'getPendingWorkSessions',
        originalError: e,
      );
    }
  }

  /// Mark a work session as synced.
  Future<void> markWorkSessionSynced(
    String sessionId, {
    String? serverId,
  }) async {
    await ensureTables();
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _localDb.transaction((txn) async {
        await txn.update(
          'local_work_sessions',
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
        'Failed to mark work session synced',
        operation: 'markWorkSessionSynced',
        originalError: e,
      );
    }
  }

  /// Mark a work session sync as errored.
  Future<void> markWorkSessionSyncError(String sessionId) async {
    await ensureTables();
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _localDb.transaction((txn) async {
        await txn.update(
          'local_work_sessions',
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
        'Failed to mark work session sync error',
        operation: 'markWorkSessionSyncError',
        originalError: e,
      );
    }
  }

  /// Revert a work session status (used when server confirmation fails).
  Future<void> updateWorkSessionStatus(
    String sessionId,
    WorkSessionStatus status,
  ) async {
    await ensureTables();
    try {
      await _localDb.transaction((txn) async {
        await txn.update(
          'local_work_sessions',
          {
            'status': status.toJson(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [sessionId],
        );
      });
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to update work session status',
        operation: 'updateWorkSessionStatus',
        originalError: e,
      );
    }
  }

  /// Delete a work session from local DB (used when server confirmation fails).
  Future<void> deleteWorkSession(String sessionId) async {
    await ensureTables();
    try {
      await _localDb.transaction((txn) async {
        await txn.delete(
          'local_work_sessions',
          where: 'id = ?',
          whereArgs: [sessionId],
        );
      });
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to delete work session',
        operation: 'deleteWorkSession',
        originalError: e,
      );
    }
  }

  /// Get count of pending work sessions for an employee.
  Future<int> getPendingWorkSessionCount(String employeeId) async {
    await ensureTables();
    try {
      final result = await _localDb.transaction((txn) async {
        return await txn.rawQuery(
          'SELECT COUNT(*) as cnt FROM local_work_sessions WHERE employee_id = ? AND sync_status = ?',
          [employeeId, 'pending'],
        );
      });
      return Sqflite.firstIntValue(result) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Get all in-progress sessions for a shift (for auto-close).
  Future<List<WorkSession>> getInProgressSessionsForShift(
    String shiftId,
    String employeeId,
  ) async {
    await ensureTables();
    try {
      final results = await _localDb.transaction((txn) async {
        return await txn.rawQuery('''
          SELECT ws.*,
                 s.studio_number AS _studio_number,
                 s.building_name AS _studio_building_name,
                 s.studio_type AS _studio_type,
                 b.name AS _building_name,
                 a.unit_number AS _apartment_unit_number
          FROM local_work_sessions ws
          LEFT JOIN local_studios s ON ws.studio_id = s.id
          LEFT JOIN local_property_buildings b ON ws.building_id = b.id
          LEFT JOIN local_apartments a ON ws.apartment_id = a.id
          WHERE ws.shift_id = ? AND ws.employee_id = ? AND ws.status = ?
        ''', [shiftId, employeeId, 'in_progress'],);
      });
      return results
          .map((map) => WorkSession.fromLocalDb(_enrichRow(map)))
          .toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get in-progress work sessions',
        operation: 'getInProgressSessionsForShift',
        originalError: e,
      );
    }
  }

  /// Get the activity type of the most recently completed session for a shift.
  /// Returns null if no completed sessions exist for this shift.
  Future<String?> getLastActivityTypeForShift(String shiftId) async {
    await ensureTables();
    try {
      final results = await _localDb.transaction((txn) async {
        return await txn.rawQuery('''
          SELECT activity_type
          FROM local_work_sessions
          WHERE shift_id = ? AND status != 'in_progress'
          ORDER BY completed_at DESC
          LIMIT 1
        ''', [shiftId],);
      });
      if (results.isEmpty) return null;
      return results.first['activity_type'] as String?;
    } catch (e) {
      return null;
    }
  }

  // ============ HELPERS ============

  /// Enrich a raw query row by merging JOIN-aliased columns back
  /// into the column names expected by [WorkSession.fromLocalDb].
  ///
  /// The LEFT JOINs use aliases prefixed with `_` to avoid collisions
  /// with the work_sessions own columns (e.g. `building_name` exists in
  /// both the work session row and the buildings table). The denormalized
  /// columns stored directly on the work session row take precedence;
  /// the JOIN values are only used as fallback when the row value is null.
  Map<String, dynamic> _enrichRow(Map<String, dynamic> row) {
    final enriched = Map<String, dynamic>.from(row);
    enriched['studio_number'] ??= row['_studio_number'];
    enriched['studio_type'] ??= row['_studio_type'];
    enriched['building_name'] ??= row['_studio_building_name'] ?? row['_building_name'];
    enriched['unit_number'] ??= row['_apartment_unit_number'];
    return enriched;
  }
}
