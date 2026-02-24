# Flutter Service Contracts: Cleaning Session Tracking

## CleaningSessionService

Manages cleaning session lifecycle. Follows the same local-first pattern as `ShiftService`.

### Methods

#### scanIn(employeeId, qrCode, shiftId) → ScanResult

Start a cleaning session by scanning a QR code.

```
Input:
  employeeId: String    -- Current authenticated user
  qrCode: String        -- Raw QR code string from scanner
  shiftId: String       -- Active shift ID

Output: ScanResult
  success: bool
  session: CleaningSession?    -- The created session (with studio info)
  errorType: ScanErrorType?    -- INVALID_QR | STUDIO_INACTIVE | NO_ACTIVE_SHIFT | SESSION_EXISTS
  errorMessage: String?
  existingSessionId: String?   -- Set when SESSION_EXISTS
```

**Flow**:
1. Look up studio by qr_code in local_studios cache
2. If not found locally, try Supabase lookup → update local cache
3. If still not found → return INVALID_QR error
4. Check if active session exists for this employee + studio → return SESSION_EXISTS
5. Create local_cleaning_session with status `in_progress`
6. Attempt Supabase RPC `scan_in` → update sync_status
7. Return success with session details

#### scanOut(employeeId, qrCode) → ScanResult

Complete a cleaning session by scanning the same QR code.

```
Input:
  employeeId: String
  qrCode: String

Output: ScanResult
  success: bool
  session: CleaningSession?    -- The completed session with duration
  errorType: ScanErrorType?    -- INVALID_QR | NO_ACTIVE_SESSION
  errorMessage: String?
  warning: String?             -- Set if duration is flagged
```

**Flow**:
1. Look up studio by qr_code
2. Find active local session for this employee + studio
3. If not found → return NO_ACTIVE_SESSION
4. Update: completed_at = now(), compute duration_minutes
5. Apply flagging logic
6. Set status to `completed`
7. Sync to Supabase via RPC `scan_out`
8. Return success with completed session

#### autoCloseSessions(shiftId, employeeId, closedAt) → int

Auto-close all open sessions when shift ends. Returns count of closed sessions.

```
Input:
  shiftId: String
  employeeId: String
  closedAt: DateTime

Output: int (number of sessions closed)
```

#### getActiveSession(employeeId) → CleaningSession?

Get the current active cleaning session (if any).

#### getShiftSessions(shiftId) → List<CleaningSession>

Get all cleaning sessions for a shift (current shift history).

#### syncPendingSessions(employeeId) → void

Sync all pending local sessions to Supabase. Called on app resume / connectivity change.

---

## StudioCacheService

Manages local cache of studios data.

### Methods

#### syncStudios() → void

Download all active studios from Supabase and update local cache.
Called on app start and periodically.

#### lookupByQrCode(qrCode) → Studio?

Look up a studio by QR code from local cache. Returns null if not found.

#### getAllStudios() → List<Studio>

Get all cached studios (for manual entry fallback).

---

## Models

### Studio

```
id: String
qrCode: String
studioNumber: String
buildingId: String
buildingName: String
studioType: StudioType    -- unit | commonArea | conciergerie
isActive: bool
```

### CleaningSession

```
id: String
employeeId: String
studioId: String
shiftId: String
status: CleaningSessionStatus    -- inProgress | completed | autoClosed | manuallyClosed
startedAt: DateTime
completedAt: DateTime?
durationMinutes: double?
isFlagged: bool
flagReason: String?
syncStatus: SyncStatus           -- pending | synced | error

// Denormalized for display
studioNumber: String?
buildingName: String?
studioType: StudioType?
```

### ScanResult

```
success: bool
session: CleaningSession?
errorType: ScanErrorType?
errorMessage: String?
existingSessionId: String?
warning: String?
```

### Enums

```
StudioType: unit, commonArea, conciergerie
CleaningSessionStatus: inProgress, completed, autoClosed, manuallyClosed
ScanErrorType: invalidQr, studioInactive, noActiveShift, sessionExists, noActiveSession
```
