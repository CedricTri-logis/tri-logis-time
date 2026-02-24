import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../../shared/services/local_database.dart';
import '../../../shared/services/local_database_exception.dart';
import '../models/cleaning_session.dart';
import '../models/studio.dart';

/// Extension for cleaning-related local database operations.
/// Creates tables on first use (lazy migration for feature modules).
class CleaningLocalDb {
  final LocalDatabase _localDb;
  bool _tablesCreated = false;

  CleaningLocalDb(this._localDb);

  /// Ensure cleaning tables exist.
  Future<void> ensureTables() async {
    if (_tablesCreated) return;

    try {
      await _localDb.transaction((txn) async {
        await txn.execute('''
          CREATE TABLE IF NOT EXISTS local_studios (
            id TEXT PRIMARY KEY,
            qr_code TEXT NOT NULL UNIQUE,
            studio_number TEXT NOT NULL,
            building_id TEXT NOT NULL,
            building_name TEXT NOT NULL,
            studio_type TEXT NOT NULL DEFAULT 'unit',
            is_active INTEGER NOT NULL DEFAULT 1,
            updated_at TEXT NOT NULL
          )
        ''');

        await txn.execute('''
          CREATE INDEX IF NOT EXISTS idx_local_studios_qr_code
          ON local_studios(qr_code)
        ''');

        await txn.execute('''
          CREATE TABLE IF NOT EXISTS local_cleaning_sessions (
            id TEXT PRIMARY KEY,
            employee_id TEXT NOT NULL,
            studio_id TEXT NOT NULL,
            shift_id TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'in_progress',
            started_at TEXT NOT NULL,
            completed_at TEXT,
            duration_minutes REAL,
            is_flagged INTEGER NOT NULL DEFAULT 0,
            flag_reason TEXT,
            sync_status TEXT NOT NULL DEFAULT 'pending',
            server_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');

        await txn.execute('''
          CREATE INDEX IF NOT EXISTS idx_local_cs_employee_status
          ON local_cleaning_sessions(employee_id, status)
        ''');

        await txn.execute('''
          CREATE INDEX IF NOT EXISTS idx_local_cs_studio
          ON local_cleaning_sessions(studio_id)
        ''');

        await txn.execute('''
          CREATE INDEX IF NOT EXISTS idx_local_cs_shift
          ON local_cleaning_sessions(shift_id)
        ''');

        await txn.execute('''
          CREATE INDEX IF NOT EXISTS idx_local_cs_sync
          ON local_cleaning_sessions(sync_status)
        ''');
      });

      _tablesCreated = true;
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to create cleaning tables',
        operation: 'ensureTables',
        originalError: e,
      );
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

  // ============ STUDIO OPERATIONS ============

  /// Upsert studios from Supabase into local cache.
  Future<void> upsertStudios(List<Studio> studios) async {
    await ensureTables();
    try {
      await _localDb.transaction((txn) async {
        for (final studio in studios) {
          await txn.insert(
            'local_studios',
            studio.toLocalDb(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to upsert studios',
        operation: 'upsertStudios',
        originalError: e,
      );
    }
  }

  /// Get a studio by QR code from local cache.
  Future<Studio?> getStudioByQrCode(String qrCode) async {
    await ensureTables();
    try {
      final db = _localDb;
      final results = await db.transaction((txn) async {
        return await txn.query(
          'local_studios',
          where: 'qr_code = ?',
          whereArgs: [qrCode],
          limit: 1,
        );
      });
      if (results.isEmpty) return null;
      return Studio.fromLocalDb(results.first);
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get studio by QR code',
        operation: 'getStudioByQrCode',
        originalError: e,
      );
    }
  }

  /// Get all cached studios.
  Future<List<Studio>> getAllStudios() async {
    await ensureTables();
    try {
      final results = await _localDb.transaction((txn) async {
        return await txn.query(
          'local_studios',
          where: 'is_active = ?',
          whereArgs: [1],
          orderBy: 'building_name, studio_number',
        );
      });
      return results.map((map) => Studio.fromLocalDb(map)).toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get all studios',
        operation: 'getAllStudios',
        originalError: e,
      );
    }
  }

  // ============ CLEANING SESSION OPERATIONS ============

  /// Insert a new cleaning session.
  Future<void> insertCleaningSession(CleaningSession session) async {
    await ensureTables();
    try {
      await _localDb.transaction((txn) async {
        await txn.insert(
          'local_cleaning_sessions',
          session.toLocalDb(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      });
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to insert cleaning session',
        operation: 'insertCleaningSession',
        originalError: e,
      );
    }
  }

  /// Update a cleaning session.
  Future<void> updateCleaningSession(CleaningSession session) async {
    await ensureTables();
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _localDb.transaction((txn) async {
        await txn.update(
          'local_cleaning_sessions',
          {
            'status': session.status.toJson(),
            'completed_at': session.completedAt?.toUtc().toIso8601String(),
            'duration_minutes': session.durationMinutes,
            'is_flagged': session.isFlagged ? 1 : 0,
            'flag_reason': session.flagReason,
            'sync_status': session.syncStatus.toJson(),
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [session.id],
        );
      });
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to update cleaning session',
        operation: 'updateCleaningSession',
        originalError: e,
      );
    }
  }

  /// Get the active session for an employee (optionally for a specific studio).
  Future<CleaningSession?> getActiveSessionForEmployee(
    String employeeId, {
    String? studioId,
  }) async {
    await ensureTables();
    try {
      String where = 'cs.employee_id = ? AND cs.status = ?';
      List<dynamic> whereArgs = [employeeId, 'in_progress'];

      if (studioId != null) {
        where += ' AND cs.studio_id = ?';
        whereArgs.add(studioId);
      }

      final results = await _localDb.transaction((txn) async {
        return await txn.rawQuery('''
          SELECT cs.*, s.studio_number, s.building_name, s.studio_type
          FROM local_cleaning_sessions cs
          LEFT JOIN local_studios s ON cs.studio_id = s.id
          WHERE $where
          ORDER BY cs.started_at DESC
          LIMIT 1
        ''', whereArgs);
      });

      if (results.isEmpty) return null;
      return CleaningSession.fromLocalDb(results.first);
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get active session',
        operation: 'getActiveSessionForEmployee',
        originalError: e,
      );
    }
  }

  /// Get all sessions for a shift.
  Future<List<CleaningSession>> getSessionsForShift(String shiftId) async {
    await ensureTables();
    try {
      final results = await _localDb.transaction((txn) async {
        return await txn.rawQuery('''
          SELECT cs.*, s.studio_number, s.building_name, s.studio_type
          FROM local_cleaning_sessions cs
          LEFT JOIN local_studios s ON cs.studio_id = s.id
          WHERE cs.shift_id = ?
          ORDER BY cs.started_at DESC
        ''', [shiftId]);
      });
      return results.map((map) => CleaningSession.fromLocalDb(map)).toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get sessions for shift',
        operation: 'getSessionsForShift',
        originalError: e,
      );
    }
  }

  /// Get all pending sessions needing sync.
  Future<List<CleaningSession>> getPendingCleaningSessions(String employeeId) async {
    await ensureTables();
    try {
      final results = await _localDb.transaction((txn) async {
        return await txn.rawQuery('''
          SELECT cs.*, s.studio_number, s.building_name, s.studio_type
          FROM local_cleaning_sessions cs
          LEFT JOIN local_studios s ON cs.studio_id = s.id
          WHERE cs.employee_id = ? AND cs.sync_status = ?
          ORDER BY cs.created_at ASC
        ''', [employeeId, 'pending']);
      });
      return results.map((map) => CleaningSession.fromLocalDb(map)).toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get pending cleaning sessions',
        operation: 'getPendingCleaningSessions',
        originalError: e,
      );
    }
  }

  /// Mark a cleaning session as synced.
  Future<void> markCleaningSessionSynced(String sessionId, {String? serverId}) async {
    await ensureTables();
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _localDb.transaction((txn) async {
        await txn.update(
          'local_cleaning_sessions',
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
        'Failed to mark session synced',
        operation: 'markCleaningSessionSynced',
        originalError: e,
      );
    }
  }

  /// Mark a cleaning session sync as errored.
  Future<void> markCleaningSessionSyncError(String sessionId) async {
    await ensureTables();
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _localDb.transaction((txn) async {
        await txn.update(
          'local_cleaning_sessions',
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
        'Failed to mark session sync error',
        operation: 'markCleaningSessionSyncError',
        originalError: e,
      );
    }
  }

  /// Get all in-progress sessions for a shift (for auto-close).
  Future<List<CleaningSession>> getInProgressSessionsForShift(
    String shiftId,
    String employeeId,
  ) async {
    await ensureTables();
    try {
      final results = await _localDb.transaction((txn) async {
        return await txn.rawQuery('''
          SELECT cs.*, s.studio_number, s.building_name, s.studio_type
          FROM local_cleaning_sessions cs
          LEFT JOIN local_studios s ON cs.studio_id = s.id
          WHERE cs.shift_id = ? AND cs.employee_id = ? AND cs.status = ?
        ''', [shiftId, employeeId, 'in_progress']);
      });
      return results.map((map) => CleaningSession.fromLocalDb(map)).toList();
    } catch (e) {
      throw LocalDatabaseException(
        'Failed to get in-progress sessions',
        operation: 'getInProgressSessionsForShift',
        originalError: e,
      );
    }
  }
}
