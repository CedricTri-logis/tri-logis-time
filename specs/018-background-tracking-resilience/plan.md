# 018 - Background Tracking Resilience — Implementation Plan

## Phase 1: iOS Critical Fixes (Highest Impact)

### Task 1.1: Deferred SignificantLocationChanges Activation
**Priority**: P0 — Eliminates the iOS 16.4+ dual-CLLocationManager conflict
**Estimated complexity**: Medium
**Dependencies**: None

#### Current behavior
In `tracking_provider.dart` → `startTracking()`, on `TrackingSuccess`:
```dart
SignificantLocationService.onWokenByLocationChange = _onWokenByLocationChange;
SignificantLocationService.startMonitoring();
```
This creates a 2nd `CLLocationManager` immediately alongside geolocator's, triggering iOS 16.4+ suspension.

#### Changes

**A) `gps_tracking_handler.dart`** — Add a new message type when the GPS stream dies:
- In `_checkStreamHealth()` (or `_recoverPositionStream`), when detecting the stream is dead (90s threshold), send a message to main isolate: `{'type': 'stream_died'}`.
- When stream recovery succeeds, send: `{'type': 'stream_alive'}`.

**B) `tracking_provider.dart`** — React to stream lifecycle:
- Remove `SignificantLocationService.startMonitoring()` from `startTracking()` success path.
- Add handler for `stream_died` → call `SignificantLocationService.startMonitoring()`.
- Add handler for `stream_alive` → call `SignificantLocationService.stopMonitoring()`.
- Keep `_onWokenByLocationChange` callback registration at tracking start (it's just setting a Dart callback, no native call).
- On `stopTracking()`, still call `SignificantLocationService.stopMonitoring()` as safety cleanup.

**C) `significant_location_service.dart`** — No changes needed (start/stop API is already correct).

#### Validation
- Clock in on iOS real device. Verify only 1 CLLocationManager active (check Xcode debug navigator → Energy tab).
- Kill the app. Verify SignificantLocationChanges relaunches it on ~500m movement.
- Simulate stream death (airplane mode briefly). Verify SignificantLocationChanges activates as fallback.

---

### Task 1.2: CLBackgroundActivitySession (iOS 17+)
**Priority**: P0 — Gives the app preferential OS treatment for background execution
**Estimated complexity**: Low
**Dependencies**: None

#### Changes

**A) `SignificantLocationPlugin.swift`** — Add session management:
```swift
private var backgroundActivitySession: Any? // CLBackgroundActivitySession (iOS 17+)

private func startBackgroundActivitySession() {
    if #available(iOS 17.0, *) {
        backgroundActivitySession = CLBackgroundActivitySession()
    }
}

private func stopBackgroundActivitySession() {
    if #available(iOS 17.0, *) {
        (backgroundActivitySession as? CLBackgroundActivitySession)?.invalidate()
        backgroundActivitySession = nil
    }
}
```
Add method channel handlers: `startBackgroundActivitySession` and `stopBackgroundActivitySession`.

**B) `significant_location_service.dart`** — Add Dart-side methods:
```dart
static Future<void> startBackgroundActivitySession() async {
    if (!Platform.isIOS) return;
    await _channel.invokeMethod<bool>('startBackgroundActivitySession');
}
static Future<void> stopBackgroundActivitySession() async {
    if (!Platform.isIOS) return;
    await _channel.invokeMethod<bool>('stopBackgroundActivitySession');
}
```

**C) `tracking_provider.dart`** — Call at tracking lifecycle:
- `startTracking()` success → `SignificantLocationService.startBackgroundActivitySession()`
- `stopTracking()` → `SignificantLocationService.stopBackgroundActivitySession()`

#### Validation
- Run on iOS 17+ device. Verify `CLBackgroundActivitySession` is created (Xcode console log).
- Run on iOS 16 device. Verify no crash (graceful fallback).
- Monitor tracking survival time — should exceed previous 5-6 minute death.

---

### Task 1.3: beginBackgroundTask Protection
**Priority**: P1 — Additional ~30s buffer during background transition
**Estimated complexity**: Low
**Dependencies**: None

#### Changes

**A) `ios/Runner/BackgroundTaskPlugin.swift`** — New native plugin:
```swift
class BackgroundTaskPlugin: NSObject, FlutterPlugin {
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    static func register(with registrar: FlutterPluginRegistrar) { ... }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "beginBackgroundTask":
            beginTask()
            result(true)
        case "endBackgroundTask":
            endTask()
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func beginTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endTask()
        }
    }

    private func endTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
```

**B) `AppDelegate.swift`** — Register the plugin:
```swift
BackgroundTaskPlugin.register(with: self.registrar(forPlugin: "BackgroundTaskPlugin")!)
```

