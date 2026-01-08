# Research: Project Foundation

**Feature Branch**: `001-project-foundation`
**Date**: 2026-01-08
**Status**: Complete

## Research Topics

### 1. Encrypted Local Storage

**Decision**: Use `sqflite_sqlcipher` + `flutter_secure_storage`

**Rationale**:
- `sqflite_sqlcipher` is a drop-in replacement for `sqflite` with AES-256 encryption
- `flutter_secure_storage` stores encryption key in platform keychain/keystore (iOS Keychain, Android EncryptedSharedPreferences)
- Full platform compatibility: iOS 14+ and Android 7.0+ (API 24)
- Same query patterns as planned `sqflite` usage - minimal migration effort
- Encryption is transparent at database level, not field-level

**Alternatives Considered**:
- **Hive with encryption**: Deprecated, author recommends Isar. No relational query support.
- **Isar**: No built-in encryption, abandoned by author (community-maintained).
- **Drift + sqlcipher_flutter_libs**: More complex, potential conflicts with other sqlite dependencies.
- **ObjectBox**: Commercial license required for sync, no built-in encryption.

**Key Implementation Notes**:
```yaml
dependencies:
  sqflite_sqlcipher: ^3.1.0+1
  flutter_secure_storage: ^9.2.4
```
- Generate encryption key on first launch, store in secure storage
- Verify SQLCipher is active with `PRAGMA cipher_version`
- Add ProGuard rules for Android release builds

---

### 2. Background Location Tracking

**Decision**: Use `geolocator` + `flutter_foreground_task` (open source approach)

**Rationale**:
- `geolocator` is well-maintained by Baseflow, supports both platforms
- `flutter_foreground_task` provides Android Foreground Service with persistent notification
- Free and open source - no licensing costs
- Sufficient for 5-minute polling interval during shifts
- `disable_battery_optimization` package for handling OEM battery managers

**Alternative Considered**:
- **flutter_background_geolocation (commercial)**: More robust, handles edge cases better, but requires $299 license for Android release. Consider if free approach proves unreliable in testing.

**Platform Configuration Required**:

**iOS Info.plist**:
```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>GPS Clock-In Tracker needs your location to track your work shifts.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>GPS Clock-In Tracker needs continuous access to your location to track your work shifts even when the app is in the background.</string>
<key>UIBackgroundModes</key>
<array>
    <string>location</string>
    <string>fetch</string>
</array>
```

**Android Manifest**:
```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```

**Key Implementation Notes**:
- Use `LocationAccuracy.balanced` for battery efficiency
- Set `distanceFilter: 100` meters to avoid unnecessary updates
- Prompt users to disable battery optimization on problematic OEMs (Xiaomi, Huawei, Samsung)
- Always test on real devices from multiple manufacturers

---

### 3. Offline Sync Conflict Resolution

**Decision**: Client-Generated UUIDs + Last Write Wins with Server Validation

**Rationale**:
- GPS points are append-only (no edits), natural fit for LWW
- Client-generated UUIDs enable offline record creation without server coordination
- Database UNIQUE constraint on `client_id` provides natural deduplication
- Clock in/out uses First Write Wins with server-side state machine

**Key Patterns**:

**1. Dual Timestamp Pattern**:
```sql
captured_at TIMESTAMPTZ NOT NULL,    -- Client time (when GPS was captured)
received_at TIMESTAMPTZ DEFAULT NOW(), -- Server time (when synced)
```

**2. Idempotency via client_id**:
```sql
INSERT INTO gps_points (client_id, shift_id, latitude, longitude, captured_at)
VALUES ($1, $2, $3, $4, $5)
ON CONFLICT (client_id) DO NOTHING;
```

**3. Clock In/Out Idempotency**:
- Add `request_id UUID UNIQUE` to shifts table
- Server function checks for duplicate request_id before processing
- Returns cached response if already processed

**Conflict Resolution Matrix**:
| Data Type | Strategy |
|-----------|----------|
| GPS Points | Append-only, dedupe by client_id |
| Clock In | First Write Wins + Server Validation |
| Clock Out | First Write Wins + Server Validation |
| Profile Data | Last Write Wins with version check |

---

### 4. Flutter + Supabase Best Practices

**Decision**: Standard supabase_flutter setup with environment-based configuration

**Key Packages**:
```yaml
dependencies:
  supabase_flutter: ^2.12.0
  flutter_dotenv: ^5.1.0
```

**Authentication Patterns**:
- Use `onAuthStateChange` stream for reactive auth state management
- Session persistence handled automatically via flutter_secure_storage
- Configure custom SMTP for production (default rate-limited to 2/hour)

**RLS Performance Pattern**:
```sql
-- Use subquery for 94% performance improvement
USING ((SELECT auth.uid()) = user_id)
-- Instead of
USING (auth.uid() = user_id)
```

**Environment Configuration**:
- Separate `.env.development`, `.env.staging`, `.env.production` files
- Never commit `.env` files - use encrypted CI/CD secrets
- Use Supabase CLI for migration management across environments

**Offline Handling**:
- Supabase Flutter has no built-in offline support
- Use manual queue with local SQLite for pending operations
- Listen to connectivity changes to trigger sync
- Consider Brick framework for comprehensive offline-first needs

---

## Dependency Updates

Based on research, update `pubspec.yaml` dependencies:

```yaml
dependencies:
  # Core
  flutter:
    sdk: flutter

  # State Management
  flutter_riverpod: ^2.5.0

  # Backend
  supabase_flutter: ^2.12.0

  # Location
  geolocator: ^12.0.0
  flutter_foreground_task: ^8.0.0
  disable_battery_optimization: ^1.1.1

  # Local Storage (encrypted)
  sqflite_sqlcipher: ^3.1.0+1
  flutter_secure_storage: ^9.2.4
  path_provider: ^2.1.5

  # Environment
  flutter_dotenv: ^5.1.0

  # Connectivity
  connectivity_plus: ^6.0.0

  # Utilities
  uuid: ^4.0.0
```

---

## Open Questions Resolved

| Question | Resolution |
|----------|------------|
| Encrypted local storage approach | sqflite_sqlcipher + flutter_secure_storage |
| Background location package | geolocator + flutter_foreground_task (free) or flutter_background_geolocation (commercial) |
| Sync conflict strategy | Client UUIDs + LWW + server validation for clock events |
| Offline handling | Manual queue with local SQLite, connectivity listener |
