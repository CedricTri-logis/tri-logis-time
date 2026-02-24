# Contract: Android OEM Battery Optimization Guide

## Method Channel: `gps_tracker/device_manufacturer`

### Overview

Extends `MainActivity.kt` to expose device manufacturer detection and OEM-specific settings deep links. Uses Android's `Build.MANUFACTURER` and `Intent` system to navigate users to the correct battery/autostart settings screen.

### Methods (Flutter → Native)

#### `getManufacturer`

Get the device manufacturer name (lowercase).

- **Arguments**: None
- **Returns**: `String` (e.g., `"samsung"`, `"xiaomi"`, `"huawei"`, `"oneplus"`, `"oppo"`, `"google"`)
- **Note**: Already available via `device_info_plus` in Dart. This method channel is provided for cases where the native side needs to make manufacturer-dependent decisions.

#### `openOemBatterySettings`

Attempt to open the OEM-specific battery/autostart settings screen.

- **Arguments**: `Map<String, dynamic>` with key `manufacturer` (`String`)
- **Returns**: `bool` (`true` if an intent was successfully launched, `false` if no matching activity found)
- **Behavior**: Tries a chain of manufacturer-specific intents with fallback:

**Samsung** (`samsung`):
1. `com.samsung.android.lool/BatteryActivity` (One UI 2+)
2. `com.samsung.android.sm/SmartManagerDashBoardActivity` (older)
3. `Settings.ACTION_BATTERY_SAVER_SETTINGS` (generic fallback)

**Xiaomi** (`xiaomi`):
1. `com.miui.securitycenter/AutoStartManagementActivity` (autostart)
2. `miui.intent.action.OP_AUTO_START` (alternative)
3. `Settings.ACTION_BATTERY_SAVER_SETTINGS` (generic fallback)

**Huawei** (`huawei`):
1. `com.huawei.systemmanager/StartupAppControlActivity` (EMUI 9+)
2. `com.huawei.systemmanager/StartupNormalAppListActivity` (EMUI 8)
3. `com.huawei.systemmanager/ProtectActivity` (EMUI 5-7)
4. `com.huawei.systemmanager/HwPowerManagerActivity` (battery fallback)

**OnePlus/Oppo/Realme** (`oneplus`, `oppo`, `realme`):
1. `com.oneplus.security/ChainLaunchAppListActivity` (OnePlus)
2. `com.coloros.safecenter/StartupAppListActivity` (ColorOS 6+)
3. `com.coloros.safecenter/StartupAppListActivity` (ColorOS 3-5, different path)
4. `com.oppo.safe/StartupAppListActivity` (older Oppo)

**Other OEMs**: Returns `false` (Dart side shows generic guidance + dontkillmyapp.com link)

All intents include `Intent.FLAG_ACTIVITY_NEW_TASK` and are wrapped in try-catch.

### Dart Widget: `OemBatteryGuideDialog`

A full-screen modal or bottom sheet showing OEM-specific step-by-step instructions in French.

#### Display Logic

```dart
static Future<void> showIfNeeded(BuildContext context) async {
  // 1. Only on Android
  if (!Platform.isAndroid) return;

  // 2. Check if already completed
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool('oem_setup_completed') == true) return;

  // 3. Detect manufacturer
  final androidInfo = await DeviceInfoPlugin().androidInfo;
  final manufacturer = androidInfo.manufacturer.toLowerCase();

  // 4. Only show for known problematic OEMs
  if (!_isProblematicOem(manufacturer)) return;

  // 5. Show the guide
  await showDialog(context: context, builder: (_) => OemBatteryGuideDialog(manufacturer: manufacturer));
}
```

#### Supported OEMs and Instructions (French)

| OEM | Title | Steps |
|-----|-------|-------|
| Samsung | "Configuration Samsung" | 1. Ouvrez Paramètres > Batterie > Limites d'utilisation en arrière-plan 2. Appuyez "Applications en veille prolongée" 3. Retirez Tri-Logis Time de la liste 4. Appuyez "Applications jamais en veille" 5. Ajoutez Tri-Logis Time |
| Xiaomi | "Configuration Xiaomi" | 1. Ouvrez Paramètres > Applications > Gérer les applications 2. Trouvez Tri-Logis Time 3. Activez "Démarrage automatique" 4. Appuyez Économie de batterie > Aucune restriction |
| Huawei | "Configuration Huawei" | 1. Ouvrez Paramètres > Batterie > Lancement d'applications 2. Trouvez Tri-Logis Time 3. Désactivez la gestion automatique 4. Activez les 3 options: Lancement auto, Lancement secondaire, Exécution en arrière-plan |
| OnePlus/Oppo/Realme | "Configuration [OEM]" | 1. Ouvrez Paramètres > Batterie > Optimisation de la batterie 2. Trouvez Tri-Logis Time 3. Sélectionnez "Ne pas optimiser" 4. Activez "Autoriser l'activité en arrière-plan" |

#### Actions

- **"Ouvrir les paramètres"** button: Calls `openOemBatterySettings` method channel
- **"En savoir plus"** link: Opens `https://dontkillmyapp.com/{manufacturer}` in browser
- **"C'est fait"** button: Sets `oem_setup_completed = true` in SharedPreferences, dismisses dialog
- **"Plus tard"** button: Dismisses without persisting

#### Trigger Points

1. **First clock-in**: After standard battery optimization dialog, if OEM is problematic
2. **GPS tracking death**: When `gps_lost` is received and SLC activates as fallback, re-show on next app foreground if setup was not completed

### SharedPreferences Keys

| Key | Type | Purpose |
|-----|------|---------|
| `oem_setup_completed` | `bool` | User completed OEM setup |
| `oem_setup_manufacturer` | `String?` | Manufacturer at time of completion (re-show if device changes) |
