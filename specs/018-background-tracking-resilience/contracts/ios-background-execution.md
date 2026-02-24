# Contract: iOS Background Execution Plugin

## Method Channel: `gps_tracker/background_execution`

### Overview

Native Swift plugin exposing `CLBackgroundActivitySession` (iOS 17+) and `UIApplication.beginBackgroundTask` to Flutter via MethodChannel. Registered in `AppDelegate.swift` alongside existing `SignificantLocationPlugin`.

### Methods (Flutter → Native)

#### `startBackgroundSession`

Start a `CLBackgroundActivitySession`. Shows the blue location indicator and tells iOS the app has legitimate continuous background location needs.

- **Arguments**: None
- **Returns**: `bool` (always `true` on success)
- **Behavior**:
  - iOS 17+: Creates and stores a strong reference to `CLBackgroundActivitySession()`
  - iOS < 17: No-op, returns `true`
  - If session already active: No-op, returns `true`
- **When to call**: At shift start (clock-in), and when app is relaunched by SLC

#### `stopBackgroundSession`

Invalidate the `CLBackgroundActivitySession`.

- **Arguments**: None
- **Returns**: `bool` (always `true`)
- **Behavior**:
  - iOS 17+: Calls `session.invalidate()`, nils the reference
  - iOS < 17: No-op
- **When to call**: At shift end (clock-out)

#### `isBackgroundSessionActive`

Check if a background session is currently active.

- **Arguments**: None
- **Returns**: `bool`

#### `beginBackgroundTask`

Request additional execution time from iOS before suspension.

- **Arguments**: `Map<String, dynamic>` with optional key `name` (`String`, default: `"gps_tracker_background_task"`)
- **Returns**: `bool` (always `true`)
- **Behavior**:
  - Calls `UIApplication.shared.beginBackgroundTask(withName:expirationHandler:)`
  - Stores the task identifier
  - If a task is already active: No-op
  - Expiration handler: calls `endBackgroundTask` and sends `onBackgroundTaskExpired` callback
- **When to call**: When app lifecycle changes to `AppLifecycleState.paused` during active shift

#### `endBackgroundTask`

End the current background task.

- **Arguments**: None
- **Returns**: `bool` (always `true`)
- **Behavior**:
  - Calls `UIApplication.shared.endBackgroundTask(taskID)`
  - Resets task identifier to `.invalid`
  - If no active task: No-op
- **When to call**: When app returns to foreground, or when expiration handler fires

### Callbacks (Native → Flutter)

#### `onBackgroundTaskExpired`

Fired when iOS background task time expires (~30s after backgrounding).

- **Arguments**: None
- **Handling in Dart**: Log the event. No action needed — the native side already ended the task.

### Dart Service: `BackgroundExecutionService`

Static utility class wrapping the method channel. All methods are no-ops on Android (checked via `Platform.isIOS`).

```dart
class BackgroundExecutionService {
  static const _channel = MethodChannel('gps_tracker/background_execution');

  static Future<void> startBackgroundSession() async { ... }
  static Future<void> stopBackgroundSession() async { ... }
  static Future<bool> isBackgroundSessionActive() async { ... }
  static Future<void> beginBackgroundTask({String? name}) async { ... }
  static Future<void> endBackgroundTask() async { ... }
}
```

### Integration Points

| Caller | Method | Trigger |
|--------|--------|---------|
| `tracking_provider.dart` → `startTracking()` | `startBackgroundSession()` | Shift start |
| `tracking_provider.dart` → `stopTracking()` | `stopBackgroundSession()` | Shift end |
| `tracking_provider.dart` → `_onWokenByLocationChange()` | `startBackgroundSession()` | SLC relaunch |
| `background_tracking_service.dart` → lifecycle listener | `beginBackgroundTask()` | App enters background |
| `background_tracking_service.dart` → lifecycle listener | `endBackgroundTask()` | App returns to foreground |

### Native Implementation File

`gps_tracker/ios/Runner/BackgroundTaskPlugin.swift`

```swift
class BackgroundTaskPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel?
    private var backgroundSession: CLBackgroundActivitySession?  // iOS 17+
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    static func register(with registrar: FlutterPluginRegistrar) { ... }
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) { ... }
}
```

### Error Handling

All method channel calls are wrapped in try-catch on the Dart side. Failures are logged via `debugPrint` and silently swallowed — these are enhancement APIs, not critical path. Tracking continues regardless.
