# Tasks: 018 - Background Tracking Resilience

**Input**: Design documents from `/specs/018-background-tracking-resilience/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: Not included — testing strategy is manual real-device validation (per spec.md).

**Organization**: Tasks are grouped by user story mapped from spec solution components:
- **US1**: iOS Background Tracking Survival (iOS-1 + iOS-2 + iOS-3) — P1, highest impact
- **US2**: Android OEM Battery Resilience (Android-1 + Android-2) — P2
- **US3**: Cross-Platform Thermal Adaptation (Cross-1) — P3

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)
- All paths relative to `gps_tracker/`

---

## Phase 1: Foundational — Native Platform Plugins

**Purpose**: Create the native iOS and Android method channel infrastructure that all user stories depend on.

**CRITICAL**: No user story work can begin until this phase is complete.

- [X] T001 Create native iOS plugin `BackgroundTaskPlugin.swift` in `gps_tracker/ios/Runner/BackgroundTaskPlugin.swift` — Implement `FlutterPlugin` with two method channels: (1) `gps_tracker/background_execution` handling `startBackgroundSession` (CLBackgroundActivitySession iOS 17+ with `#available` guard, strong reference), `stopBackgroundSession` (invalidate + nil), `isBackgroundSessionActive`, `beginBackgroundTask` (UIApplication.shared.beginBackgroundTask with named task + expiration handler that calls endBackgroundTask and invokes `onBackgroundTaskExpired` callback), `endBackgroundTask`; (2) `gps_tracker/thermal` handling `getThermalState` (ProcessInfo.processInfo.thermalState.rawValue) + NotificationCenter observer on `ProcessInfo.thermalStateDidChangeNotification` invoking `onThermalStateChanged` callback to Flutter. See `contracts/ios-background-execution.md` and `contracts/thermal-state.md` for full API.

- [X] T002 Register BackgroundTaskPlugin in `gps_tracker/ios/Runner/AppDelegate.swift` — Add `BackgroundTaskPlugin.register(with: self.registrar(forPlugin: "BackgroundTaskPlugin")!)` in `application(didFinishLaunchingWithOptions:)` alongside existing `SignificantLocationPlugin` registration.

- [X] T003 [P] Extend `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/MainActivity.kt` with two method channels: (1) `gps_tracker/device_manufacturer` handling `getManufacturer` (Build.MANUFACTURER.lowercase()) and `openOemBatterySettings` (try chain of manufacturer-specific intents per `contracts/android-oem-battery.md` — Samsung: lool/BatteryActivity → sm/SmartManagerDashBoardActivity → ACTION_BATTERY_SAVER_SETTINGS; Xiaomi: securitycenter/AutoStartManagementActivity → OP_AUTO_START; Huawei: systemmanager/StartupAppControlActivity → StartupNormalAppListActivity → ProtectActivity → HwPowerManagerActivity; OnePlus/Oppo/Realme: oneplus.security/ChainLaunchAppListActivity → coloros.safecenter/StartupAppListActivity variants; all with FLAG_ACTIVITY_NEW_TASK + try-catch, return bool); (2) `gps_tracker/thermal` MethodChannel handling `getThermalStatus` (PowerManager.getCurrentThermalStatus on API 29+, return 0 on older) + EventChannel `gps_tracker/thermal/stream` with PowerManager.addThermalStatusListener. See `contracts/android-oem-battery.md` and `contracts/thermal-state.md`.

**Checkpoint**: Native plugins registered and ready. Flutter method channels can now be called.

---

## Phase 2: US1 — iOS Background Tracking Survival (Priority: P1) — MVP

**Goal**: Fix the critical iOS bug where tracking dies after ~5 minutes by deferring SignificantLocationChanges activation and adding CLBackgroundActivitySession + beginBackgroundTask protection.

**Independent Test**: Clock in on a real iOS device → background the app → verify GPS tracking survives >10 minutes. Verify SLC does NOT activate at clock-in (only after 90s stream silence). Verify CLBackgroundActivitySession is created on iOS 17+ and no crash on iOS 16.

### Implementation for US1

