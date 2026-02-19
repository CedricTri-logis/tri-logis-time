import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/supabase_provider.dart';
import '../../shifts/providers/shift_provider.dart';
import '../services/device_session_service.dart';

/// Status of the device session check.
enum DeviceSessionStatus { active, checking, forcedOut }

/// Monitors whether this device is still the active session.
///
/// Polls every 60 seconds and on app resume. When another device
/// takes over, it auto-clocks out and signs out.
class DeviceSessionNotifier extends StateNotifier<DeviceSessionStatus>
    with WidgetsBindingObserver {
  final Ref _ref;
  Timer? _timer;

  /// Static flag checked by sign-in screen to show explanation.
  static bool wasForceLoggedOut = false;

  DeviceSessionNotifier(this._ref) : super(DeviceSessionStatus.active) {
    WidgetsBinding.instance.addObserver(this);
    _startPolling();
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
