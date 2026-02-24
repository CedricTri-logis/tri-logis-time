# Quickstart: 019-diagnostic-logging

## Prerequisites

- Flutter >=3.29.0 with Dart >=3.0.0
- Supabase CLI installed (`supabase start` for local dev)
- Existing GPS Tracker app running on branch `019-diagnostic-logging`

## Setup Steps

### 1. Apply Database Migration

```bash
cd supabase
supabase db push   # Applies migration 036_diagnostic_logs.sql
```

This creates:
- `diagnostic_logs` table with indexes and RLS
- `sync_diagnostic_logs` RPC function
- pg_cron job for 90-day retention cleanup

### 2. Flutter Dependencies

No new dependencies required. Uses existing:
- `sqflite_sqlcipher` (local encrypted storage)
- `supabase_flutter` (server sync)
- `package_info_plus` (app version)
- `device_info_plus` (OS version)
- `flutter_secure_storage` (device ID)

### 3. Key Files to Create

```
gps_tracker/lib/
├── shared/
│   └── services/
│       └── diagnostic_logger.dart       # Central logging service
└── features/
    └── shifts/
        └── services/
            └── diagnostic_sync_service.dart  # Server sync for diagnostic events
```

### 4. Key Files to Modify

```
gps_tracker/lib/
├── main.dart                                          # Add session_start event
├── shared/
│   └── services/
│       └── local_database.dart                        # Add diagnostic_events table
├── features/
│   ├── tracking/
│   │   ├── providers/tracking_provider.dart           # Replace debugPrints with DiagnosticLogger
│   │   └── services/
│   │       ├── background_tracking_service.dart       # Replace debugPrints
│   │       ├── gps_tracking_handler.dart              # Add diagnostic messages to handler
│   │       ├── significant_location_service.dart      # Replace debugPrints
│   │       ├── background_execution_service.dart      # Replace debugPrints
│   │       └── thermal_state_service.dart             # Replace debugPrints
│   └── shifts/
│       ├── services/
│       │   └── sync_service.dart                      # Replace debugPrints + add diagnostic sync step
│       └── providers/
│           └── shift_provider.dart                    # Replace debugPrints
├── features/auth/
│   └── providers/device_session_provider.dart         # Add force_logout event
└── shared/services/
    └── realtime_service.dart                          # Replace debugPrints
```

### 5. Usage Example

```dart
// Initialize once at app startup
final logger = DiagnosticLogger(
  localDb: LocalDatabase(),
  employeeId: currentUserId,
  deviceId: await DeviceIdService.getDeviceId(),
);

// Log a GPS event
await logger.log(
  category: EventCategory.gps,
  severity: Severity.warn,
  message: 'GPS signal lost for 90+ seconds',
  shiftId: activeShiftId,
  metadata: {
    'gap_started_at': DateTime.now().toUtc().toIso8601String(),
    'last_position': {'lat': 45.5017, 'lng': -73.5673, 'accuracy': 15.0},
    'seconds_since_last': 95,
  },
);

// Log from background isolate (via message channel)
FlutterForegroundTask.sendDataToMain(jsonEncode({
  'type': 'diagnostic',
  'category': 'gps',
  'severity': 'error',
  'message': 'Position stream error',
  'metadata': {'error': error.toString()},
}));
```

### 6. Verification

```sql
-- Check diagnostic logs on server
SELECT event_category, severity, message, created_at
FROM diagnostic_logs
WHERE employee_id = '<uuid>'
ORDER BY created_at DESC
LIMIT 50;

-- Check GPS-specific events for a shift
SELECT severity, message, metadata, created_at
FROM diagnostic_logs
WHERE shift_id = '<uuid>' AND event_category = 'gps'
ORDER BY created_at;

-- Count events by category
SELECT event_category, severity, COUNT(*)
FROM diagnostic_logs
WHERE created_at > NOW() - INTERVAL '24 hours'
GROUP BY event_category, severity
ORDER BY event_category, severity;
```

## Architecture Notes

- **DiagnosticLogger** is a singleton, initialized once at app startup
- All `log()` calls are async fire-and-forget (never block callers)
- Background isolate events flow through existing `FlutterForegroundTask.sendDataToMain()` channel
- Sync piggybacks on existing `SyncService.syncAll()` cycle (step 5, after GPS points)
- `debug` severity events are local-only (never synced to server)
- Local storage capped at 5000 events (~2MB), auto-pruned
- Server retention: 90 days via pg_cron
