# Research: 018 - Background Tracking Resilience

## R1: Dual CLLocationManager Conflict (iOS 16.4+)

**Decision**: Defer SignificantLocationChanges activation — do NOT start it simultaneously with the continuous GPS stream at clock-in. Additionally, add `CLBackgroundActivitySession` on iOS 17+ which sidesteps the issue entirely.

**Rationale**: Since iOS 16.4, Apple changed Core Location behavior so that apps running both `startUpdatingLocation()` and `startMonitoringSignificantLocationChanges()` on separate CLLocationManager instances may be suspended in background. This is documented in Apple Developer Forums (thread 726945) and confirmed by Apple engineers. The suspension is triggered when the OS interprets dual-manager usage as excessive/conflicting location requests.

Our current config (`distanceFilter: 0`, high accuracy, `showsBackgroundLocationIndicator: true`) is theoretically safe, but this is fragile — it relies on the geolocator plugin's internal CLLocationManager configuration remaining compatible. Deferring SLC activation eliminates the conflict entirely.

**Alternatives considered**:
- **Single shared CLLocationManager**: Would require forking geolocator or building a custom location plugin. Too invasive and violates the non-goal of not replacing geolocator.
- **Remove SLC entirely**: SLC is the only mechanism that relaunches the app after true iOS termination. Must keep it as a fallback.
- **Always run both but add CLBackgroundActivitySession**: The session helps on iOS 17+ but doesn't fix iOS 16.x devices. Deferred activation is the safer cross-version solution.

## R2: CLBackgroundActivitySession (iOS 17+)

**Decision**: Create a `CLBackgroundActivitySession` when tracking starts and invalidate when tracking stops. On iOS < 17, fall back to current behavior (no-op).

**Rationale**: `CLBackgroundActivitySession` is Apple's iOS 17+ API for explicitly declaring legitimate continuous background location activity. It shows the blue location indicator in the status bar/Dynamic Island and grants preferential OS treatment (less likely to be suspended). It complements the existing `allowsBackgroundLocationUpdates = true` and `showsBackgroundLocationIndicator = true` settings.

Key implementation details:
- Must hold a **strong reference** to the session object (deallocation invalidates it)
- Create at shift start, invalidate at shift end
- If app is relaunched by SLC, re-create the session immediately
- Works with both legacy CLLocationManager delegate API and new async API

**Alternatives considered**:
- **CLLocationUpdate.liveUpdates() async stream (iOS 17+)**: Apple's modern replacement for `startUpdatingLocation()`. Would require replacing geolocator entirely — violates non-goal.
- **Background URLSession**: Not applicable for continuous location tracking.

## R3: beginBackgroundTask Protection

**Decision**: Call `UIApplication.shared.beginBackgroundTask(withName:expirationHandler:)` when the app enters background during an active shift. End the task when expiration fires or app returns to foreground.

**Rationale**: This requests ~30 seconds of additional execution time from iOS before suspension. It's a belt-and-suspenders approach — even if `CLBackgroundActivitySession` keeps the app alive long-term, `beginBackgroundTask` protects the critical transition moment when the app first enters background.

