# Android Unused App Killer Survival — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Prevent Samsung S9 (and similar Android devices) from killing the GPS foreground service when workers switch apps or lock the screen during an active shift.

**Architecture:** Three coordinated layers — (A) raise foreground notification importance so Samsung doesn't classify the service as killable; (B) make the OEM battery setup dialog mandatory/state-verified instead of one-time-skippable, and add PackageManagerCompat unused-app-restrictions check for Android 11+ devices; (C) add a native 60-second AlarmManager rescue watchdog in Kotlin that unconditionally restarts the FFT service if a shift is active, reducing the recovery gap from 5 minutes (WorkManager) to ~60 seconds.

**Tech Stack:** Flutter/Dart, Kotlin, flutter_foreground_task 9.0.0, flutter_riverpod 2.5.0, AlarmManager, PackageManagerCompat (AndroidX core-ktx), WorkManager (existing, not changed)

---

## Pre-flight: Verify AndroidX dependency

Open `gps_tracker/android/app/build.gradle`. Confirm `androidx.core:core-ktx` is listed at version >= 1.7.0 (either directly or via `implementation platform(...)`). If not present explicitly, add:

```gradle
implementation 'androidx.core:core-ktx:1.12.0'
```

Then run `flutter pub get` and `cd android && ./gradlew dependencies | grep core-ktx` to confirm it resolves.

---

### Task 1: Layer A — Raise foreground notification channel importance

**Files:**
- Modify: `gps_tracker/lib/features/tracking/services/background_tracking_service.dart:54-60`

**Why a new channel ID:** Android caches channel importance permanently per channel ID. Changing `channelImportance` on the existing `'gps_tracking_channel'` ID is silently ignored on existing installs. A new ID forces Android to create a fresh channel at `HIGH` importance.

**Step 1: Apply the three-line change**

In `background_tracking_service.dart`, find the `FlutterForegroundTask.init(...)` block (around line 53) and change these three values:

```dart
// BEFORE:
channelId: 'gps_tracking_channel',
channelImportance: NotificationChannelImportance.DEFAULT,
priority: NotificationPriority.DEFAULT,

// AFTER:
channelId: 'gps_tracking_channel_v2',
channelImportance: NotificationChannelImportance.HIGH,
priority: NotificationPriority.HIGH,
```

**Step 2: Verify the change compiles**

```bash
cd gps_tracker && flutter analyze lib/features/tracking/services/background_tracking_service.dart
```

Expected: no errors.

**Step 3: Manual test on Android device**

```bash
flutter run -d <android-device-id>
```

1. Clock in (or start tracking)
2. Press the Home button to background the app
3. Pull down the notification shade — the "Suivi de position actif" notification should be **visible with higher visual weight** (may appear above other notifications)
4. Wait 2 minutes — notification should still be present
5. Clock out

**Step 4: Commit**

```bash
cd gps_tracker
git add lib/features/tracking/services/background_tracking_service.dart
git commit -m "fix: raise foreground notification importance to HIGH (new channel v2)

Samsung treats DEFAULT-importance foreground service notifications as killable.
HIGH importance signals to OEM memory manager that this service must survive.
New channel ID required because Android caches importance per channel ID."
```

---

### Task 2: Layer B1 — Add PackageManagerCompat to native Kotlin

**Files:**
- Modify: `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/MainActivity.kt`

This adds two new method channel calls to detect and disable Android 11+ "unused app restrictions" (the `PackageManagerCompat` API). On Android 10 (S9), `getUnusedAppRestrictionsStatus()` returns `FEATURE_NOT_AVAILABLE` (1) — no action taken. This is purely future-proofing for Android 11+ workers.

**Step 1: Add the new imports to MainActivity.kt**

At the top of `MainActivity.kt`, add these imports after the existing `import` block:

```kotlin
import androidx.core.content.PackageManagerCompat
import androidx.core.content.IntentCompat
import androidx.core.content.ContextCompat
```

**Step 2: Add two new cases to the `gps_tracker/device_manufacturer` method channel**