- [X] T004 [P] [US1] Create `BackgroundExecutionService` Dart wrapper in `gps_tracker/lib/features/tracking/services/background_execution_service.dart` — Static utility class wrapping `MethodChannel('gps_tracker/background_execution')`. Methods: `startBackgroundSession()`, `stopBackgroundSession()`, `isBackgroundSessionActive()`, `beginBackgroundTask({String? name})`, `endBackgroundTask()`. All methods are no-ops on Android (guard with `Platform.isIOS`). Register callback handler for `onBackgroundTaskExpired` (log via debugPrint). All calls wrapped in try-catch with debugPrint on failure. See `contracts/ios-background-execution.md`.

- [X] T005 [US1] Modify `gps_tracker/lib/features/tracking/providers/tracking_provider.dart` — Deferred SLC activation + CLBackgroundActivitySession integration: (1) Remove `SignificantLocationService.startMonitoring()` call from `startTracking()`. (2) Add `bool _significantLocationActive = false` state field. (3) In the `gps_lost` handler: call `SignificantLocationService.startMonitoring()` and set `_significantLocationActive = true` (iOS only). (4) In the `gps_restored` handler: if `_significantLocationActive`, call `SignificantLocationService.stopMonitoring()` and reset flag. (5) In `stopTracking()`: if `_significantLocationActive`, stop SLC. (6) In `startTracking()` after successful service start: call `BackgroundExecutionService.startBackgroundSession()`. (7) In `stopTracking()`: call `BackgroundExecutionService.stopBackgroundSession()`. (8) In `_onWokenByLocationChange()`: call `BackgroundExecutionService.startBackgroundSession()` before restarting tracking. Per `research.md` R1/R2/R7 and `contracts/ios-background-execution.md`.

- [X] T006 [P] [US1] Modify `gps_tracker/lib/features/tracking/services/background_tracking_service.dart` — Add `beginBackgroundTask`/`endBackgroundTask` lifecycle hooks: (1) Add `WidgetsBindingObserver` mixin or use existing lifecycle detection. (2) On `AppLifecycleState.paused` during active tracking: call `BackgroundExecutionService.beginBackgroundTask(name: 'gps_tracking_background')`. (3) On `AppLifecycleState.resumed`: call `BackgroundExecutionService.endBackgroundTask()`. Per `research.md` R3 and `contracts/ios-background-execution.md`. Note: beginBackgroundTask is belt-and-suspenders — it protects the ~30s transition to background while CLBackgroundActivitySession provides long-term protection.

**Checkpoint**: iOS tracking should now survive >10 minutes in background. SLC only activates as fallback after stream death. This is the MVP — deploy and validate with Jessy Mainville's device.

---

## Phase 3: US2 — Android OEM Battery Resilience (Priority: P2)

**Goal**: Show OEM-specific battery optimization instructions for Samsung/Xiaomi/Huawei/OnePlus devices and auto-restart the foreground service when it dies during an active shift.

**Independent Test**: On a Samsung device, clock in → verify OEM guide appears with Samsung-specific instructions → tap "Ouvrir les paramètres" → verify correct settings screen opens. Force-kill the foreground service → reopen the app → verify tracking auto-restarts.

### Implementation for US2

- [X] T007 [P] [US2] Create `OemBatteryGuideDialog` widget in `gps_tracker/lib/features/tracking/widgets/oem_battery_guide_dialog.dart` — AlertDialog with OEM-specific French step-by-step instructions. Constructor takes `String manufacturer`. Static method `showIfNeeded(BuildContext context)`: guard Android only → check SharedPreferences `oem_setup_completed` → detect manufacturer via `device_info_plus` → check `_isProblematicOem()` (samsung, xiaomi, huawei, oneplus, oppo, realme) → show dialog. Content: OEM title + numbered steps per `contracts/android-oem-battery.md` (Samsung: "Applications jamais en veille", Xiaomi: "Démarrage automatique" + "Aucune restriction", Huawei: 3 toggles, OnePlus/Oppo/Realme: "Ne pas optimiser"). Actions: "Ouvrir les paramètres" button (calls `MethodChannel('gps_tracker/device_manufacturer').invokeMethod('openOemBatterySettings', {'manufacturer': manufacturer})`), "En savoir plus" link (url_launcher to `https://dontkillmyapp.com/$manufacturer`), "C'est fait" button (set `oem_setup_completed=true` + `oem_setup_manufacturer=manufacturer` in SharedPreferences, pop), "Plus tard" button (pop without persisting).

