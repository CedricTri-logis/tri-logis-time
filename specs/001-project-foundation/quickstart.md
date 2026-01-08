# Quickstart: GPS Clock-In Tracker

**Feature Branch**: `001-project-foundation`
**Date**: 2026-01-08

## Prerequisites

- **Flutter SDK**: 3.x (latest stable)
- **Dart SDK**: 3.x (included with Flutter)
- **Xcode**: 15.0+ (for iOS development)
- **Android Studio**: Latest stable (for Android development)
- **Supabase CLI**: Latest (`brew install supabase/tap/supabase`)
- **Git**: 2.x+

## Quick Setup (15 minutes)

### 1. Clone and Install Dependencies

```bash
# Clone the repository
git clone <repository-url> gps-tracker
cd gps-tracker

# Install Flutter dependencies
cd gps_tracker
flutter pub get
```

### 2. Supabase Configuration

#### Option A: Local Development (Recommended for Development)

1. Start local Supabase stack:
   ```bash
   cd supabase
   supabase start
   ```

   Wait for the services to start. The output will show credentials like:
   ```
   API URL: http://localhost:54321
   anon key: eyJhbGci...
   service_role key: eyJhbGci...
   ```

2. Apply database migrations:
   ```bash
   supabase db push
   ```
   This creates the tables (employee_profiles, shifts, gps_points) with RLS policies.

3. Copy local credentials to Flutter project:
   ```bash
   cd ../gps_tracker
   cp .env.example .env
   ```

   Edit `.env` with the values from step 1:
   ```
   SUPABASE_URL=http://localhost:54321
   SUPABASE_ANON_KEY=<anon-key-from-supabase-start>
   ```

4. Verify tables exist:
   ```bash
   # Open Supabase Studio
   open http://localhost:54323
   ```
   Navigate to Table Editor - you should see employee_profiles, shifts, and gps_points tables.

5. Verify RLS is enabled:
   - In Supabase Studio, go to Authentication > Policies
   - Each table should show RLS policies for SELECT, INSERT, UPDATE

6. Stop local Supabase (when done developing):
   ```bash
   supabase stop
   ```

#### Option B: Using Remote Supabase Project

1. Create a project at [supabase.com](https://supabase.com)

2. Link your local CLI to the remote project:
   ```bash
   cd supabase
   supabase link --project-ref your-project-ref
   ```

3. Apply database migrations to remote:
   ```bash
   supabase db push
   ```

4. Copy environment template and configure:
   ```bash
   cd ../gps_tracker
   cp .env.example .env
   ```

   Edit `.env` with your remote Supabase credentials:
   ```
   SUPABASE_URL=https://your-project-ref.supabase.co
   SUPABASE_ANON_KEY=your-anon-key
   ```

5. Enable email/password authentication:
   - Go to Supabase Dashboard > Authentication > Providers
   - Ensure "Email" provider is enabled
   - Configure email templates if needed

### 3. iOS Setup

```bash
cd gps_tracker/ios
pod install
cd ..
```

Open `ios/Runner.xcworkspace` in Xcode and:
1. Select your development team in Signing & Capabilities
2. Update bundle identifier if needed

### 4. Android Setup

No additional setup required for development. Ensure Android SDK is installed via Android Studio.

### 5. Run the Application

```bash
# iOS Simulator
flutter run -d ios

# Android Emulator
flutter run -d android

# List available devices
flutter devices
```

## Verify Setup

### Setup Verification Checklist

Run through this checklist to verify your development environment is properly configured:

```bash
# 1. Verify Flutter installation
flutter --version
# Expected: Flutter 3.x.x

# 2. Check Flutter doctor status
flutter doctor
# Expected: All checks pass (or acceptable warnings only)

# 3. Install dependencies
cd gps_tracker
flutter pub get
# Expected: No errors, all packages resolved

# 4. List available devices
flutter devices
# Expected: At least one iOS simulator or Android emulator listed

# 5. Run on iOS simulator
flutter run -d ios
# Expected: App launches with welcome screen, no red errors

# 6. Run on Android emulator
flutter run -d android
# Expected: App launches with welcome screen, no red errors

# 7. Verify Supabase CLI (for backend work)
supabase --version
# Expected: Supabase CLI version displayed
```

### Success Criteria

1. **App Launches**: You should see a welcome/placeholder screen
2. **No Errors**: Console shows no red errors
3. **Both Platforms**: Test on both iOS simulator and Android emulator

### Common Issues

#### iOS: Pod Install Fails

```bash
cd ios
rm -rf Pods Podfile.lock
pod install --repo-update
```

#### Android: Gradle Sync Issues

```bash
cd android
./gradlew clean
cd ..
flutter clean
flutter pub get
```

#### Supabase Connection Errors

1. Verify `.env` file exists and has correct values
2. Check Supabase project is running (if local: `supabase status`)
3. Ensure network connectivity

## Project Structure

```
gps_tracker/
├── lib/
│   ├── main.dart           # App entry point
│   ├── app.dart            # Root widget
│   └── core/
│       └── config/         # Environment configuration
├── ios/                    # iOS platform code
├── android/                # Android platform code
└── pubspec.yaml           # Dependencies

supabase/
├── migrations/            # SQL migrations
└── config.toml           # Supabase CLI config
```

## Next Steps

After verifying setup:

1. **Authentication**: Implement email/password auth flow
2. **Location Permissions**: Request and handle location permissions
3. **Shift Management**: Clock in/out functionality
4. **GPS Tracking**: Background location capture

See the [spec.md](./spec.md) for detailed requirements.

## Environment Variables Reference

| Variable | Description | Example |
|----------|-------------|---------|
| `SUPABASE_URL` | Supabase API URL | `https://xyz.supabase.co` |
| `SUPABASE_ANON_KEY` | Public anonymous key | `eyJhbGciOiJI...` |

## Dependencies Overview

| Package | Purpose |
|---------|---------|
| `supabase_flutter` | Backend connectivity |
| `flutter_riverpod` | State management |
| `geolocator` | Location services |
| `sqflite_sqlcipher` | Encrypted local storage |
| `flutter_secure_storage` | Secure key storage |
| `flutter_dotenv` | Environment configuration |