In `MainActivity.kt`, find the `when (call.method)` block inside the `gps_tracker/device_manufacturer` channel (around line 27). Add these two cases **before** `else -> result.notImplemented()`:

```kotlin
"getUnusedAppRestrictionsStatus" -> {
    // PackageManagerCompat constants:
    // 0=ERROR, 1=FEATURE_NOT_AVAILABLE, 2=DISABLED,
    // 3=API_30_BACKPORT, 4=API_30, 5=API_31
    try {
        val future = PackageManagerCompat.getUnusedAppRestrictionsStatus(this)
        future.addListener(
            {
                try {
                    result.success(future.get())
                } catch (e: Exception) {
                    result.success(0) // ERROR — fail open
                }
            },
            ContextCompat.getMainExecutor(this)
        )
    } catch (e: Exception) {
        result.success(1) // FEATURE_NOT_AVAILABLE — fail open
    }
}
"openManageUnusedAppRestrictionsSettings" -> {
    try {
        val intent = IntentCompat.createManageUnusedAppRestrictionsIntent(
            this, packageName
        )
        startActivity(intent)
        result.success(true)
    } catch (e: Exception) {
        // Fall back to App Info page
        try {
            val fallback = android.content.Intent(
                android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS
            ).apply {
                data = android.net.Uri.fromParts("package", packageName, null)
                addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(fallback)
            result.success(true)
        } catch (_: Exception) {
            result.success(false)
        }
    }
}
```

**Step 3: Verify the Kotlin compiles**

```bash
cd gps_tracker/android && ./gradlew assembleDebug 2>&1 | tail -20
```

Expected: `BUILD SUCCESSFUL`

**Step 4: Commit**

```bash
cd gps_tracker
git add android/app/src/main/kotlin/ca/trilogis/gpstracker/MainActivity.kt
git commit -m "feat(android): add PackageManagerCompat unused app restrictions API

Adds getUnusedAppRestrictionsStatus() and openManageUnusedAppRestrictionsSettings()
to the device_manufacturer method channel. Returns FEATURE_NOT_AVAILABLE (1) on
Android <= 10 (e.g. Samsung S9) so no user action is prompted on older devices."
```

---

### Task 3: Layer B1 — Wire unused app restrictions into Dart permission guard

**Files:**
- Modify: `gps_tracker/lib/features/tracking/services/android_battery_health_service.dart`
- Modify: `gps_tracker/lib/features/tracking/models/permission_guard_status.dart`
- Modify: `gps_tracker/lib/features/tracking/models/permission_guard_state.dart`
- Modify: `gps_tracker/lib/features/tracking/providers/permission_guard_provider.dart`

**Step 1: Add methods to AndroidBatteryHealthService**

At the end of `android_battery_health_service.dart`, before the closing `}` of the class, add:

```dart
/// Unused app restrictions status constants (mirrors PackageManagerCompat):
/// 0=ERROR, 1=FEATURE_NOT_AVAILABLE, 2=DISABLED,
/// 3=API_30_BACKPORT, 4=API_30, 5=API_31
static Future<int> getUnusedAppRestrictionsStatus() async {
  if (!Platform.isAndroid) return 1; // FEATURE_NOT_AVAILABLE on iOS
  try {
    return await _channel.invokeMethod<int>('getUnusedAppRestrictionsStatus') ?? 1;
  } catch (_) {
    return 1; // Fail open
  }
}

static Future<bool> openManageUnusedAppRestrictionsSettings() async {
  if (!Platform.isAndroid) return false;
  try {
    return await _channel.invokeMethod<bool>('openManageUnusedAppRestrictionsSettings') ?? false;
  } catch (_) {
    return false;
  }
}

/// Returns true if unused app restrictions need user action.
/// Status 3 (API_30_BACKPORT), 4 (API_30), 5 (API_31) = restrictions active.
static bool unusedRestrictionsNeedAction(int status) {
  return status == 3 || status == 4 || status == 5;
}
```

**Step 2: Add new status to PermissionGuardStatus**

In `permission_guard_status.dart`, add one new value after `appStandbyRestricted`:

