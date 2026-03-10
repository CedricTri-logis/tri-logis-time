import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:gps_tracker/main.dart' show isFirebaseInitialized;

import '../models/diagnostic_event.dart';
import '../services/diagnostic_logger.dart';

/// Handles FCM token lifecycle and silent push reception.
///
/// All methods are no-op safe: they catch errors internally and never throw.
/// Removing this file + its 3 call sites fully disables FCM.
class FcmService {
  static final FcmService _instance = FcmService._internal();
  factory FcmService() => _instance;
  FcmService._internal();

  DiagnosticLogger? get _logger =>
      DiagnosticLogger.isInitialized ? DiagnosticLogger.instance : null;

  String? _lastRegisteredToken;
  bool _permissionRequested = false;
  bool _tokenRefreshListening = false;
  bool _foregroundListenerActive = false;

  /// Set up the foreground message listener.
  /// Call once after Firebase.initializeApp(). Safe to call multiple times.
  ///
  /// Logs a diagnostic event when a "wake" message arrives while the app is
  /// in the foreground. No tracking restart needed — if the app is foregrounded,
  /// tracking should already be running.
  void initialize() {
    if (_foregroundListenerActive) return;
    if (!isFirebaseInitialized) return;
    _foregroundListenerActive = true;

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final type = message.data['type'];
      if (type == 'wake') {
        _logger?.lifecycle(
          Severity.info,
          'FCM wake received in foreground (no-op)',
          metadata: {
            'timestamp': message.data['timestamp'] ?? '',
          },
        );
        debugPrint('[FCM] Wake message received in foreground — no action needed');
      }
    });
  }

  /// Check if FCM is enabled for this employee via app_config + per-employee opt-in.
  /// Returns false if anything fails (safe default = disabled).
  Future<bool> _isEnabled() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return false;

      // Check global kill switch
      final configResult = await Supabase.instance.client
          .from('app_config')
          .select('value')
          .eq('key', 'fcm_enabled')
          .maybeSingle();

      final globalEnabled = configResult?['value'] == 'true';

      if (globalEnabled) return true;

      // Global is off — check per-employee opt-in for gradual rollout
      final profileResult = await Supabase.instance.client
          .from('employee_profiles')
          .select('fcm_opt_in')
          .eq('id', user.id)
          .maybeSingle();

      return profileResult?['fcm_opt_in'] == true;
    } catch (e) {
      debugPrint('[FCM] Kill switch check failed (defaulting to disabled): $e');
      return false;
    }
  }

  /// Register the current FCM token to employee_profiles.
  /// Call after successful authentication. No-op if FCM disabled.
  Future<void> registerToken() async {
    if (!isFirebaseInitialized) return;
    try {
      if (!await _isEnabled()) return;

      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;

      // Request permission once per session (cached)
      if (!_permissionRequested) {
        await _requestPermission();
        _permissionRequested = true;
      }

      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;

      // Skip if same token was already registered this session
      if (token == _lastRegisteredToken) return;

      await Supabase.instance.client
          .from('employee_profiles')
          .update({'fcm_token': token})
          .eq('id', user.id);

      _lastRegisteredToken = token;

      _logger?.lifecycle(
        Severity.info,
        'FCM token registered',
        metadata: {'token_prefix': token.substring(0, 12)},
      );
    } catch (e) {
      _logger?.lifecycle(
        Severity.warn,
        'FCM token registration failed',
        metadata: {'error': e.toString()},
      );
    }
  }

  /// Listen for token refreshes and re-register. Safe to call multiple times.
  /// Catches FirebaseException if Firebase isn't initialized yet (deferred init).
  void listenForTokenRefresh() {
    if (_tokenRefreshListening) return;
    if (!isFirebaseInitialized) return;
    _tokenRefreshListening = true;

    try {
      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
        _lastRegisteredToken = null; // Force re-registration
        await registerToken();
      });
    } catch (e) {
      _tokenRefreshListening = false; // Allow retry after Firebase initializes
      debugPrint('[FCM] listenForTokenRefresh failed (Firebase not ready?): $e');
    }
  }

  /// Clear FCM token from server on sign-out.
  Future<void> clearToken() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;

      await Supabase.instance.client
          .from('employee_profiles')
          .update({'fcm_token': null})
          .eq('id', user.id);

      _lastRegisteredToken = null;
      _permissionRequested = false;
    } catch (e) {
      debugPrint('[FCM] Failed to clear token: $e');
    }
  }

  /// Request push notification permissions.
  /// On Android 13+, POST_NOTIFICATIONS is already in manifest.
  /// On iOS, provisional = silent delivery without user prompt.
  Future<void> _requestPermission() async {
    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: false,
        badge: false,
        sound: false,
        provisional: true,
      );
    } catch (e) {
      debugPrint('[FCM] Permission request failed: $e');
    }
  }
}
