# Comprehensive Telemetry, Logging & Diagnostic Data Research

**Date:** 2026-03-07
**Purpose:** Identify every possible piece of diagnostic data extractable from Android and iOS for a Flutter GPS tracking app, to achieve 100% crash and GPS gap diagnosis coverage.

**Existing infrastructure:** The app already has `DiagnosticLogger` (categories: gps, shift, sync, auth, permission, lifecycle, thermal, error, network), `DiagnosticEvent` model, `DiagnosticSyncService` (batch sync to Supabase via `sync_diagnostic_logs` RPC), and local SQLCipher storage with server sync.

---

## Table of Contents

1. [iOS Crash and Diagnostic Data](#1-ios-crash-and-diagnostic-data)
2. [Android Crash and Diagnostic Data](#2-android-crash-and-diagnostic-data)
3. [Flutter-Specific Diagnostic Data](#3-flutter-specific-diagnostic-data)
4. [GPS-Specific Diagnostics](#4-gps-specific-diagnostics)
5. [Crash Reporting Services for Flutter](#5-crash-reporting-services-for-flutter)
6. [Background Execution Diagnostics](#6-background-execution-diagnostics)
7. [Summary: Master Data Collection Matrix](#7-summary-master-data-collection-matrix)

---

## 1. iOS Crash and Diagnostic Data

### 1.1 MetricKit Framework (iOS 13+, diagnostics from iOS 14+)

MetricKit is Apple's first-party framework for collecting aggregated performance and diagnostic data. It delivers payloads every ~24 hours (metrics) and immediately after events (diagnostics from iOS 15+).

#### MXMetricPayload (delivered every ~24 hours)

| Metric Class | What It Gives You | Background? |
|---|---|---|
| `MXCPUMetric` | Cumulative CPU time, CPU instruction count | Yes (aggregated) |
| `MXGPUMetric` | Cumulative GPU time | Yes (aggregated) |
| `MXMemoryMetric` | Peak memory usage, average suspended memory | Yes (aggregated) |
| `MXDiskIOMetric` | Cumulative disk reads/writes in bytes | Yes (aggregated) |
| `MXAppLaunchMetric` | Cold/warm/resume launch time histograms | N/A |
| `MXAppResponsivenessMetric` | Hang time histograms (main thread blocks) | Yes (aggregated) |
| `MXLocationActivityMetric` | Cumulative time using GPS, total distance | Yes (aggregated) |
| `MXNetworkTransferMetric` | Cumulative bytes sent/received (cellular + wifi) | Yes (aggregated) |
| `MXCellularConditionMetric` | Histogram of cellular signal quality bars | Yes (aggregated) |
| `MXAppRunTimeMetric` | Foreground/background/audio run time | Yes (aggregated) |
| `MXAppExitMetric` | Exit reasons: normal, abnormal, crash, memory, watchdog, CPU, suspension, background task timeout, illegal instruction | Yes (aggregated) |
| `MXSignpostMetric` | Custom signpost-based measurements you define | Yes (aggregated) |
| `MXAnimationMetric` | Scroll hitch rate, hitch time ratio | N/A |

#### MXDiagnosticPayload (delivered immediately from iOS 15+)

| Diagnostic Class | What It Gives You |
|---|---|
| `MXCrashDiagnostic` | Crash reason, exception type, signal, full call stack tree with symbolication data, virtual memory region info |
| `MXHangDiagnostic` | Hang duration, call stack at point of hang |
| `MXCPUExceptionDiagnostic` | CPU time consumed, total CPU instructions, call stack |
| `MXDiskWriteExceptionDiagnostic` | Total disk writes that triggered the exception, call stack |
| `MXAppLaunchDiagnostic` (iOS 16+) | Launch duration that exceeded threshold, call stack |

**How to implement in Flutter:** Requires a Swift platform channel. Register `MXMetricManager.shared.add(self)` in AppDelegate, implement `MXMetricManagerSubscriber` protocol, serialize payloads to JSON via `jsonRepresentation()`, and send to Dart via EventChannel or store directly via native Supabase call.

**Privacy:** No additional permissions required. Data is per-app only. Apple aggregates it automatically.

**Key value for GPS app:** `MXLocationActivityMetric` tells you exactly how much GPS time was consumed. `MXAppExitMetric` tells you every reason the app died. `MXCrashDiagnostic` gives symbolicated crash stacks without any third-party SDK.

---

### 1.2 OSLog / os_log (Unified Logging System)

Apple's structured logging framework that persists logs to the system log store.

| Feature | What It Gives You |
|---|---|
| Severity levels | `.debug`, `.info`, `.default`, `.error`, `.fault` |
| Subsystem + Category | Structured filtering (e.g., subsystem="com.trilogis.gps", category="tracking") |
| Privacy controls | Public vs private data annotation |
| Persistence | `.error` and `.fault` persist to disk; others are memory-only |
| Programmatic access | `OSLogStore(scope: .currentProcessIdentifier)` can read back logs from current process |

**How to implement in Flutter:** Swift platform channel. Create an `OSLog` instance with subsystem/category, log natively. To read logs back after restart, use `OSLogStore` with `getEntries(with: position)` and filter via `NSPredicate`.

**Background mode:** Logs are captured in background. Reading logs back requires foreground app process.

**Privacy:** No special permissions. Logs are process-scoped.

**Key limitation:** You can only read logs from your own process. You cannot read system-wide logs. After a crash, logs from the crashed session may be partially available on next launch.

---

### 1.3 UIApplication Lifecycle Notifications

| Notification | When It Fires |
|---|---|
| `willEnterForegroundNotification` | App about to enter foreground from background |
| `didBecomeActiveNotification` | App is now active and receiving events |
| `willResignActiveNotification` | App about to lose focus (incoming call, notification center) |
| `didEnterBackgroundNotification` | App entered background |
| `willTerminateNotification` | App about to terminate (NOT called if suspended first) |
| `didReceiveMemoryWarningNotification` | System issued memory warning |
| `significantTimeChangeNotification` | Midnight, time zone change, daylight saving |
| `backgroundRefreshStatusDidChangeNotification` | User toggled background app refresh |
| `protectedDataWillBecomeUnavailableNotification` | Device about to lock (data protection) |
| `protectedDataDidBecomeAvailableNotification` | Device unlocked (data accessible) |

**How to implement in Flutter:** Already partially covered by `WidgetsBindingObserver.didChangeAppLifecycleState`. For the full set, add native `NotificationCenter` observers in AppDelegate via platform channel, especially for memory warnings, protected data changes, and background refresh status.

**Background mode:** Notifications fire in background (willTerminate is unreliable).

---

### 1.4 CLLocationManager Delegate Callbacks

| Callback | What It Gives You |
|---|---|
| `didUpdateLocations` | Array of CLLocation objects (lat, lon, altitude, horizontalAccuracy, verticalAccuracy, speed, speedAccuracy, course, courseAccuracy, timestamp, floor, sourceInformation, ellipsoidalAltitude) |
| `didFailWithError` | Error code: `kCLErrorDenied`, `kCLErrorLocationUnknown`, `kCLErrorNetwork`, `kCLErrorHeadingFailure`, `kCLErrorRangingUnavailable`, `kCLErrorRangingFailure` |
| `locationManagerDidChangeAuthorization` | New authorization status + `accuracyAuthorization` (.fullAccuracy vs .reducedAccuracy) |
| `didFinishDeferredUpdatesWithError` | Deferred update completion or error |
| `locationManagerDidPauseLocationUpdates` | System paused updates to save power (critical for GPS gap diagnosis!) |
| `locationManagerDidResumeLocationUpdates` | System resumed updates |

**Critical for GPS gaps:** The `locationManagerDidPauseLocationUpdates` and `locationManagerDidResumeLocationUpdates` callbacks are the #1 source of iOS GPS gaps. The system pauses updates automatically when it detects the user is stationary. Must log these events.

**How to implement:** Platform channel from native iOS code. The `geolocator` Flutter package does NOT expose pause/resume callbacks -- this requires custom native code.

---

### 1.5 CLLocation Properties (per fix)

| Property | What It Gives You |
|---|---|
| `coordinate` | Latitude, longitude |
| `altitude` | Meters above sea level |
| `ellipsoidalAltitude` (iOS 15+) | WGS84 ellipsoidal altitude |
| `horizontalAccuracy` | Radius of uncertainty in meters (negative = invalid) |
| `verticalAccuracy` | Vertical uncertainty in meters (negative = invalid) |
| `speed` | Meters per second (negative = invalid) |
| `speedAccuracy` (iOS 10+) | Speed uncertainty in m/s |
| `course` | Degrees from true north (negative = invalid) |
| `courseAccuracy` (iOS 13.4+) | Course uncertainty in degrees |
| `timestamp` | When the fix was determined |
| `floor` | Floor of building (if available) |
| `sourceInformation` (iOS 15+) | `.isSimulatedBySoftware` and `.isProducedByAccessory` |

---

### 1.6 Thermal State Monitoring

| State | Meaning |
|---|---|
| `.nominal` | Normal operation |
| `.fair` | Slightly elevated, delay non-critical work |
| `.serious` | Significantly elevated, reduce CPU/GPU/I/O |
| `.critical` | Device may shut down, minimal work only |

**How to access:** `ProcessInfo.processInfo.thermalState` and observe `ProcessInfo.thermalStateDidChangeNotification`. Also available via the Flutter `thermal` package on pub.dev.

**Background mode:** Notifications fire in background.

**Key value:** Thermal throttling causes GPS degradation. Log state changes with timestamps.

---

### 1.7 Memory Pressure Monitoring

Four approaches on iOS:

1. **`applicationDidReceiveMemoryWarning`** - AppDelegate callback
2. **`didReceiveMemoryWarning`** - UIViewController callback
3. **`UIApplication.didReceiveMemoryWarningNotification`** - NotificationCenter
4. **`DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])`** - GCD dispatch source with `.normal`, `.warning`, `.critical` levels

**Flutter built-in:** `WidgetsBindingObserver.didHaveMemoryPressure()` -- but this is unreliable on iOS (always fires when entering background, may NOT fire on actual OOM).

**Best approach:** Use `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` via platform channel for granular pressure levels.

**Background mode:** Memory pressure dispatch source works in background.

---

### 1.8 NWPathMonitor (Network Path Monitoring)

| Data Available | Description |
|---|---|
| `path.status` | `.satisfied`, `.unsatisfied`, `.requiresConnection` |
| `path.availableInterfaces` | Array of interface types (wifi, cellular, wiredEthernet, loopback, other) |
| `path.isExpensive` | True if on cellular or personal hotspot |
| `path.isConstrained` | True if Low Data Mode is active |
| `path.supportsDNS` | DNS resolution available |
| `path.supportsIPv4` / `supportsIPv6` | Protocol support |
| `path.gateways` | Network gateway endpoints |

**Flutter integration:** `connectivity_plus` package uses `NWPathMonitor` internally on iOS. For more detail, use platform channel.

**Background mode:** Works in background.

---

### 1.9 CoreMotion Activity Detection

| Activity Type | Description |
|---|---|
| `stationary` | Device not moving |
| `walking` | User walking |
| `running` | User running |
| `cycling` | User cycling |
| `automotive` | User in a vehicle |
| `unknown` | Cannot determine activity |
| `confidence` | `.low`, `.medium`, `.high` |

**How to implement:** `CMMotionActivityManager().startActivityUpdates()` via platform channel, or use the `activity_recognition_flutter` package.

**Permission:** Requires `NSMotionUsageDescription` in Info.plist and `CMMotionActivityManager.isActivityAvailable()` check.

**Background mode:** Works in background with proper configuration.

**Key value for GPS app:** Correlating activity with GPS gaps -- if the user is stationary, iOS will pause location updates. Logging this proves the gap was expected vs. a bug.

---

## 2. Android Crash and Diagnostic Data

### 2.1 GNSS Status and Satellite Information

| API | What It Gives You |
|---|---|
| `GnssStatus.Callback.onStarted()` | GNSS engine started |
| `GnssStatus.Callback.onStopped()` | GNSS engine stopped |
| `GnssStatus.Callback.onFirstFix(ttffMillis)` | Time to first fix in milliseconds |
| `GnssStatus.Callback.onSatelliteStatusChanged(status)` | Full satellite status |
| `GnssStatus.getSatelliteCount()` | Total satellites visible |
| `GnssStatus.usedInFix(i)` | Whether satellite i was used in the fix |
| `GnssStatus.getCn0DbHz(i)` | Signal strength (carrier-to-noise density) per satellite |
| `GnssStatus.getConstellationType(i)` | GPS, GLONASS, Galileo, BeiDou, QZSS, SBAS, IRNSS |
| `GnssStatus.getElevationDegrees(i)` | Satellite elevation |
| `GnssStatus.getAzimuthDegrees(i)` | Satellite azimuth |
| `GnssStatus.getCarrierFrequencyHz(i)` (API 26+) | Carrier frequency (L1, L5, etc.) |
| `GnssStatus.hasCarrierFrequencyHz(i)` | Whether carrier frequency is available |

**Flutter package:** `raw_gnss_flutter` provides streams for GNSS measurements, navigation messages, and status. Alternatively, custom platform channel with `LocationManager.registerGnssStatusCallback()`.

**Background mode:** Works when location updates are active (foreground service).

---

### 2.2 Raw GNSS Measurements (API 24+, mandatory API 29+)

| Data | Description |
|---|---|
| Pseudorange | Distance to each satellite |
| Carrier phase | Phase measurement for precise positioning |
| Doppler shift | Velocity measurement |
| Accumulated delta range | Carrier phase accumulation |
| Signal-to-noise ratio | Per-satellite signal quality |
| Multipath indicator | Multipath reflection detection |
| Constellation type | Which satellite system |
| SVID | Satellite vehicle ID |

**Flutter package:** `raw_gnss_flutter` on pub.dev.

**Key value:** Can compute your own HDOP/PDOP from satellite geometry, detect multipath (urban canyon) issues causing GPS drift.

---

### 2.3 Battery Optimization and Doze Mode Detection

| API | What It Gives You |
|---|---|
| `PowerManager.isIgnoringBatteryOptimizations(packageName)` | Whether app is whitelisted from battery optimization |
| `PowerManager.isInteractive()` | Whether screen is on / device awake |
| `PowerManager.isDeviceIdleMode()` (API 23+) | Whether device is in Doze mode |
| `PowerManager.isPowerSaveMode()` | Whether Battery Saver is active |
| `PowerManager.isLightDeviceIdleMode()` (API 24+) | Light doze mode (screen off but not stationary) |
| `ACTION_DEVICE_IDLE_MODE_CHANGED` broadcast | Doze mode entry/exit |
| `ACTION_POWER_SAVE_MODE_CHANGED` broadcast | Battery saver toggled |

**How to implement:** Platform channel from Kotlin/Java. Register broadcast receivers for state changes.

**Background mode:** Broadcast receivers work in background. Doze mode will defer them in deep doze unless whitelisted.

---

### 2.4 App Standby Buckets (API 28+)

| Bucket | Restrictions |
|---|---|
| `STANDBY_BUCKET_ACTIVE` | No restrictions (app actively used) |
| `STANDBY_BUCKET_WORKING_SET` | Mild restrictions on jobs/alarms |
| `STANDBY_BUCKET_FREQUENT` | Stronger restrictions, FCM high-priority cap |
| `STANDBY_BUCKET_RARE` | Strict restrictions, limited network |
| `STANDBY_BUCKET_RESTRICTED` (API 31+) | Maximum restrictions |

**How to access:** `UsageStatsManager.getAppStandbyBucket()`. Requires `PACKAGE_USAGE_STATS` permission with `Settings.ACTION_USAGE_ACCESS_SETTINGS` intent.

**Key value:** If your app is in RARE or RESTRICTED bucket, background location updates will be severely throttled -- this is a direct cause of GPS gaps.

---

### 2.5 ActivityManager Memory State

| Field | What It Gives You |
|---|---|
| `pid` | Process ID |
| `uid` | User ID |
| `importance` | `IMPORTANCE_FOREGROUND`, `IMPORTANCE_FOREGROUND_SERVICE`, `IMPORTANCE_VISIBLE`, `IMPORTANCE_TOP_SLEEPING`, `IMPORTANCE_PERCEPTIBLE`, `IMPORTANCE_CACHED`, `IMPORTANCE_GONE` |
| `lastTrimLevel` | `TRIM_MEMORY_RUNNING_LOW`, `TRIM_MEMORY_RUNNING_CRITICAL`, `TRIM_MEMORY_COMPLETE`, etc. |
| `lru` | Position in the LRU list |
| `importanceReasonCode` | Why the process has this importance |

**How to access:** `ActivityManager.getMyMemoryState(RunningAppProcessInfo)`.

**Background mode:** Works in any state.

---

### 2.6 ConnectivityManager Network State

| Callback | What It Gives You |
|---|---|
| `onAvailable(network)` | Network became available |
| `onLost(network)` | Network lost |
| `onCapabilitiesChanged(network, capabilities)` | Network capabilities changed |
| `onLinkPropertiesChanged(network, linkProperties)` | Link properties changed |
| `NetworkCapabilities.hasTransport(TRANSPORT_WIFI/CELLULAR/VPN/BLUETOOTH/ETHERNET)` | Transport type |
| `NetworkCapabilities.hasCapability(NET_CAPABILITY_NOT_METERED)` | Is the network metered? |
| `NetworkCapabilities.getLinkDownstreamBandwidthKbps()` | Estimated download bandwidth |
| `NetworkCapabilities.getLinkUpstreamBandwidthKbps()` | Estimated upload bandwidth |
| `NetworkCapabilities.getSignalStrength()` | Signal strength (dBm) |

**How to implement:** `ConnectivityManager.registerDefaultNetworkCallback()` via platform channel.

**Background mode:** Callbacks fire in background.

---

### 2.7 BatteryManager

| Property | What It Gives You |
|---|---|
| `BATTERY_PROPERTY_CHARGE_COUNTER` | Battery charge in microampere-hours |
| `BATTERY_PROPERTY_CURRENT_NOW` | Instantaneous battery current in microamperes |
| `BATTERY_PROPERTY_CURRENT_AVERAGE` | Average battery current in microamperes |
| `BATTERY_PROPERTY_CAPACITY` | Battery remaining capacity as percentage |
| `BATTERY_PROPERTY_ENERGY_COUNTER` | Battery remaining energy in nanowatt-hours |
| `BATTERY_STATUS_*` | Charging, discharging, full, not charging, unknown |
| `BATTERY_HEALTH_*` | Good, overheat, dead, over voltage, cold, unspecified failure |
| `EXTRA_TEMPERATURE` | Battery temperature in tenths of degree Celsius |
| `EXTRA_VOLTAGE` | Battery voltage in millivolts |
| `EXTRA_PLUGGED` | AC, USB, wireless charging |

**How to implement:** `BatteryManager` system service + `ACTION_BATTERY_CHANGED` sticky broadcast via platform channel. Also `battery_plus` Flutter package for basic level/state.

**Background mode:** Sticky broadcast available anytime.

---

### 2.8 ANR Detection

| Approach | What It Gives You |
|---|---|
| `StrictMode.ThreadPolicy` | Detects disk reads, disk writes, network access on main thread |
| `StrictMode.VmPolicy` | Detects leaked closeable objects, leaked activities, leaked SQLite cursors |
| Main thread watchdog | Custom: post a Runnable to main thread, if it doesn't execute within N seconds, capture stack trace |
| `ActivityManager.getProcessesInErrorState()` | Returns processes in ANR state |

**Sentry's approach:** Sentry ANR detection spawns a watchdog thread that monitors the main thread. If the main thread is blocked for >5 seconds, it captures a stack trace. This is the most practical approach for production.

**Background mode:** StrictMode is debug-only. Watchdog thread works in any state.

---

### 2.9 ForegroundService Lifecycle

| Event | How to Detect |
|---|---|
| Service created | `onCreate()` callback |
| Service started | `onStartCommand()` callback |
| Service destroyed | `onDestroy()` callback |
| Foreground promotion | `startForeground()` call |
| Task removed | `onTaskRemoved()` callback -- fires when user swipes app from recents |
| Low memory | `onLowMemory()` callback |
| Trim memory | `onTrimMemory(level)` callback with TRIM_MEMORY_* levels |

**Key value:** `onTaskRemoved()` is critical -- it tells you when the user swiped the app away, which on many OEMs kills the foreground service despite Android documentation saying it shouldn't.

---

## 3. Flutter-Specific Diagnostic Data

### 3.1 Comprehensive Error Capture Strategy

Three layers are needed to capture 100% of errors:

#### Layer 1: runZonedGuarded (async/platform errors)
```dart
runZonedGuarded(() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}, (error, stackTrace) {
  // Catches ALL uncaught async errors, including platform channel errors
  DiagnosticLogger.instance.log(
    category: EventCategory.error,
    severity: Severity.critical,
    message: error.toString(),
    metadata: {'stack_trace': stackTrace.toString()},
  );
});
```

#### Layer 2: FlutterError.onError (framework errors)
```dart
FlutterError.onError = (FlutterErrorDetails details) {
  // Catches widget build errors, layout errors, paint errors
  DiagnosticLogger.instance.log(
    category: EventCategory.error,
    severity: Severity.error,
    message: details.exceptionAsString(),
    metadata: {
      'library': details.library,
      'stack_trace': details.stack.toString(),
    },
  );
};
```

#### Layer 3: PlatformDispatcher.instance.onError (platform errors)
```dart
PlatformDispatcher.instance.onError = (error, stack) {
  // Catches errors not caught by Zone or FlutterError
  DiagnosticLogger.instance.log(
    category: EventCategory.error,
    severity: Severity.critical,
    message: error.toString(),
    metadata: {'stack_trace': stack.toString()},
  );
  return true; // Handled
};
```

### 3.2 AppLifecycleState (via WidgetsBindingObserver)

| State | Meaning | Platform Mapping |
|---|---|---|
| `resumed` | App visible, receiving input | iOS: didBecomeActive / Android: onResume |
| `inactive` | App visible but not receiving input (e.g., phone call) | iOS: willResignActive / Android: onPause |
| `hidden` | App views not visible (transitional) | iOS/Android: brief state between inactive/paused |
| `paused` | App in background, not visible | iOS: didEnterBackground / Android: onStop |
| `detached` | App still hosted but detached from views | iOS/Android: initial state or engine detached |

### 3.3 Additional WidgetsBindingObserver Callbacks

| Callback | What It Gives You |
|---|---|
| `didChangeAppLifecycleState(state)` | Lifecycle transitions (above) |
| `didHaveMemoryPressure()` | System memory warning (unreliable on iOS) |
| `didChangeAccessibilityFeatures()` | Accessibility settings changed |
| `didChangeLocales()` | System locale changed |
| `didChangeMetrics()` | Screen size/orientation changed |
| `didChangePlatformBrightness()` | Dark/light mode changed |
| `didChangeTextScaleFactor()` | Text scale changed |

### 3.4 Flutter Engine Lifecycle Events

| Event | How to Capture |
|---|---|
| Engine created | Log in `main()` before `runApp()` |
| First frame rendered | `WidgetsBinding.instance.addPostFrameCallback()` or `SchedulerBinding.instance.addTimingsCallback()` |
| Frame timing | `SchedulerBinding.addTimingsCallback()` gives build/raster duration per frame |
| Platform channel errors | `PlatformException` caught in try/catch around `MethodChannel.invokeMethod()` |
| Isolate spawn | `Isolate.spawn()` errors via `Isolate.addErrorListener()` |
| Hot restart | `ServicesBinding.instance.reassemble()` (debug only) |

### 3.5 flutter_foreground_task Lifecycle Callbacks

| Callback | When It Fires |
|---|---|
| `onStart()` | Foreground task is starting |
| `onRepeatEvent()` | Periodic callback at specified interval |
| `onDestroy()` | Foreground task is being destroyed |
| `onNotificationPressed()` | User tapped the foreground notification |
| `onNotificationButtonPressed(id)` | User tapped a notification action button |
| `WillStartForegroundTask` widget | Widget-level lifecycle wrapper |

---

## 4. GPS-Specific Diagnostics

### 4.1 Flutter Geolocator Position Class (All Fields)

Every location fix from the `geolocator` package contains:

| Field | Type | Description | Background? |
|---|---|---|---|
| `latitude` | double | WGS84 latitude (-90 to +90) | Yes |
| `longitude` | double | WGS84 longitude (-180 to +180) | Yes |
| `altitude` | double | Altitude in meters | Yes |
| `altitudeAccuracy` | double | Vertical accuracy in meters | Yes |
| `accuracy` | double | Horizontal accuracy in meters (radius of uncertainty) | Yes |
| `heading` | double | Direction of travel in degrees from true north | Yes |
| `headingAccuracy` | double | Heading uncertainty in degrees | Yes |
| `speed` | double | Speed in meters per second | Yes |
| `speedAccuracy` | double | Speed uncertainty in m/s | Yes |
| `timestamp` | DateTime | When the fix was determined | Yes |
| `floor` | int? | Building floor (if available) | Yes |
| `isMocked` | bool | Mock location detection (Android API 18+) | Yes |

**Recommendation:** Log ALL fields with every GPS point, not just lat/lon. The `accuracy`, `speed`, `speedAccuracy`, and `isMocked` fields are critical for diagnosing GPS quality issues.

### 4.2 DOP (Dilution of Precision) Metrics

| Metric | What It Means | How to Get |
|---|---|---|
| HDOP | Horizontal position precision degradation | Android: compute from satellite geometry via raw GNSS or NMEA $GPGSA sentence. iOS: not directly available. |
| VDOP | Vertical position precision degradation | Same as HDOP |
| PDOP | 3D position precision degradation (sqrt(HDOP^2 + VDOP^2)) | Computed |
| GDOP | Overall geometric degradation including time | Computed from full satellite geometry |

**Practical approach:** On Android, use `OnNmeaMessageListener` to capture $GPGSA sentences which contain PDOP, HDOP, and VDOP directly. On iOS, use `horizontalAccuracy` and `verticalAccuracy` as proxies (accuracy ~= HDOP * 4.7 meters typically).

### 4.3 Mock Location / GPS Spoofing Detection

| Platform | API | What It Detects |
|---|---|---|
| Android (API 18-30) | `Location.isFromMockProvider()` | Basic mock provider detection |
| Android (API 31+) | `Location.isMock()` | Updated mock detection |
| iOS (15+) | `CLLocation.sourceInformation.isSimulatedBySoftware` | Xcode simulation only (not third-party tools) |
| iOS (15+) | `CLLocation.sourceInformation.isProducedByAccessory` | External GPS accessory |

**Flutter packages:** `detect_fake_location`, `trust_location`, `safe_device`.

**Limitation:** On rooted Android devices with Magisk/Smali Patcher, `isMock` flag can be bypassed. For high-security needs, combine with device integrity checks (Play Integrity API).

### 4.4 Time to First Fix (TTFF)

| Platform | How to Get |
|---|---|
| Android | `GnssStatus.Callback.onFirstFix(ttffMillis)` -- exact milliseconds from GNSS engine start to first fix |
| iOS | No direct API. Measure time between `startUpdatingLocation()` and first `didUpdateLocations` callback with valid accuracy. |

### 4.5 GPS Chip / Provider Status

| Platform | Data | How to Get |
|---|---|---|
| Android | Which provider gave the fix (GPS, Network, Fused, Passive) | `Location.getProvider()` |
| Android | GNSS engine running status | `GnssStatus.Callback.onStarted()` / `onStopped()` |
| Android | Number of satellites visible vs. used in fix | `GnssStatus.getSatelliteCount()` + `usedInFix(i)` |
| Android | Per-satellite signal strength | `GnssStatus.getCn0DbHz(i)` |
| iOS | Location source | `CLLocation.sourceInformation` (iOS 15+) |
| iOS | Accuracy authorization | `CLLocationManager.accuracyAuthorization` (.fullAccuracy vs .reducedAccuracy) |

---

## 5. Crash Reporting Services for Flutter

### 5.1 Comparison Matrix

| Feature | Firebase Crashlytics | Sentry | BugSnag | Datadog RUM | Self-hosted (Supabase) |
|---|---|---|---|---|---|
| **Flutter SDK** | Yes (official) | Yes (official) | Yes | Yes | Custom |
| **Native crash capture** | Yes (iOS + Android) | Yes (iOS + Android) | Yes | Yes | Requires MetricKit + native handler |
| **Dart error capture** | Yes | Yes | Yes | Yes | Yes (via existing DiagnosticLogger) |
| **ANR detection** | Yes | Yes (Android, 5s default) | Yes | Yes | Custom watchdog thread |
| **App hang detection** | Yes | Yes (iOS) | Yes | Yes | Via MetricKit MXHangDiagnostic |
| **Breadcrumbs** | Yes (auto + manual) | Yes (auto + manual) | Yes | Yes | Manual only |
| **Device context** | Yes | Yes (battery, orientation, connectivity) | Yes | Yes | Via device_info_plus + manual |
| **Performance traces** | Via Firebase Performance | Yes (transactions, spans) | Yes | Yes (RUM) | Custom |
| **Offline storage** | Yes | Yes | Yes | Yes | Yes (existing SQLCipher) |
| **Symbolication** | Yes (dSYM upload) | Yes (dSYM + ProGuard) | Yes | Yes | Manual |
| **Grouping/dedup** | Automatic | Automatic + customizable | Automatic | Automatic | Custom |
| **Alerting** | Firebase console | Yes (email, Slack, PagerDuty) | Yes | Yes | Custom |
| **Open source** | No | Yes (self-hostable) | No | No | Yes |
| **Cost** | Free (unlimited) | Free tier (5k errors/mo) | Free tier (7.5k events/mo) | Paid | Infrastructure only |
| **CPU overhead** | ~0.9% | ~1% | ~1% | ~1% | Minimal (custom) |
| **Data ownership** | Google | Self-host option | BugSnag | Datadog | 100% yours |

### 5.2 Recommendation

**For maximum data capture with data ownership:** Hybrid approach:

1. **Keep the existing self-hosted DiagnosticLogger + Supabase sync** for all custom telemetry (GPS diagnostics, lifecycle events, thermal/battery state, network changes). This gives you 100% data ownership and custom querying.

2. **Add Sentry (self-hosted or cloud)** for native crash capture, symbolication, ANR/hang detection, breadcrumbs, and performance traces. Sentry is open-source and self-hostable (Docker, 32GB RAM recommended). It captures data that is extremely difficult to replicate:
   - Native iOS/Android crash symbolication
   - Automatic breadcrumb trail before crashes
   - ANR detection with stack traces
   - Release health tracking
   - Session replay (optional)

3. **Add MetricKit integration (iOS only)** via platform channel for Apple's first-party diagnostics that no third-party SDK can match:
   - `MXAppExitMetric` (all exit reasons)
   - `MXLocationActivityMetric` (GPS usage time)
   - `MXCellularConditionMetric` (signal quality)
   - `MXCrashDiagnostic` (second opinion on crashes)

### 5.3 Self-Hosted Sentry

Sentry can be fully self-hosted on your own infrastructure:
- Requires Docker 19.03.6+ and Docker Compose 2.32.2+
- Recommended: 32GB RAM (works with 16GB + 16GB swap)
- Equivalent to the Business plan without software limitations
- Custom DSN pointing to your server
- Full data ownership

Alternative: Use Sentry cloud free tier (5,000 errors/month) and keep detailed telemetry in Supabase.

---

## 6. Background Execution Diagnostics

### 6.1 iOS: Detecting System Kill vs. User Kill

| Method | What It Detects |
|---|---|
| **Persistent state flag** | Write "in_background" to UserDefaults on `didEnterBackground`. On next launch, if flag is "in_background", app was killed (either by user or system). If "in_foreground", it crashed while active. |
| **MetricKit MXAppExitMetric** | Breakdown by exit reason: `.normalAppExit`, `.abnormalAppExit`, `.memoryResourceLimit`, `.watchdogExit`, `.CPUResourceLimit`, `.suspendedWithLockedFile`, `.backgroundTaskAssertionTimeout`, `.badAccess`, `.illegalInstruction` |
| **applicationWillTerminate** | Only called if app is in foreground when terminated. NOT called if app is suspended first (which is the common case). |
| **Sentry session tracking** | Detects abnormal session terminations automatically. |

**Key distinction:** There is NO reliable API to distinguish user force-quit from system kill. The best approach is MetricKit `MXAppExitMetric` which categorizes exits by reason.

### 6.2 iOS: Background App Refresh Status

```swift
UIApplication.shared.backgroundRefreshStatus
// .available, .denied, .restricted
```

**Monitor changes:** `UIApplication.backgroundRefreshStatusDidChangeNotification`

**Key value:** If Background App Refresh is disabled, the app will NOT be woken for significant location changes or region monitoring events.

### 6.3 iOS: Significant Location Change Wake-ups

| Event | How to Detect |
|---|---|
| App launched due to location event | Check `launchOptions?[.location]` in `application(_:didFinishLaunchingWithOptions:)` |
| Significant location change | `CLLocationManager.startMonitoringSignificantLocationChanges()` delivers events to delegate |
| Region entry/exit | `didEnterRegion` / `didExitRegion` delegate callbacks |
| Visit detection | `didVisit` callback with CLVisit object (arrival/departure times, coordinates) |

**Limitation:** User force-quit prevents significant location change and visit monitoring wake-ups entirely.

### 6.4 iOS: Background Task Time Remaining

```swift
let remaining = UIApplication.shared.backgroundTimeRemaining
// Typically ~30 seconds after entering background
// Value is an estimate and changes dynamically
```

**How to use for diagnostics:** Log remaining time at entry to background and periodically during background work. Log when expiration handler fires (app is about to be suspended).

### 6.5 iOS: CLBackgroundActivitySession (iOS 17+)

Creates a visual indicator that keeps the app alive in the background for location updates. Replaces the old "blue bar" behavior.

### 6.6 Android: Doze Mode Entry/Exit Detection

```kotlin
// Register broadcast receiver for:
PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED

// Check current state:
val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
pm.isDeviceIdleMode      // Deep doze
pm.isLightDeviceIdleMode // Light doze (API 24+)
pm.isPowerSaveMode       // Battery saver
pm.isInteractive         // Screen on/off
```

**Background mode:** Broadcast receiver fires even in background (but may be deferred during deep doze unless whitelisted).

### 6.7 Android: Battery Optimization Whitelist Status

```kotlin
val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
val isWhitelisted = pm.isIgnoringBatteryOptimizations(packageName)
```

**Log this on every app start and shift start.** If the app is NOT whitelisted, doze mode will throttle location updates.

### 6.8 Android: Foreground Service Kill Detection

| Event | How to Detect |
|---|---|
| User swipe from recents | `onTaskRemoved()` in Service |
| System kill (low memory) | `onDestroy()` may or may not be called. On next launch, check if service was running before via shared preference flag. |
| OEM-specific kill | Same as system kill. Some OEMs (Xiaomi, Huawei, Samsung) aggressively kill foreground services. |
| Service restart | `START_STICKY` or `START_REDELIVER_INTENT` return value from `onStartCommand()` triggers automatic restart |

**Log these events:** Write a "service_alive" heartbeat timestamp to SharedPreferences every N seconds. On next service start, check if the gap exceeds expected interval -- if so, the service was killed.

---

## 7. Summary: Master Data Collection Matrix

### Data We Can Collect (Organized by Priority)

#### Priority 1: Critical for GPS Gap Diagnosis

| Data Point | iOS | Android | Flutter Package | Background? | Permission Needed |
|---|---|---|---|---|---|
| Location fix (all fields) | CLLocation | FusedLocation | `geolocator` | Yes | Location |
| Location accuracy (horizontal/vertical) | CLLocation | Location | `geolocator` | Yes | Location |
| Speed + speed accuracy | CLLocation | Location | `geolocator` | Yes | Location |
| Mock location flag | sourceInformation (iOS 15+) | isMock | `geolocator` | Yes | Location |
| Location pause/resume events | CLLocationManager delegate | N/A | Platform channel | Yes | Location |
| GPS error callbacks | didFailWithError | onProviderDisabled/Error | Platform channel | Yes | Location |
| Authorization/permission changes | locationManagerDidChangeAuthorization | Runtime permission callbacks | Platform channel | Yes | None |
| Foreground service lifecycle | N/A | onCreate/onDestroy/onTaskRemoved | Platform channel | Yes | Foreground service |
| App lifecycle state | UIApplication notifications | ProcessLifecycleOwner | `WidgetsBindingObserver` | Yes | None |
| Battery optimization whitelist | N/A | isIgnoringBatteryOptimizations | Platform channel | Yes | None |
| Doze mode state | N/A | isDeviceIdleMode | Platform channel | Yes | None |
| App standby bucket | N/A | getAppStandbyBucket | Platform channel | Yes | PACKAGE_USAGE_STATS |

#### Priority 2: Important for Crash Diagnosis

| Data Point | iOS | Android | Flutter Package | Background? | Permission Needed |
|---|---|---|---|---|---|
| Crash stack traces | MetricKit MXCrashDiagnostic | Native crash handler | Sentry / Crashlytics | N/A | None |
| ANR / hang stacks | MetricKit MXHangDiagnostic | Watchdog thread | Sentry | N/A | None |
| Uncaught Dart exceptions | FlutterError.onError | FlutterError.onError | Built-in | Yes | None |
| Async exceptions | runZonedGuarded | runZonedGuarded | Built-in | Yes | None |
| Platform channel errors | PlatformDispatcher.onError | PlatformDispatcher.onError | Built-in | Yes | None |
| Memory warnings/pressure | dispatch_source memory pressure | onTrimMemory/onLowMemory | Platform channel | Yes | None |
| Thermal state | ProcessInfo.thermalState | N/A (BatteryManager temp) | `thermal` / platform channel | Yes | None |
| App exit reasons | MXAppExitMetric | `ActivityManager.getHistoricalProcessExitReasons()` (API 30+) | Platform channel | N/A | None |

#### Priority 3: Valuable Context Data

| Data Point | iOS | Android | Flutter Package | Background? | Permission Needed |
|---|---|---|---|---|---|
| Battery level + state | UIDevice | BatteryManager | `battery_plus` | Yes | None |
| Battery temperature | N/A (private API) | EXTRA_TEMPERATURE | Platform channel | Yes | None |
| Network type + state | NWPathMonitor | ConnectivityManager | `connectivity_plus` | Yes | None |
| Network bandwidth | NWPath | NetworkCapabilities | Platform channel | Yes | None |
| Signal strength | NWPath | NetworkCapabilities.getSignalStrength | Platform channel | Yes | None |
| Satellite count + CN0 | N/A | GnssStatus.Callback | `raw_gnss_flutter` / platform channel | Yes | Location |
| TTFF | Manual timing | GnssStatus.onFirstFix | Platform channel | Yes | Location |
| HDOP/VDOP/PDOP | N/A (use accuracy proxy) | NMEA $GPGSA | Platform channel | Yes | Location |
| Motion activity | CMMotionActivityManager | ActivityRecognitionClient | `activity_recognition_flutter` | Yes | Motion/Activity |
| Device info | UIDevice / ProcessInfo | Build / DeviceInfo | `device_info_plus` | N/A | None |
| OS version | UIDevice.systemVersion | Build.VERSION | `device_info_plus` | N/A | None |
| Free memory | os_proc_available_memory | ActivityManager.getMemoryInfo | Platform channel | Yes | None |
| Disk space available | FileManager | StatFs | Platform channel | Yes | None |
| Background App Refresh status | UIApplication.backgroundRefreshStatus | N/A | Platform channel | N/A | None |
| Screen on/off state | UIApplication.isProtectedDataAvailable | PowerManager.isInteractive | Platform channel | Yes | None |
| CPU usage per metric interval | MXCPUMetric | N/A (dumpsys only) | Platform channel | N/A | None |
| Location usage time | MXLocationActivityMetric | N/A | Platform channel | N/A | None |
| Cellular condition quality | MXCellularConditionMetric | NetworkCapabilities | Platform channel | N/A | None |

### New EventCategory Values Needed

The existing `DiagnosticLogger` has categories: `gps`, `shift`, `sync`, `auth`, `permission`, `lifecycle`, `thermal`, `error`, `network`. To capture all the above data, consider adding:

| New Category | Purpose |
|---|---|
| `battery` | Battery level, state, temperature, optimization status |
| `memory` | Memory warnings, trim levels, pressure events |
| `satellite` | GNSS satellite count, CN0, TTFF, HDOP |
| `crash` | Native crash data from MetricKit/signal handlers |
| `service` | Foreground service lifecycle events |
| `doze` | Doze mode, standby bucket, power save mode |
| `motion` | CoreMotion/ActivityRecognition activity changes |
| `metrickit` | iOS MetricKit payload summaries |

---

## Sources

### iOS Crash and Diagnostic Data
- [Debug crashes in iOS using MetricKit](https://ohmyswift.com/blog/2025/05/09/debug-crashes-in-ios-using-metrickit/)
- [MetricKit | Apple Developer Documentation](https://developer.apple.com/documentation/MetricKit)
- [Monitoring app performance with MetricKit | Swift with Majid](https://swiftwithmajid.com/2025/12/09/monitoring-app-performance-with-metrickit/)
- [A Practical Guide to Apple's MetricKit](https://medium.com/@rajanTheSilentCompiler/a-practical-guide-to-apples-metrickit-stop-guessing-start-measuring-your-ios-app-s-health-5639db388e9c)
- [MetricKit in Production: What Apple Doesn't Document](https://medium.com/@mrhotfix/metrickit-in-production-what-apple-doesnt-document-and-why-you-still-need-crashlytics-sentry-2a3c9591ed05)
- [MXMetricPayload | Apple Developer Documentation](https://developer.apple.com/documentation/metrickit/mxmetricpayload)
- [MetricKit - NSHipster](https://nshipster.com/metrickit/)
- [MetricKit Internals | AppSpector](https://www.appspector.com/blog/metrickit-internals)

### OSLog and Logging
- [OSLog and Unified logging as recommended by Apple - SwiftLee](https://www.avanderlee.com/debugging/oslog-unified-logging/)
- [Debug with structured logging - WWDC23](https://developer.apple.com/videos/play/wwdc2023/10226/)
- [Fetching OSLog Messages in Swift](https://useyourloaf.com/blog/fetching-oslog-messages-in-swift/)

### iOS Lifecycle and Background
- [Determine if the App is terminated by the User or by iOS](https://developer.apple.com/forums/thread/97582)
- [How iOS Suspends and Wakes Apps](https://mohsinkhan845.medium.com/how-ios-suspends-and-wakes-apps-understanding-the-app-lifecycle-af56bc763f27)
- [beginBackgroundTask(expirationHandler:) | Apple Developer Documentation](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(expirationhandler:))
- [Extending your app's background execution time | Apple](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)
- [CLBackgroundActivitySession | Apple Developer Documentation](https://developer.apple.com/documentation/corelocation/clbackgroundactivitysession-3mzv3)
- [Handling location updates in the background | Apple](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background)

### iOS Location and Sensors
- [CLLocationManagerDelegate | Apple Developer Documentation](https://developer.apple.com/documentation/corelocation/cllocationmanagerdelegate)
- [CLLocation | Apple Developer Documentation](https://developer.apple.com/documentation/corelocation/cllocation)
- [CLLocationSourceInformation - isSimulatedBySoftware | Apple](https://developer.apple.com/documentation/corelocation/cllocationsourceinformation/issimulatedbysoftware)
- [ProcessInfo.ThermalState | Apple Developer Documentation](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum)
- [NWPathMonitor | Apple Developer Documentation](https://developer.apple.com/documentation/network/nwpathmonitor)
- [CMMotionActivity - NSHipster](https://nshipster.com/cmmotionactivity/)

### iOS Memory
- [DISPATCH_SOURCE_TYPE_MEMORYPRESSURE | Apple Documentation](https://developer.apple.com/documentation/dispatch/dispatch_source_type_memorypressure)
- [Respond to Low memory warnings using 4 different ways](https://pushpsenairekar.medium.com/respond-to-low-memory-warnings-using-4-different-ways-bb3da998735a)
- [didHaveMemoryPressure Flutter issue](https://github.com/flutter/flutter/issues/93176)

### Android Location and GNSS
- [GnssStatus | Android Developers](https://developer.android.com/reference/android/location/GnssStatus)
- [GnssStatus.Callback | Android Developers](https://developer.android.com/reference/android/location/GnssStatus.Callback)
- [Raw GNSS Measurements | Android Developers](https://developer.android.com/develop/sensors-and-location/sensors/gnss)
- [Fused Location Provider API | Google](https://developers.google.com/location-context/fused-location-provider)
- [LocationRequest | Google Play services](https://developers.google.com/android/reference/com/google/android/gms/location/LocationRequest)
- [A Technical Overview of Android's GPS System](https://apexpenn.github.io/2025/02/13/android-gps/)

### Android Power and Battery
- [Optimize for Doze and App Standby | Android Developers](https://developer.android.com/training/monitoring-device-state/doze-standby)
- [PowerManager | Android Developers](https://developer.android.com/reference/android/os/PowerManager)
- [App Standby Buckets | Android Developers](https://developer.android.com/topic/performance/appstandby)
- [BatteryManager | Android Developers](https://developer.android.com/reference/android/os/BatteryManager)
- [About background location and battery life | Android](https://developer.android.com/develop/sensors-and-location/location/battery)

### Android System
- [ActivityManager | Android Developers](https://developer.android.com/reference/android/app/ActivityManager)
- [Read network state | Android Developers](https://developer.android.com/develop/connectivity/network-ops/reading-network-state)
- [ConnectivityManager.NetworkCallback | Android Developers](https://developer.android.com/reference/android/net/ConnectivityManager.NetworkCallback)
- [ANRs | Android Developers](https://developer.android.com/topic/performance/vitals/anr)
- [StrictMode for ANR detection](https://riggaroo.dev/smooth-operator-using-strictmode-to-make-your-android-app-anr-free/)
- [Debug WorkManager | Android Developers](https://developer.android.com/develop/background-work/background-tasks/testing/persistent/debug)

### Flutter Error Handling
- [Handling errors in Flutter | flutter.dev](https://docs.flutter.dev/testing/errors)
- [runZonedGuarded function | Dart API](https://api.flutter.dev/flutter/dart-async/runZonedGuarded.html)
- [Error Handling in Flutter Using runZonedGuarded](https://www.dbestech.com/tutorials/error-handling-in-flutter-using-runzonedguarded-and-global-error-catching)
- [AppLifecycleState enum | Dart API](https://api.flutter.dev/flutter/dart-ui/AppLifecycleState.html)
- [AppLifecycleListener class | Dart API](https://api.flutter.dev/flutter/widgets/AppLifecycleListener-class.html)
- [WidgetsBindingObserver class | Dart API](https://api.flutter.dev/flutter/widgets/WidgetsBindingObserver-class.html)

### Flutter Packages
- [geolocator | pub.dev](https://pub.dev/packages/geolocator)
- [Position class | Dart API](https://pub.dev/documentation/geolocator_platform_interface/latest/geolocator_platform_interface/Position-class.html)
- [battery_plus | pub.dev](https://pub.dev/packages/battery_plus)
- [connectivity_plus | pub.dev](https://pub.dev/packages/connectivity_plus)
- [device_info_plus | pub.dev](https://pub.dev/packages/device_info_plus)
- [thermal | pub.dev](https://pub.dev/packages/thermal/example)
- [raw_gnss_flutter | pub.dev](https://pub.dev/packages/raw_gnss_flutter)
- [detect_fake_location | pub.dev](https://pub.dev/packages/detect_fake_location)

### Crash Reporting Services
- [Sentry Features for Flutter](https://docs.sentry.io/platforms/dart/guides/flutter/features/)
- [Sentry vs Crashlytics Comparison 2025](https://uxcam.com/blog/sentry-vs-crashlytics/)
- [Self-Hosted Sentry](https://develop.sentry.dev/self-hosted/)
- [Firebase Crashlytics](https://firebase.google.com/docs/crashlytics)
- [Customize crash reports for Flutter | Firebase Crashlytics](https://firebase.google.com/docs/crashlytics/flutter/customize-crash-reports)
- [Datadog Flutter Monitoring](https://docs.datadoghq.com/real_user_monitoring/application_monitoring/flutter/)
- [Sentry Breadcrumbs for Flutter](https://docs.sentry.io/platforms/flutter/enriching-events/breadcrumbs/)

### GPS Accuracy
- [GPS Accuracy: HDOP, PDOP, GDOP & Multipath](https://gisgeography.com/gps-accuracy-hdop-pdop-gdop-multipath/)
- [Flutter Security: Why isMockLocation Is Dead in 2026](https://dev.to/alex_g_aeeb05ba69eee8a4fd/flutter-security-why-ismocklocation-is-dead-in-2026-and-how-to-fix-it-2odn)

### Mock Location Detection
- [detect_fake_location | pub.dev](https://pub.dev/packages/detect_fake_location)
- [How to detect Mock location using isMocked property](https://github.com/Baseflow/flutter-geolocator/issues/675)
