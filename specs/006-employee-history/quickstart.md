# Quickstart: Employee History

**Feature**: 006-employee-history | **Date**: 2026-01-10

This guide provides step-by-step instructions for implementing the Employee History feature.

---

## Prerequisites

Before starting, ensure:
- [ ] Specs 001-005 are implemented and working
- [ ] Supabase project is running (`supabase status`)
- [ ] Flutter app builds and runs (`flutter run`)
- [ ] Test user accounts exist with shift data

---

## Step 1: Database Migration

### 1.1 Create Migration File

```bash
cd /Users/cedric/Desktop/PROJECT/TEST/GPS_Tracker
touch supabase/migrations/006_employee_history.sql
```

### 1.2 Apply Migration

The migration should include:
1. Add `role` column to `employee_profiles`
2. Create `employee_supervisors` table
3. Create new RLS policies for manager access
4. Create RPC functions for history queries

```bash
supabase db push
```

### 1.3 Verify Migration

```bash
supabase db diff
```

---

## Step 2: Add Dependencies

### 2.1 Update pubspec.yaml

```yaml
# In gps_tracker/pubspec.yaml, add under dependencies:
  google_maps_flutter: ^2.5.0
  pdf: ^3.10.0
  printing: ^5.12.0
  csv: ^5.1.0
  share_plus: ^7.2.0
```

### 2.2 Install Dependencies

```bash
cd gps_tracker
flutter pub get
```

### 2.3 Configure Google Maps

**Android** (`android/app/src/main/AndroidManifest.xml`):
```xml
<manifest ...>
    <application ...>
        <meta-data
            android:name="com.google.android.geo.API_KEY"
            android:value="YOUR_GOOGLE_MAPS_API_KEY"/>
    </application>
</manifest>
```

**iOS** (`ios/Runner/AppDelegate.swift`):
```swift
import GoogleMaps

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GMSServices.provideAPIKey("YOUR_GOOGLE_MAPS_API_KEY")
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
```

---

## Step 3: Create Feature Structure

### 3.1 Create Directories

```bash
cd gps_tracker/lib/features
mkdir -p history/{models,providers,screens,services,widgets}
```

### 3.2 Create Barrel Export

Create `lib/features/history/history.dart`:
```dart
// Models
export 'models/employee_summary.dart';
export 'models/shift_history_filter.dart';
export 'models/history_statistics.dart';
export 'models/supervision_record.dart';

// Providers
export 'providers/supervised_employees_provider.dart';
export 'providers/employee_history_provider.dart';
export 'providers/history_filter_provider.dart';
export 'providers/history_statistics_provider.dart';

// Services
export 'services/history_service.dart';
export 'services/export_service.dart';
export 'services/statistics_service.dart';

// Screens
export 'screens/supervised_employees_screen.dart';
export 'screens/employee_history_screen.dart';
export 'screens/shift_detail_screen.dart';
export 'screens/statistics_screen.dart';

// Widgets
export 'widgets/employee_list_tile.dart';
export 'widgets/history_filter_bar.dart';
export 'widgets/shift_history_card.dart';
export 'widgets/statistics_card.dart';
export 'widgets/gps_route_map.dart';
export 'widgets/export_dialog.dart';
```

---

## Step 4: Update Existing Models

### 4.1 Add UserRole Enum

Create `lib/shared/models/user_role.dart` with the `UserRole` enum.

### 4.2 Update EmployeeProfile

Add `role` field to `EmployeeProfile` class in `lib/features/auth/models/employee_profile.dart`.

---

## Step 5: Implement Core Components

### Implementation Order

1. **Models** (in data-model.md order)
   - `UserRole`
   - Update `EmployeeProfile`
   - `SupervisionRecord`
   - `EmployeeSummary`
   - `ShiftHistoryFilter`
   - `HistoryStatistics`

2. **Services**
   - `HistoryService` - Fetch history data from Supabase
   - `StatisticsService` - Calculate and cache statistics
   - `ExportService` - Generate CSV/PDF exports