```dart
/// Unused app restrictions active (Android 11+) — permission auto-revoke / hibernation risk.
unusedAppRestrictionsActive,
```

**Step 3: Add field and logic to PermissionGuardState**

In `permission_guard_state.dart`:

a) Add field after `isAppStandbyRestricted`:
```dart
/// Whether Android 11+ unused app restrictions are active (auto-revoke / hibernation).
final bool isUnusedAppRestrictionsActive;
```

b) Update the constructor to include the new field:
```dart
const PermissionGuardState({
  // ... existing fields ...
  required this.isUnusedAppRestrictionsActive,  // ADD THIS
  // ...
});
```

c) Update `PermissionGuardState.initial()`:
```dart
isUnusedAppRestrictionsActive: false,
```

d) In the `status` getter, add the new check **after** `isAppStandbyRestricted` and **before** `isPreciseLocationEnabled`:
```dart
if (isUnusedAppRestrictionsActive) {
  return PermissionGuardStatus.unusedAppRestrictionsActive;
}
```

e) In `shouldBlockClockIn`, add:
```dart
bool get shouldBlockClockIn {
  return deviceStatus == DeviceLocationStatus.disabled ||
      !permission.hasAnyPermission ||
      permission.level == LocationPermissionLevel.whileInUse ||
      !isBatteryOptimizationDisabled ||
      isAppStandbyRestricted ||
      isUnusedAppRestrictionsActive ||  // ADD THIS
      !isPreciseLocationEnabled;
}
```

f) Update `copyWith` to include the new field:
```dart
PermissionGuardState copyWith({
  // ... existing params ...
  bool? isUnusedAppRestrictionsActive,  // ADD THIS
}) => PermissionGuardState(
  // ... existing fields ...
  isUnusedAppRestrictionsActive: isUnusedAppRestrictionsActive ?? this.isUnusedAppRestrictionsActive,
);
```

**Step 4: Add the check in PermissionGuardNotifier.checkStatus()**

In `permission_guard_provider.dart`, inside `checkStatus()`, after the `standbyBucket` check (around line 57), add:

```dart
// Check unused app restrictions status (Android 11+)
bool unusedAppRestrictionsActive = false;
if (Platform.isAndroid) {
  final unusedStatus =
      await AndroidBatteryHealthService.getUnusedAppRestrictionsStatus();
  unusedAppRestrictionsActive =
      AndroidBatteryHealthService.unusedRestrictionsNeedAction(unusedStatus);
}
```

Then in the `applyState()` closure, add the new field:
```dart
state = state.copyWith(
  // ... existing fields ...
  isUnusedAppRestrictionsActive: unusedAppRestrictionsActive,  // ADD THIS
  lastChecked: DateTime.now(),
);
```

Also add a log entry alongside the `standbyBucket.isRestricted` log (after line 95):
```dart
if (unusedAppRestrictionsActive) {
  _logger?.permission(
    Severity.warn,
    'Android unused app restrictions active',
    metadata: {'platform': 'android'},
  );
}
```

**Step 5: Add action handler in PermissionGuardNotifier**

After `requestBatteryOptimization()` method, add:

```dart
/// Opens unused app restrictions settings (Android 11+).
Future<void> openUnusedAppRestrictionsSettings() async {
  if (!Platform.isAndroid) return;
  await AndroidBatteryHealthService.openManageUnusedAppRestrictionsSettings();
  await checkStatus();
}
```

**Step 6: Wire into the banner widget**

In `lib/features/tracking/widgets/permission_status_banner.dart`, add a case for `unusedAppRestrictionsActive` in the `_BannerConfig` switch (follow the same pattern as `appStandbyRestricted`):

```dart
PermissionGuardStatus.unusedAppRestrictionsActive => _BannerConfig(
  backgroundColor: Theme.of(context).colorScheme.errorContainer,
  iconColor: Theme.of(context).colorScheme.error,
  icon: Icons.battery_alert,
  title: 'Restrictions d\'application actives',
  subtitle: 'Android peut révoquer les permissions. Désactivez les restrictions.',
  actionLabel: 'Corriger',
  canDismiss: false,
),
```

