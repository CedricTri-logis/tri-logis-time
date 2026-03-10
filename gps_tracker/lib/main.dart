import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/config/env_config.dart';
import 'features/tracking/services/background_tracking_service.dart';
import 'features/tracking/services/android_battery_health_service.dart';
import 'features/tracking/services/tracking_watchdog_service.dart';
import 'shared/models/diagnostic_event.dart';
import 'shared/providers/diagnostic_provider.dart';
import 'shared/services/diagnostic_logger.dart';
import 'shared/services/diagnostic_native_service.dart';
import 'shared/services/local_database.dart';
import 'shared/services/fcm_service.dart';
import 'shared/services/notification_service.dart';
import 'shared/services/session_backup_service.dart';
import 'shared/services/shift_activity_service.dart';

/// Top-level handler for FCM background/terminated messages.
/// Firebase requires this to be a top-level function (not a class method).
///
/// Runs in a SEPARATE ISOLATE — cannot access Riverpod providers or app state.
/// CAN access SharedPreferences and FlutterForegroundTask platform channels
/// (firebase_messaging sets up a background Flutter engine).
///
/// On iOS: receiving this silent push relaunches the full app (main() re-runs),
/// so the existing tracking recovery in _refreshServiceState() handles restart.
/// On Android: we additionally restart the foreground service here as a belt-
/// and-suspenders complement to the rescue alarm chain.
///
/// We write a breadcrumb for debugging + to satisfy Apple's "useful work"
/// requirement for silent push budget.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // 1. Write breadcrumb (existing behavior)
  try {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = DateTime.now().toIso8601String();
    final breadcrumbs = prefs.getStringList('fcm_wake_breadcrumbs') ?? [];
    breadcrumbs.add('$timestamp|fcm_wake|${message.data['type'] ?? 'unknown'}');
    // Keep last 20 breadcrumbs only
    if (breadcrumbs.length > 20) {
      breadcrumbs.removeRange(0, breadcrumbs.length - 20);
    }
    await prefs.setStringList('fcm_wake_breadcrumbs', breadcrumbs);
  } catch (_) {
    // Silently fail — this is a best-effort breadcrumb
  }

  // 2. If there's an active shift, ensure the foreground tracking service is alive.
  //    Uses FlutterForegroundTask shared prefs key (same as TrackingRescueReceiver.kt).
  //    If the service was killed, launch the app to trigger recovery via
  //    _refreshServiceState(). If still running, this is a no-op.
  try {
    final shiftId = await FlutterForegroundTask.getData<String>(key: 'shift_id');
    if (shiftId != null && shiftId.isNotEmpty) {
      final isRunning = await FlutterForegroundTask.isRunningService;
      if (!isRunning) {
        // Service was killed — launch app to trigger existing recovery path
        FlutterForegroundTask.launchApp();
        debugPrint('[FCM] Active shift $shiftId, service dead — launched app for recovery');
      } else {
        debugPrint('[FCM] Active shift $shiftId, service already running — no action needed');
      }
    }
  } catch (_) {
    // Best-effort — don't crash the background handler
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Show loading screen immediately with visible styling
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF1976D2), // Blue background
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.location_on,
                size: 64,
                color: Colors.white,
              ),
              const SizedBox(height: 24),
              const Text(
                'Tri-Logis Time',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 32),
              const CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
              const SizedBox(height: 16),
              const Text(
                'Chargement...',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  String? initError;

  try {
    // Load environment variables first (required for Supabase config)
    await dotenv.load(fileName: '.env');
  } catch (e) {
    initError = 'Failed to load .env: $e';
  }

  if (initError == null) {
    try {
      // Initialize Supabase (required before other services)
      await Supabase.initialize(
        url: EnvConfig.supabaseUrl,
        anonKey: EnvConfig.supabaseAnonKey,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: true),
      );
    } catch (e) {
      initError = 'Failed to initialize Supabase: $e';
    }
  }

  if (initError == null) {
    try {
      // Initialize critical services in parallel
      await Future.wait([
        LocalDatabase().initialize(),
        _initializeTracking(),
        ShiftActivityService.instance.initialize(),
        SessionBackupService.initialize(),
      ]);
      // Initialize notifications separately (non-critical — don't block app startup)
      try {
        await NotificationService().initialize();
      } catch (e) {
        debugPrint('[Main] Notification init failed (non-critical): $e');
      }

      // Initialize diagnostic logger (non-critical — don't block app startup)
      try {
        final stopwatch = Stopwatch()..start();
        final userId = Supabase.instance.client.auth.currentUser?.id;
        await initializeDiagnosticLogger(employeeId: userId);
        stopwatch.stop();
        DiagnosticLogger.instance
            .lifecycle(Severity.info, 'App started', metadata: {
          'init_duration_ms': stopwatch.elapsedMilliseconds,
        });

        // Start native diagnostic event listener (MetricKit, GNSS, doze, etc.)
        DiagnosticNativeService.instance.initialize();

        // Listen for auth state changes so _employeeId gets set once
        // the session is restored (often null at cold start).
        Supabase.instance.client.auth.onAuthStateChange.listen((data) {
          if (DiagnosticLogger.isInitialized) {
            DiagnosticLogger.instance
                .setEmployeeId(data.session?.user.id);
          }
        });
      } catch (e) {
        debugPrint('[Main] DiagnosticLogger init failed (non-critical): $e');
      }
    } catch (e) {
      initError = 'Failed to initialize services: $e';
    }
  }

  // Firebase init — deferred to reduce CPU pressure on background launches.
  // On iOS, SLC background launches get ~10s of CPU budget. Running Firebase
  // init concurrently with Supabase + SQLCipher + tracking can exceed that
  // budget, causing iOS to kill the app (observed: 3 kills in 40s on build 102).
  // Solution: wait 3s for lifecycle state to settle, then init Firebase only
  // if we're in the foreground. Background launches defer until next foreground.
  if (initError == null) {
    _scheduleFirebaseInit();
  }

  if (initError != null) {
    runApp(_ErrorApp(error: initError));
    return;
  }

  runApp(
    const ProviderScope(
      child: GpsTrackerApp(),
    ),
  );
}

