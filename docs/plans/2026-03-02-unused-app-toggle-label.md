# Unused App Restrictions — Explicit Toggle Label in Banner

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Show the exact Android toggle label (in the phone's language) in the permission banner so employees know what to disable.

**Architecture:** Add `getApiLevel` native method, build a locale+API lookup table in Dart, store the computed label in `PermissionGuardState`, and display it dynamically in the banner subtitle.

**Tech Stack:** Kotlin (Android native), Dart/Flutter, Riverpod

---

### Task 1: Add `getApiLevel` native method

**Files:**
- Modify: `gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/MainActivity.kt`
- Modify: `gps_tracker/lib/features/tracking/services/android_battery_health_service.dart`

**Step 1: Add native handler in MainActivity.kt**

In the `"gps_tracker/device_manufacturer"` method channel handler (around line 30), add a new case before the `else -> result.notImplemented()`:

```kotlin
"getApiLevel" -> {
    result.success(Build.VERSION.SDK_INT)
}
```

**Step 2: Add Dart method in AndroidBatteryHealthService**

After the `getManufacturer()` method (around line 83), add:

```dart
static Future<int> getApiLevel() async {
  if (!Platform.isAndroid) return 0;
  try {
    return await _channel.invokeMethod<int>('getApiLevel') ?? 0;
  } catch (_) {
    return 0;
  }
}
```

**Step 3: Commit**

```bash
git add gps_tracker/android/app/src/main/kotlin/ca/trilogis/gpstracker/MainActivity.kt gps_tracker/lib/features/tracking/services/android_battery_health_service.dart
git commit -m "feat: add getApiLevel native method for Android SDK version"
```

---

### Task 2: Add toggle label lookup table

**Files:**
- Modify: `gps_tracker/lib/features/tracking/services/android_battery_health_service.dart`

**Step 1: Add the lookup method**

Add at the end of the `AndroidBatteryHealthService` class, before the closing `}`:

```dart
/// Returns the exact toggle label the user sees in Android settings
/// for "unused app restrictions", based on API level and device locale.
///
/// The label is in the phone's language so the user can find it.
/// Falls back to a generic French instruction if locale is unknown.
static String getUnusedAppToggleLabel({
  required int apiLevel,
  required String languageCode,
}) {
  // Android 13+ (API 33): "Pause app activity if unused"
  if (apiLevel >= 33) {
    return switch (languageCode) {
      'fr' => 'Mettre en pause l\'activité de l\'appli si elle est inutilisée',
      'en' => 'Pause app activity if unused',
      'es' => 'Pausar la actividad de la app si no se usa',
      'pt' => 'Pausar atividade do app se não usado',
      _ => 'Pause app activity if unused',
    };
  }

  // Android 12 (API 31-32): "Remove permissions and free up space"
  if (apiLevel >= 31) {
    return switch (languageCode) {
      'fr' => 'Supprimer les autorisations et libérer de l\'espace',
      'en' => 'Remove permissions and free up space',
      'es' => 'Quitar permisos y liberar espacio',
      'pt' => 'Remover permissões e liberar espaço',
      _ => 'Remove permissions and free up space',
    };
  }

  // Android 11 (API 30): "Remove permissions if app isn't used"
  return switch (languageCode) {
    'fr' => 'Supprimer les autorisations si l\'appli est inutilisée',
    'en' => 'Remove permissions if app isn\'t used',
    'es' => 'Quitar permisos si no se usa la app',
    'pt' => 'Remover permissões se o app não for usado',
    _ => 'Remove permissions if app isn\'t used',
  };
}
```

**Step 2: Commit**

```bash
git add gps_tracker/lib/features/tracking/services/android_battery_health_service.dart
git commit -m "feat: add unused app toggle label lookup by API level and locale"
```

---

### Task 3: Store label in PermissionGuardState

**Files:**
- Modify: `gps_tracker/lib/features/tracking/models/permission_guard_state.dart`

**Step 1: Add the field**

Add after `isUnusedAppRestrictionsActive` field (line 28):

```dart
/// The exact toggle label text for unused app restrictions (Android only).
/// In the phone's language so the user can find it in settings.
final String? unusedAppToggleLabel;
```

Add to constructor parameters (after `required this.isUnusedAppRestrictionsActive`):

```dart
this.unusedAppToggleLabel,
```

Add to `initial()` factory:

```dart
unusedAppToggleLabel: null,
```

Add to `copyWith` parameter list:

```dart
String? unusedAppToggleLabel,
```

And in the `copyWith` body:

```dart
unusedAppToggleLabel: unusedAppToggleLabel ?? this.unusedAppToggleLabel,
```

**Step 2: Commit**

```bash
git add gps_tracker/lib/features/tracking/models/permission_guard_state.dart
git commit -m "feat: add unusedAppToggleLabel field to PermissionGuardState"
```

---

### Task 4: Compute the label in the provider

**Files:**
- Modify: `gps_tracker/lib/features/tracking/providers/permission_guard_provider.dart`

**Step 1: Add dart:ui import**

At the top of the file, add:

```dart
import 'dart:ui' as ui;
```

**Step 2: Compute the label when restrictions are active**

In `checkStatus()`, after line 66 (`unusedAppRestrictionsActive = AndroidBatteryHealthService.unusedRestrictionsNeedAction(unusedStatus);`), add:

```dart
if (unusedAppRestrictionsActive) {
  final apiLevel = await AndroidBatteryHealthService.getApiLevel();
  final locale = ui.PlatformDispatcher.instance.locale;
  unusedToggleLabel = AndroidBatteryHealthService.getUnusedAppToggleLabel(
    apiLevel: apiLevel,
    languageCode: locale.languageCode,
  );
}
```

Declare `unusedToggleLabel` at the start of the unused app restrictions block (before the `if (Platform.isAndroid)` on line 61):

```dart
String? unusedToggleLabel;
```

Then in the `applyState()` closure, add to `copyWith`:

```dart
unusedAppToggleLabel: unusedToggleLabel,
```

**Step 3: Commit**

```bash
git add gps_tracker/lib/features/tracking/providers/permission_guard_provider.dart
git commit -m "feat: compute unused app toggle label from API level and locale"
```

---

### Task 5: Update the banner subtitle

**Files:**
- Modify: `gps_tracker/lib/features/tracking/widgets/permission_status_banner.dart`

**Step 1: Make banner config aware of toggle label**

Change `_getBannerConfig` signature to accept the full state:

```dart
_BannerConfig _getBannerConfig(
  BuildContext context,
  PermissionGuardState state,
) {
```

Update the call site in `build()` (line 39):

```dart
final config = _getBannerConfig(context, state);
```

Inside the method, replace `status` with `state.status` everywhere, and update the `unusedAppRestrictionsActive` case (lines 185-194):

```dart
PermissionGuardStatus.unusedAppRestrictionsActive => _BannerConfig(
    backgroundColor: theme.colorScheme.errorContainer,
    iconColor: theme.colorScheme.error,
    icon: Icons.battery_alert,
    title: 'Restrictions d\'application actives',
    subtitle: state.unusedAppToggleLabel != null
        ? 'Désactivez « ${state.unusedAppToggleLabel} »'
        : 'Android peut révoquer les permissions. Désactivez les restrictions.',
    actionLabel: 'Corriger',
    canDismiss: false,
  ),
```

**Step 2: Commit**

```bash
git add gps_tracker/lib/features/tracking/widgets/permission_status_banner.dart
git commit -m "feat: show exact Android toggle label in unused app restrictions banner"
```

---

### Task 6: Build and verify

**Step 1: Run Flutter analyze**

```bash
cd gps_tracker && flutter analyze
```

Expected: No errors.

**Step 2: Run tests**

```bash
cd gps_tracker && flutter test
```

Expected: All existing tests pass.

**Step 3: Commit any fixups if needed**