- [X] T008 [US2] Modify `gps_tracker/lib/features/tracking/widgets/battery_optimization_dialog.dart` — After the existing AOSP battery optimization dialog returns `true` (user allowed), chain to `OemBatteryGuideDialog.showIfNeeded(context)` to show OEM-specific instructions if applicable. Import `oem_battery_guide_dialog.dart`.

- [X] T009 [US2] Modify `gps_tracker/lib/features/tracking/providers/tracking_provider.dart` — Two additions: (1) **Foreground service resume check**: When app returns to foreground (detect via existing lifecycle handling or add `WidgetsBindingObserver`), if there is an active shift, check `await FlutterForegroundTask.isRunningService`. If service is dead: log the event, call `startTracking()` to auto-restart (safe in foreground context on Android 12+), add `_foregroundServiceDied = true` flag. (2) **OEM guide re-trigger**: When `gps_lost` signal is received on Android and `_foregroundServiceDied` was detected, mark that OEM guide should re-show on next foreground if `oem_setup_completed` is false (check SharedPreferences).

**Checkpoint**: Android employees on Samsung/Xiaomi/Huawei devices should see OEM-specific setup instructions. Foreground service auto-restarts when user reopens the app after OEM battery kill.

---

## Phase 4: US3 — Cross-Platform Thermal Adaptation (Priority: P3)

**Goal**: Proactively reduce GPS tracking frequency when the device overheats to prevent the OS from killing the app as thermal mitigation.

**Independent Test**: Use Xcode Thermal State simulation (Debug → Simulate Thermal State) to change thermal state → verify GPS capture interval changes from 60s to 120s (elevated) or 300s (critical). On Android API 29+, verify thermal status stream delivers updates.

### Implementation for US3

- [X] T010 [P] [US3] Create `ThermalStateService` in `gps_tracker/lib/features/tracking/services/thermal_state_service.dart` — Define `ThermalLevel` enum (`normal`, `elevated`, `critical`). Static methods: `getCurrentLevel()` (calls `MethodChannel('gps_tracker/thermal').invokeMethod('getThermalState'/'getThermalStatus')` based on platform, maps to ThermalLevel per `contracts/thermal-state.md` platform mapping table), `Stream<ThermalLevel> get levelStream` (iOS: listen for `onThermalStateChanged` callbacks via method channel handler; Android: `EventChannel('gps_tracker/thermal/stream').receiveBroadcastStream()` mapped to ThermalLevel). Fail-open: any error returns `ThermalLevel.normal`. Unsupported platforms/versions emit single `normal`.

- [X] T011 [US3] Modify `gps_tracker/lib/features/tracking/providers/tracking_provider.dart` — Thermal adaptation integration: (1) Add `ThermalLevel _currentThermalLevel = ThermalLevel.normal` field and `StreamSubscription? _thermalSubscription`. (2) In `startTracking()` after service start: subscribe to `ThermalStateService.levelStream`, on level change call `_applyThermalConfig(level)`. (3) `_applyThermalConfig(ThermalLevel level)`: map level to intervals (normal: active=60s/stationary=300s, elevated: 120s/600s, critical: 300s/900s) and send `updateConfig` command to background handler via `FlutterForegroundTask.sendDataToTask()` with the existing config format. (4) In `stopTracking()`: cancel `_thermalSubscription`, reset `_currentThermalLevel = normal`. Per `contracts/thermal-state.md` GPS adaptation config table.

**Checkpoint**: GPS tracking adapts to device thermal state on both platforms. Thermal stress no longer causes app termination.

---

## Phase 5: Polish & Cross-Cutting Concerns

**Purpose**: Verification and cleanup across all user stories.