3. **Providers**
   - `supervisedEmployeesProvider` - List of supervised employees
   - `historyFilterProvider` - Current filter state
   - `employeeHistoryProvider` - Filtered shift list
   - `historyStatisticsProvider` - Calculated stats

4. **Widgets**
   - `EmployeeListTile` - Employee row in list
   - `HistoryFilterBar` - Date range and search
   - `ShiftHistoryCard` - Shift summary card
   - `StatisticsCard` - Stats display
   - `GpsRouteMap` - Google Maps with route
   - `ExportDialog` - Format selection

5. **Screens**
   - `SupervisedEmployeesScreen` - Employee list
   - `EmployeeHistoryScreen` - Shift list with filters
   - `ShiftDetailScreen` - Full shift details with map
   - `StatisticsScreen` - Stats dashboard

---

## Step 6: Add Navigation

### 6.1 Update Home Screen

Add navigation to Employee History for managers:

```dart
// In home_screen.dart or appropriate location
if (profile.isManager) {
  ListTile(
    leading: Icon(Icons.history),
    title: Text('Employee History'),
    onTap: () => Navigator.pushNamed(context, '/history'),
  ),
}
```

### 6.2 Define Routes

Add routes in `app.dart` or routing configuration:

```dart
'/history': (context) => const SupervisedEmployeesScreen(),
'/history/employee/:id': (context) => const EmployeeHistoryScreen(),
'/history/shift/:id': (context) => const ShiftDetailScreen(),
'/history/statistics': (context) => const StatisticsScreen(),
```

---

## Step 7: Testing

### 7.1 Create Test Data

```sql
-- Add manager role to test user
UPDATE employee_profiles
SET role = 'manager'
WHERE email = 'manager@test.com';

-- Create supervision relationships
INSERT INTO employee_supervisors (manager_id, employee_id, supervision_type)
SELECT
    (SELECT id FROM employee_profiles WHERE email = 'manager@test.com'),
    id,
    'direct'
FROM employee_profiles
WHERE email != 'manager@test.com'
LIMIT 5;
```

### 7.2 Run Tests

```bash
cd gps_tracker
flutter test
flutter test integration_test/history_test.dart
```

---

## Step 8: Verification Checklist

### Functional Verification

- [ ] Manager can see list of supervised employees
- [ ] Manager can view employee shift history
- [ ] Date range filter works correctly
- [ ] Employee search works correctly
- [ ] Shift details display correctly
- [ ] GPS route displays on map
- [ ] CSV export works
- [ ] PDF export works
- [ ] Statistics display correctly
- [ ] Employee can view own enhanced history
- [ ] Non-supervised employees are not accessible

### Performance Verification

- [ ] History loads in <3 seconds
- [ ] Filter updates in <2 seconds
- [ ] Map renders 100+ points in <3 seconds
- [ ] CSV export (1000 shifts) completes in <10 seconds
- [ ] PDF export (100 shifts) completes in <15 seconds

### Security Verification

- [ ] RLS policies prevent unauthorized access
- [ ] Manager can only see supervised employees
- [ ] Employee can only see own data
- [ ] Deactivated employees' history is preserved

---

## Common Issues & Solutions

### Google Maps Not Displaying

1. Verify API key is correct in both Android and iOS config
2. Ensure Maps SDK is enabled in Google Cloud Console
3. Check API key restrictions match app bundle ID

### Export Fails on iOS

1. Ensure `share_plus` is properly configured
2. Check Info.plist has required permissions for file sharing

### Statistics Incorrect

1. Verify all shifts are synced (check sync status)
2. Confirm timezone handling is correct
3. Check that incomplete shifts (no clock-out) are handled

### RLS Access Denied

1. Verify supervision relationship exists in `employee_supervisors`
2. Check `effective_to` is NULL or future date
3. Confirm user's role is 'manager' or 'admin'

---

## Next Steps

After implementation:
1. Run `/speckit.tasks` to generate detailed task breakdown
2. Review generated tasks.md
3. Begin implementation following task order
4. Run tests after each major component
