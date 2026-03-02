# Android Background Tracking Resilience — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Eliminate GPS tracking gaps on Samsung/OEM Android devices by hardening the foreground service notification, making the OEM battery setup dialog mandatory and state-verified, adding a native 60-second AlarmManager rescue watchdog, and surfacing battery health issues visually near the clock button.

**Architecture:** Ten tasks across four layers — (A) notification importance upgrade, (B) mandatory OEM setup enforcement + server tracking, (UX) visual signals near the clock button, (C) native AlarmManager self-chaining rescue watchdog. Each task is independently committable. Tasks within a layer may be parallel; cross-layer dependencies are noted.

**Merges:** `2026-03-02-android-unused-app-killer-plan.md` (7 tasks) + `2026-03-02-background-tracking-reliability.md` (5 tasks). BTR Task 1 (`forceOemGuide` parameter) is dropped — superseded by the Layer B2 mandatory dialog. BTR Task 4 server tracking is merged into Task 4. Migration renumbered to 104.

**Tech Stack:** Flutter/Dart, Kotlin, Riverpod, `flutter_foreground_task`, `geolocator`, `device_info_plus`, `package_info_plus`, Supabase (PostgreSQL + RPC), `AlarmManager`, `PackageManagerCompat` (AndroidX core-ktx)

---

## Context You Must Know Before Touching Anything

### Key files

| File | Role |
|---|---|
| `gps_tracker/lib/features/tracking/services/background_tracking_service.dart` | FlutterForegroundTask init + start/stop tracking |
| `gps_tracker/lib/features/tracking/services/android_battery_health_service.dart` | Method channel bridge: standby bucket, battery settings, rescue alarms |
| `gps_tracker/lib/features/tracking/widgets/battery_optimization_dialog.dart` | AOSP battery exemption dialog; chains to OEM guide |
| `gps_tracker/lib/features/tracking/widgets/oem_battery_guide_dialog.dart` | Per-manufacturer step-by-step guide (Samsung, Xiaomi, etc.) |
| `gps_tracker/lib/features/tracking/models/permission_guard_state.dart` | `shouldBlockClockIn`, fields per-permission |
| `gps_tracker/lib/features/tracking/models/permission_guard_status.dart` | Status enum values |
| `gps_tracker/lib/features/tracking/providers/permission_guard_provider.dart` | `checkStatus()` + action methods |
| `gps_tracker/lib/features/tracking/widgets/permission_status_banner.dart` | Top-of-screen warning banner |
| `gps_tracker/lib/features/tracking/screens/battery_health_screen.dart` | ⋮-menu battery health screen |
| `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart` | `_handlePermissionBlock()`, `_handleClockIn()`, `_checkBatteryHealthOnResume()` |
| `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/MainActivity.kt` | Method channel cases: manufacturer, standby, rescue alarms |
| `gps_tracker/android/app/src/main/AndroidManifest.xml` | Receivers + permissions |

### Running the app

```bash
cd gps_tracker
flutter pub get
flutter run -d android
flutter analyze             # must be clean before any commit
flutter test                # all unit + widget tests
```

### Current migration state

Last applied: `103_backfill_effective_location_type`. Next available: **104**.

---

## Pre-flight: Verify AndroidX core-ktx

Before Tasks 2–3, check that `androidx.core:core-ktx` is available (needed for `PackageManagerCompat`).

```bash
cd gps_tracker/android
./gradlew dependencies --configuration debugRuntimeClasspath 2>&1 | grep "core-ktx"
```

If no output, open `gps_tracker/android/app/build.gradle` and add inside the `dependencies {}` block:

```gradle
implementation 'androidx.core:core-ktx:1.12.0'
```

Then re-run `./gradlew dependencies ... | grep core-ktx` to confirm it resolves. If it was already a transitive dep, no change needed.

---

## Task 1: Layer A — Raise foreground notification channel importance

**Problem:** Samsung One UI treats `DEFAULT`-importance foreground service notifications as killable. Raising to `HIGH` signals the memory manager to keep the service alive.

**Why a new channel ID:** Android caches channel importance per ID. Changing `channelImportance` on the existing `'gps_tracking_channel'` is silently ignored on all existing installs. A new ID forces Android to create a fresh channel at `HIGH` importance.

**Files:**
- Modify: `gps_tracker/lib/features/tracking/services/background_tracking_service.dart`

---

### Step 1: Find the FlutterForegroundTask.init block

```bash
cd gps_tracker
grep -n "channelId\|channelImportance\|priority" lib/features/tracking/services/background_tracking_service.dart
```

Note the line numbers (around line 53–60).

### Step 2: Apply the three-line change

In `background_tracking_service.dart`, change:

```dart
// BEFORE:
channelId: 'gps_tracking_channel',
channelImportance: NotificationChannelImportance.DEFAULT,
priority: NotificationPriority.DEFAULT,
```

```dart
// AFTER:
channelId: 'gps_tracking_channel_v2',
channelImportance: NotificationChannelImportance.HIGH,
priority: NotificationPriority.HIGH,
```

### Step 3: Verify compile

```bash
cd gps_tracker
flutter analyze lib/features/tracking/services/background_tracking_service.dart
```

Expected: no errors.

### Step 4: Manual test on Android device

1. Clock in (start tracking)
2. Press Home to background the app
3. Pull down notification shade — "Suivi de position actif" should be **visible above lower-priority notifications**
4. Wait 2 minutes — notification should still be present
5. Clock out

### Step 5: Commit