**C) `background_tracking_service.dart`** — Add lifecycle method:
```dart
static const _bgTaskChannel = MethodChannel('gps_tracker/background_task');

static Future<void> requestBackgroundTime() async {
    if (!Platform.isIOS) return;
    await _bgTaskChannel.invokeMethod<bool>('beginBackgroundTask');
}
static Future<void> releaseBackgroundTime() async {
    if (!Platform.isIOS) return;
    await _bgTaskChannel.invokeMethod<bool>('endBackgroundTask');
}
```

**D) `tracking_provider.dart`** — Hook into app lifecycle:
- Add `WidgetsBindingObserver` mixin (or use existing lifecycle listener).
- On `AppLifecycleState.paused` (app goes to background) + active shift → call `requestBackgroundTime()`.
- On `AppLifecycleState.resumed` → call `releaseBackgroundTime()`.

#### Validation
- Background the app during tracking. Verify `beginBackgroundTask` is called (Xcode console).
- Verify expiration handler fires cleanly after ~30s without crash.

---

## Phase 2: Android Hardening

### Task 2.1: OEM-Specific Battery Optimization Guidance
**Priority**: P0 — #1 cause of Android GPS tracking failure
**Estimated complexity**: Medium-High
**Dependencies**: None

#### Changes

**A) `device_info_service.dart`** — New service:
```dart
class DeviceInfoService {
    static const _channel = MethodChannel('gps_tracker/device_info');

    static Future<String> getManufacturer() async {
        if (!Platform.isAndroid) return 'unknown';
        return await _channel.invokeMethod<String>('getManufacturer') ?? 'unknown';
    }
}
```

**B) Android native method channel** — In `MainActivity.kt`:
```kotlin
MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gps_tracker/device_info")
    .setMethodCallHandler { call, result ->
        when (call.method) {
            "getManufacturer" -> result.success(Build.MANUFACTURER.lowercase())
            else -> result.notImplemented()
        }
    }
```

**C) `oem_battery_guide_dialog.dart`** — New widget:
A dialog that shows manufacturer-specific instructions in French. Structure:
```dart
class OemBatteryGuideDialog extends StatelessWidget {
    final String manufacturer;
    // Returns the appropriate instructions + deep link intent for:
    // samsung, xiaomi, huawei, oneplus, oppo, vivo, other
}
```

Each manufacturer section includes:
- Step-by-step text instructions (in French)
- A "Ouvrir les paramètres" button that launches the OEM-specific settings intent via `url_launcher` or a method channel
- A "C'est fait" button that persists `oem_setup_completed` in SharedPreferences

Known OEM settings intents:
| OEM | Intent |
|---|---|
| Samsung | `com.samsung.android.lool.ACTION_BATTERY_USAGE_BATTERY_OPTIMIZATION` |
| Xiaomi | `com.miui.securitycenter` / `AutoStartManagementActivity` |
| Huawei | `com.huawei.systemmanager` / `StartupNormalAppListActivity` |
| OnePlus/Oppo | `com.coloros.safecenter` / `StartupAppListActivity` |

Wrap intent launches in try-catch — OEM settings intents are undocumented and may change between OS versions. Fall back to generic app settings on failure.

**D) `tracking_provider.dart`** — Trigger the dialog:
- On first clock-in (check `oem_setup_completed` flag), show the OEM guide if manufacturer is known.
- On unexpected tracking death (service dies during active shift), show the OEM guide again with an explanation: "Votre téléphone a arrêté le suivi GPS. Pour éviter ce problème :"

**E) `battery_optimization_dialog.dart`** — Update to check manufacturer first:
- If manufacturer is Samsung/Xiaomi/Huawei/etc → delegate to `OemBatteryGuideDialog`
- Otherwise → show current generic AOSP dialog

#### Validation
- Test on Samsung device: verify deep link opens correct settings.
- Test on non-OEM device (Pixel): verify generic dialog still works.
- Verify `oem_setup_completed` flag prevents re-showing.

---

### Task 2.2: Foreground Service Resume Check (Android 12+)
**Priority**: P1 — Detect and recover from service death on app resume
**Estimated complexity**: Low
**Dependencies**: None

#### Changes

**A) `AndroidManifest.xml`** — Add permission:
```xml
<uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM" />
```

**B) `tracking_provider.dart`** — Enhance `_refreshServiceState()`:
The current `_refreshServiceState()` already checks `BackgroundTrackingService.isTracking` and restarts if dead. But it only runs at startup.