/// Error screen with a retry button so the user isn't permanently stuck.
class _ErrorApp extends StatelessWidget {
  final String error;
  const _ErrorApp({required this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.red.shade50,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 64, color: Colors.red),
                  const SizedBox(height: 16),
                  const Text(
                    'Erreur de démarrage',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.red,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    error,
                    style: const TextStyle(color: Colors.red, fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  ElevatedButton.icon(
                    onPressed: () => main(),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Réessayer'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _initializeTracking() async {
  FlutterForegroundTask.initCommunicationPort();
  await BackgroundTrackingService.initialize();
  await AndroidBatteryHealthService.saveBatteryOptimizationSnapshot();
  await TrackingWatchdogService.initialize();
}

/// Whether Firebase has been initialized this session.
/// Guards against double-init from both the schedule timer and the
/// foreground deferral observer firing.
bool _firebaseInitialized = false;

/// Whether Firebase has been initialized. Used by FcmService to avoid
/// calling FirebaseMessaging.instance before init completes.
bool get isFirebaseInitialized => _firebaseInitialized;

/// Schedule Firebase init based on whether the app is in foreground or background.
/// Waits 3 seconds for the lifecycle state to settle (on a cold start,
/// `lifecycleState` is null until the first frame renders).
void _scheduleFirebaseInit() {
  Future<void>.delayed(const Duration(seconds: 3), () {
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == AppLifecycleState.resumed) {
      // App is in foreground — safe to init Firebase now
      _initializeFirebase();
    } else {
      // Background launch (SLC / FCM) — defer Firebase to save CPU budget.
      // The FCM background handler still works: it's registered at the native
      // plugin level, independent of Dart-side Firebase.initializeApp().
      debugPrint('[Main] Background launch detected (lifecycle=$state) — deferring Firebase');
      WidgetsBinding.instance.addObserver(_FirebaseDeferralObserver());
    }
  });
}

/// Lifecycle observer that initializes Firebase when the app comes to foreground.
class _FirebaseDeferralObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_firebaseInitialized) {
      WidgetsBinding.instance.removeObserver(this);
      _initializeFirebase();
    }
  }
}

Future<void> _initializeFirebase() async {
  if (_firebaseInitialized) return;
  _firebaseInitialized = true;
  try {
    await Firebase.initializeApp();

    // --- Crashlytics setup ---
    // Pass all uncaught Flutter framework errors to Crashlytics
    FlutterError.onError = (details) {
      FirebaseCrashlytics.instance.recordFlutterFatalError(details);
      if (DiagnosticLogger.isInitialized) {
        DiagnosticLogger.instance.crash(
          Severity.critical,
          'Flutter error: ${details.exceptionAsString()}',
          metadata: {
            'stack': _safeTake(details.stack?.toString(), 500),
            'library': details.library,
          },
        );
      }
    };

    // Pass uncaught async errors to Crashlytics
    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      if (DiagnosticLogger.isInitialized) {
        DiagnosticLogger.instance.crash(
          Severity.critical,
          'Platform error: $error',
          metadata: {'stack': _safeTake(stack.toString(), 500)},
        );
      }
      return true;
    };

    // Set user identifier for Crashlytics (if logged in)
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId != null) {
      FirebaseCrashlytics.instance.setUserIdentifier(userId);
    }

    // Update Crashlytics user on auth changes
    Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      final uid = data.session?.user.id;
      FirebaseCrashlytics.instance.setUserIdentifier(uid ?? '');
    });

    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    FcmService().initialize();

    // Register FCM token now that Firebase is ready.
    // The initial attempt in app.dart fires before Firebase init (deferred 3s)
    // and always fails. This retry ensures the token gets registered.
    FcmService().registerToken();
    FcmService().listenForTokenRefresh();

    debugPrint('[Main] Firebase + Crashlytics initialized successfully');
  } catch (e) {
    _firebaseInitialized = false; // Allow retry on next foreground
    debugPrint('[Main] Firebase init failed (non-critical): $e');
  }
}

/// Safely truncate a string to [n] characters.
String? _safeTake(String? s, int n) =>
    s == null ? null : (s.length <= n ? s : s.substring(0, n));
