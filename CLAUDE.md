# GPS_Tracker Development Guidelines

Auto-generated from all feature plans. Last updated: 2026-01-08

## Active Technologies
- Dart 3.x / Flutter 3.x (latest stable) + flutter, supabase_flutter 2.12.0, flutter_riverpod 2.5.0, flutter_secure_storage 9.2.4 (002-employee-auth)
- PostgreSQL via Supabase (employee_profiles table already exists), flutter_secure_storage for tokens (002-employee-auth)
- Dart 3.x / Flutter 3.x (>=3.0.0) + flutter_riverpod 2.5.0 (state), supabase_flutter 2.12.0 (backend), geolocator 12.0.0 (GPS), sqflite_sqlcipher 3.1.0 (local encrypted storage), connectivity_plus 6.0.0 (network status) (003-shift-management)
- PostgreSQL via Supabase (shifts, gps_points tables exist), SQLCipher for encrypted local storage (003-shift-management)
- Dart 3.x / Flutter 3.x (>=3.0.0) + flutter_riverpod 2.5.0 (state), supabase_flutter 2.12.0 (backend), geolocator 12.0.0 (GPS), flutter_foreground_task 8.0.0 (background services), disable_battery_optimization 1.1.1, sqflite_sqlcipher 3.1.0 (local encrypted storage), connectivity_plus 6.0.0 (network status) (004-background-gps-tracking)
- PostgreSQL via Supabase (gps_points table exists), SQLCipher for encrypted local storage (local_gps_points table exists) (004-background-gps-tracking)
- Dart 3.x / Flutter 3.x (>=3.0.0) + flutter_riverpod 2.5.0 (state), supabase_flutter 2.12.0 (backend), sqflite_sqlcipher 3.1.0 (local encrypted storage), connectivity_plus 6.0.0 (network status) (005-offline-resilience)
- SQLCipher-encrypted SQLite (local_shifts, local_gps_points tables exist); PostgreSQL via Supabase (shifts, gps_points tables) (005-offline-resilience)
- Dart 3.x / Flutter 3.x (>=3.0.0) + flutter_riverpod 2.5.0 (state), supabase_flutter 2.12.0 (backend), google_maps_flutter (map display), pdf (client-side PDF generation), csv (CSV export) (006-employee-history)
- PostgreSQL via Supabase (existing: employee_profiles, shifts, gps_points; new: employee_supervisors), SQLCipher local storage (existing) (006-employee-history)
- Dart >=3.0.0 <4.0.0 / Flutter >=3.0.0 + flutter_riverpod 2.5.0 (state), geolocator 12.0.0 (permissions/location), flutter_foreground_task 8.0.0 (background services) (007-location-permission-guard)
- N/A (uses existing local storage infrastructure; session-scoped acknowledgment state only) (007-location-permission-guard)
- Dart >=3.0.0 <4.0.0 / Flutter >=3.0.0 + flutter_riverpod 2.5.0 (state), supabase_flutter 2.12.0 (backend), fl_chart (bar charts for team statistics) (008-employee-shift-dashboard)
- PostgreSQL via Supabase (existing: employee_profiles, shifts, gps_points, employee_supervisors); SQLCipher local storage (7-day cache) (008-employee-shift-dashboard)
- TypeScript 5.x, Node.js 18.x LTS + Next.js 14+ (App Router), shadcn/ui, Refine (@refinedev/supabase), Tailwind CSS, Zod (009-dashboard-foundation)
- PostgreSQL via Supabase (existing schema), client-side cache (React Query via Refine) (009-dashboard-foundation)
- TypeScript 5.x / Node.js 18.x LTS + Next.js 14+ (App Router), Refine (@refinedev/supabase), shadcn/ui, Tailwind CSS, Zod, @tanstack/react-table (010-employee-management)
- PostgreSQL via Supabase (existing `employee_profiles`, `employee_supervisors` tables) (010-employee-management)
- TypeScript 5.x, Node.js 18.x LTS + Next.js 14+ (App Router), Refine (@refinedev/supabase), shadcn/ui, Tailwind CSS, Zod, react-leaflet (map), Supabase Realtime (011-shift-monitoring)
- PostgreSQL via Supabase (existing tables: employee_profiles, shifts, gps_points, employee_supervisors) (011-shift-monitoring)
- TypeScript 5.x, Node.js 18.x LTS + Next.js 14+ (App Router), Refine (@refinedev/supabase), shadcn/ui, Tailwind CSS, Zod, react-leaflet 5.0.0, Leaflet 1.9.4, date-fns 4.1.0 (012-gps-visualization)
- PostgreSQL via Supabase (existing: employee_profiles, shifts, gps_points, employee_supervisors tables) (012-gps-visualization)

