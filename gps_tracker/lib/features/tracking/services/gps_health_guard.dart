import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../../../shared/models/diagnostic_event.dart';
import '../../../shared/services/diagnostic_logger.dart';

/// Result of a GPS health check.
enum HealthCheckResult {
  /// Service was already running — no action needed.
  alreadyAlive,

  /// No active shift — check skipped.
  noActiveShift,

  /// Service was dead — restart succeeded.
  restartSuccess,

  /// Service was dead — restart failed or timed out.
  restartFailed,
}

/// Verifies GPS tracking is alive on user interactions.
///
/// Two modes:
/// - [ensureAlive]: Awaited (hard gate) — used before business actions.
/// - [nudge]: Fire-and-forget with 30s debounce — used on general interactions.
class GpsHealthGuard {
  DateTime? _lastCheckAt;
  bool _isRestarting = false;

  DiagnosticLogger? get _logger =>
      DiagnosticLogger.isInitialized ? DiagnosticLogger.instance : null;

  /// Hard gate — check if GPS tracking service is alive.
  /// If dead and an active shift exists, restart and wait up to 5 seconds.
  /// Returns result; action should always proceed regardless.
  ///
  /// [source] identifies the caller for logging (e.g. 'cleaning_scan_in').
  /// [hasActiveShift] whether a shift is currently active.
  /// [startTrackingCallback] called to restart tracking if service is dead.
  Future<HealthCheckResult> ensureAlive({
    required String source,
    required bool hasActiveShift,
    required String? shiftId,
    required Future<void> Function() startTrackingCallback,
  }) async {
    final timeSinceLastCheck = _lastCheckAt != null
        ? DateTime.now().difference(_lastCheckAt!).inSeconds
        : null;
    _lastCheckAt = DateTime.now();

    // Fast path: check if service is running
    final isRunning = await FlutterForegroundTask.isRunningService;

    if (isRunning) {
      _logger?.lifecycle(
        Severity.info,
        'GPS health check OK',
        metadata: {
          'source': source,
          'tier': 'hard',
          'service_was_alive': true,
          if (shiftId != null) 'shift_id': shiftId,
          if (timeSinceLastCheck != null)
            'time_since_last_check_s': timeSinceLastCheck,
        },
      );
      return HealthCheckResult.alreadyAlive;
    }

    // Service is not running
    if (!hasActiveShift) {
      _logger?.lifecycle(
        Severity.info,
        'GPS health check — no active shift',
        metadata: {
          'source': source,
          'tier': 'hard',
          'service_was_alive': false,
        },
      );
      return HealthCheckResult.noActiveShift;
    }

    // Service dead + active shift → restart
    if (_isRestarting) {
      _logger?.lifecycle(
        Severity.info,
        'GPS health check — restart already in progress',
        metadata: {
          'source': source,
          'tier': 'hard',
          'shift_id': shiftId,
        },
      );
      return HealthCheckResult.restartSuccess;
    }

    _isRestarting = true;
    final stopwatch = Stopwatch()..start();

    _logger?.lifecycle(
      Severity.warn,
      'GPS health check — service dead, restarting',
      metadata: {
        'source': source,
        'tier': 'hard',
        'service_was_alive': false,
        'shift_id': shiftId,
        if (timeSinceLastCheck != null)
          'time_since_last_check_s': timeSinceLastCheck,
      },
    );

    try {
      // Start tracking with a 5-second timeout
      await startTrackingCallback().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _logger?.lifecycle(
            Severity.error,
            'GPS health check — restart timed out after 5s',
            metadata: {
              'source': source,
              'tier': 'hard',
              'shift_id': shiftId,
              'restart_duration_ms': stopwatch.elapsedMilliseconds,
            },
          );
        },
      );

      stopwatch.stop();

      // Verify restart actually worked
      final nowRunning = await FlutterForegroundTask.isRunningService;
      final result = nowRunning
          ? HealthCheckResult.restartSuccess
          : HealthCheckResult.restartFailed;

      _logger?.lifecycle(
        nowRunning ? Severity.info : Severity.error,
        nowRunning
            ? 'GPS health check — restart succeeded'
            : 'GPS health check — restart failed',
        metadata: {
          'source': source,
          'tier': 'hard',
          'shift_id': shiftId,
          'restart_duration_ms': stopwatch.elapsedMilliseconds,
        },
      );

      return result;
    } catch (e) {
      stopwatch.stop();
      _logger?.lifecycle(
        Severity.error,
        'GPS health check — restart threw exception',
        metadata: {
          'source': source,
          'tier': 'hard',
          'shift_id': shiftId,
          'restart_duration_ms': stopwatch.elapsedMilliseconds,
          'error': e.toString(),
        },
      );
      return HealthCheckResult.restartFailed;
    } finally {
      _isRestarting = false;
    }
  }

  /// Soft nudge — fire-and-forget with 30-second debounce.
  /// Call from general interactions (navigation, taps, pull-to-refresh).
  void nudge({
    required String source,
    required bool hasActiveShift,
    required String? shiftId,
    required Future<void> Function() startTrackingCallback,
  }) {
    if (!hasActiveShift) return;

    // Debounce: skip if checked within last 30 seconds
    if (_lastCheckAt != null &&
        DateTime.now().difference(_lastCheckAt!).inSeconds < 30) {
      return;
    }

    // Fire-and-forget — log with soft tier
    _lastCheckAt = DateTime.now();
    _ensureAliveSoft(
      source: source,
      shiftId: shiftId,
      startTrackingCallback: startTrackingCallback,
    );
  }

  /// Internal soft check — same logic as ensureAlive but non-blocking.
  Future<void> _ensureAliveSoft({
    required String source,
    required String? shiftId,
    required Future<void> Function() startTrackingCallback,
  }) async {
    try {
      final isRunning = await FlutterForegroundTask.isRunningService;

      if (isRunning) {
        _logger?.lifecycle(
          Severity.info,
          'GPS health check OK',
          metadata: {
            'source': source,
            'tier': 'soft',
            'service_was_alive': true,
            if (shiftId != null) 'shift_id': shiftId,
          },
        );
        return;
      }

      if (_isRestarting) return;
      _isRestarting = true;
      final stopwatch = Stopwatch()..start();

      _logger?.lifecycle(
        Severity.warn,
        'GPS health check — service dead, restarting',
        metadata: {
          'source': source,
          'tier': 'soft',
          'service_was_alive': false,
          'shift_id': shiftId,
        },
      );

      try {
        await startTrackingCallback().timeout(
          const Duration(seconds: 5),
        );
        stopwatch.stop();

        final nowRunning = await FlutterForegroundTask.isRunningService;
        _logger?.lifecycle(
          nowRunning ? Severity.info : Severity.error,
          nowRunning
              ? 'GPS health check — restart succeeded'
              : 'GPS health check — restart failed',
          metadata: {
            'source': source,
            'tier': 'soft',
            'shift_id': shiftId,
            'restart_duration_ms': stopwatch.elapsedMilliseconds,
          },
        );
      } catch (e) {
        stopwatch.stop();
        _logger?.lifecycle(
          Severity.error,
          'GPS health check — restart threw exception',
          metadata: {
            'source': source,
            'tier': 'soft',
            'shift_id': shiftId,
            'restart_duration_ms': stopwatch.elapsedMilliseconds,
            'error': e.toString(),
          },
        );
      } finally {
        _isRestarting = false;
      }
    } catch (_) {
      // Never crash for a soft nudge
    }
  }
}
