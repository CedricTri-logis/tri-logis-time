# Background Tracking Resilience - Audit complet

> Dernière mise à jour : 2026-03-12 | Build actuel : v1.0.0+134

## Table des matières

1. [Vue d'ensemble de l'architecture](#1-vue-densemble)
2. [Mécanismes iOS natifs](#2-mécanismes-ios-natifs)
3. [Mécanismes Android natifs](#3-mécanismes-android-natifs)
4. [Mécanismes Flutter (cross-platform)](#4-mécanismes-flutter)
5. [Mécanismes serveur (Supabase)](#5-mécanismes-serveur)
6. [Historique des builds et changements](#6-historique-des-builds)
7. [Ce qui fonctionne vs ce qui ne fonctionne pas](#7-bilan)
8. [Pistes d'amélioration](#8-pistes-damélioration)

---

## 1. Vue d'ensemble

L'architecture de résilience utilise une approche **multi-couches** (defense in depth) :

```
┌─────────────────────────────────────────────┐
│           COUCHE SERVEUR (Supabase)          │
│  pg_cron midnight cleanup, heartbeat,       │
│  flag_gpsless_shifts, minimum_app_version,  │
│  wake-stale-devices cron (2min), FCM push   │
├─────────────────────────────────────────────┤
│         COUCHE FLUTTER (Main Isolate)        │
│  GPS self-healing (2min nudge),             │
│  connectivity monitor, server heartbeat,     │
│  tracking verification, thermal adaptation,  │
│  GpsHealthGuard (hard gate + soft nudge)    │
├─────────────────────────────────────────────┤
│       COUCHE FLUTTER (Background Isolate)    │
│  GPS stream + exponential backoff recovery,  │
│  30s heartbeat loop, GPS loss detection,     │
│  adaptive frequency, force capture           │
├─────────────────────────────────────────────┤
│           COUCHE NATIVE iOS                  │
│  CLBackgroundActivitySession (iOS 17+),      │
│  beginBackgroundTask, SLC (~500m),           │
│  BGAppRefreshTask (~5min), Live Activity,    │
│  NativeGpsBuffer (UserDefaults, 500pts)      │
├─────────────────────────────────────────────┤
│           COUCHE NATIVE Android              │
│  setAlarmClock (45s rescue chain),           │
│  WorkManager (5min periodic),                │
│  Boot/Package receiver, OEM battery guide,   │
│  GeofenceWakeReceiver (200m exit),           │
│  NativeGpsBuffer (SharedPreferences, 500pts) │
└─────────────────────────────────────────────┘
```

**Philosophie** : Fail-open (les erreurs sont loguées mais ne crashent jamais le tracking)

---

## 2. Mécanismes iOS natifs

### 2.1 CLBackgroundActivitySession (iOS 17+)

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `ios/Runner/BackgroundTaskPlugin.swift` |
| **Introduit** | Build +52 (018-background-tracking-resilience) |
| **Statut** | ✅ ACTIF |
| **Principe** | Déclare une activité de localisation continue à iOS. Affiche l'indicateur bleu dans la barre de statut. Empêche iOS de suspendre l'app. |
| **Fallback** | No-op sur iOS < 17 (beginBackgroundTask prend le relais) |

**Comment ça marche** : Au démarrage du tracking, une référence forte à `CLBackgroundActivitySession()` est maintenue. iOS comprend que l'app a besoin de continuer en arrière-plan pour la localisation. La session est relâchée à l'arrêt du tracking.

### 2.2 beginBackgroundTask (iOS 10+)

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `ios/Runner/BackgroundTaskPlugin.swift` |
| **Introduit** | Build +52 (018-background-tracking-resilience) |
| **Statut** | ✅ ACTIF (belt-and-suspenders avec 2.1) |
| **Principe** | Demande ~30s d'exécution supplémentaire lors de la transition foreground→background. |

**Comment ça marche** : Appelé à chaque `applicationDidEnterBackground`. Donne un délai pour que le GPS stream s'établisse en arrière-plan. Le handler d'expiration nettoie automatiquement.

### 2.3 Significant Location Change (SLC)

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `ios/Runner/SignificantLocationPlugin.swift` |
| **Introduit** | Build +52 (018), modifié +55 (deferred activation) |
| **Statut** | ✅ ACTIF (activation différée) |
| **Principe** | iOS relance l'app même après terminaison quand un changement de ~500m est détecté via triangulation cellulaire. |

**Évolution** :
- **Build +52** : SLC activé au clock-in (immédiat)
- **Build +55** : SLC activé au clock-in (immédiat) — confirmé
- **Build actuel** : SLC activé **après détection de perte GPS** (différé, pas au clock-in)
  - Seuil de perte GPS : 45s sans position
  - Grace period : 60s post-démarrage (évite faux positifs au restart)

**Limitation** : Précision ~500m (triangulation cellulaire). Utilisé uniquement comme dernier recours pour relancer l'app si iOS l'a tuée.

### 2.4 Live Activity (iOS 16.1+)

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `ios/Runner/LiveActivityPlugin.swift` |
| **Introduit** | Build +52 (018-background-tracking-resilience) |
| **Statut** | ✅ ACTIF |
| **Principe** | Affiche le statut du shift sur le Lock Screen. Donne une visibilité à l'utilisateur que le tracking est actif. |

### 2.5 NativeGpsBuffer (UserDefaults)

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `ios/Runner/NativeGpsBuffer.swift` |
| **Introduit** | Build +98 |
| **Statut** | ✅ ACTIF |
| **Principe** | Capture des points GPS dans UserDefaults quand le SLC callback se déclenche. Permet de sauver des points même si Flutter engine est mort. Drainé dans SQLCipher au prochain sync. |

**Limites** : Max 100 points. Source tag : `native_slc`. Singleton pattern. Intégré dans `SignificantLocationPlugin.didUpdateLocations`.

### 2.6 BGAppRefreshTask (iOS 13+)

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `ios/Runner/BackgroundAppRefreshPlugin.swift` + `lib/features/tracking/services/bg_app_refresh_service.dart` |
| **Introduit** | Build +103 |
| **Statut** | ✅ ACTIF |
| **Principe** | iOS schedule un refresh ~5min (réel : 15-30min selon usage). Quand l'employé est stationnaire (pas de SLC trigger), c'est le seul mécanisme capable de relancer l'app. Le handler vérifie UserDefaults pour shift_id, écrit un breadcrumb, et laisse `_refreshServiceState()` de main.dart redémarrer le tracking. |

**Comportement** : One-shot — se re-schedule à chaque exécution. Scheduled au clock-in (`BgAppRefreshService.schedule()`), annulé au clock-out (`BgAppRefreshService.cancel()`). Handler minimal (UserDefaults reads only) pour ne pas faire baisser la priorité iOS.

### 2.7 Configuration iOS critique

| Paramètre | Valeur | Pourquoi |
|------------|--------|----------|
| `distanceFilter` | `0` | **CRITIQUE** — si > 0, iOS suspend l'app quand stationnaire |
| `activityType` | `.other` | Empêche iOS d'optimiser/pauser les mises à jour |
| `pauseLocationUpdatesAutomatically` | `false` | Empêche iOS de décider de pauser |
| `allowBackgroundLocationUpdates` | `true` | Obligatoire pour le background |
| `showBackgroundLocationIndicator` | `true` | Indicateur bleu = signal à iOS que c'est légitime |
| `UIBackgroundModes` | `location, fetch` | Déclaré dans Info.plist |

---

## 3. Mécanismes Android natifs

### 3.1 Foreground Service avec notification

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `AndroidManifest.xml` + FlutterForegroundTask config |
| **Introduit** | Builds originaux (004-background-gps-tracking) |
| **Statut** | ✅ ACTIF |
| **Principe** | Service de premier plan avec notification persistante de type `location`. `stopWithTask=false` — continue même si l'app est tuée. |

**Configuration** :
```xml
<service
  android:name="...ForegroundService"
  android:foregroundServiceType="location"
  android:stopWithTask="false" />
```

### 3.2 Rescue Alarm Chain (setAlarmClock — 45s)

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `android/.../TrackingRescueReceiver.kt` |
| **Introduit** | Build +90 (AlarmManager 60s), réécrit +94 (setAlarmClock 45s) |
| **Statut** | ✅ ACTIF (mécanisme principal Android) |

**Évolution importante** :

| Build | Mécanisme | Problème |
|-------|-----------|----------|
| +87 | `android_alarm_manager_plus` (plugin Flutter) | Crash sur Android 16 |
| +88 | Supprimé `android_alarm_manager_plus` | — |
| +90 | `TrackingRescueReceiver` avec `setExactAndAllowWhileIdle()` 60s | Throttled par Doze sur Android 16 |
| +91 | Supprimé permission `USE_EXACT_ALARM` | Conflit avec Google Play policies |
| +94 | **Réécriture complète** : 3 tiers d'alarmes, 45s | ✅ Solution actuelle |

**Stratégie 3 tiers (actuelle)** :

| Tier | Méthode | Fiabilité | Notes |
|------|---------|-----------|-------|
| 1 (Principal) | `setAlarmClock()` | Jamais throttled par Doze | Affiche icône alarme dans la barre |
| 2 (Fallback) | `setExactAndAllowWhileIdle()` | Peut être throttled | Nécessite `canScheduleExactAlarms()` |
| 3 (Dernier recours) | `setAndAllowWhileIdle()` | Inexact, peut être retardé | Toujours disponible |

**Boucle** : Alarme toutes les 45s → vérifie si shift actif → si le service FFT est mort, le redémarre → re-programme la prochaine alarme.

### 3.3 NativeGpsBuffer (SharedPreferences)

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `android/.../NativeGpsBuffer.kt` |
| **Introduit** | Build +98 |
| **Statut** | ✅ ACTIF |
| **Principe** | Capture native via `FusedLocationProviderClient` dans le rescue alarm callback. Sauve dans SharedPreferences (JSON array). Drainé dans SQLCipher au prochain sync via MethodChannel. |

**Limites** : Max 100 points. Source tag : `native_rescue`. Timeout GPS : 10s. Intégré dans `TrackingRescueReceiver`.

### 3.4 TrackingWatchdogService (WorkManager — 5min)

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `lib/features/tracking/services/tracking_watchdog_service.dart` |
| **Introduit** | Build ~+87 (watchdog initial) |
| **Statut** | ✅ ACTIF (backup du rescue alarm) |
| **Principe** | Tâche périodique WorkManager toutes les 5 min. Vérifie si le foreground service tourne toujours. Si mort + shift actif → restart. |

**Contraintes** : `networkType: notRequired`, `requiresBatteryNotLow: false`, `requiresCharging: false` — tourne dans toutes les conditions.

### 3.4 Boot / Package Replaced Receiver

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `android/.../TrackingBootReceiver.kt` |
| **Introduit** | Build +52 (018) |
| **Statut** | ✅ ACTIF |
| **Principe** | Au redémarrage du téléphone ou après mise à jour de l'app, vérifie s'il y avait un shift actif et redémarre le tracking + rescue alarm chain. |

### 3.5 Guide OEM Battery Optimization

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `android/.../MainActivity.kt` (method channel) |
| **Introduit** | Build +52 (018), enrichi +84 (Samsung battery guard) |
| **Statut** | ✅ ACTIF |
| **Principe** | Deep links vers les paramètres batterie spécifiques à chaque fabricant (Samsung, Xiaomi, Huawei, OnePlus, OPPO, Honor). |

**Détection** :
- App standby bucket (`ACTIVE/WORKING_SET/FREQUENT/RARE/RESTRICTED`)
- Unused app restrictions status
- Guide utilisateur adapté au fabricant

### 3.6 disable_battery_optimization

| Attribut | Valeur |
|----------|--------|
| **Package** | `disable_battery_optimization 1.1.1` |
| **Statut** | ✅ ACTIF |
| **Principe** | Demande à l'utilisateur de désactiver l'optimisation batterie pour l'app. |

### 3.7 Permissions Android

```xml
ACCESS_FINE_LOCATION, ACCESS_BACKGROUND_LOCATION
FOREGROUND_SERVICE, FOREGROUND_SERVICE_LOCATION
SCHEDULE_EXACT_ALARM          <!-- pour setAlarmClock tier 2 -->
RECEIVE_BOOT_COMPLETED        <!-- boot receiver -->
POST_NOTIFICATIONS
REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
ACTIVITY_RECOGNITION
```

> **Note** : `USE_EXACT_ALARM` a été **supprimé** au build +91 (conflit Google Play policies).

---

## 4. Mécanismes Flutter (cross-platform)

### 4.1 FlutterForegroundTask — Configuration

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `lib/features/tracking/services/background_tracking_service.dart` |
| **Statut** | ✅ ACTIF |

```dart
ForegroundTaskOptions(
  eventAction: ForegroundTaskEventAction.repeat(30000), // heartbeat 30s
  autoRunOnBoot: true,
  autoRunOnMyPackageReplaced: true,
  allowWakeLock: true,
  allowWifiLock: true,
)
```

- Retry au démarrage : 3 tentatives avec backoff 500ms × attempt
- Restart : stop → wait 500ms → start

### 4.2 GPS Stream Recovery (Exponential Backoff)

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `lib/features/tracking/services/gps_tracking_handler.dart` |
| **Introduit** | Build +52 (018), raffiné continuellement |
| **Statut** | ✅ ACTIF |

**Backoff** : 1min → 2min → 4min → 8min → 15min (cap)

```
Tentative 0 → attente 1 min
Tentative 1 → attente 2 min
Tentative 2 → attente 4 min
Tentative 3 → attente 8 min
Tentative 4+ → attente 15 min (cap)
```

- **Pas de limite de tentatives** — retry indéfiniment
- Toutes les 5 échecs : notification au main isolate pour logging
- Action : annule le stream GPS + recrée un nouveau

### 4.3 GPS Self-Healing (Main Isolate Nudge)

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `lib/features/tracking/providers/tracking_provider.dart` |
| **Introduit** | Build +52 (018) |
| **Statut** | ✅ ACTIF |
| **Principe** | Si 2+ minutes sans point GPS du background, le main isolate envoie `recoverStream` comme dernier recours. Rate-limité à 1 fois par 2 min. |

### 4.4 GPS Loss Detection (45s)

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `gps_tracking_handler.dart` |
| **Seuil** | 45 secondes (réduit de 90s) |
| **Grace period** | 60s post-démarrage |
| **Statut** | ✅ ACTIF |
| **Action** | Notifie le main isolate → active SLC (iOS) |

### 4.5 Fréquence GPS Adaptive (vitesse + thermique)

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `gps_tracking_handler.dart` |
| **Statut** | ✅ ACTIF |

**Tiers de vitesse** :

| État | Vitesse | Intervalle de base |
|------|---------|-------------------|
| Stationnaire | < 0.5 m/s pendant 5 min | 60s |
| Actif (marche/véhicule) | ≥ 0.5 m/s | 10s |

**Multiplicateur thermique** :

| Niveau | Multiplicateur | Intervalle stationnaire | Intervalle actif |
|--------|---------------|------------------------|-----------------|
| Normal | ×1 | 60s | 10s |
| Élevé | ×2 | 120s | 20s |
| Critique | ×4 | 240s | 40s |

**Transition asymétrique** : Passage immédiat vers actif, mais 5 min de délai avant stationnaire (tolérance feu rouge / arrêt temporaire).

**Évolution** :
- Build +89 : Détection stationnaire basée sur la vitesse (3 min delay)
- Build +94 : Délai augmenté de 3 à 5 minutes

### 4.6 Thermal State Monitoring

| Attribut | Valeur |
|----------|--------|
| **Fichiers** | `BackgroundTaskPlugin.swift` (iOS), `MainActivity.kt` (Android), `tracking_provider.dart` |
| **Introduit** | Build +52 (018) |
| **Statut** | ✅ ACTIF |
| **Principe** | Écoute les changements d'état thermique du téléphone. Multiplie les intervalles GPS pour réduire la charge. |

- iOS : `ProcessInfo.thermalState` via NotificationCenter
- Android : `PowerManager.OnThermalStatusChangedListener` (API 29+)

### 4.7 Server Heartbeat (~90s)

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `tracking_provider.dart` |
| **RPC** | `ping_shift_heartbeat` |
| **Fréquence** | Toutes les 3 heartbeats FFT ≈ 90s |
| **Statut** | ✅ ACTIF |

- Met à jour `shifts.last_heartbeat_at` côté serveur
- Indépendant des points GPS (un shift peut avoir un heartbeat sans GPS)
- Toutes les 10 heartbeats (~5 min) : validation légère du statut du shift

### 4.8 Tracking Verification (30s)

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `tracking_provider.dart` |
| **Statut** | ✅ ACTIF |
| **Principe** | Timer de 30s au démarrage du tracking. Si aucun point GPS reçu → auto clock-out + dialog d'erreur. Empêche l'état "tracking bloqué". |

### 4.9 Connectivity Monitor

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `tracking_provider.dart` |
| **Statut** | ✅ ACTIF |
| **Principe** | Écoute les changements de connectivité. À la reconnexion, vérifie si le foreground service tourne encore. Si mort + shift actif → restart automatique. |

### 4.10 Activity Recognition (Ghost Trip Prevention)

| Attribut | Valeur |
|----------|--------|
| **Package** | `flutter_activity_recognition ^4.0.0` |
| **Introduit** | Build ~+52 (feature 050) |
| **Statut** | ✅ ACTIF |
| **Principe** | Détecte l'activité physique (still/walking/in_vehicle). Envoyé au background handler. Utilisé par le serveur pour filtrer les ghost trips (activity_type='still' supprime le mouvement). |

### 4.11 Midnight Warning + Auto Clock-Out

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `tracking_provider.dart` |
| **Statut** | ✅ ACTIF |
| **Principe** | 23:55 → notification d'avertissement. 00:00-00:05 → validation du statut du shift (le serveur ferme à minuit via pg_cron). |

### 4.12 Transient Provider Rebuild Guard

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `tracking_provider.dart` |
| **Statut** | ✅ ACTIF |
| **Principe** | Empêche les faux arrêts lors des rebuilds de `authStateChangesProvider`. Valide le shift dans SQLCipher avant d'arrêter le tracking. |

### 4.13 GPS Alert Notification (5 min)

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `gps_tracking_handler.dart`, `tracking_provider.dart`, `notification_service.dart` |
| **Introduit** | Build +98 |
| **Statut** | ✅ ACTIF |
| **Seuil** | 5 minutes sans point GPS |
| **Principe** | Le background handler envoie un message `gps_alert` au main isolate après 5 min sans GPS. Le main isolate affiche une notification persistante "Suivi de position interrompu". Automatiquement dismiss quand un point GPS est reçu. |

### 4.14 Native GPS Buffer Drain

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `sync_service.dart` |
| **Introduit** | Build +98 |
| **Statut** | ✅ ACTIF |
| **Principe** | Step 0 de `syncAll()` — lit les GPS buffers natifs via MethodChannel (Android: `gps_tracker/device_manufacturer`, iOS: `gps_tracker/native_gps_buffer`), crée des `LocalGpsPoint`, insère dans SQLCipher. |

### 4.15 Breadcrumb Logging (Watchdog)

| Attribut | Valeur |
|----------|--------|
| **Fichier** | `tracking_watchdog_service.dart`, `TrackingRescueReceiver.kt` |
| **Statut** | ✅ ACTIF |
| **Format** | `2026-03-03T12:00:00Z|source|action|shift-id` |
| **Limite** | 20 entrées max dans SharedPreferences |
| **Sync** | Lu par DiagnosticLogger au resume de l'app |

---

## 5. Mécanismes serveur (Supabase)

### 5.1 Midnight Shift Cleanup (pg_cron)

| Attribut | Valeur |
|----------|--------|
| **Migration** | 030 |
| **Statut** | ✅ ACTIF |
| **Fréquence** | Toutes les 5 min (pg_cron) |
| **Action** | Ferme les shifts actifs **uniquement à minuit Eastern** (America/Montreal) |

> Important : Le clock-out ne devrait arriver QUE depuis l'app, sauf le reset de minuit.

### 5.2 GPS-less Shift Monitoring

| Attribut | Valeur |
|----------|--------|
| **Migration** | 098 (flag_gpsless_shifts) |
| **Statut** | ✅ ACTIF |
| **Fréquence** | Toutes les 10 min (pg_cron) |
| **Action** | Flag les shifts actifs avec 0 GPS après 10 min. Auto-ferme ces shifts "zombie". |

### 5.3 Heartbeat Trigger

| Attribut | Valeur |
|----------|--------|
| **Principe** | Trigger sur INSERT de gps_points → met à jour `shifts.last_heartbeat_at` automatiquement |
| **Statut** | ✅ ACTIF |
| **Complément** | RPC `ping_shift_heartbeat` appelé toutes les ~90s par l'app (indépendant des GPS points) |

### 5.4 FCM Silent Push Wake (pg_cron + Edge Function)

| Attribut | Valeur |
|----------|--------|
| **Migrations** | 127 (fcm_wake_push), 128 (wake_stale_devices_cron) |
| **Edge Function** | `send-wake-push` |
| **Introduit** | Build +98 (server-side prêt, client-side en attente Firebase) |
| **Statut** | ⏳ PRÊT côté serveur — en attente d'intégration Firebase côté client |
| **Fréquence** | Toutes les 2 min (pg_cron) |
| **Throttle** | Max 1 push par 5 min par device |

**Comment ça marche** :
1. pg_cron appelle `send-wake-push` Edge Function toutes les 2 min via pg_net
2. La fonction appelle `get_stale_active_devices()` (shifts actifs + heartbeat > 5 min + FCM token valide)
3. Pour chaque device stale : envoie un silent push FCM v1 (Android `priority: high`, iOS `content-available: 1`)
4. `record_wake_push()` met à jour `last_wake_push_at` pour le throttle

**Prérequis non-déployé** : Firebase doit être configuré côté Flutter (Task 10-11 du plan Firebase) + `FIREBASE_SERVICE_ACCOUNT_KEY` en secret Supabase. Sans ça, la fonction retourne `{sent: 0, skipped: true}` (no-op gracieux).

### 5.5 Advisory Locks (detect_trips / detect_carpools)

| Attribut | Valeur |
|----------|--------|
| **Migration** | 126 (advisory_locks_detect_trips) |
| **Introduit** | Build +98 |
| **Statut** | ✅ ACTIF |
| **Principe** | `pg_advisory_xact_lock` empêche l'exécution concurrente de `detect_trips` (clé: shift_id) et `detect_carpools` (clé: date). Prévient les deadlocks DB. |

### 5.6 Minimum App Version Enforcement

| Attribut | Valeur |
|----------|--------|
| **Migration** | 097 (enforce_clock_in_version) |
| **Statut** | ✅ ACTIF |
| **Principe** | `app_config.minimum_app_version` bloque le clock-in pour les builds obsolètes. Dialog de mise à jour avec lien vers le store. |

---

## 6. Historique des builds — Focus tracking/résilience

### Phase 1 : Fondations (Builds +26 à +51)

| Build | Date | Changement | Statut |
|-------|------|-----------|--------|
| +26 | Feb 20 | GPS tracking fiable de base, suppression auto clock-out | ✅ Base |
| +44 | Feb 24 | Mileage tracking + trip detection | ✅ Actif |

### Phase 2 : Background Resilience (Build +52)

| Build | Date | Changement | Statut |
|-------|------|-----------|--------|
| +52 | Feb 24 | **018-background-tracking-resilience** : CLBackgroundActivitySession, beginBackgroundTask, SLC, Live Activity, thermal monitoring, OEM battery guide, FGS auto-restart | ✅ Actif (colonne vertébrale) |
| +53 | Feb 24 | **019-diagnostic-logging** : DiagnosticLogger, SQLCipher local, Supabase sync, 9 catégories | ✅ Actif |

### Phase 3 : Raffinements iOS (Builds +55 à +65)

| Build | Date | Changement | Statut |
|-------|------|-----------|--------|
| +55 | Feb 25 | SLC activé au clock-in (pas différé) | ⚠️ Remplacé par activation différée |
| +65 | Feb 25 | Suppression notifications GPS lost/restored | ✅ Actif (UX cleanup) |

### Phase 4 : Android Watchdog Saga (Builds +83 à +94)

C'est la phase la plus mouvementée. Android 16 a introduit des restrictions sévères sur les alarmes exactes.

| Build | Date | Changement | Problème résolu / créé |
|-------|------|-----------|----------------------|
| +83 | Feb 28 | GPS gap resilience (cluster splitting prevention) | ✅ Actif |
| +84 | Feb 28 | Samsung battery guard, app standby detection | ✅ Actif |
| +87 | Feb 28 | `android_alarm_manager_plus` pour watchdog 60s | ❌ **Crash sur Android 16** |
| +88 | Feb 28 | **Supprimé** `android_alarm_manager_plus` | ✅ Fix du crash |
| +89 | Mar 1 | Stationary detection basée sur la vitesse (3 min) | ✅ Actif (modifié à 5 min) |
| +90 | Mar 2 | `TrackingRescueReceiver` natif Kotlin avec `setExactAndAllowWhileIdle()` 60s | ⚠️ Throttled par Doze Android 16 |
| +91 | Mar 2 | Supprimé permission `USE_EXACT_ALARM` | ✅ Fix politique Google Play |
| +94 | Mar 3 | **Réécriture** : `setAlarmClock()` comme tier principal, 45s, 3 tiers | ✅ **Solution actuelle** |
| +95 | Mar 3 | Stationary delay 3→5 min, GPS gap time window filter | ✅ Actif |
| +96 | Mar 3 | Dashboard: approval grid hours breakdown | ✅ (dashboard only) |

### Phase 5 : Background Resilience v2 (Build +98)

| Build | Date | Changement | Statut |
|-------|------|-----------|--------|
| +98 | Mar 3 | **Advisory locks** sur detect_trips/detect_carpools (migration 126) — prévient deadlocks DB concurrents | ✅ Actif |
| +98 | Mar 3 | **detect_trips retiré du cycle actif** — exécuté seulement sur shifts complétés, réduit contention DB | ✅ Actif |
| +98 | Mar 3 | **Stationary interval 120s→60s** — détection de gap GPS 2x plus rapide quand immobile | ✅ Actif |
| +98 | Mar 3 | **NativeGpsBuffer Android** (Kotlin, SharedPreferences) — capture GPS native dans rescue alarm, max 100 pts | ✅ Actif |
| +98 | Mar 3 | **NativeGpsBuffer iOS** (Swift, UserDefaults) — capture GPS native dans SLC callback, max 100 pts | ✅ Actif |
| +98 | Mar 3 | **Native buffer drain** (sync_service.dart) — Step 0 de syncAll(), lit buffers natifs via MethodChannel | ✅ Actif |
| +98 | Mar 3 | **GPS alert notification** — notification persistante après 5 min sans GPS, auto-dismiss au retour | ✅ Actif |
| +98 | Mar 3 | **FCM wake push server-side** (migrations 127-128, Edge Function) — pg_cron 2min, silent push, throttle 5min | ⏳ Prêt (attend Firebase client) |
| +99 | Mar 4 | iOS Fastfile réécriture xcodebuild direct avec API key auth (nouveau Mac) | ✅ (iOS deploy only) |
| +100 | Mar 4 | Fix `MinimumOSVersion` manquant dans AppFrameworkInfo.plist, widget extension version sync (`$(CURRENT_PROJECT_VERSION)`) | ✅ Actif |
| +101 | Mar 5 | **NativeGpsBuffer 100→500 pts** (iOS+Android) — couvre ~6.25h au lieu de 75min | ✅ Actif |
| +101 | Mar 5 | **GeofenceWakeReceiver** (Android) — geofence 200m, redémarre tracking si l'employé bouge après un kill Samsung | ✅ Actif |
| +101 | Mar 5 | **Dialogue batterie OEM obligatoire** avant clock-in sur Android | ✅ Actif |
| +101 | Mar 5 | **Watchdog relance rescue alarm** après restart FFT | ✅ Actif |
| +101 | Mar 5 | **FCM client activé** — Firebase init (non-bloquant), FCM token enregistré, kill switch migration 132 | ✅ Actif |
| +101 | Mar 5 | Dashboard : untracked time gaps dans approval timeline, GPS freshness badges sidebar, badge monitoring | Dashboard |
| +102 | Mar 5 | iOS push notification entitlement APS ajouté, dashboard overlap prevention geofences (migration 133), map fixes — pas de changement tracking | ✅ Stable |
| +103 | Mar 6 | **BGAppRefreshTask iOS** (Swift native + Dart bridge) — relance l'app quand employé stationnaire, schedule ~5min, breadcrumbs UserDefaults | ✅ Actif |
| +103 | Mar 6 | **Firebase init différé** — attend 3s + foreground avant init Firebase ; background launches (SLC) skip Firebase pour éviter Jetsam kills iOS | ✅ Actif |
| +103 | Mar 6 | **FCM background handler amélioré** — vérifie shift actif, relance app via `FlutterForegroundTask.launchApp()` si service mort | ✅ Actif |
| +103 | Mar 6 | **verifyTrackingHealth()** sur interactions utilisateur (QR scan in/out, maintenance) — redémarre tracking si iOS l'a tué. Remplacé par GpsHealthGuard en +109 | ✅ → Upgraded +109 |
| +103 | Mar 6 | **FCM foreground listener** — log diagnostic quand wake reçu en foreground (no-op, déjà en marche) | ✅ Actif |
| +103 | Mar 6 | **Orphan GPS log batching** — logs quarantaine groupés par shift au lieu d'un par point (réduit spam diagnostic) | ✅ Actif |
| +103 | Mar 6 | Dashboard : satellite/roadmap toggle sur toutes les cartes location | Dashboard |
| +104 | Mar 6 | **HOTFIX** — `FirebaseMessaging.instance` crash quand Firebase pas encore initialisé (deferred 3s). try/catch ajouté dans app.dart + fcm_service.dart | ✅ Fix |
| +105 | Mar 6 | **Remplacement google_maps_flutter → flutter_map** (OpenStreetMap) — élimine crash shift detail quand clé API Google Maps absente. 5 fichiers convertis : gps_route_map, fullscreen_map_screen, trip_route_map, shift_detail_screen, polyline_decoder | ✅ Fix |
| +106 | Mar 6 | **Pause dîner** — stopTracking(reason: 'lunch_break') pendant la pause, reprise startTracking() à la fin. Live Activity status 'lunch'. Sync lunch_breaks via sync_service. Pas de changement aux mécanismes de résilience eux-mêmes | ✅ Actif |
| +107 | Mar 7 | **UI dîner + fix build iOS apostrophe** — Chrono travail = durée - lunch. Chrono dîner temps réel (orange). Fix CocoaPods eval→direct codesign (apostrophe path). Fix com.apple.provenance xattr (build phase sur tous les Pod targets). Aucun changement tracking/résilience | ✅ Actif |
| +108 | Mar 7 | **Sync lunch break au start** — `notifyPendingData()` appelé dans `startLunchBreak()` (pas seulement `endLunchBreak()`). `getPendingLunchBreaks()` retire filtre `ended_at IS NOT NULL`. `endLunchBreak()` reset `sync_status=pending`. Dashboard : badge orange sidebar (Realtime `lunch_breaks`). Approval timeline : lunch = ligne distincte avec durée | ✅ Actif |
| +109 | Mar 7 | **GPS Health Guard** — remplace `verifyTrackingHealth()` fire-and-forget par système 2 tiers : **hard gate** (awaited, timeout 5s) sur clock-out, QR scan in/out, maintenance start/complete, lunch end ; **soft nudge** (fire-and-forget, debounce 30s) via `NavigatorObserver` + `Listener` sur toutes navigations et taps. Logs structurés DiagnosticLogger (source, tier, durée, shift_id). Dashboard : timezone fixes, GPS gap approval grouping | ✅ Actif |
| +110 | Mar 9 | **Telemetry Phase 1-3** — Firebase Crashlytics (double-write DiagnosticLogger), battery_level sur gps_points, app lifecycle logging. **iOS DiagnosticNativePlugin** (MetricKit, CLLocationManager pause/resume, memory pressure). **Android DiagnosticNativePlugin** (GNSS satellite 60s, doze mode BroadcastReceiver, standby bucket 5min). Fix : DiagnosticNativePlugin.swift ajouté au Xcode project + `pausesLocationUpdatesAutomatically` corrigé. Migration 142 (battery_level + 17 catégories diagnostiques) | ✅ Actif |
| +111 | Mar 9 | Dashboard/mileage UI updates only — aucun changement tracking/résilience | ✅ Actif |
| +112 | Mar 9 | **Fix FCM token race condition** — `registerToken()` + `listenForTokenRefresh()` appelés dans `_initializeFirebase()` après succès Firebase init. Avant : token uniquement tenté au widget build (~200ms), toujours avant Firebase init (3s) → échec silencieux, token jamais enregistré, push wake impossibles | ✅ Fix |
| +113 | Mar 10 | **Fix sync race condition sessions ménage/entretien** — `startSession()` et `scanIn()` attendaient `serverShiftId` du shift, mais si shift sync encore en vol → UUID local envoyé au RPC → `NO_ACTIVE_SHIFT` silencieux. Fix : retry `resolveServerShiftId()` 5×500ms. Ajout `_syncPendingQuietly()` dans `_initialize()` des providers cleaning + maintenance (avant : sync uniquement sur changement connectivité). Dashboard : refactors approval, weekly summary, transport mode sensor speed, project sessions | ✅ Fix |
| +114 | Mar 10 | **Fix lunch break duplicates + approvals** — Race condition `startLunchBreak()` : ajout vérification DB avant insert (si `_init()` async pas terminé → état mémoire faux). Migration SQL : restaure `lunch_minutes` dans `get_weekly_approval_summary` et `_get_day_approval_detail_base`, remplace `get_day_approval_detail` monolithique par thin wrapper. Nettoyage 10 micro-breaks (<60s) Supabase. Aucun changement tracking/résilience | ✅ Fix |
| +115 | Mar 10 | **Fix maintenance sessions non sync** — Deux surcharges `start_maintenance` RPC (4 et 7 params) causaient ambiguïté PostgREST : l'ancienne version bloquait si cleaning session active au lieu de l'auto-closer. Erreurs RPC avalées silencieusement (retournaient success). Fix : supprimé l'ancienne surcharge 4 params, ajouté coords GPS au RPC call Dart, propagé erreurs serveur au lieu de les masquer. Dashboard : fix monitoring GPS stale data merge, approval dashboard fixes | ✅ Fix |
| +116 | Mar 10 | **Server-side session cleanup** — `server_close_all_sessions()` ferme atomiquement cleaning+maintenance+lunch+shift côté serveur. `register_device_login()` appelle cette fonction si device change (plus besoin que l'ancien téléphone coopère). Nouveau RPC `sign_out_cleanup()` appelé avant signOut. Flutter : retiré client-side clockOut du force-logout, ajouté warning shift actif dans dialogue déconnexion. Aucun changement tracking/résilience directement — améliore la fermeture propre des sessions | ✅ Fix |
| +117 | Mar 10 | **3 fixes résilience GPS Android** — (1) **Fix Firebase init race** : `FcmService.registerToken()` guardé par `isFirebaseInitialized` — élimine erreur `[core/no-app]` qui affectait 100% des employés, wake push FCM maintenant fonctionnel. (2) **Native GPS sync direct** : `NativeGpsSyncer.kt` (OkHttp) POST les points GPS natifs directement à Supabase depuis `TrackingRescueReceiver` — GPS arrive en temps réel même quand Dart engine mort. `NativeGpsBuffer` génère `client_id` déterministe pour dedup. (3) **Télémétrie device health au clock-in** : log battery_optimization_exempt, standby_bucket, manufacturer, api_level au démarrage de chaque quart Android — identification proactive des appareils à risque | ✅ Résilience |
| +118 | Mar 11 | **Fix GPS hors shift** — nettoyage 3532 points GPS orphelins hors fenêtre de shift (migration 147 : `approval_detail_shift_window_filter`). Callback shifts (rappels) : `shift_type` colonne, auto-détection trigger, catégories employé. Dashboard : callback toggle, bonus 3h minimum. App Flutter : badges rappel, visibilité approbation employé (summary, breakdown par lieu, timeline activités, carte trajets OSRM). Aucun changement aux mécanismes de résilience tracking | ✅ Stable |
| +119 | Mar 11 | **Fix approbation sur mauvais écrans** — Les widgets d'approbation (badge, summary, breakdown, timeline, carte trajets) étaient sur `features/shifts/` mais la navigation principale utilise `features/history/`. Portage vers `my_history_screen`, `shift_history_card`, `shift_detail_screen` (historique). Aucun changement tracking/résilience | ✅ UI Fix |
| +120 | Mar 11 | **Fix approbation mauvais employé** — `dayApprovalDetailProvider` et `dayApprovalSummariesProvider` utilisaient `currentUser.id` au lieu de l'`employeeId` du quart consulté → superviseur voyait ses propres données d'approbation en regardant un subordonné. Fix : paramètre `employeeId` explicite. Migration RLS : `supervisor_view_subordinate_day_approvals` sur `day_approvals`. Aucun changement tracking/résilience | ✅ Data Fix |
| +121 | Mar 11 | **Carte interactive activités/lieux** — Tap sur un arrêt ou déplacement dans la timeline/répartition par lieu ouvre un bottom sheet avec carte flutter_map (marker pour stops, polyline OSRM pour trips). Nouveau widget `ActivityMapSheet` + callbacks `onActivityTap`/`onLocationTap`. Aucun changement tracking/résilience | ✅ UI |
| +122 | Mar 11 | **Fix carte trajets** — Titre bottom sheet affiche noms de lieux (via `startLocationName`/`endLocationName`) au lieu de coordonnées GPS. Polyline OSRM connectée aux points GPS départ/arrivée (prépend start, append end) pour éliminer le gap entre marqueur et tracé. Aucun changement tracking/résilience | ✅ UI Fix |
| +123 | Mar 11 | **Fix trajets multi-quarts + refresh approbations** — `tripsForShiftProvider` remplacé par `tripsForPeriodProvider` (charge tous les trips de la journée) pour corriger les 3 premiers déplacements non-cliquables quand employé a plusieurs quarts/jour. `dayApprovalDetailProvider` → `autoDispose` pour rafraîchir données d'approbation à chaque ouverture. Migrations backend : `work_sessions` table + RPCs. Aucun changement tracking/résilience | ✅ Fix |
| +124 | Mar 11 | **Sessions de travail unifiées (Phase 1)** — `cleaning_sessions` + `maintenance_sessions` fusionnées dans `work_sessions` (table, 6 RPCs, sync triggers bidirectionnels). Flutter : `ActivityTypePicker` au clock-in (Ménage/Entretien/Admin), `ActiveWorkSessionCard` + `WorkSessionHistoryList` remplacent onglets séparés. Dashboard : nouvelle page `/work-sessions`, sidebar mise à jour. Auto-close intégré au clock-out. Aucun changement tracking/résilience — restructuration sessions uniquement | ✅ Stable |
| +126 | Mar 11 | **Fix sessions ménage bloquées** — `ActiveWorkSessionCard` importait l'ancien `QrScannerScreen` (cleaning) au lieu du nouveau (work_sessions) → scan QR cherchait dans `local_cleaning_sessions` au lieu de `local_work_sessions`, rendant impossible la fin de session par scan. Fix import + `startSession` retourne maintenant succès local même si RPC serveur rejette (évite sessions fantômes). Aucun changement tracking/résilience | ✅ Fix |
| +125 | Mar 11 | **UX : carte active minimaliste + 4 bugfixes** — `ShiftStatusCard` redessinée (timer live, badge combiné sync+points cliquable → `SyncDetailSheet` enrichi avec infos quart/GPS). Fix RPC name `manually_close_work_session`, fix admin `location_type='office'`, fix `completeSession` passe `p_session_id`, fix building filter dashboard. `SessionStartSheet` bottom sheet, auto-close QR scan, lunch button masqué pendant pause. Aucun changement tracking/résilience | ✅ Stable |
| +127 | Mar 12 | **Dashboard : position pointage sur carte monitoring** — `GoogleTeamMap` affiche la position de clock-in comme marker sur la carte d'équipe, `TeamList` affiche coordonnées clock-in dans la liste. Aucun changement tracking/résilience — dashboard only | ✅ UI |
| +128 | Mar 12 | **UX : suppression carte ShiftTimer redondante, dîner dans historique, auto-close session sur lunch** — `ShiftTimer` retiré (doublon avec `ShiftStatusCard` qui affiche déjà temps de travail). `ShiftStatusCard` calcule maintenant temps réel travail (elapsed - lunch), affiche "Pause dîner" orange quand en pause. `startLunchBreak()` ferme automatiquement la session active avant de démarrer le dîner. `WorkSessionHistoryList` fusionne lunch breaks et work sessions triés chronologiquement. GPS tracking pause/resume inchangé | ✅ UX |
| +129 | Mar 12 | **Sessions serveur-requises + monitoring session visible** — `startSession()` et `completeSession()` exigent maintenant confirmation serveur (bloquent si offline au lieu de créer localement). Sessions orphelines nettoyées via `SyncService.syncAll()`. Dashboard monitoring : badge session affiché au-dessus du lieu de pointage, visible même pour sessions admin sans lieu. Aucun changement tracking/résilience — sync et UI uniquement | ✅ Sync |
| +130 | Mar 12 | **Fix crash RPC `start_work_session`** — PostgreSQL "record not assigned yet" causait échec 100% des sessions (admin, maintenance, cleaning). RECORD variables remplacées par variables individuelles TEXT/UUID. Contrainte `chk_ws_cleaning_has_studio` remplacée par `chk_ws_cleaning_has_location` (studio OU building). Fix propagation erreurs `WorkSessionResult` (3 endroits message→errorType au lieu de errorMessage). `_humanReadableError()` pour messages français. **`_isStationary` initialisé à `true`** — GPS tracking commence stationnaire au lieu d'actif, switch sur mouvement | ✅ Fix + ⚡ Tracking |
| +131 | Mar 12 | **Fix `NO_SERVER_SHIFT` — sessions impossibles après clock-in** — 3 bugs combinés causaient `activeShift.serverId = null` → erreur "Connexion requise" sur toute session. (1) `getActiveShift()` `LIMIT 1` sans `ORDER BY` retournait un quart local obsolète sans `server_id` au lieu du plus récent. Fix : `ORDER BY created_at DESC`. (2) `markShiftSynced()` sans paramètre `serverId` écrasait le `server_id` existant à null. Fix : update conditionnel. (3) `ClockInResult` ne reconnaissait pas `status: 'reopened'` comme succès → cycle inutile clock-out+retry. Fix : ajouté `'reopened'`. (4) `closeAllActiveShifts()` bulk cleanup en réconciliation — ferme TOUS les quarts locaux obsolètes, pas un seul. Aucun changement tracking/résilience | ✅ Fix |
| +132 | Mar 12 | **Failsafe serveur direct pour `NO_SERVER_SHIFT`** — Si `serverShiftId` est null ET la résolution locale échoue (5 retries), `startSession()` fait maintenant une requête directe Supabase `shifts WHERE employee_id AND status='active'` comme dernier recours avant d'échouer. Élimine toute dépendance sur la cohérence du `server_id` local pour démarrer une session | ✅ Fix |
| +133 | Mar 12 | Dashboard : positions pointage carte monitoring, dîner historique, auto-close session sur lunch, sessions serveur-requises, fix crash RPC `start_work_session`, fix `NO_SERVER_SHIFT`, failsafe serveur direct — aucun changement tracking/résilience | ✅ Stable |
| +134 | Mar 12 | **Exit Reason Collection** — Nouveau mécanisme de diagnostic : **ExitReasonPlugin Android** (Kotlin) lit `ApplicationExitInfo` (API 30+) au lancement, `setProcessStateSummary()` écrit état shift/GPS toutes les 30s depuis `_handleHeartbeat()` (main isolate). **ExitReasonPlugin iOS** (Swift) lit `MXAppExitMetric` (iOS 15+) via `pastPayloads` avec delta UserDefaults, buffer crash diagnostics MetricKit. **ExitReasonCollector** (Dart) insère directement dans SQLCipher (`EventCategory.exitInfo`), `deviceId` comme `employee_id` temporaire → résolu en `auth.uid()` au sync. MetricKit retiré de `DiagnosticNativePlugin` (centralisé dans ExitReasonPlugin). Migration v10 SQLCipher : supprimé CHECK `event_category` (limitait à 9 catégories, l'app en a 18+). Migration Supabase : supprimé CHECK `diagnostic_logs_event_category_check`. Dashboard : corrections manuelles de temps, taux horaires employés, prime ménage weekend, export feuille de temps enrichie | ✅ Diagnostic |

### Chronologie complète Android Watchdog

```
android_alarm_manager_plus (plugin Flutter)
  → ❌ Crash Android 16 (build +87)
  → Supprimé (build +88)

TrackingRescueReceiver v1 (Kotlin natif, setExactAndAllowWhileIdle, 60s)
  → ⚠️ Throttled par Doze Android 16 (build +90)
  → USE_EXACT_ALARM supprimé (build +91)

TrackingRescueReceiver v2 (Kotlin natif, setAlarmClock tier principal, 45s)
  → ✅ Solution actuelle (build +94)
  → setAlarmClock() jamais throttled par Doze
  → Fallback: setExactAndAllowWhileIdle → setAndAllowWhileIdle
```

---

## 7. Bilan — Ce qui fonctionne vs ce qui ne fonctionne pas

### ✅ Fonctionne bien

| Mécanisme | Plateforme | Pourquoi ça marche |
|-----------|------------|-------------------|
| CLBackgroundActivitySession | iOS 17+ | API officielle Apple pour les apps de localisation continue |
| distanceFilter: 0 | iOS | Empêche iOS de suspendre l'app quand stationnaire |
| SLC différé | iOS | Relance l'app après kill, mais seulement si nécessaire |
| setAlarmClock() 45s | Android | Jamais throttled par Doze — conçu pour les réveils |
| Foreground Service (stopWithTask=false) | Android | Survit même si l'app est tuée |
| Boot/Package Receiver | Android | Reprend le tracking après reboot/mise à jour |
| Exponential backoff (stream recovery) | Both | Retry infini mais pas agressif |
| Server heartbeat (~90s) | Both | Détecte les shifts zombie côté serveur |
| Diagnostic logging | Both | Visibilité sur ce qui se passe en background |
| Exit reason collection | Both | Android: `ApplicationExitInfo` per-event + `processStateSummary` 30s. iOS: MetricKit cumulative deltas. Diagnostique pourquoi l'OS a tué l'app |

### ⚠️ Fonctionne partiellement

| Mécanisme | Plateforme | Limitation |
|-----------|------------|-----------|
| WorkManager (5 min) | Android | Période minimale 15 min en pratique (OS peut retarder). Backup du rescue alarm. |
| beginBackgroundTask | iOS | Seulement ~30s. Utile pendant la transition, pas pour le long terme. |
| Activity Recognition | Both | Parfois imprécis (still détecté en voiture à l'arrêt). Fail-open = ok. |
| Thermal monitoring | Both | Réduit la fréquence GPS mais ne peut pas empêcher l'OS de tuer l'app si le téléphone surchauffe. |

### ❌ N'a pas fonctionné / Supprimé

| Mécanisme | Plateforme | Problème | Build |
|-----------|------------|----------|-------|
| `android_alarm_manager_plus` | Android | **Crash sur Android 16** | +87→+88 (supprimé) |
| `USE_EXACT_ALARM` permission | Android | Conflit avec les policies Google Play | +90→+91 (supprimé) |
| `setExactAndAllowWhileIdle()` comme méthode principale | Android | **Throttled par Doze sur Android 16** | +90→+94 (rétrogradé en tier 2) |
| SLC activé immédiatement au clock-in | iOS | Consommation batterie inutile si GPS fonctionne bien | +55→remplacé par activation différée |
| Notifications GPS lost/restored | Both | Anxiogène pour l'utilisateur, pas actionnable | +65 (supprimé) |
| Auto clock-out sur heartbeat timeout | Both | Fermait le shift des travailleurs hors réseau | +26 (supprimé) |
| 15-min heartbeat cap / 16h shift cap | Server | Trop restrictif pour les longs shifts | Migration 030 (supprimé, remplacé par midnight-only) |

---

## 8. Pistes d'amélioration

### 8.1 Ce qu'on pourrait encore faire

| Idée | Plateforme | Complexité | Impact potentiel |
|------|------------|-----------|-----------------|
| **BGProcessingTask** (iOS 13+) | iOS | Moyenne | Tâche de fond planifiée par iOS — pourrait vérifier le tracking après un kill |
| ~~**Geofencing API**~~ | ~~Both~~ | ~~Moyenne~~ | ✅ Implémenté (+101) — GeofenceWakeReceiver Android avec 200m exit trigger |
| ~~**Push-to-Wake** (Silent Push)~~ | ~~Both~~ | ~~Faible~~ | ✅ Implémenté (+98→+101) — FCM silent push server-side (pg_cron 2min) + client FCM service |
| **Persistent connection** (WebSocket/SSE) | Both | Élevée | Connexion permanente qui garderait l'app éveillée — mais coûteux en batterie |
| **Companion Watch App** | Both | Élevée | Apple Watch / Wear OS peut continuer le tracking si le téléphone tue l'app |
| **Native GPS stream** (bypass Flutter) | Both | Élevée | GPS directement en natif Swift/Kotlin au lieu de passer par geolocator — éliminerait la couche Flutter comme point de failure |
| **Foreground Service type "specialUse"** | Android 14+ | Faible | Nouveau type Android 14 qui pourrait être plus approprié que "location" |
| **User-facing health dashboard** | Both | Faible | Indicateurs dans l'app : batterie, GPS status, dernière capture, service actif |
| **Smart GPS frequency** (ML-based) | Both | Élevée | Apprendre les patterns de déplacement de chaque employé pour optimiser les intervalles |

### 8.2 Risques connus non adressés

| Risque | Probabilité | Impact | Mitigation actuelle |
|--------|------------|--------|-------------------|
| iOS tue l'app en zone sans réseau cellulaire | Moyenne | SLC ne peut pas relancer (pas de cellules) | Exponential backoff + retry au retour en zone |
| Android OEM agressif (Xiaomi MIUI, Samsung OneUI) | Élevée | Tue le foreground service malgré tout | Guide OEM + disable_battery_optimization + rescue alarm |
| Téléphone en mode batterie ultra-économie | Faible | Toutes les apps background sont tuées | Rien — l'utilisateur a choisi de tout couper |
| iOS Low Power Mode | Moyenne | Réduit la fréquence GPS | Thermal monitoring réduit les intervalles |
| Reboot du téléphone pendant un shift | Faible | Perte de GPS entre le reboot et la reconnexion | Boot receiver reprend le tracking (Android) |

---

## Annexe : Résumé des fichiers clés

| Fichier | Rôle |
|---------|------|
| `ios/Runner/AppDelegate.swift` | Enregistre les plugins natifs iOS |
| `ios/Runner/SignificantLocationPlugin.swift` | SLC — relance après kill iOS |
| `ios/Runner/BackgroundTaskPlugin.swift` | CLBackgroundActivitySession + beginBackgroundTask + thermal |
| `ios/Runner/LiveActivityPlugin.swift` | Lock Screen tracking status |
| `ios/Runner/NativeGpsBuffer.swift` | UserDefaults GPS buffer (max 500 pts) |
| `ios/Runner/BackgroundAppRefreshPlugin.swift` | BGAppRefreshTask — relance app quand stationnaire (~5min) |
| `lib/features/tracking/services/bg_app_refresh_service.dart` | Dart bridge pour BGAppRefreshTask iOS |
| `android/.../TrackingRescueReceiver.kt` | Rescue alarm chain (setAlarmClock 45s) + native GPS capture |
| `android/.../GeofenceWakeReceiver.kt` | Geofence 200m — redémarre tracking après kill Samsung |
| `android/.../NativeGpsBuffer.kt` | SharedPreferences GPS buffer (max 500 pts) |
| `android/.../TrackingBootReceiver.kt` | Boot/update recovery |
| `android/.../MainActivity.kt` | OEM battery guide + thermal + rescue alarm + native buffer drain |
| `lib/features/tracking/services/background_tracking_service.dart` | FFT lifecycle manager |
| `lib/features/tracking/services/gps_tracking_handler.dart` | Background isolate — GPS capture + recovery |
| `lib/features/tracking/services/tracking_watchdog_service.dart` | WorkManager 5min watchdog |
| `lib/features/tracking/providers/tracking_provider.dart` | Main isolate — state + self-healing + heartbeat + GPS alert |
| `lib/features/shifts/services/sync_service.dart` | Sync cycle + native buffer drain (Step 0) |
| `lib/shared/services/fcm_service.dart` | FCM silent push — token registration + kill switch |
| `lib/shared/services/notification_service.dart` | Local notifications (midnight, GPS alert) |
| `supabase/migrations/030_*` | Midnight cleanup pg_cron |
| `supabase/migrations/098_*` | GPS-less shift monitoring |
