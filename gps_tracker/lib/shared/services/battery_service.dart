import 'package:battery_plus/battery_plus.dart';

/// Simple battery level reader. Fire-and-forget, never crashes.
class BatteryService {
  static final Battery _battery = Battery();
  static int? _lastLevel;

  /// Get current battery level (0-100). Returns null on failure.
  static Future<int?> getLevel() async {
    try {
      _lastLevel = await _battery.batteryLevel;
      return _lastLevel;
    } catch (_) {
      return _lastLevel;
    }
  }

  /// Get last known battery level without async call.
  static int? get lastKnownLevel => _lastLevel;
}