```bash
cd gps_tracker
git add lib/features/tracking/services/background_tracking_service.dart
git commit -m "fix: raise foreground notification importance to HIGH (new channel v2)

Samsung treats DEFAULT-importance foreground service notifications as killable.
HIGH importance signals to OEM memory manager that this service must survive.
New channel ID required because Android caches importance per channel ID.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 2: Layer B1 — Add PackageManagerCompat to native Kotlin

**Problem:** Android 11+ can place apps in hibernation / auto-revoke permissions when unused. `PackageManagerCompat` detects this. On Android 10 (S9), returns `FEATURE_NOT_AVAILABLE (1)` — no user action taken. Pure future-proofing.

**Files:**
- Modify: `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/MainActivity.kt`

---

### Step 1: Add imports to MainActivity.kt

At the top of `MainActivity.kt`, after the existing `import` block, add:

```kotlin
import androidx.core.content.PackageManagerCompat
import androidx.core.content.IntentCompat
import androidx.core.content.ContextCompat
```

### Step 2: Add two new cases to the device_manufacturer channel

In `MainActivity.kt`, find the `when (call.method)` block (lines 27–51). Add these two cases **before** `else -> result.notImplemented()` (currently line 51):

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

### Step 3: Verify Kotlin compiles

```bash
cd gps_tracker/android
./gradlew assembleDebug 2>&1 | tail -20
```

Expected: `BUILD SUCCESSFUL`

### Step 4: Commit

```bash
cd gps_tracker
git add android/app/src/main/kotlin/ca/trilogis/gpstracker/MainActivity.kt
git commit -m "feat(android): add PackageManagerCompat unused app restrictions API

Adds getUnusedAppRestrictionsStatus() and openManageUnusedAppRestrictionsSettings()
to the device_manufacturer method channel. Returns FEATURE_NOT_AVAILABLE (1) on
Android <= 10 (e.g. Samsung S9) so no user action is prompted on older devices.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 3: Layer B1 — Wire unused app restrictions into Dart permission guard

**Depends on:** Task 2 (Kotlin side must compile first)

**Files:**
- Modify: `gps_tracker/lib/features/tracking/services/android_battery_health_service.dart`
- Modify: `gps_tracker/lib/features/tracking/models/permission_guard_status.dart`
- Modify: `gps_tracker/lib/features/tracking/models/permission_guard_state.dart`
- Modify: `gps_tracker/lib/features/tracking/providers/permission_guard_provider.dart`
- Modify: `gps_tracker/lib/features/tracking/widgets/permission_status_banner.dart`

---

### Step 1: Add methods to AndroidBatteryHealthService

In `android_battery_health_service.dart`, before the closing `}` of the class, add:

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
    return await _channel.invokeMethod<bool>(
            'openManageUnusedAppRestrictionsSettings') ??
        false;
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

### Step 2: Add new status to PermissionGuardStatus

In `permission_guard_status.dart`, add one value after `appStandbyRestricted`:

```dart
/// Unused app restrictions active (Android 11+) — hibernation / auto-revoke risk.
unusedAppRestrictionsActive,
```

### Step 3: Add field and logic to PermissionGuardState

In `permission_guard_state.dart`:

**a)** Add field after `isAppStandbyRestricted`:
```dart
/// Whether Android 11+ unused app restrictions are active.
final bool isUnusedAppRestrictionsActive;
```

**b)** Update the constructor to include the new field (find the `const PermissionGuardState({` line and add `required this.isUnusedAppRestrictionsActive,` with the other required fields).

**c)** Update `PermissionGuardState.initial()` — add:
```dart
isUnusedAppRestrictionsActive: false,
```

**d)** In the `status` getter, add the check **after** `isAppStandbyRestricted` and **before** `isPreciseLocationEnabled`:
```dart
if (isUnusedAppRestrictionsActive) {
  return PermissionGuardStatus.unusedAppRestrictionsActive;
}
```

**e)** In `shouldBlockClockIn`, add `isUnusedAppRestrictionsActive` to the list:
```dart
bool get shouldBlockClockIn {
  return deviceStatus == DeviceLocationStatus.disabled ||
      !permission.hasAnyPermission ||
      permission.level == LocationPermissionLevel.whileInUse ||
      !isBatteryOptimizationDisabled ||
      isAppStandbyRestricted ||
      isUnusedAppRestrictionsActive ||   // ADD THIS LINE
      !isPreciseLocationEnabled;
}
```

**f)** Update `copyWith` to include the new field:
```dart
PermissionGuardState copyWith({
  // ... existing params ...
  bool? isUnusedAppRestrictionsActive,
}) => PermissionGuardState(
  // ... existing fields ...
  isUnusedAppRestrictionsActive:
      isUnusedAppRestrictionsActive ?? this.isUnusedAppRestrictionsActive,
);
```

### Step 4: Add the check in PermissionGuardNotifier.checkStatus()

In `permission_guard_provider.dart`, inside `checkStatus()`, after the standby bucket check, add:

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

In the `state = state.copyWith(...)` closure, add:
```dart
isUnusedAppRestrictionsActive: unusedAppRestrictionsActive,
```

Also add a log entry after the standby log:
```dart
if (unusedAppRestrictionsActive) {
  _logger?.permission(
    Severity.warn,
    'Android unused app restrictions active',
    metadata: {'platform': 'android'},
  );
}
```

### Step 5: Add openUnusedAppRestrictionsSettings action

In `permission_guard_provider.dart`, after `requestBatteryOptimization()`, add:

