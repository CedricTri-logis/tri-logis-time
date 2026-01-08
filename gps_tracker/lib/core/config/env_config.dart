import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Environment configuration loaded from .env file
class EnvConfig {
  EnvConfig._();

  /// Supabase project URL
  static String get supabaseUrl {
    final url = dotenv.env['SUPABASE_URL'];
    if (url == null || url.isEmpty) {
      throw Exception('SUPABASE_URL not found in .env file');
    }
    return url;
  }

  /// Supabase anonymous key for public access
  static String get supabaseAnonKey {
    final key = dotenv.env['SUPABASE_ANON_KEY'];
    if (key == null || key.isEmpty) {
      throw Exception('SUPABASE_ANON_KEY not found in .env file');
    }
    return key;
  }

  /// Whether running in debug mode
  static bool get isDebug {
    bool isDebug = false;
    assert(() {
      isDebug = true;
      return true;
    }());
    return isDebug;
  }
}