And in the action handler:
```dart
PermissionGuardStatus.unusedAppRestrictionsActive =>
  ref.read(permissionGuardProvider.notifier).openUnusedAppRestrictionsSettings(),
```

**Step 7: Verify compile**

```bash
cd gps_tracker && flutter analyze lib/features/tracking/
```

Expected: no errors.

**Step 8: Commit**

```bash
git add lib/features/tracking/services/android_battery_health_service.dart \
        lib/features/tracking/models/permission_guard_status.dart \
        lib/features/tracking/models/permission_guard_state.dart \
        lib/features/tracking/providers/permission_guard_provider.dart \
        lib/features/tracking/widgets/permission_status_banner.dart
git commit -m "feat: add unused app restrictions check to permission guard (Android 11+)

Detects API_30/API_31 unused app restriction state via PackageManagerCompat.
Blocks clock-in and shows banner if restrictions are active. Has no effect on
Android <= 10 (returns FEATURE_NOT_AVAILABLE, no action taken)."
```

---

### Task 4: Layer B2 — Make OEM battery guide mandatory (state-verified)

**Files:**
- Modify: `gps_tracker/lib/features/tracking/widgets/oem_battery_guide_dialog.dart`

**The problem:** `oem_setup_completed` flag is set once and never re-checked against actual state. Workers skip or ignore the dialog. The fix: check actual battery optimization state on every display trigger, remove the "Plus tard" (skip) button, and verify state when worker taps "C'est fait".

**Step 1: Convert to StatefulWidget**

Replace the class declaration and build structure. The full new file:

```dart
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:url_launcher/url_launcher.dart';

/// OEM-specific battery optimization guide dialog (Android only).
///
/// Shown as a mandatory (non-dismissible) dialog when OEM battery killers
/// are detected as still active. Workers cannot proceed until battery
/// optimization is confirmed as disabled.
class OemBatteryGuideDialog extends StatefulWidget {
  final String manufacturer;

  const OemBatteryGuideDialog({required this.manufacturer, super.key});

  static const _channel = MethodChannel('gps_tracker/device_manufacturer');

  static const _problematicOems = {
    'samsung', 'xiaomi', 'huawei', 'honor', 'oneplus', 'oppo', 'realme',
  };

  /// Show the OEM guide if:
  /// - Device is a known problematic OEM (Android only)
  /// - AND battery optimization is still active (actual state check)
  ///
  /// Pass [force] = true to show even if already fixed (e.g. from settings screen).
  static Future<void> showIfNeeded(
    BuildContext context, {
    bool force = false,
  }) async {
    if (!Platform.isAndroid) return;

    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final manufacturer = androidInfo.manufacturer.lowercase();
    if (!_problematicOems.contains(manufacturer)) return;

    // Check actual state — don't rely on the one-time flag
    final batteryOptDisabled =
        await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (batteryOptDisabled && !force) return;

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false, // Mandatory — no tap-outside dismiss
      builder: (_) => OemBatteryGuideDialog(manufacturer: manufacturer),
    );
  }

  @override
  State<OemBatteryGuideDialog> createState() => _OemBatteryGuideDialogState();
}

class _OemBatteryGuideDialogState extends State<OemBatteryGuideDialog> {
  bool _hasOpenedSettings = false;
  bool _showNotFixedMessage = false;
  bool _isChecking = false;

  String get _title {
    switch (widget.manufacturer) {
      case 'samsung': return 'Configuration Samsung';
      case 'xiaomi': return 'Configuration Xiaomi';
      case 'huawei': return 'Configuration Huawei';
      case 'honor': return 'Configuration Honor';
      case 'oneplus': return 'Configuration OnePlus';
      case 'oppo': return 'Configuration Oppo';
      case 'realme': return 'Configuration Realme';
      default: return 'Configuration batterie';
    }
  }

  List<String> get _steps {
    switch (widget.manufacturer) {
      case 'samsung':
        return [
          'Ouvrez Paramètres > Batterie > Limites d\'utilisation en arrière-plan',
          'Appuyez "Applications en veille prolongée" et retirez Tri-Logis Time',
          'Appuyez "Applications jamais en veille" et ajoutez Tri-Logis Time',
          'Revenez ici et appuyez "C\'est fait"',
        ];
      case 'xiaomi':
        return [
          'Ouvrez Paramètres > Applications > Gérer les applications',
          'Trouvez Tri-Logis Time et activez "Démarrage automatique"',
          'Appuyez Économie de batterie > Aucune restriction',
          'Revenez ici et appuyez "C\'est fait"',
        ];
      case 'huawei':
      case 'honor':
        return [
          'Ouvrez Paramètres > Batterie > Lancement d\'applications',
          'Trouvez Tri-Logis Time et désactivez la gestion automatique',
          'Activez : Lancement auto, Lancement secondaire, Exécution en arrière-plan',
          'Revenez ici et appuyez "C\'est fait"',
        ];
      case 'oneplus':
      case 'oppo':
      case 'realme':
        return [
          'Ouvrez Paramètres > Batterie > Optimisation de la batterie',
          'Trouvez Tri-Logis Time et sélectionnez "Ne pas optimiser"',
          'Activez "Autoriser l\'activité en arrière-plan"',
          'Revenez ici et appuyez "C\'est fait"',
        ];
      default:
        return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.phone_android, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(_title)),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Votre appareil peut interrompre le suivi GPS en arrière-plan. '
              'Ces étapes sont requises pour un suivi continu :',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            ...List.generate(_steps.length, (i) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          '${i + 1}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onPrimary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _steps[i],
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              );
            }),
            if (_showNotFixedMessage) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber,
                        color: theme.colorScheme.error, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'L\'optimisation batterie est encore activée. '
                        'Vérifiez les étapes et réessayez.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            Center(
              child: TextButton.icon(
                onPressed: () => _openDontKillMyApp(),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('En savoir plus'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: _isChecking ? null : () => _openOemSettings(),
          child: const Text('Ouvrir les paramètres'),
        ),
        FilledButton(
          onPressed: _isChecking ? null : () => _confirmDone(context),
          child: _isChecking
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text("C'est fait"),
        ),
      ],
    );
  }

  Future<void> _openOemSettings() async {
    setState(() => _hasOpenedSettings = true);
    try {
      await OemBatteryGuideDialog._channel.invokeMethod<bool>(
        'openOemBatterySettings',
        {'manufacturer': widget.manufacturer},
      );
    } catch (_) {}
  }

  Future<void> _openDontKillMyApp() async {
    final url = Uri.parse('https://dontkillmyapp.com/${widget.manufacturer}');
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _confirmDone(BuildContext context) async {
    setState(() {
      _isChecking = true;
      _showNotFixedMessage = false;
    });

    final isFixed = await FlutterForegroundTask.isIgnoringBatteryOptimizations;

    if (!mounted) return;

    if (!isFixed) {
      setState(() {
        _isChecking = false;
        _showNotFixedMessage = true;
      });
      return;
    }

    // Confirmed fixed — persist and close
    await FlutterForegroundTask.saveData(key: 'oem_setup_completed', value: true);
    await FlutterForegroundTask.saveData(
        key: 'oem_setup_manufacturer', value: widget.manufacturer);

    if (mounted) Navigator.of(context).pop();
  }
}

extension on String {
  String lowercase() => toLowerCase();
}
```

**Step 2: Verify compile**

```bash
cd gps_tracker && flutter analyze lib/features/tracking/widgets/oem_battery_guide_dialog.dart
```

Expected: no errors.

**Step 3: Manual test**

1. Enable battery optimization for the app: `adb shell dumpsys deviceidle whitelist -ca.trilogis.gpstracker`
2. Run app on Samsung device (or emulator with `ro.product.manufacturer=samsung`)
3. Try to trigger `OemBatteryGuideDialog.showIfNeeded(context)`
4. Verify:
   - Dialog appears without a "Plus tard" button
   - Tapping "C'est fait" without fixing shows the red error message
   - After disabling battery optimization and tapping "C'est fait", dialog closes