- [X] T012 Run `flutter analyze` in `gps_tracker/` to verify no lint issues from all changes
- [X] T013 Verify all method channel names match between native (Swift/Kotlin) and Dart services — cross-reference `gps_tracker/background_execution`, `gps_tracker/thermal`, `gps_tracker/thermal/stream`, `gps_tracker/device_manufacturer`
- [X] T014 Validate regression: clock-in/clock-out flow unchanged, GPS points captured at expected intervals, SLC still relaunches app after true termination

---

## Dependencies & Execution Order

### Phase Dependencies

- **Foundational (Phase 1)**: No dependencies — start immediately
  - T001 → T002 (sequential: must create plugin before registering)
  - T003 is parallel with T001+T002 (different platform)
- **US1 (Phase 2)**: Depends on Phase 1 completion (T002 specifically for iOS)
  - T004 can start once Phase 1 is complete
  - T005 depends on T004 (needs BackgroundExecutionService)
  - T006 depends on T004 (needs BackgroundExecutionService), parallel with T005 (different files)
- **US2 (Phase 3)**: Depends on Phase 1 (T003 for Android method channels)
  - T007 can start once T003 is complete (needs OEM method channel)
  - T008 depends on T007 (needs OemBatteryGuideDialog)
  - T009 depends on T007 (references OEM guide)
- **US3 (Phase 4)**: Depends on Phase 1 (both T002 for iOS thermal + T003 for Android thermal)
  - T010 can start once Phase 1 is complete
  - T011 depends on T010 (needs ThermalStateService)
- **Polish (Phase 5)**: Depends on all previous phases

### User Story Independence

- **US1 (P1)**: Fully independent — iOS-only changes to tracking_provider.dart + background_tracking_service.dart
- **US2 (P2)**: Fully independent — Android-only dialog + tracking_provider.dart FGS resume check
- **US3 (P3)**: Fully independent — cross-platform thermal service + tracking_provider.dart config update

Note: US1, US2, and US3 all modify `tracking_provider.dart` but touch different code paths (SLC/session, FGS resume/OEM trigger, thermal subscription). They must be implemented sequentially in priority order to avoid merge conflicts.

### Parallel Opportunities

```
Phase 1 (Foundational):
  T001 → T002          (sequential — iOS)
  T003                  (parallel with T001+T002 — Android)

Phase 2 (US1) — after Phase 1:
  T004                  (BackgroundExecutionService)
  T005 + T006           (parallel after T004 — different files)

Phase 3 (US2) — after US1:
  T007                  (OemBatteryGuideDialog)
  T008 + T009           (after T007 — T008 and T009 touch different files, can be parallel)

Phase 4 (US3) — after US2:
  T010                  (ThermalStateService)
  T011                  (after T010)
```

---

## Implementation Strategy

### MVP First (US1 Only — iOS Fix)

1. Complete Phase 1: Foundational native plugins
2. Complete Phase 2: US1 — iOS Background Tracking Survival
3. **STOP and DEPLOY**: This fixes the critical Jessy Mainville bug and all similar iOS suspension issues
4. Monitor `auto_zombie_cleanup` rate for improvement

### Incremental Delivery

1. Phase 1 (Foundational) → Native plugins ready
2. Phase 2 (US1) → iOS tracking fixed → **Deploy to TestFlight** — immediate value
3. Phase 3 (US2) → Android OEM resilience → **Deploy to both stores** — Samsung/Xiaomi users protected
4. Phase 4 (US3) → Thermal adaptation → **Deploy** — thermal kill prevention
5. Phase 5 (Polish) → Verification pass

### Critical Path

```
T001 → T002 → T004 → T005 → (MVP deployable)
                   ↘ T006 (parallel with T005)
```

The fastest path to fixing the active iOS bug is 5 tasks: T001 → T002 → T004 → T005 + T006.

---

## Notes

- [P] tasks = different files, no dependencies on incomplete tasks in the same phase
- All tracking_provider.dart modifications are sequential across stories to avoid conflicts
- No database migrations needed — all changes are client-side
- No new Flutter dependencies needed — uses existing device_info_plus, shared_preferences, url_launcher
- Testing is manual on real devices per spec.md testing strategy
- All native method channel calls are fail-open (errors logged, tracking continues)