```dart
/// Opens unused app restrictions settings (Android 11+).
Future<void> openUnusedAppRestrictionsSettings() async {
  if (!Platform.isAndroid) return;
  await AndroidBatteryHealthService.openManageUnusedAppRestrictionsSettings();
  await checkStatus();
}
```

### Step 6: Wire into permission_status_banner.dart

In `permission_status_banner.dart`, add a case for `unusedAppRestrictionsActive` in the `_BannerConfig` switch (follow the same pattern as `appStandbyRestricted`):

```dart
PermissionGuardStatus.unusedAppRestrictionsActive => _BannerConfig(
  backgroundColor: Theme.of(context).colorScheme.errorContainer,
  iconColor: Theme.of(context).colorScheme.error,
  icon: Icons.battery_alert,
  title: 'Restrictions d\'application actives',
  subtitle:
      'Android peut révoquer les permissions. Désactivez les restrictions.',
  actionLabel: 'Corriger',
  canDismiss: false,
),
```

And in the banner action handler, add the case:
```dart
PermissionGuardStatus.unusedAppRestrictionsActive =>
    ref.read(permissionGuardProvider.notifier)
        .openUnusedAppRestrictionsSettings(),
```

### Step 7: Verify compile

```bash
cd gps_tracker
flutter analyze lib/features/tracking/
```

Expected: no errors.

### Step 8: Commit

```bash
cd gps_tracker
git add lib/features/tracking/services/android_battery_health_service.dart \
        lib/features/tracking/models/permission_guard_status.dart \
        lib/features/tracking/models/permission_guard_state.dart \
        lib/features/tracking/providers/permission_guard_provider.dart \
        lib/features/tracking/widgets/permission_status_banner.dart
git commit -m "feat: add unused app restrictions check to permission guard (Android 11+)

Detects API_30/API_31 unused app restriction state via PackageManagerCompat.
Blocks clock-in and shows banner if restrictions are active. Has no effect on
Android <= 10 (returns FEATURE_NOT_AVAILABLE, no action taken).

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 4: Layer B2 + Migration 104 — Mandatory OEM guide dialog + server tracking

**Depends on:** Task 2 (uses `AndroidBatteryHealthService` additions from Task 3, but Task 4 can run in parallel with Task 3 if needed)

**Problem:** `oem_setup_completed` flag is set once — dialog never shown again after firmware regressions. No "C'est fait" verification. Admins can't see who has never run setup.

**Conflict resolution note:** BTR Task 1 (`forceOemGuide` parameter) is dropped. Instead, `BatteryOptimizationDialog.show()` is changed to always chain to the OEM guide (removing `allowed &&`). The OEM guide (after this rewrite) only shows when battery is actually bad.

**Files:**
- Create: `supabase/migrations/104_battery_setup_tracking.sql`
- Modify: `gps_tracker/lib/features/tracking/widgets/oem_battery_guide_dialog.dart`
- Modify: `gps_tracker/lib/features/tracking/widgets/battery_optimization_dialog.dart`
- Modify: `gps_tracker/lib/features/admin/screens/user_management_screen.dart`

---

### Step 1: Write the migration

Create `supabase/migrations/104_battery_setup_tracking.sql`:

```sql
-- Migration 104: battery_setup_tracking
-- Adds server-side tracking for when an employee completes the OEM battery
-- setup wizard. Admins can filter for employees who have never done it.

ALTER TABLE employee_profiles
  ADD COLUMN IF NOT EXISTS battery_setup_completed_at TIMESTAMPTZ;

-- RPC callable by the authenticated employee.
-- SECURITY DEFINER so it can update own row without needing UPDATE policy.
CREATE OR REPLACE FUNCTION mark_battery_setup_completed()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE employee_profiles
  SET battery_setup_completed_at = NOW()
  WHERE user_id = auth.uid()
    AND battery_setup_completed_at IS NULL; -- only first-time, never regress
END;
$$;

-- Grant execute to authenticated users only
REVOKE ALL ON FUNCTION mark_battery_setup_completed() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION mark_battery_setup_completed() TO authenticated;
```

### Step 2: Apply the migration

```bash
# From GPS_Tracker/ root
supabase db push
```

Expected: Migration `104_battery_setup_tracking` applied successfully.

### Step 3: Rewrite OemBatteryGuideDialog

Replace the full content of `gps_tracker/lib/features/tracking/widgets/oem_battery_guide_dialog.dart` with:

```dart
import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

/// OEM-specific battery optimization guide dialog (Android only).
///
/// Shown as a mandatory dialog when OEM battery killers are detected as
/// still active. "C'est fait" verifies actual battery optimization state
/// before dismissing.
class OemBatteryGuideDialog extends StatefulWidget {
  final String manufacturer;

  const OemBatteryGuideDialog({required this.manufacturer, super.key});

  static const _problematicOems = {
    'samsung', 'xiaomi', 'huawei', 'honor', 'oneplus', 'oppo', 'realme',
  };

