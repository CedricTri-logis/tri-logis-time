# Research: Cleaning Session Tracking via QR Code

**Feature**: 016-cleaning-qr-tracking
**Date**: 2026-02-12

## R-001: QR Code Scanning Library for Flutter

**Decision**: `mobile_scanner: ^7.1.4`

**Rationale**: Most actively maintained Flutter QR scanning package. Uses CameraX + Google ML Kit on Android and AVFoundation + Apple Vision on iOS. Replaces the deprecated `qr_code_scanner`. Supports restricting detection to QR-only format for performance.

**Alternatives considered**:
- `qr_code_scanner`: Deprecated, not using modern native APIs
- `flutter_barcode_scanner`: Less maintained, fewer features
- Scanbot SDK: Commercial license, overkill for simple QR reads

**Key setup requirements**:
- Android: Add `CAMERA` permission to AndroidManifest.xml, ML Kit ProGuard rules, minSdkVersion >= 23
- iOS: Add `NSCameraUsageDescription` to Info.plist
- Use `DetectionSpeed.noDuplicates` + `formats: [BarcodeFormat.qrCode]` to prevent duplicate scans
- Must implement `WidgetsBindingObserver` for camera lifecycle management

## R-002: QR Code Content Format

**Decision**: QR codes encode a plain-text unique ID string (e.g., "8FJ3K2L9H4")

**Rationale**: The physical QR labels are already printed with unique ID strings. The app will look up the studio record by matching the scanned string against the `qr_code` column in the `studios` table. No URL encoding needed.

**Alternatives considered**:
- URL format (e.g., `https://app.example.com/studio/8FJ3K2L9H4`): Adds complexity, no benefit since app handles all scanning
- JSON payload: Unnecessary complexity for a simple identifier lookup

## R-003: Cleaning Session Auto-Close on Shift End

**Decision**: Hook into `ShiftNotifier.clockOut()` after successful clock-out to auto-close open cleaning sessions

**Rationale**: The shift end is a single, well-defined event in `shift_provider.dart`. After `clockOut()` succeeds (line ~140-144), call cleaning session auto-close. This works for both manual clock-out and force clock-out (GPS grace period timeout).

**Implementation approach**:
- Create a `CleaningSessionService` following the same pattern as `ShiftService`
- Add `autoCloseOpenSessions(shiftId, employeeId)` method
- Call from `ShiftNotifier.clockOut()` after successful local update
- Mark auto-closed sessions with status `auto_closed`

**Alternatives considered**:
- Observer pattern (watch shift state changes): More decoupled but adds complexity
- Database trigger on shift update: Server-side only, doesn't work offline

## R-004: Data Storage Architecture

**Decision**: Follow existing local-first architecture with SQLCipher for offline support

**Rationale**: The app already uses encrypted SQLite (`sqflite_sqlcipher`) for shifts and GPS points. Cleaning sessions should follow the same pattern for consistency and offline resilience.

**New local tables**:
- `local_studios`: Cache of studio data (synced from Supabase)
- `local_cleaning_sessions`: Cleaning sessions with sync status

**Sync model**: Same as shifts — create locally first, sync to Supabase when online, track sync_status (pending/synced/error).

## R-005: Studio Data Seeding

**Decision**: Seed via SQL migration with all 100+ studios from user-provided data

**Rationale**: The studio data is static (QR codes are already printed). A migration ensures all environments have identical data. The `buildings` and `studios` tables will be created and populated in a single migration file.

**Data summary**:
- 10 buildings
- ~95 rental studios + 10 common areas + 10 conciergeries = ~115 total entries
- 3 studio types: `unit`, `common_area`, `conciergerie`

## R-006: Dashboard Integration Pattern

**Decision**: Follow the same patterns established by Spec 015 (Locations)

**Rationale**: The locations feature is the most recent dashboard addition and demonstrates the current best practices for the project.

**Pattern to follow**:
- New sidebar nav item: "Cleaning" with icon
- New page: `/dashboard/cleaning/page.tsx`
- Custom hooks: `use-cleaning-sessions.ts`
- Types: `cleaning.ts`
- Validation: `cleaning.ts` (Zod schemas)
- Components: `dashboard/src/components/cleaning/`
- RPC functions for data aggregation (cleaning stats by building, by employee)

## R-007: Studio Type Classification

**Decision**: Three studio types — `unit` (rental studio), `common_area` (aires communes), `conciergerie`

**Rationale**: The user's data clearly shows three distinct categories. Each building has individual rental units plus one "Aires communes" and one "Conciergerie" entry. Duration thresholds differ by type (studios expect longer cleaning than common areas).

**Duration thresholds for warnings**:
- `unit`: Warning if < 5 minutes or > 4 hours
- `common_area`: Warning if < 2 minutes or > 4 hours
- `conciergerie`: Warning if < 2 minutes or > 4 hours
