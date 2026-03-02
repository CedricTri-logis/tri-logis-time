import 'package:flutter_test/flutter_test.dart';

/// Extracted stationary detection logic — mirrors the handler's behavior.
/// This class is ONLY for testing. The real logic lives in GPSTrackingHandler.
class StationaryDetector {
  bool isStationary = false;
  DateTime? _lowSpeedSince;
  static const stationaryDelay = Duration(minutes: 3);

  /// Call on every GPS position update. Returns the new isStationary state.
  bool update(double speed, DateTime now) {
    if (speed >= 0.5) {
      // Any movement → immediately active
      isStationary = false;
      _lowSpeedSince = null;
      return false;
    }

    // speed < 0.5 — track how long
    _lowSpeedSince ??= now;

    if (now.difference(_lowSpeedSince!) >= stationaryDelay) {
      isStationary = true;
    }

    return isStationary;
  }
}

void main() {
  group('StationaryDetector', () {
    late StationaryDetector detector;
    late DateTime t;

    setUp(() {
      detector = StationaryDetector();
      t = DateTime(2026, 3, 2, 8, 0, 0); // arbitrary start
    });

    test('starts as not stationary', () {
      expect(detector.isStationary, isFalse);
    });

    test('stays active when speed >= 0.5', () {
      detector.update(5.0, t);
      expect(detector.isStationary, isFalse);

      detector.update(0.5, t.add(const Duration(seconds: 10)));
      expect(detector.isStationary, isFalse);
    });

    test('does NOT become stationary before 3 minutes', () {
      // Feed low speed for 2 min 59 sec
      for (var i = 0; i < 18; i++) {
        detector.update(0.1, t.add(Duration(seconds: i * 10)));
      }
      // At 2:59
      detector.update(0.1, t.add(const Duration(minutes: 2, seconds: 59)));
      expect(detector.isStationary, isFalse);
    });

    test('becomes stationary after exactly 3 minutes of low speed', () {
      detector.update(0.1, t); // start
      detector.update(0.1, t.add(const Duration(minutes: 3)));
      expect(detector.isStationary, isTrue);
    });

    test('exits stationary IMMEDIATELY on one high-speed reading', () {
      // Become stationary
      detector.update(0.1, t);
      detector.update(0.1, t.add(const Duration(minutes: 3)));
      expect(detector.isStationary, isTrue);

      // One moving reading
      detector.update(0.6, t.add(const Duration(minutes: 3, seconds: 10)));
      expect(detector.isStationary, isFalse);
    });

    test('requires full 3 minutes again after reset', () {
      // Become stationary
      detector.update(0.1, t);
      detector.update(0.1, t.add(const Duration(minutes: 3)));
      expect(detector.isStationary, isTrue);

      // Movement resets
      detector.update(0.6, t.add(const Duration(minutes: 3, seconds: 10)));
      expect(detector.isStationary, isFalse);

      // 1 minute of low speed — not enough
      detector.update(0.1, t.add(const Duration(minutes: 3, seconds: 11)));
      detector.update(0.1, t.add(const Duration(minutes: 4, seconds: 11)));
      expect(detector.isStationary, isFalse);

      // 3 more minutes from reset point
      detector.update(0.1, t.add(const Duration(minutes: 6, seconds: 11)));
      expect(detector.isStationary, isTrue);
    });

    test('single speed blip resets the 3-minute timer', () {
      detector.update(0.1, t);
      detector.update(0.1, t.add(const Duration(minutes: 2)));
      expect(detector.isStationary, isFalse);

      // Blip at 2 min
      detector.update(0.8, t.add(const Duration(minutes: 2, seconds: 1)));
      expect(detector.isStationary, isFalse);

      // Low speed resumes — needs 3 full min from blip
      detector.update(0.1, t.add(const Duration(minutes: 2, seconds: 2)));
      detector.update(0.1, t.add(const Duration(minutes: 5, seconds: 1)));
      expect(detector.isStationary, isFalse);

      detector.update(0.1, t.add(const Duration(minutes: 5, seconds: 2)));
      expect(detector.isStationary, isTrue);
    });

    test('handles zero speed as stationary-capable', () {
      detector.update(0.0, t);
      detector.update(0.0, t.add(const Duration(minutes: 3)));
      expect(detector.isStationary, isTrue);
    });
  });
}