Key rules (from Apple DTS engineer Quinn "the Eskimo"):
1. Always end every task you begin (failing to do so causes iOS to kill the app)
2. Always use named tasks (name appears in crash logs)
3. Never rely on `backgroundTimeRemaining` (it's an estimate, not a contract)
4. The expiration handler must call `endBackgroundTask` immediately

**Alternatives considered**:
- **BGProcessingTask / BGAppRefreshTask**: These are for deferred, discretionary work (ML training, cleanup). Not suitable for continuous location tracking which needs immediate execution.
- **Relying solely on CLBackgroundActivitySession**: Doesn't help iOS < 17 devices.

## R4: Android OEM-Specific Battery Optimization

**Decision**: Detect device manufacturer via existing `device_info_plus` package. Show OEM-specific step-by-step instructions with deep links to the correct settings screens. Support Samsung, Xiaomi, Huawei, OnePlus/Oppo/Realme. Fall back to generic guidance + dontkillmyapp.com link for unknown OEMs.

**Rationale**: The standard Android `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` API only handles AOSP battery optimization. Samsung SmartManager, Xiaomi MIUI Battery Saver, Huawei App Launch Management, and ColorOS add their own restriction layers that bypass this API entirely. These OEM layers are the primary cause of GPS tracking death on Android devices.

Deep link intents (with fallback chains):
- **Samsung**: `com.samsung.android.lool/BatteryActivity` → `com.samsung.android.sm/SmartManagerDashBoardActivity` → generic
- **Xiaomi**: `com.miui.securitycenter/AutoStartManagementActivity` (autostart) + `com.miui.powerkeeper/HiddenAppsConfigActivity` (battery)
- **Huawei**: `com.huawei.systemmanager/StartupAppControlActivity` → `StartupNormalAppListActivity` → `ProtectActivity`
- **OnePlus/Oppo/Realme**: `com.coloros.safecenter/StartupAppListActivity` variants

Existing `device_info_plus` in the project already captures `manufacturer` — no new dependency needed.

**Alternatives considered**:
- **`disable_battery_optimization` package**: Listed in pubspec but never used. Provides some OEM handling but is a less-maintained package. Custom implementation gives full control over French UI text and the exact OEM deep links.
- **`AutoStarter` library (judemanutd)**: Android-only Kotlin library with comprehensive OEM intent database. Would need a method channel bridge. Our custom implementation is simpler and more maintainable for our ~5 target OEMs.
- **dontkillmyapp.com JSON API**: Could fetch OEM instructions dynamically. Adds a network dependency at a critical moment (user needs guidance when offline tracking fails). Better to embed instructions statically and link to dontkillmyapp.com as supplementary reference.

## R5: Foreground Service Restart Hardening (Android 12+)

**Decision**: Add foreground resume check in `tracking_provider.dart` — when app returns to foreground during an active shift, check `FlutterForegroundTask.isRunningService`. If the service died, auto-restart it (allowed from foreground context on Android 12+). Do NOT add `SCHEDULE_EXACT_ALARM` permission.

**Rationale**: On Android 12+, `startForegroundService()` from background throws `ForegroundServiceStartNotAllowedException`. The `flutter_foreground_task` RestartReceiver attempts this and silently fails. The safest recovery point is when the user returns to the app (foreground context), where FGS start is always allowed.

`SCHEDULE_EXACT_ALARM` was considered but rejected: Android 14 denies it by default for non-alarm apps, requiring the user to navigate to system settings to grant it. This is an additional friction point with minimal benefit since the foreground resume check already covers the primary recovery scenario.

**Alternatives considered**:
- **SCHEDULE_EXACT_ALARM for background restart**: Rejected — Android 14 denies by default for GPS trackers, requires user action in system settings, and the permission can be revoked at any time.
- **WorkManager fallback**: Could enqueue a one-time work request when FGS start fails. However, WorkManager cannot start a foreground service from background either on Android 12+. Only useful for scheduling work that doesn't need FGS.
- **Do nothing**: The existing auto-restart on boot/package-replace covers reboot/update scenarios. The foreground resume check fills the gap for OEM-killed services.

## R6: Thermal State Monitoring

**Decision**: Add a cross-platform `ThermalStateService` using method channels. iOS: `ProcessInfo.ThermalState` via NotificationCenter observer. Android: `PowerManager.getCurrentThermalStatus()` + `OnThermalStatusChangedListener` (API 29+). Send config updates to background handler via existing `updateConfig` command.

**Rationale**: Thermal throttling is a common cause of app termination on both platforms. By proactively reducing GPS frequency when the device overheats, we avoid being the target of thermal mitigation kills.

Thermal adaptation mapping:
| Thermal Level | GPS Accuracy | Capture Interval |
|---|---|---|
| Normal/Light | LocationAccuracy.high | 60s (current default) |
| Moderate/Serious | LocationAccuracy.medium | 120s |
| Critical/Severe+ | LocationAccuracy.low | 300s |

iOS thermal states: `.nominal`, `.fair`, `.serious`, `.critical`
Android thermal statuses: `NONE(0)`, `LIGHT(1)`, `MODERATE(2)`, `SEVERE(3)`, `CRITICAL(4)`, `EMERGENCY(5)`, `SHUTDOWN(6)`

**Alternatives considered**:
- **Disable tracking entirely on critical thermal**: Too aggressive — we'd lose GPS data during the shift. Reducing frequency is a better tradeoff.
- **Use battery level as proxy**: Battery percentage doesn't correlate well with thermal state. A device can be at 80% battery but thermally throttled.
- **Third-party thermal package**: No well-maintained Flutter package exists. Direct method channel is simpler and avoids dependency.

## R7: SignificantLocationChanges Deferred Activation Strategy

**Decision**: Start only the continuous GPS stream at clock-in. Activate SLC only when the GPS stream dies (detected by `_checkStreamHealth` after 90s with no position). Stop SLC when the stream recovers. On iOS relaunch via SLC, restart the full tracking pipeline (existing behavior).

**Rationale**: This eliminates the dual-CLLocationManager conflict (R1) while preserving SLC's critical role as an app relaunch mechanism after termination. The 90-second health check in `GPSTrackingHandler` already detects stream death and sends `gps_lost` to the main isolate — we just need to wire this signal to SLC activation.

Communication flow:
1. Background handler detects stream death → sends `gps_lost` to main isolate
2. Main isolate (`tracking_provider.dart`) receives `gps_lost` → calls `SignificantLocationService.startMonitoring()`
3. Background handler recovers stream → sends `gps_restored` to main isolate
4. Main isolate receives `gps_restored` → calls `SignificantLocationService.stopMonitoring()`
5. If app is terminated, SLC relaunches app → existing `_onWokenByLocationChange` restarts tracking

**Alternatives considered**:
- **Delay SLC start by N minutes**: Arbitrary delay doesn't address the root cause. The conflict exists regardless of timing.
- **Start SLC only after app enters background**: Adds complexity for marginal benefit. The real issue is running both simultaneously, not the specific lifecycle state.
