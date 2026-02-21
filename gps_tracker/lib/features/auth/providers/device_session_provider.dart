import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/supabase_provider.dart';
import '../../../shared/services/realtime_service.dart';
import '../../shifts/providers/shift_provider.dart';
import '../services/device_id_service.dart';
import '../services/device_session_service.dart';

/// Status of the device session check.
enum DeviceSessionStatus { active, checking, forcedOut }

/// Monitors whether this device is still the active session.
///
/// Uses Supabase Realtime for near-instant detection (~1-2s) when online,
/// with 60-second polling as fallback for offline/reconnection scenarios.
class DeviceSessionNotifier extends StateNotifier<DeviceSessionStatus>
    with WidgetsBindingObserver {
  final Ref _ref;
  Timer? _timer;
  String? _currentDeviceId;

  /// Static flag checked by sign-in screen to show explanation.
  static bool wasForceLoggedOut = false;

  DeviceSessionNotifier(this._ref) : super(DeviceSessionStatus.active) {
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    // Cache the device ID for Realtime comparison
    _currentDeviceId = await DeviceIdService.getDeviceId();
    _setupRealtime();
    _startPolling();
  }

  /// Set up Realtime listener for instant force-logout detection.
  void _setupRealtime() {
    final realtimeService = _ref.read(realtimeServiceProvider);
    realtimeService.onSessionChanged = (newRecord) {
      if (state == DeviceSessionStatus.forcedOut) return;

      final newDeviceId = newRecord['device_id'] as String?;
      if (newDeviceId != null &&
          _currentDeviceId != null &&
          newDeviceId != _currentDeviceId) {
        // Another device took the session — force logout
        debugPrint(
            'DeviceSessionNotifier: Realtime detected session takeover');
        _handleForceLogout();
      }
    };
  }

  void _startPolling() {
    // Initial check after a short delay (let auth settle)
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted) _checkSession();
    });

    _timer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) _checkSession();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _checkSession();
    }
  }

  Future<void> _checkSession() async {
    if (state == DeviceSessionStatus.forcedOut) return;

    try {
      final client = _ref.read(supabaseClientProvider);
      // Don't check if not authenticated
      if (client.auth.currentUser == null) return;

      final service = DeviceSessionService(client);
      final isActive = await service.isDeviceSessionActive();

      if (!isActive && mounted) {
        await _handleForceLogout();
      }
    } catch (e) {
      // Fail-open: do nothing on error
      debugPrint('DeviceSessionNotifier: check error (ignoring): $e');
    }
  }

  Future<void> _handleForceLogout() async {
    state = DeviceSessionStatus.forcedOut;
    wasForceLoggedOut = true;

    // Clock out active shift (which auto-closes cleaning + maintenance)
    try {
      final shiftState = _ref.read(shiftProvider);
      if (shiftState.activeShift != null) {
        await _ref.read(shiftProvider.notifier).clockOut();
      }
    } catch (e) {
      debugPrint('DeviceSessionNotifier: clock-out during force logout failed: $e');
    }

    // Sign out — navigation happens via authStateChangesProvider
    try {
      final authService = _ref.read(authServiceProvider);
      await authService.signOut();
    } catch (e) {
      debugPrint('DeviceSessionNotifier: sign-out during force logout failed: $e');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// Provider for device session monitoring.
/// Should be watched in the authenticated branch of app.dart.
final deviceSessionProvider =
    StateNotifierProvider<DeviceSessionNotifier, DeviceSessionStatus>((ref) {
  // Rebuild when auth state changes
  ref.watch(authStateChangesProvider);
  return DeviceSessionNotifier(ref);
});