**Step 4: Commit**

```bash
git add lib/features/tracking/widgets/oem_battery_guide_dialog.dart
git commit -m "fix: make OEM battery guide mandatory with state verification

Removes one-time flag gate in favor of actual battery optimization state check.
Dialog is now non-dismissible (no 'Plus tard' button, barrierDismissible=false).
'C'est fait' verifies actual state before closing — workers cannot proceed
until battery optimization is confirmed disabled on their OEM device."
```

---

### Task 5: Layer C — Create native AlarmManager rescue receiver

**Files:**
- Create: `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/TrackingRescueReceiver.kt`
- Modify: `gps_tracker/android/app/src/main/AndroidManifest.xml`

**Step 1: Create TrackingRescueReceiver.kt**

```kotlin
package ca.trilogis.gpstracker

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import android.util.Log

/**
 * BroadcastReceiver that forms a 60-second AlarmManager chain to rescue
 * the flutter_foreground_task (FFT) GPS tracking service if Android kills it.
 *
 * Chain logic:
 *   startAlarmChain() → alarm fires → onReceive() → restart FFT service
 *                                                 → startAlarmChain() (next alarm)
 *
 * The chain stops naturally when shift_id is cleared (clock-out), or explicitly
 * via stopAlarmChain() called from Flutter.
 */
class TrackingRescueReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "TrackingRescueReceiver"
        const val ACTION_RESCUE_ALARM = "ca.trilogis.gpstracker.ACTION_RESCUE_ALARM"

        // SharedPreferences keys (same as TrackingBootReceiver)
        private const val FGT_PREFS = "FlutterSharedPreferences"
        private const val KEY_SHIFT_ID =
            "flutter.com.pravera.flutter_foreground_task.prefs.shift_id"

        private const val RESCUE_INTERVAL_MS = 60_000L
        private const val REQUEST_CODE = 9877 // Must not conflict with other PendingIntents

        /**
         * Start the 60-second rescue alarm chain. Call this when tracking begins.
         * Safe to call multiple times — cancels and re-schedules.
         */
        fun startAlarmChain(context: Context) {
            val alarmManager =
                context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pendingIntent = buildPendingIntent(context) ?: return
            val triggerTime = SystemClock.elapsedRealtime() + RESCUE_INTERVAL_MS

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                if (!alarmManager.canScheduleExactAlarms()) {
                    // Android 12+ without SCHEDULE_EXACT_ALARM permission:
                    // use inexact alarm (~5-15 min delay). WorkManager 5-min watchdog covers the gap.
                    alarmManager.setAndAllowWhileIdle(
                        AlarmManager.ELAPSED_REALTIME_WAKEUP,
                        triggerTime,
                        pendingIntent
                    )
                    Log.d(TAG, "Inexact rescue alarm scheduled (no exact alarm permission)")
                    return
                }
            }

            alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                triggerTime,
                pendingIntent
            )
            Log.d(TAG, "Exact rescue alarm scheduled in ${RESCUE_INTERVAL_MS / 1000}s")
        }

        /**
         * Cancel the rescue alarm chain. Call this when tracking ends.
         */
        fun stopAlarmChain(context: Context) {
            val alarmManager =
                context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pendingIntent = buildPendingIntent(context) ?: return
            alarmManager.cancel(pendingIntent)
            pendingIntent.cancel()
            Log.d(TAG, "Rescue alarm chain stopped")
        }

        private fun buildPendingIntent(context: Context): PendingIntent? {
            val intent = Intent(context, TrackingRescueReceiver::class.java).apply {
                action = ACTION_RESCUE_ALARM
            }
            return PendingIntent.getBroadcast(
                context,
                REQUEST_CODE,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null || intent?.action != ACTION_RESCUE_ALARM) return

        // Read shift_id from FFT's SharedPreferences
        val prefs = context.getSharedPreferences(FGT_PREFS, Context.MODE_PRIVATE)
        val shiftId = prefs.getString(KEY_SHIFT_ID, null)

        if (shiftId.isNullOrEmpty()) {
            // No active shift — stop the chain naturally (don't reschedule)
            Log.d(TAG, "Rescue alarm fired but no active shift — chain stopped")
            return
        }

        Log.d(TAG, "Rescue alarm fired, shift $shiftId active — restarting FFT service")

        // Unconditionally start the FFT foreground service.
        // If it's already running, this is harmless (just calls onStartCommand() again).
        // If it was killed, this restarts it with its previously saved notification/data state.
        try {
            val serviceIntent = Intent().apply {
                setClassName(
                    context.packageName,
                    "com.pravera.flutter_foreground_task.service.ForegroundService"
                )
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
            Log.i(TAG, "FFT service restart attempted for shift $shiftId")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to restart FFT service: ${e.message}")
        }

        // Schedule the next alarm — continue the chain
        startAlarmChain(context)
    }
}
```