  /// Show the OEM guide if:
  /// - Device is a known problematic OEM (Android only)
  /// - AND battery optimization is still active (actual state check)
  ///
  /// Pass [force] = true to show even when battery is already fixed
  /// (e.g. from the settings screen for re-education).
  static Future<void> showIfNeeded(
    BuildContext context, {
    bool force = false,
  }) async {
    if (!Platform.isAndroid) return;

    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final manufacturer = androidInfo.manufacturer.toLowerCase();
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

  static const _channel =
      MethodChannel('gps_tracker/device_manufacturer', JSONMethodCodec());

  String get _title {
    switch (widget.manufacturer) {
      case 'samsung':
        return 'Configuration Samsung';
      case 'xiaomi':
        return 'Configuration Xiaomi';
      case 'huawei':
        return 'Configuration Huawei';
      case 'honor':
        return 'Configuration Honor';
      case 'oneplus':
        return 'Configuration OnePlus';
      case 'oppo':
        return 'Configuration Oppo';
      case 'realme':
        return 'Configuration Realme';
      default:
        return 'Configuration batterie';
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
                onPressed: _openDontKillMyApp,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('En savoir plus'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: _isChecking ? null : _openOemSettings,
          child: const Text('Ouvrir les paramètres'),
        ),
        FilledButton(
          onPressed: (_isChecking || !_hasOpenedSettings)
              ? null
              : () => _confirmDone(context),
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
      await _channel.invokeMethod<bool>(
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

    // Confirmed fixed — persist locally and close
    await FlutterForegroundTask.saveData(
        key: 'oem_setup_completed', value: true);
    await FlutterForegroundTask.saveData(
        key: 'oem_setup_manufacturer', value: widget.manufacturer);

    // Fire-and-forget: record completion server-side for admin visibility.
    unawaited(_syncCompletionToServer());

    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _syncCompletionToServer() async {
    try {
      await Supabase.instance.client.rpc('mark_battery_setup_completed');
    } catch (_) {
      // Best-effort: local completion flag is source of truth for the app.
    }
  }
}
```

> **Note on `_channel` in state:** The channel is accessed via `_OemBatteryGuideDialogState._channel` — move the const to the widget class if your linter complains. Pattern is fine in practice.

### Step 4: Modify BatteryOptimizationDialog.show() to always chain OEM guide

In `battery_optimization_dialog.dart`, change the `if (allowed && context.mounted)` condition:

**Before:**
```dart
// After AOSP dialog, show OEM-specific instructions if applicable
if (allowed && context.mounted) {
  await OemBatteryGuideDialog.showIfNeeded(context);
}
```

**After:**
```dart
// After AOSP dialog, always attempt OEM guide.
// OemBatteryGuideDialog.showIfNeeded() gates on actual battery state,
// so it self-skips when exemption is already granted.
if (context.mounted) {
  await OemBatteryGuideDialog.showIfNeeded(context);
}
```

> **Why:** If user taps "Plus tard" on the AOSP dialog (`allowed = false`), the OEM guide was previously never shown. After this change, the guide runs the state check — if battery is still bad, it shows. If battery is somehow now good, it skips. No visible change for the user in the happy path.

### Step 5: Run analyzer

```bash
cd gps_tracker
flutter analyze lib/features/tracking/widgets/
```

Expected: no errors.

### Step 6: Commit dialogs + migration

```bash
cd gps_tracker
git add lib/features/tracking/widgets/oem_battery_guide_dialog.dart \
        lib/features/tracking/widgets/battery_optimization_dialog.dart \
        ../supabase/migrations/104_battery_setup_tracking.sql
git commit -m "feat: mandatory OEM battery guide with state verification + server tracking

- OemBatteryGuideDialog rewritten: StatefulWidget, non-dismissible,
  checks actual battery state (not one-time flag), 'C'est fait' button
  disabled until settings page opened, verifies state before closing
- mark_battery_setup_completed RPC syncs completion to Supabase (fire-and-forget)
- BatteryOptimizationDialog.show() always chains OEM guide regardless
  of AOSP dialog response (guide self-gates on actual state)
- Migration 104: battery_setup_completed_at column on employee_profiles

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

### Step 7: Add battery badge to admin user management screen

In `user_management_screen.dart`, first find how employee data is queried:

```bash
cd gps_tracker
grep -n "select\|battery_setup\|employee_profiles" lib/features/admin/screens/user_management_screen.dart | head -20
```

**a) Add `battery_setup_completed_at` to the Supabase select call.** Find the `.select(...)` call and add the column:
```dart
.select('..., battery_setup_completed_at')
```

**b) Add the battery alert icon next to the employee name in the row/tile widget.** Find where `full_name` or employee name is rendered and add:
```dart
if (employee['battery_setup_completed_at'] == null && Platform.isAndroid)
  const Padding(
    padding: EdgeInsets.only(left: 6),
    child: Tooltip(
      message: 'Configuration batterie jamais complétée',
      child: Icon(Icons.battery_alert, size: 14, color: Colors.orange),
    ),
  ),
```

Add `import 'dart:io';` if not already present.

### Step 8: Run analyzer and commit

```bash
cd gps_tracker
flutter analyze lib/features/admin/screens/user_management_screen.dart
```

```bash
cd gps_tracker
git add lib/features/admin/screens/user_management_screen.dart
git commit -m "feat: show battery setup completion badge in admin user management

Android employees who have never tapped 'C'est fait' on the OEM battery
guide now show a battery_alert icon in the user management screen.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 5: Settings warning chip below clock button

**No dependencies.** Can run in parallel with Tasks 1–4.

**Problem:** The `PermissionStatusBanner` at the top may not be visible when the employee reaches for the clock button. The button is just disabled with no contextual explanation.

**Fix:** A tappable orange chip appears directly below the clock button when battery/standby blocks clock-in, linking to `BatteryHealthScreen`.

**Files:**
- Create: `gps_tracker/lib/features/tracking/widgets/clock_button_settings_warning.dart`
- Create: `gps_tracker/test/features/tracking/clock_button_settings_warning_test.dart`
- Modify: `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`

---

### Step 1: Find where ClockButton is rendered

```bash
cd gps_tracker
grep -n "ClockButton" lib/features/shifts/screens/shift_dashboard_screen.dart
```

Note the line number. The `ClockButton` is in a Column or similar layout. You will add the new widget **directly below** it.

### Step 2: Write the widget test

Create `gps_tracker/test/features/tracking/clock_button_settings_warning_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gps_tracker/features/tracking/models/permission_guard_state.dart';
import 'package:gps_tracker/features/tracking/providers/permission_guard_provider.dart';
import 'package:gps_tracker/features/tracking/widgets/clock_button_settings_warning.dart';

Widget _wrap(Widget child, {PermissionGuardState? state}) {
  return ProviderScope(
    overrides: state == null
        ? []
        : [
            permissionGuardProvider.overrideWith(
              (ref) => _FakeNotifier(state),
            ),
          ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

class _FakeNotifier extends PermissionGuardNotifier {
  _FakeNotifier(PermissionGuardState s) : super() {
    // ignore: invalid_use_of_protected_member
    state = s;
  }
}

void main() {
  testWidgets('shows nothing when battery optimization is disabled (ok)',
      (tester) async {
    final goodState = PermissionGuardState.initial().copyWith(
      isBatteryOptimizationDisabled: true,
      isAppStandbyRestricted: false,
    );
    await tester.pumpWidget(
        _wrap(const ClockButtonSettingsWarning(), state: goodState));
    expect(find.text('Configuration requise'), findsNothing);
  });

  testWidgets('does not throw when rendered on non-Android test env',
      (tester) async {
    final badState = PermissionGuardState.initial().copyWith(
      isBatteryOptimizationDisabled: false,
    );
    await tester.pumpWidget(
        _wrap(const ClockButtonSettingsWarning(), state: badState));
    // On non-Android test env, widget renders SizedBox.shrink() — no throw
    expect(tester.takeException(), isNull);
  });
}
```

### Step 3: Run test to confirm it fails (or passes trivially — no widget file yet)

```bash
cd gps_tracker
flutter test test/features/tracking/clock_button_settings_warning_test.dart -v
```

Expected: compile error (widget file doesn't exist yet).

### Step 4: Create the widget

Create `gps_tracker/lib/features/tracking/widgets/clock_button_settings_warning.dart`:

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/permission_guard_provider.dart';
import '../screens/battery_health_screen.dart';

/// A small warning chip shown below the clock button when device settings
/// prevent reliable GPS tracking. Tapping opens the BatteryHealthScreen.
///
/// Only visible on Android and only when battery/standby blocks clock-in.
/// iOS location issues are shown via the PermissionStatusBanner only.
class ClockButtonSettingsWarning extends ConsumerWidget {
  const ClockButtonSettingsWarning({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!Platform.isAndroid) return const SizedBox.shrink();

    final guardState = ref.watch(permissionGuardProvider);

    final isBatteryBlock = !guardState.isBatteryOptimizationDisabled ||
        guardState.isAppStandbyRestricted;

    if (!isBatteryBlock) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: GestureDetector(
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const BatteryHealthScreen(),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.orange.shade100,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.orange.shade400),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.battery_alert, size: 16, color: Colors.orange.shade800),
              const SizedBox(width: 6),
              Text(
                'Configuration requise',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.orange.shade900,
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.arrow_forward_ios,
                  size: 11, color: Colors.orange.shade700),
            ],
          ),
        ),
      ),
    );
  }
}
```

### Step 5: Run tests

```bash
cd gps_tracker
flutter test test/features/tracking/clock_button_settings_warning_test.dart -v
```

Expected: PASS (Android platform guard means widget renders `SizedBox.shrink()` in test env).

### Step 6: Add widget below ClockButton in ShiftDashboardScreen

In `shift_dashboard_screen.dart`, find the `ClockButton(...)` widget (from the grep in Step 1). Wrap it with the new widget in a Column, or add to the existing column:

```dart
Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    ClockButton(
      onClockIn: _handleClockIn,
      onClockOut: _handleClockOut,
      isExternallyLoading: _isClockInPreparing,
    ),
    const ClockButtonSettingsWarning(),
  ],
),
```

Add import at the top of `shift_dashboard_screen.dart`:
```dart
import '../../tracking/widgets/clock_button_settings_warning.dart';
```

### Step 7: Run analyzer and tests

```bash
cd gps_tracker
flutter analyze
flutter test test/features/tracking/clock_button_settings_warning_test.dart -v
```

Expected: 0 issues, PASS.

### Step 8: Commit

```bash
cd gps_tracker
git add lib/features/tracking/widgets/clock_button_settings_warning.dart \
        lib/features/shifts/screens/shift_dashboard_screen.dart \
        test/features/tracking/clock_button_settings_warning_test.dart
git commit -m "feat: add settings warning chip below clock button on Android

When battery optimization or standby restrictions block clock-in, an
orange 'Configuration requise' chip appears directly below the clock
button, linking to BatteryHealthScreen. Puts the fix one tap away.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 6: Persistent regression banner during active shift

**Depends on:** Task 4 (uses modified `BatteryOptimizationDialog.show()` without `forceOemGuide`)

**Problem:** When `_checkBatteryHealthOnResume()` detects a lost battery exemption, the employee can tap "Plus tard" on the dialogs. If a shift is active, GPS immediately degrades with no persistent signal.

**Files:**
- Modify: `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`

---

### Step 1: Add state flag to _ShiftDashboardScreenState

In `shift_dashboard_screen.dart`, find `_ShiftDashboardScreenState` class. Add a bool field:

```dart
bool _regressionBannerShown = false;
```

### Step 2: Replace `_checkBatteryHealthOnResume()`

Find `_checkBatteryHealthOnResume()` (around line 190). Replace the full method:

```dart
Future<void> _checkBatteryHealthOnResume() async {
  if (!Platform.isAndroid || !mounted) return;

  final lostExemption =
      await AndroidBatteryHealthService.hasLostBatteryOptimizationExemption();
  if (!lostExemption || !mounted) return;

  await _logger?.permission(
    Severity.warn,
    'Battery optimization exemption lost on resume',
  );

  // Show AOSP + OEM dialog chain.
  // BatteryOptimizationDialog.show() chains to OemBatteryGuideDialog
  // which auto-shows if battery is still bad (state-verified).
  await BatteryOptimizationDialog.show(context);
  if (!mounted) return;

  await ref.read(permissionGuardProvider.notifier).checkStatus();

  // After dialog chain, if still bad AND a shift is active → persistent banner.
  if (!mounted) return;
  final guardState = ref.read(permissionGuardProvider);
  final hasActiveShift = ref.read(shiftProvider).activeShift != null;
  final exemptionStillMissing = !guardState.isBatteryOptimizationDisabled;

  if (exemptionStillMissing && hasActiveShift && !_regressionBannerShown) {
    _showRegressionBanner();
  }
}

void _showRegressionBanner() {
  _regressionBannerShown = true;
  ScaffoldMessenger.of(context).showMaterialBanner(
    MaterialBanner(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      content: const Text(
        'Suivi GPS dégradé — batterie non exemptée.\nTouchez Corriger pour protéger votre quart.',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      ),
      backgroundColor: Colors.orange.shade800,
      leading: const Icon(Icons.battery_alert, color: Colors.white),
      actions: [
        TextButton(
          onPressed: () async {
            ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
            _regressionBannerShown = false;
            await BatteryOptimizationDialog.show(context);
            if (!mounted) return;
            await ref.read(permissionGuardProvider.notifier).checkStatus();
            if (!mounted) return;
            final state = ref.read(permissionGuardProvider);
            if (!state.isBatteryOptimizationDisabled) {
              _showRegressionBanner(); // Re-show if still not fixed
            }
          },
          child: const Text('Corriger', style: TextStyle(color: Colors.white)),
        ),
        TextButton(
          onPressed: () {
            ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
            _regressionBannerShown = false;
          },
          child: const Text('Plus tard',
              style: TextStyle(color: Colors.white70)),
        ),
      ],
    ),
  );
}
```

> **Note on "Plus tard":** The banner is dismissible via "Plus tard" because a fully non-dismissible banner is unusable while driving. The improvement is that "Corriger" re-triggers the full repair flow and re-shows the banner if still not fixed.

### Step 3: Clear banner on clock-out

Find `_handleClockOut()` in `shift_dashboard_screen.dart`. Inside the success block, add:

```dart
// Dismiss regression banner when shift ends
ScaffoldMessenger.of(context).clearMaterialBanners();
_regressionBannerShown = false;
```

### Step 4: Run analyzer

```bash
cd gps_tracker
flutter analyze
```

Expected: 0 issues.

### Step 5: Commit

```bash
cd gps_tracker
git add lib/features/shifts/screens/shift_dashboard_screen.dart
git commit -m "feat: persistent regression banner during active shift

When battery optimization exemption is lost mid-shift (e.g. after Samsung
firmware update) and the employee dismisses the repair dialogs, a
MaterialBanner persists at the top of the screen. 'Corriger' re-opens
the full repair flow. Banner auto-dismisses on clock-out.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 7: Shareable diagnostic report in BatteryHealthScreen

**No dependencies.** Can run in parallel with any task.

**Problem:** Admins must ask multiple questions to diagnose GPS issues remotely. No single snapshot exists.

**Fix:** "Copier le rapport de diagnostic" button copies platform, manufacturer, battery state, standby bucket, location permission, and app version to clipboard as human-readable text.

**Files:**
- Modify: `gps_tracker/lib/features/tracking/screens/battery_health_screen.dart`
- Create: `gps_tracker/test/features/tracking/battery_health_screen_test.dart`

---

### Step 1: Write the render test

Create `gps_tracker/test/features/tracking/battery_health_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gps_tracker/features/tracking/screens/battery_health_screen.dart';

void main() {
  testWidgets('BatteryHealthScreen renders without error', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: BatteryHealthScreen(),
        ),
      ),
    );
    // Initial frame — FutureBuilder shows loading
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
```

### Step 2: Run test

```bash
cd gps_tracker
flutter test test/features/tracking/battery_health_screen_test.dart -v
```

Expected: PASS.

### Step 3: Add imports to battery_health_screen.dart

Check existing imports and add missing ones:

```dart
import 'package:flutter/services.dart';           // Clipboard
import 'package:geolocator/geolocator.dart';       // permission check
import 'package:package_info_plus/package_info_plus.dart'; // app version
```

### Step 4: Add `_buildDiagnosticReport()` method to `_BatteryHealthScreenState`

Add this method inside `_BatteryHealthScreenState` (after `_refresh()`):

```dart
Future<String> _buildDiagnosticReport() async {
  final snapshot = await _load();
  final packageInfo = await PackageInfo.fromPlatform();
  final permission = await Geolocator.checkPermission();
  final locationEnabled = await Geolocator.isLocationServiceEnabled();

  final lines = <String>[
    '=== Rapport Diagnostic Tri-Logis Time ===',
    'Date: ${DateTime.now().toIso8601String()}',
    'Version app: ${packageInfo.version}+${packageInfo.buildNumber}',
    'Plateforme: ${Platform.isIOS ? 'iOS' : 'Android'}',
    '',
    '--- Localisation ---',
    'Services de localisation: ${locationEnabled ? 'Activés' : 'DÉSACTIVÉS'}',
    'Permission: ${permission.name}',
    '',
  ];

  if (Platform.isAndroid) {
    final standbyLabel = snapshot.standbyBucket.supported
        ? (snapshot.standbyBucket.bucketName ?? 'INCONNU')
        : 'Non supporté';
    lines.addAll([
      '--- Android ---',
      'Constructeur: ${snapshot.manufacturer ?? 'Inconnu'}',
      'Optimisation batterie: ${snapshot.batteryOptimizationDisabled ? 'DÉSACTIVÉE (OK)' : 'ACTIVE (PROBLÈME)'}',
      'App Standby Bucket: $standbyLabel',
      if (snapshot.standbyBucket.isRestricted) '  ⚠ App en veille prolongée!',
    ]);
  }

  lines.addAll([
    '',
    '=== Fin du rapport ===',
  ]);

  return lines.join('\n');
}
```

> **Note:** `_load()` is the private method that fetches the battery health snapshot. Verify the method name by searching `grep -n "_load\|Future.*load" lib/features/tracking/screens/battery_health_screen.dart`. If the method name differs, adjust accordingly.

### Step 5: Add the "Copier le rapport" button to the build method

In `_BatteryHealthScreenState.build()`, inside the `ListView` in the `FutureBuilder`, after the last `_StatusTile` and the blue tip box, add:

```dart
const SizedBox(height: 16),
OutlinedButton.icon(
  onPressed: () async {
    final report = await _buildDiagnosticReport();
    await Clipboard.setData(ClipboardData(text: report));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Rapport copié dans le presse-papiers'),
        duration: Duration(seconds: 2),
      ),
    );
  },
  icon: const Icon(Icons.copy),
  label: const Text('Copier le rapport de diagnostic'),
),
```

### Step 6: Run analyzer and tests

```bash
cd gps_tracker
flutter analyze
flutter test test/features/tracking/battery_health_screen_test.dart -v
```

Expected: 0 issues, PASS.

### Step 7: Commit

```bash
cd gps_tracker
git add lib/features/tracking/screens/battery_health_screen.dart \
        test/features/tracking/battery_health_screen_test.dart
git commit -m "feat: add shareable diagnostic report to battery health screen

'Copier le rapport de diagnostic' collects platform, manufacturer,
battery exemption, standby bucket, location permission, and app version
into a text block copied to clipboard for remote admin triage.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 8: Layer C — Create native AlarmManager rescue receiver

**No dependencies.** Can run in parallel with any task.

**Files:**
- Create: `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/TrackingRescueReceiver.kt`
- Modify: `gps_tracker/android/app/src/main/AndroidManifest.xml`

---

### Step 1: Create TrackingRescueReceiver.kt

Create `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/TrackingRescueReceiver.kt`:

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

        // SharedPreferences keys (same format as FlutterForegroundTask)
        private const val FGT_PREFS = "FlutterSharedPreferences"
        private const val KEY_SHIFT_ID =
            "flutter.com.pravera.flutter_foreground_task.prefs.shift_id"

        private const val RESCUE_INTERVAL_MS = 60_000L
        private const val REQUEST_CODE = 9877 // Must not conflict with other PendingIntents

        /**
         * Start the 60-second rescue alarm chain. Safe to call multiple times.
         */
        fun startAlarmChain(context: Context) {
            val alarmManager =
                context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pendingIntent = buildPendingIntent(context) ?: return
            val triggerTime = SystemClock.elapsedRealtime() + RESCUE_INTERVAL_MS

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                if (!alarmManager.canScheduleExactAlarms()) {
                    // Android 12+ without SCHEDULE_EXACT_ALARM: use inexact alarm.
                    // WorkManager 5-min watchdog covers the gap.
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
         * Cancel the rescue alarm chain. Call when tracking ends.
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

        // Read shift_id from FFT SharedPreferences
        val prefs = context.getSharedPreferences(FGT_PREFS, Context.MODE_PRIVATE)
        val shiftId = prefs.getString(KEY_SHIFT_ID, null)

        if (shiftId.isNullOrEmpty()) {
            // No active shift — stop the chain naturally (don't reschedule)
            Log.d(TAG, "Rescue alarm fired but no active shift — chain stopped")
            return
        }

        Log.d(TAG, "Rescue alarm fired, shift $shiftId active — restarting FFT service")

        // Unconditionally start the FFT foreground service.
        // If already running, this is harmless (just calls onStartCommand() again).
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

### Step 2: Register receiver and add permission in AndroidManifest.xml

In `AndroidManifest.xml`:

**a) Add permission** in the `<uses-permission>` block (after line 30, near other permissions):
```xml
<!-- Exact alarms for GPS tracking rescue watchdog (Android 13+, auto-granted for location apps) -->
<uses-permission android:name="android.permission.USE_EXACT_ALARM" />
```

**b) Add receiver** — insert after the closing `</receiver>` tag of `TrackingBootReceiver` and before `</application>`:
```xml
<!-- 60-second rescue watchdog for GPS tracking service -->
<receiver
    android:name=".TrackingRescueReceiver"
    android:exported="false" />
```

### Step 3: Verify Kotlin compiles

```bash
cd gps_tracker/android
./gradlew assembleDebug 2>&1 | tail -20
```

Expected: `BUILD SUCCESSFUL`

### Step 4: Commit

```bash
cd gps_tracker
git add android/app/src/main/kotlin/ca/trilogis/gpstracker/TrackingRescueReceiver.kt \
        android/app/src/main/AndroidManifest.xml
git commit -m "feat(android): add TrackingRescueReceiver 60s AlarmManager watchdog

Creates a self-rescheduling BroadcastReceiver that fires every 60s during
active shifts and unconditionally calls startForegroundService() on the FFT
service. Reduces recovery gap from 5min (WorkManager) to ~60s when Samsung
kills the service. Falls back to inexact alarm on Android 12+ without
SCHEDULE_EXACT_ALARM permission.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 9: Layer C — Expose rescue alarms via method channel

**Depends on:** Task 8 (TrackingRescueReceiver must exist before it's called)

**Files:**
- Modify: `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/MainActivity.kt`

---

### Step 1: Add two new cases to the device_manufacturer channel

In `MainActivity.kt`, inside the `when (call.method)` block of the `gps_tracker/device_manufacturer` channel, add these cases **before** `else -> result.notImplemented()`:

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

### Step 2: Verify Kotlin compiles

```bash
cd gps_tracker/android
./gradlew assembleDebug 2>&1 | tail -20
```

Expected: `BUILD SUCCESSFUL`

### Step 3: Commit

```bash
cd gps_tracker
git add android/app/src/main/kotlin/ca/trilogis/gpstracker/MainActivity.kt
git commit -m "feat(android): expose rescue alarm start/stop via method channel

Adds startRescueAlarms(shiftId) and stopRescueAlarms() to the
gps_tracker/device_manufacturer method channel so Flutter can control
the AlarmManager rescue chain lifecycle.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 10: Layer C — Wire rescue alarms into Flutter tracking lifecycle

**Depends on:** Task 9 (method channel must exist)

**Files:**
- Modify: `gps_tracker/lib/features/tracking/services/android_battery_health_service.dart`
- Modify: `gps_tracker/lib/features/tracking/services/background_tracking_service.dart`

---

### Step 1: Add Dart methods to AndroidBatteryHealthService

In `android_battery_health_service.dart`, before the closing `}` of the class:

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

### Step 2: Call startRescueAlarms after successful tracking start

In `background_tracking_service.dart`, find the `if (result is ServiceRequestSuccess)` block. Add the rescue alarm call **before** returning:

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

> Verify by searching: `grep -n "ServiceRequestSuccess\|TrackingSuccess" lib/features/tracking/services/background_tracking_service.dart`

### Step 3: Call stopRescueAlarms in stopTracking()

In `background_tracking_service.dart`, find `static Future<void> stopTracking() async {`. Add as the **first action** inside (before `FlutterForegroundTask.stopService()`):

```dart
static Future<void> stopTracking() async {
  // Stop the native rescue watchdog before the service (order matters)
  if (Platform.isAndroid) {
    await AndroidBatteryHealthService.stopRescueAlarms();
  }
  await FlutterForegroundTask.stopService();
  // ... rest of existing removeData calls unchanged
```

### Step 4: Verify compile

```bash
cd gps_tracker
flutter analyze lib/features/tracking/services/
```

Expected: no errors.

### Step 5: Manual integration test

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
8. Verify no further logcat entries from `TrackingRescueReceiver`

### Step 6: Commit

```bash
cd gps_tracker
git add lib/features/tracking/services/android_battery_health_service.dart \
        lib/features/tracking/services/background_tracking_service.dart
git commit -m "feat: wire rescue alarm watchdog into tracking lifecycle

startRescueAlarms() called after successful FFT service start.
stopRescueAlarms() called before FFT service stop on clock-out.
The alarm chain self-terminates naturally if shift_id is cleared
(race condition safety: no ghost restarts after clock-out).

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Final Verification

After all 10 tasks are committed:

```bash
cd gps_tracker
flutter analyze
flutter test
flutter build apk --debug
```

Expected: 0 analyzer issues, all tests pass, APK builds successfully.

**Manual test checklist (Samsung Android device preferred):**

1. **Task 1:** Clock in → switch to another app → wait 3 minutes → verify HIGH-importance notification stays in status bar
2. **Task 3 (Android 11+):** Set app hibernatable → verify clock-in is blocked with banner
3. **Task 4:** Enable battery optimization → try to clock in → verify OEM dialog is non-dismissible → tap "C'est fait" without fixing → verify inline error → fix → tap "C'est fait" → verify `battery_setup_completed_at` set in Supabase
4. **Task 5:** With battery optimization enabled → verify orange "Configuration requise" chip appears below clock button → tap it → verify BatteryHealthScreen opens → fix setting → chip disappears
5. **Task 6:** Start a shift → revoke battery exemption (`adb shell dumpsys deviceidle whitelist -ca.trilogis.gpstracker`) → bring app to foreground → verify orange MaterialBanner appears → tap "Corriger" → fix setting → banner gone
6. **Task 7:** ⋮ → Santé batterie → "Copier le rapport" → paste in text editor → verify multi-line report with all fields
7. **Task 10:** Clock in → `adb shell am kill ca.trilogis.gpstracker` → wait 90s → verify notification reappears → clock out → wait 90s → verify no further `TrackingRescueReceiver` logcat output
