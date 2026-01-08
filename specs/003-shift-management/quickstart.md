# Quickstart: Shift Management

**Feature Branch**: `003-shift-management`
**Date**: 2026-01-08

## Prerequisites

- Flutter SDK 3.x installed
- Supabase CLI installed (`npm install -g supabase`)
- Local Supabase instance running (`supabase start` in project root)
- Completed Spec 002 (Employee Authentication) - user can sign in

## Quick Verification

After implementation, verify the feature works:

```bash
# 1. Start local Supabase (if not running)
cd /Users/cedric/Desktop/PROJECT/TEST/GPS_Tracker/supabase
supabase start

# 2. Run the app
cd /Users/cedric/Desktop/PROJECT/TEST/GPS_Tracker/gps_tracker
flutter run

# 3. Sign in with test account
# 4. Tap "Clock In" button
# 5. Verify shift appears with timer
# 6. Tap "Clock Out" button
# 7. Verify shift summary shows duration
# 8. Check shift history shows the completed shift
```

## Development Setup

### 1. Branch Setup

```bash
git checkout 003-shift-management
```

### 2. Dependencies

All dependencies are already in `pubspec.yaml`. No new packages required.

```bash
cd gps_tracker
flutter pub get
```

### 3. Database

Schema already exists in `001_initial_schema.sql`. No new migrations needed.

```bash
cd supabase
supabase db push
```

### 4. iOS Permissions

Permissions already configured in Spec 001. Verify in `ios/Runner/Info.plist`:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>GPS Tracker needs location access to record where you clock in and out.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>GPS Tracker needs location access to track your work shifts.</string>
```

### 5. Android Permissions

Permissions already configured. Verify in `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
```

## File Structure to Create

```
gps_tracker/lib/features/shifts/
├── models/
│   ├── shift.dart
│   ├── geo_point.dart
│   └── local_shift.dart
├── providers/
│   ├── shift_provider.dart
│   ├── shift_history_provider.dart
│   ├── shift_timer_provider.dart
│   └── sync_provider.dart
├── screens/
│   ├── shift_dashboard_screen.dart
│   ├── shift_history_screen.dart
│   └── shift_detail_screen.dart
├── services/
│   ├── shift_service.dart
│   ├── location_service.dart
│   └── sync_service.dart
└── widgets/
    ├── clock_button.dart
    ├── shift_timer.dart
    ├── shift_status_card.dart
    ├── shift_card.dart
    └── sync_status_indicator.dart

gps_tracker/lib/shared/services/
└── local_database.dart

gps_tracker/test/features/shifts/
├── models/
│   └── shift_test.dart
├── providers/
│   └── shift_provider_test.dart
└── services/
    ├── shift_service_test.dart
    └── location_service_test.dart
```

## Key Implementation Steps

### Step 1: Create Data Models

Start with `shift.dart`, `geo_point.dart`, and `local_shift.dart` in the models folder.

### Step 2: Implement Local Database

Create `local_database.dart` in shared/services with SQLite table creation and CRUD operations.

### Step 3: Build Location Service

Implement `location_service.dart` with permission handling and GPS capture.

### Step 4: Build Shift Service

Implement `shift_service.dart` with clock-in/out logic, calling both local DB and Supabase RPC.

### Step 5: Create Providers

Build Riverpod providers for:
- Active shift state
- Shift history (paginated)
- Timer state
- Sync status

### Step 6: Build UI Screens

Create the dashboard, history, and detail screens using the widgets.

### Step 7: Update Home Screen

Replace the placeholder home screen content with the shift dashboard.

### Step 8: Add Tests

Write unit tests for models and services, widget tests for key UI components.

## Testing Checklist

- [ ] Clock in creates local record immediately
- [ ] Clock in syncs to Supabase when online
- [ ] Clock out completes shift locally
- [ ] Clock out syncs to Supabase when online
- [ ] Timer updates every second during active shift
- [ ] Timer survives app restart
- [ ] Offline clock-in works (airplane mode)
- [ ] Offline data syncs when back online
- [ ] Shift history loads and paginates
- [ ] Shift detail shows all information
- [ ] Location captured at clock-in/out
- [ ] Low GPS accuracy handled gracefully
- [ ] Sync status indicator works

## Common Issues

### Location Permission Denied

If clock-in fails with permission error:
1. Check Info.plist / AndroidManifest.xml has required permissions
2. Verify geolocator permission flow prompts user
3. On iOS simulator, use Features > Location to simulate location

### Database Not Found

If local database operations fail:
1. Ensure `LocalDatabase.initialize()` called in main.dart
2. Check encryption key stored in flutter_secure_storage
3. Verify sqflite_sqlcipher configured correctly

### Supabase RPC Errors

If sync fails with "Not authenticated":
1. Verify user is signed in before clock-in
2. Check Supabase access token not expired
3. Review RLS policies in database

## API Reference

See `contracts/supabase-rpc.md` for Supabase function signatures.
See `contracts/local-database.md` for local database operations.