**Step 2: Register the receiver in AndroidManifest.xml**

In `AndroidManifest.xml`, after the `TrackingBootReceiver` receiver block (around line 105), add:

```xml
<!-- 60-second rescue watchdog for GPS tracking service -->
<receiver
    android:name=".TrackingRescueReceiver"
    android:exported="false" />
```

**Step 3: Verify Kotlin compiles**

```bash
cd gps_tracker/android && ./gradlew assembleDebug 2>&1 | tail -20
```

Expected: `BUILD SUCCESSFUL`

**Step 4: Commit**

```bash
cd gps_tracker
git add android/app/src/main/kotlin/ca/trilogis/gpstracker/TrackingRescueReceiver.kt \
        android/app/src/main/AndroidManifest.xml
git commit -m "feat(android): add TrackingRescueReceiver 60s AlarmManager watchdog

Creates a self-rescheduling BroadcastReceiver that fires every 60s during active
shifts and unconditionally calls startForegroundService() on the FFT service.
Reduces recovery gap from 5min (WorkManager) to ~60s when Samsung kills the service.
Falls back to inexact alarm on Android 12+ without SCHEDULE_EXACT_ALARM permission."
```

---

### Task 6: Layer C — Expose start/stop rescue alarms via method channel

**Files:**
- Modify: `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/MainActivity.kt`

**Step 1: Add two new cases to the device_manufacturer method channel**

In `MainActivity.kt`, add these two cases **before** `else -> result.notImplemented()`:

```kotlin
"startRescueAlarms" -> {
    val shiftId = call.argument<String>("shiftId") ?: ""
    TrackingRescueReceiver.startAlarmChain(this)
    android.util.Log.d("MainActivity", "Rescue alarm chain started for shift $shiftId")
    result.success(true)
}
"stopRescueAlarms" -> {
    TrackingRescueReceiver.stopAlarmChain(this)
    android.util.Log.d("MainActivity", "Rescue alarm chain stopped")
    result.success(true)
}
```

**Step 2: Verify Kotlin compiles**

```bash
cd gps_tracker/android && ./gradlew assembleDebug 2>&1 | tail -20
```

Expected: `BUILD SUCCESSFUL`

**Step 3: Commit**

```bash
cd gps_tracker
git add android/app/src/main/kotlin/ca/trilogis/gpstracker/MainActivity.kt
git commit -m "feat(android): expose rescue alarm start/stop via method channel

Adds startRescueAlarms(shiftId) and stopRescueAlarms() to the
gps_tracker/device_manufacturer method channel so Flutter can control
the AlarmManager rescue chain lifecycle."
```

---

### Task 7: Layer C — Wire rescue alarms into Flutter tracking service

**Files:**
- Modify: `gps_tracker/lib/features/tracking/services/android_battery_health_service.dart`
- Modify: `gps_tracker/lib/features/tracking/services/background_tracking_service.dart`

**Step 1: Add Dart methods to AndroidBatteryHealthService**

At the end of `android_battery_health_service.dart`, before the closing `}`:

```dart
/// Start the 60-second AlarmManager rescue watchdog for an active shift.
/// No-op on iOS. Fire-and-forget.
static Future<void> startRescueAlarms(String shiftId) async {
  if (!Platform.isAndroid) return;
  try {
    await _channel.invokeMethod<bool>(
      'startRescueAlarms',
      {'shiftId': shiftId},
    );
  } catch (_) {
    // Best-effort — WorkManager watchdog is the fallback
  }
}

/// Stop the AlarmManager rescue watchdog. Call when tracking ends.
/// No-op on iOS. Fire-and-forget.
static Future<void> stopRescueAlarms() async {
  if (!Platform.isAndroid) return;
  try {
    await _channel.invokeMethod<bool>('stopRescueAlarms');
  } catch (_) {}
}
```

**Step 2: Call startRescueAlarms after successful tracking start**

In `background_tracking_service.dart`, find the `if (result is ServiceRequestSuccess)` block (around line 177). Add the rescue alarm call **before** `return const TrackingSuccess()`:

```dart
if (result is ServiceRequestSuccess) {
  // Start the 60-second native rescue watchdog (Android only)
  if (Platform.isAndroid) {
    await AndroidBatteryHealthService.startRescueAlarms(shiftId);
  }
  _logger?.gps(
    Severity.info,
    'Foreground service start success',
    metadata: {'shift_id': shiftId, 'attempt': attempt},
  );
  return const TrackingSuccess();
}
```

**Step 3: Call stopRescueAlarms in stopTracking()**

In `background_tracking_service.dart`, find `static Future<void> stopTracking() async {` (around line 217). Add the rescue alarm stop as the **first line** after the opening brace:

```dart
static Future<void> stopTracking() async {
  // Stop the native rescue watchdog before the service (order matters)
  if (Platform.isAndroid) {
    await AndroidBatteryHealthService.stopRescueAlarms();
  }
  await FlutterForegroundTask.stopService();
  // ... rest of existing removeData calls unchanged
```

**Step 4: Verify compile**

```bash
cd gps_tracker && flutter analyze lib/features/tracking/services/
```

Expected: no errors.

**Step 5: Run full analysis**

```bash
cd gps_tracker && flutter analyze lib/
```

Expected: no errors.

**Step 6: Manual integration test**

```bash
flutter run -d <android-device-id>
```

Test sequence:
1. Clock in → verify tracking notification appears
2. Check logcat: `adb logcat -s TrackingRescueReceiver` — should see no output yet
3. Wait 70 seconds — logcat should show: `Rescue alarm fired, shift <id> active — restarting FFT service`
4. Force-kill the FFT service: `adb shell am kill ca.trilogis.gpstracker`
5. Wait 70 seconds — verify service restarted: `adb shell dumpsys activity services | grep ForegroundService`
6. Clock out
7. Wait 70 seconds — logcat should show: `Rescue alarm fired but no active shift — chain stopped`
8. Verify no further logcat entries from TrackingRescueReceiver

**Step 7: Commit**

```bash
git add lib/features/tracking/services/android_battery_health_service.dart \
        lib/features/tracking/services/background_tracking_service.dart
git commit -m "feat: wire rescue alarm watchdog into tracking lifecycle

startRescueAlarms() called after successful FFT service start.
stopRescueAlarms() called before FFT service stop on clock-out.
The alarm chain self-terminates naturally if shift_id is cleared
(race condition safety: no ghost restarts after clock-out)."
```

---

## Final smoke test

```bash
cd gps_tracker
flutter build apk --debug
# Install on Samsung S9 (or Android 10 device)
adb install build/app/outputs/flutter-apk/app-debug.apk
```

Full test on device:
1. Open app → clock in → switch to another app → wait 3 minutes → verify GPS is still tracking (check Supabase for new gps_points rows)
2. Lock screen for 5 minutes → unlock → verify tracking still active (notification in shade)
3. Force-stop service via `adb shell am kill ca.trilogis.gpstracker` → wait 90s → verify notification reappears
4. Clock out → wait 2 minutes → verify service is stopped and no rescue alarms firing (`adb logcat -s TrackingRescueReceiver`)
5. On Android 11+ test device: confirm clock-in is blocked when unused app restrictions are active
