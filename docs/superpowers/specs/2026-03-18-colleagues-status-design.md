# Colleagues Status — Employee View

**Date:** 2026-03-18
**Feature:** Allow employees to see which colleagues are currently clocked in or on lunch break

## Overview

New screen "Collegues" accessible from the 3-dot menu in the Flutter app. Displays a simple list of all active employees with their current status: on-shift, on-lunch, or off-shift. Available to all authenticated employees (not just managers).

## Backend

### New RPC: `get_colleagues_status()`

**Purpose:** Return the current work status of all active employees.

**Returns (per employee):**

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID | Employee profile ID |
| `full_name` | TEXT | Display name |
| `work_status` | TEXT | `'on-shift'`, `'on-lunch'`, `'off-shift'` |

**Logic:**
- Queries `employee_profiles` WHERE `status = 'active'`
- LEFT JOIN `shifts` WHERE `status = 'active'` to detect on-shift
- LEFT JOIN `lunch_breaks` WHERE `ended_at IS NULL` to detect on-lunch
- Status derivation:
  - `lunch_breaks` row exists with `ended_at IS NULL` → `'on-lunch'`
  - `shifts` row exists with `status = 'active'` → `'on-shift'`
  - Otherwise → `'off-shift'`
- Excludes the calling user (`auth.uid()`)
- Sort order: on-shift first, then on-lunch, then off-shift, alphabetical within each group

**Authorization:** Any authenticated user can call this RPC. No manager/admin restriction.

**Migration:** Single migration file creating the RPC as a `SECURITY DEFINER` function (to bypass employee_profiles RLS self-reference limitation).

## Flutter

### Screen: `ColleaguesScreen`

**Location:** `gps_tracker/lib/features/colleagues/screens/colleagues_screen.dart`

**UI layout:**
1. **App bar:** Title "Collegues"
2. **Summary bar:** "X en quart · Y en diner · Z hors quart"
3. **List:** One tile per employee
   - Leading: Circle avatar with initials (first letter of first + last name)
   - Title: Full name
   - Trailing: Status badge (colored chip)
     - Green: "En quart"
     - Orange/yellow: "Diner"
     - Grey: "Hors quart"
4. **Pull-to-refresh:** `RefreshIndicator` for manual refresh
5. **Empty state:** Message when no colleagues found

### Provider: `ColleaguesProvider`

**Location:** `gps_tracker/lib/features/colleagues/providers/colleagues_provider.dart`

- Riverpod `StateNotifier` or `AsyncNotifier`
- Calls `get_colleagues_status()` RPC
- Polls every 30 seconds while the screen is mounted
- Stops polling when the screen is disposed
- Exposes: list of colleagues + loading state + error state

### Model: `ColleagueStatus`

**Location:** `gps_tracker/lib/features/colleagues/models/colleague_status.dart`

```dart
enum WorkStatus { onShift, onLunch, offShift }

class ColleagueStatus {
  final String id;
  final String fullName;
  final WorkStatus workStatus;
}
```

### Menu Entry

Add "Collegues" item to the 3-dot menu in `HomeScreen` (available to all roles, not just managers).
- Icon: `Icons.people`
- Label: "Collegues"
- Navigates to `ColleaguesScreen`

## What This Feature Does NOT Include

- No details beyond name + status (no clock-in time, location, GPS, duration)
- No Realtime WebSocket subscriptions (polling only)
- No search or filtering
- No navigation to employee profile/detail
- No offline caching (requires network)

## Dependencies

- Existing `employee_profiles` table
- Existing `shifts` table
- Existing `lunch_breaks` table (migration 129)
- Supabase RPC infrastructure
