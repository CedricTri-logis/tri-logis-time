# Data Model: 018 - Background Tracking Resilience

## Overview

This feature introduces **no new database tables or columns**. All changes are client-side (Flutter mobile app + native iOS/Android platform code).

## Existing Tables Used (Read-Only)

| Table | Usage in This Feature |
|-------|----------------------|
| `shifts` | Read `activeShift` to determine if tracking should be active; `last_heartbeat_at` updated by existing heartbeat mechanism |
| `gps_points` | GPS points written by existing capture pipeline (no changes) |
| `app_config` | Read `minimum_app_version` (no changes) |

## Local State (Client-Side Only)

### New SharedPreferences Keys

| Key | Type | Default | Purpose |
|-----|------|---------|---------|
| `oem_setup_completed` | `bool` | `false` | Persists whether the user has completed OEM-specific battery optimization setup. Prevents re-showing the guide on every clock-in. |
| `oem_setup_manufacturer` | `String?` | `null` | Stores the manufacturer at time of setup completion, to re-show if user switches devices. |

### New In-Memory State (Provider-Scoped)

| Field | Type | Location | Purpose |
|-------|------|----------|---------|
| `_significantLocationActive` | `bool` | `TrackingNotifier` | Tracks whether SLC is currently monitoring (for deferred activation) |
| `_currentThermalLevel` | `ThermalLevel` | `TrackingNotifier` | Current device thermal state for GPS frequency adaptation |
| `_foregroundServiceDied` | `bool` | `TrackingNotifier` | Flag set when foreground service is detected as dead during active shift |

### Thermal Level Enum

```dart
enum ThermalLevel {
  normal,    // No adaptation
  elevated,  // Moderate — double GPS interval
  critical,  // Severe+ — 5x GPS interval, reduce accuracy
}
```

Mapped from platform-specific values:
- iOS: `.nominal`/`.fair` → normal, `.serious` → elevated, `.critical` → critical
- Android: `NONE`/`LIGHT` → normal, `MODERATE`/`SEVERE` → elevated, `CRITICAL`+ → critical

## State Transitions

### SignificantLocationChanges Lifecycle

```
Clock-In
  → Start continuous GPS stream ONLY
  → SLC = inactive

GPS stream dies (90s no position)
  → gps_lost signal from background handler
  → Start SLC monitoring
  → SLC = active

GPS stream recovers
  → gps_restored signal from background handler
  → Stop SLC monitoring
  → SLC = inactive

App terminated by iOS
  → SLC relaunches app on ~500m movement
  → Validate shift with server
  → If active: restart full tracking pipeline
  → SLC = inactive (continuous stream takes over)

Clock-Out
  → Stop continuous GPS stream
  → Stop SLC monitoring (if active)
  → SLC = inactive
```

### Thermal Adaptation Lifecycle

```
Tracking starts
  → Subscribe to thermal state changes
  → Initial state = normal

Thermal state changes
  → Map to ThermalLevel
  → If level changed:
    → Send updateConfig to background handler
    → New intervals: normal=60s, elevated=120s, critical=300s
    → New accuracy: normal=high, elevated=medium, critical=low

Tracking stops
  → Unsubscribe from thermal state changes
  → Reset to normal
```
