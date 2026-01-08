# GPS_Tracker Development Guidelines

Auto-generated from all feature plans. Last updated: 2026-01-08

## Active Technologies

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

- 001-project-foundation: Added Dart 3.x / Flutter 3.x (latest stable) + flutter, supabase_flutter, flutter_riverpod, geolocator, sqflite (local storage)

<!-- MANUAL ADDITIONS START -->
<!-- MANUAL ADDITIONS END -->
