import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Callback type for Realtime events.
typedef RealtimeCallback = void Function(Map<String, dynamic> newRecord);

/// Service managing Supabase Realtime subscriptions for:
/// - `active_device_sessions` changes (force-logout detection)
/// - `shifts` changes (server-side close detection)
///
/// Acts as an overlay on top of existing polling — not a replacement.
/// If WebSocket is unavailable, polling continues as fallback.
class RealtimeService {
  RealtimeChannel? _sessionChannel;
  RealtimeChannel? _shiftChannel;
  String? _subscribedEmployeeId;

  /// Called when the device session row is updated (e.g. device_id changed).
  RealtimeCallback? onSessionChanged;

  /// Called when a shift row is updated (e.g. server-side close).
  RealtimeCallback? onShiftChanged;

  /// Subscribe to Realtime channels for the given employee.
  void subscribe(String employeeId) {
    // Avoid duplicate subscriptions
    if (_subscribedEmployeeId == employeeId) return;

    // Clean up any existing subscriptions first
    unsubscribe();
    _subscribedEmployeeId = employeeId;

    final supabase = Supabase.instance.client;

    // Channel 1: Device session changes (force-logout detection)
    _sessionChannel = supabase
        .channel('device-session-$employeeId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'active_device_sessions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'employee_id',
            value: employeeId,
          ),
          callback: (payload) {
            debugPrint('RealtimeService: session change detected');
            onSessionChanged?.call(payload.newRecord);
          },
        )
        .subscribe((status, [error]) {
      debugPrint('RealtimeService: session channel status=$status'
          '${error != null ? " error=$error" : ""}');
    });

    // Channel 2: Shift changes (server-side close, admin cleanup, zombie cleanup)
    _shiftChannel = supabase
        .channel('shift-updates-$employeeId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'shifts',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'employee_id',
            value: employeeId,
          ),
          callback: (payload) {
            debugPrint('RealtimeService: shift change detected');
            onShiftChanged?.call(payload.newRecord);
          },
        )
        .subscribe((status, [error]) {
      debugPrint('RealtimeService: shift channel status=$status'
          '${error != null ? " error=$error" : ""}');
    });
  }

  /// Unsubscribe from all channels.
  void unsubscribe() {
    _sessionChannel?.unsubscribe();
    _shiftChannel?.unsubscribe();
    _sessionChannel = null;
    _shiftChannel = null;
    _subscribedEmployeeId = null;
  }
}

/// Provider for the [RealtimeService] singleton.
///
/// Auto-disposed when nothing watches it (i.e. user logs out and app.dart
/// stops calling ref.watch). Subscription is managed explicitly by app.dart
/// calling [RealtimeService.subscribe] — NOT via provider watch chains —
/// to avoid rebuild race conditions with other auth-dependent providers.
final realtimeServiceProvider = Provider.autoDispose<RealtimeService>((ref) {
  final service = RealtimeService();
  ref.onDispose(() => service.unsubscribe());
  return service;
});