Add: also run this check on `AppLifecycleState.resumed` (app returns to foreground). This already partially exists in `refreshState()`, but make it more robust:
- If service is dead + active shift exists + Android 12+:
  1. Log the event with device manufacturer for analytics
  2. Show a brief SnackBar: "Le suivi GPS a été interrompu. Redémarrage..."
  3. Auto-restart the service (we're in foreground context, so Android 12+ allows it)
  4. If manufacturer is known OEM killer → show OEM guide dialog

#### Validation
- On Android 12+ device, manually stop the foreground service via adb. Resume the app. Verify auto-restart + notification.

---

## Phase 3: Cross-Platform Thermal Monitoring

### Task 3.1: Thermal State Service
**Priority**: P2 — Edge case protection
**Estimated complexity**: Medium
**Dependencies**: Task 1.2 (iOS plugin infrastructure), Task 2.1 (Android method channel infrastructure)

#### Changes

**A) `thermal_state_service.dart`** — New cross-platform service:
```dart
enum ThermalLevel { nominal, elevated, critical }

class ThermalStateService {
    static const _channel = MethodChannel('gps_tracker/thermal_state');
    static final _controller = StreamController<ThermalLevel>.broadcast();
    static Stream<ThermalLevel> get thermalStateStream => _controller.stream;

    static Future<void> startMonitoring() async {
        _channel.setMethodCallHandler((call) async {
            if (call.method == 'onThermalStateChanged') {
                final level = _parseThermalLevel(call.arguments as int);
                _controller.add(level);
            }
        });
        await _channel.invokeMethod('startMonitoring');
    }
}
```

Map native levels to 3 simplified levels:
- iOS: `.nominal`/`.fair` → nominal, `.serious` → elevated, `.critical` → critical
- Android: `NONE`/`LIGHT` → nominal, `MODERATE`/`SEVERE` → elevated, `CRITICAL`+ → critical

**B) iOS native** — Add to `BackgroundTaskPlugin.swift`:
```swift
func startThermalMonitoring() {
    NotificationCenter.default.addObserver(
        self, selector: #selector(thermalStateChanged),
        name: ProcessInfo.thermalStateDidChangeNotification, object: nil
    )
}

@objc private func thermalStateChanged() {
    let state = ProcessInfo.processInfo.thermalState
    channel?.invokeMethod("onThermalStateChanged", arguments: state.rawValue)
}
```

**C) Android native** — Add to `MainActivity.kt`:
```kotlin
if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
    val powerManager = getSystemService(PowerManager::class.java)
    powerManager.addThermalStatusListener { status ->
        thermalChannel.invokeMethod("onThermalStateChanged", status)
    }
}
```

**D) `tracking_provider.dart`** — Listen and adapt:
```dart
ThermalStateService.thermalStateStream.listen((level) {
    switch (level) {
        case ThermalLevel.nominal:
            updateConfig(TrackingConfig.active); // 60s, high accuracy
        case ThermalLevel.elevated:
            updateConfig(TrackingConfig(activeIntervalSeconds: 120, ...));
        case ThermalLevel.critical:
            updateConfig(TrackingConfig.batterySaver); // 300s, low accuracy
    }
});
```

#### Validation
- iOS: Use Xcode > Debug > Simulate Thermal State to test transitions.
- Android: Use `adb shell cmd thermalservice override-status <level>`.
- Verify config updates reach background handler and polling interval changes.

---

## Implementation Order

```
Phase 1 (iOS) — Can be done in parallel:
├── Task 1.1: Deferred SignificantLocation (P0)
├── Task 1.2: CLBackgroundActivitySession (P0)
└── Task 1.3: beginBackgroundTask (P1)

Phase 2 (Android) — Can be done in parallel with Phase 1:
├── Task 2.1: OEM Battery Guide (P0)
└── Task 2.2: Foreground Service Resume Check (P1)

Phase 3 (Cross-Platform) — Depends on Phase 1+2 plugin infrastructure:
└── Task 3.1: Thermal State Service (P2)
```

## Risk Assessment

| Risk | Mitigation |
|---|---|
| CLBackgroundActivitySession changes iOS behavior unexpectedly | Feature-flag behind iOS 17+ check, can disable via remote config |
| OEM settings intents break on newer OS versions | All intent launches wrapped in try-catch with generic fallback |
| Thermal monitoring over-reduces GPS accuracy | Only adapts at `elevated`/`critical`, restores on `nominal` |
| beginBackgroundTask expiration handler timing | Always call endBackgroundTask in expiration handler to avoid iOS penalty |
| Deferred SignificantLocation misses the window between stream death and activation | 90s detection threshold is acceptable; SignificantLocation is a last-resort safety net |

## Success Metrics
- Reduction in `auto_zombie_cleanup` shift closures (primary metric)
- Increase in average GPS points per shift hour
- Reduction in GPS gaps > 5 minutes
- Zero new crash reports from thermal/service handling
