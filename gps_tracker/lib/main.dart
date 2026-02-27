import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config/env_config.dart';
import 'features/tracking/services/background_tracking_service.dart';
import 'features/tracking/services/android_battery_health_service.dart';
import 'features/tracking/services/tracking_watchdog_service.dart';
import 'shared/models/diagnostic_event.dart';
import 'shared/providers/diagnostic_provider.dart';
import 'shared/services/diagnostic_logger.dart';
import 'shared/services/local_database.dart';
import 'shared/services/notification_service.dart';
import 'shared/services/shift_activity_service.dart';

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
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
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
      } catch (e) {
        debugPrint('[Main] DiagnosticLogger init failed (non-critical): $e');
      }
    } catch (e) {
      initError = 'Failed to initialize services: $e';
    }
  }

  if (initError != null) {
    runApp(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.red.shade50,
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline,
                        size: 64, color: Colors.red),
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
                      initError,
                      style: const TextStyle(color: Colors.red, fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return;
  }

  runApp(
    const ProviderScope(
      child: GpsTrackerApp(),
    ),
  );
}

Future<void> _initializeTracking() async {
  FlutterForegroundTask.initCommunicationPort();
  await BackgroundTrackingService.initialize();
  await AndroidBatteryHealthService.saveBatteryOptimizationSnapshot();
  await TrackingWatchdogService.initialize();
}
