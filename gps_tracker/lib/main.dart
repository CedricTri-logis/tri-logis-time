import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config/env_config.dart';
import 'features/tracking/services/background_tracking_service.dart';
import 'shared/services/local_database.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load environment variables
  await dotenv.load(fileName: '.env');

  // Initialize Supabase
  await Supabase.initialize(
    url: EnvConfig.supabaseUrl,
    anonKey: EnvConfig.supabaseAnonKey,
  );

  // Initialize local database
  await LocalDatabase().initialize();

  // Initialize background tracking service
  FlutterForegroundTask.initCommunicationPort();
  await BackgroundTrackingService.initialize();

  runApp(
    const ProviderScope(
      child: GpsTrackerApp(),
    ),
  );
}
