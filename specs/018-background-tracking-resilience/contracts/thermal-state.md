# Contract: Cross-Platform Thermal State Monitoring

## Overview

Cross-platform service monitoring device thermal state to proactively reduce GPS tracking frequency when the device overheats, preventing the OS from killing the app as thermal mitigation.

## Method Channels

### iOS: `gps_tracker/thermal` (in BackgroundTaskPlugin)

#### `getThermalState`

Get current iOS thermal state.

- **Arguments**: None
- **Returns**: `int` mapped from `ProcessInfo.ThermalState`:
  - `0` = `.nominal` (normal)
  - `1` = `.fair` (slightly elevated)
  - `2` = `.serious` (high, system may throttle)
  - `3` = `.critical` (system will aggressively throttle)
- **Implementation**: `ProcessInfo.processInfo.thermalState.rawValue`

#### Thermal state change stream

Uses `NotificationCenter` observer on `ProcessInfo.thermalStateDidChangeNotification` to push changes to Flutter via method channel callback `onThermalStateChanged(int state)`.

### Android: `gps_tracker/thermal` (in MainActivity)

#### `getThermalStatus`

Get current Android thermal status.

- **Arguments**: None
- **Returns**: `int` from `PowerManager.getCurrentThermalStatus()`:
  - `0` = `THERMAL_STATUS_NONE`
  - `1` = `THERMAL_STATUS_LIGHT`
  - `2` = `THERMAL_STATUS_MODERATE`
  - `3` = `THERMAL_STATUS_SEVERE`
  - `4` = `THERMAL_STATUS_CRITICAL`
  - `5` = `THERMAL_STATUS_EMERGENCY`
  - `6` = `THERMAL_STATUS_SHUTDOWN`
- **API level**: Android 10+ (API 29). Returns `0` on older devices.

#### Thermal status change stream

Uses `PowerManager.addThermalStatusListener` to push changes via `EventChannel` (`gps_tracker/thermal/stream`).

## Dart Service: `ThermalStateService`

### Enum

```dart
enum ThermalLevel {
  normal,    // No adaptation needed
  elevated,  // Moderate thermal pressure — reduce GPS frequency
  critical,  // Severe thermal pressure — minimum GPS frequency
}
```

### Platform Mapping

| ThermalLevel | iOS States | Android Statuses |
|-------------|------------|-----------------|
| `normal` | `.nominal`, `.fair` | `NONE(0)`, `LIGHT(1)` |
| `elevated` | `.serious` | `MODERATE(2)`, `SEVERE(3)` |
| `critical` | `.critical` | `CRITICAL(4)`, `EMERGENCY(5)`, `SHUTDOWN(6)` |

### API

```dart
class ThermalStateService {
  static const _methodChannel = MethodChannel('gps_tracker/thermal');
  static const _eventChannel = EventChannel('gps_tracker/thermal/stream');

  /// Get current thermal level (one-shot).
  static Future<ThermalLevel> getCurrentLevel() async { ... }

  /// Stream of thermal level changes.
  /// On unsupported platforms/versions, emits a single `normal` and completes.
  static Stream<ThermalLevel> get levelStream { ... }
}
```

### GPS Adaptation Config

When thermal level changes, `TrackingNotifier` sends `updateConfig` to the background handler:

| ThermalLevel | `activeIntervalSeconds` | `stationaryIntervalSeconds` | GPS Accuracy |
|-------------|------------------------|----------------------------|-------------|
| `normal` | 60 (default) | 300 (default) | `LocationAccuracy.high` |
| `elevated` | 120 | 600 | `LocationAccuracy.medium` |
| `critical` | 300 | 900 | `LocationAccuracy.low` |

The `updateConfig` command already exists in `GPSTrackingHandler` — no new background handler protocol needed.

### Integration Flow

```
App start (shift active)
  ↓
ThermalStateService.levelStream.listen((level) {
  if (level != _currentThermalLevel) {
    _currentThermalLevel = level;
    _sendThermalConfig(level);  // updateConfig to background handler
  }
})
  ↓
Background handler receives updateConfig
  → Updates _activeIntervalSeconds, _stationaryIntervalSeconds
  → GPS accuracy change applied on next position request
  ↓
Shift end
  → Cancel thermal stream subscription
  → Reset to normal config
```

### Error Handling

- Platform method channel failures: Return `ThermalLevel.normal` (fail-open, never degrades tracking due to thermal API errors)
- Unsupported OS versions: Return `ThermalLevel.normal`
- Android < API 29: No thermal API available, always `normal`
- iOS: Thermal API available on all supported versions (iOS 14+)