- Dart 3.x / Flutter 3.x (latest stable) + flutter, supabase_flutter, flutter_riverpod, geolocator, sqflite (local storage) (001-project-foundation)

## Project Structure

```text
gps_tracker/                    # Flutter project root
├── lib/
│   ├── main.dart               # App entry point with Supabase init
│   ├── app.dart                # Root MaterialApp widget
│   ├── core/
│   │   └── config/             # Environment config, constants
│   ├── features/
│   │   ├── auth/               # Authentication feature
│   │   ├── home/               # Home/welcome screens
│   │   ├── shifts/             # Shift management
│   │   └── tracking/           # GPS tracking
│   └── shared/
│       ├── models/             # Data models
│       ├── providers/          # Riverpod providers
│       └── widgets/            # Reusable widgets
├── test/                       # Unit and widget tests
├── integration_test/           # Integration tests
├── ios/Runner/Info.plist       # iOS permissions config
└── android/app/src/main/AndroidManifest.xml  # Android permissions

supabase/                       # Supabase configuration
├── migrations/                 # Database migrations
└── config.toml                 # Local dev config
```

## Commands

```bash
# Flutter development
cd gps_tracker
flutter pub get                 # Install dependencies
flutter run -d ios              # Run on iOS simulator
flutter run -d android          # Run on Android emulator
flutter build ios --debug       # Build iOS debug
flutter build apk --debug       # Build Android debug APK
flutter test                    # Run unit tests
flutter analyze                 # Run linter

# Supabase backend
cd supabase
supabase start                  # Start local Supabase
supabase stop                   # Stop local Supabase
supabase db push                # Apply migrations
supabase status                 # Check service status
```

## Code Style

Dart 3.x / Flutter 3.x (latest stable): Follow standard conventions
- Use `flutter_lints` package for linting rules
- Prefer `const` constructors where possible
- Use trailing commas for better formatting
- Follow feature-based folder structure

## Platform Permissions

### iOS (Info.plist)
- `NSLocationWhenInUseUsageDescription` - Location when in use
- `NSLocationAlwaysAndWhenInUseUsageDescription` - Background location
- `UIBackgroundModes` - location, fetch

### Android (AndroidManifest.xml)
- `ACCESS_FINE_LOCATION` - Precise GPS
- `ACCESS_COARSE_LOCATION` - Approximate location
- `ACCESS_BACKGROUND_LOCATION` - Background tracking
- `FOREGROUND_SERVICE` - Foreground service
- `FOREGROUND_SERVICE_LOCATION` - Location foreground service
- `POST_NOTIFICATIONS` - Push notifications

## Recent Changes
- 012-gps-visualization: Added TypeScript 5.x, Node.js 18.x LTS + Next.js 14+ (App Router), Refine (@refinedev/supabase), shadcn/ui, Tailwind CSS, Zod, react-leaflet 5.0.0, Leaflet 1.9.4, date-fns 4.1.0
- 011-shift-monitoring: Added TypeScript 5.x, Node.js 18.x LTS + Next.js 14+ (App Router), Refine (@refinedev/supabase), shadcn/ui, Tailwind CSS, Zod, react-leaflet (map), Supabase Realtime
- 010-employee-management: Added TypeScript 5.x / Node.js 18.x LTS + Next.js 14+ (App Router), Refine (@refinedev/supabase), shadcn/ui, Tailwind CSS, Zod, @tanstack/react-table


<!-- MANUAL ADDITIONS START -->
<!-- MANUAL ADDITIONS END -->
