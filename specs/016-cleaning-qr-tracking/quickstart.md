# Quickstart: Cleaning Session Tracking via QR Code

**Feature**: 016-cleaning-qr-tracking
**Date**: 2026-02-12

## Prerequisites

- Flutter SDK >= 3.29.0 (required for mobile_scanner 7.x)
- Node.js 18.x LTS (for dashboard)
- Supabase CLI running locally (`supabase start`)
- Physical or emulated camera for QR code testing

## New Dependencies

### Flutter (gps_tracker/pubspec.yaml)

```yaml
dependencies:
  mobile_scanner: ^7.1.4    # QR code scanning
```

### Dashboard (dashboard/package.json)

No new dependencies required — uses existing stack.

## Platform Configuration

### Android

**AndroidManifest.xml** — add camera permission:
```xml
<uses-permission android:name="android.permission.CAMERA" />
```

**proguard-rules.pro** — add ML Kit rules:
```
-keep class com.google.mlkit.vision.barcode.** { *; }
-keep class com.google.mlkit.vision.common.** { *; }
```

Verify `minSdkVersion >= 23` in `build.gradle.kts`.

### iOS

**Info.plist** — add camera usage description:
```xml
<key>NSCameraUsageDescription</key>
<string>Camera access is needed to scan QR codes for room check-in and check-out.</string>
```

## Database Setup

Apply migration:
```bash
cd supabase
supabase db push
```

This creates:
- `buildings` table (10 rows seeded)
- `studios` table (~115 rows seeded with QR codes)
- `cleaning_sessions` table
- RPC functions: `scan_in`, `scan_out`, `auto_close_shift_sessions`, `get_cleaning_dashboard`, `get_cleaning_stats_by_building`, `get_employee_cleaning_stats`, `manually_close_session`, `get_active_session`

## Development Workflow

### 1. Database & Backend (Phase 1)

```bash
# Apply migration
cd supabase && supabase db push

# Verify tables created
supabase db exec "SELECT count(*) FROM studios;"
# Expected: ~115

# Verify RPC functions
supabase db exec "SELECT routine_name FROM information_schema.routines WHERE routine_schema = 'public' AND routine_name LIKE '%clean%' OR routine_name LIKE '%scan%';"
```

### 2. Flutter Mobile App (Phase 2)

```bash
cd gps_tracker
flutter pub get
flutter run -d ios      # or android
```

**QR Code Testing**: Generate test QR codes containing studio QR code IDs (e.g., "8FJ3K2L9H4") using any QR generator. Point the device camera at the QR code to test scanning.

### 3. Dashboard (Phase 3)

```bash
cd dashboard
npm install
npm run dev
```

Navigate to `http://localhost:3000/dashboard/cleaning` to view the cleaning dashboard.

## File Structure

### Flutter (new files)

```
gps_tracker/lib/features/cleaning/
├── models/
│   ├── studio.dart
│   ├── cleaning_session.dart
│   └── scan_result.dart
├── providers/
│   ├── cleaning_session_provider.dart
│   └── studio_cache_provider.dart
├── screens/
│   └── qr_scanner_screen.dart
├── services/
│   ├── cleaning_session_service.dart
│   └── studio_cache_service.dart
└── widgets/
    ├── active_session_card.dart
    ├── cleaning_history_list.dart
    ├── manual_entry_dialog.dart
    └── scan_result_dialog.dart
```

### Dashboard (new files)

```
dashboard/src/
├── app/dashboard/cleaning/
│   └── page.tsx
├── components/cleaning/
│   ├── cleaning-sessions-table.tsx
│   ├── building-stats-cards.tsx
│   ├── cleaning-filters.tsx
│   └── close-session-dialog.tsx
├── lib/hooks/
│   └── use-cleaning-sessions.ts
├── lib/validations/
│   └── cleaning.ts
└── types/
    └── cleaning.ts
```

### Supabase (new files)

```
supabase/migrations/
└── 016_cleaning_qr_tracking.sql
```

## Testing QR Codes

For development/testing, use any of the seeded QR code IDs:

| QR Code    | Studio | Building       |
|------------|--------|----------------|
| 8FJ3K2L9H4 | 201    | Le Citadin     |
| B7Z2Q1M8N5 | 202    | Le Citadin     |
| H4Q3N5D8X7 | 254    | Le Cardinal    |
| E2Y7U5R3O8 | 311    | Le Chic-urbain |
| P0O9I8U7Y6 | 401    | Le Contemporain |

Generate QR images from these strings using any online QR generator for camera testing.
