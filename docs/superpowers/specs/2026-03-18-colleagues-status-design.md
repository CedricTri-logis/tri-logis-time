# Colleagues Status — Employee View

**Date:** 2026-03-18
**Feature:** Allow employees to see which colleagues are currently clocked in or on lunch break

## Overview

New screen "Collègues" accessible from the 3-dot menu in the Flutter app. Displays a simple list of all active employees with their current status: on-shift, on-lunch, or off-shift. Available to all authenticated employees (not just managers).

## Backend

### New RPC: `get_colleagues_status()`

**Purpose:** Return the current work status of all active employees.

**Returns (per employee):**

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID | Employee profile ID |
| `full_name` | TEXT | Display name |
| `work_status` | TEXT | `'on-shift'`, `'on-lunch'`, `'off-shift'` |
| `active_session_type` | TEXT | `'cleaning'`, `'maintenance'`, `'admin'`, or NULL |
| `active_session_location` | TEXT | Human-readable location (e.g. "123 — Immeuble X"), or NULL |

**Logic:**
- Queries `employee_profiles` WHERE `status = 'active'`
- LEFT JOIN `shifts` WHERE `status = 'active'` to detect on-shift
- LEFT JOIN `lunch_breaks` WHERE `ended_at IS NULL` to detect on-lunch
- LEFT JOIN `work_sessions` WHERE `status = 'in_progress'` to get active session type + location
- Active session location derived from joined studio/building (same CASE logic as `get_monitored_team()`)
- Status derivation:
  - `lunch_breaks` row exists with `ended_at IS NULL` → `'on-lunch'`
  - `shifts` row exists with `status = 'active'` → `'on-shift'`
  - Otherwise → `'off-shift'`
- Excludes the calling user (`auth.uid()`)
- Sort order: on-shift first, then on-lunch, then off-shift, alphabetical within each group

**Authorization:** Any authenticated user can call this RPC. No manager/admin restriction. This is intentionally unrestricted — all employees see all colleagues. The existing `get_monitored_team()` restricts by supervisor relationship, but this feature is designed for peer visibility across the entire company.

**Migration:** Single migration file (next available number) creating the RPC as a `SECURITY DEFINER` function with `SET search_path = public` (to bypass employee_profiles RLS self-reference limitation). Must include `GRANT EXECUTE ON FUNCTION get_colleagues_status TO authenticated;`.

## Flutter

### Screen: `ColleaguesScreen`

**Location:** `gps_tracker/lib/features/colleagues/screens/colleagues_screen.dart`

**UI layout:**
1. **App bar:** Title "Collègues"
2. **Summary bar:** "X en quart · Y en diner · Z hors quart"
3. **List:** One tile per employee
   - Leading: Circle avatar with initials (first letter of first + last name)
   - Title: Full name
   - Trailing: Status badge (colored chip)
     - Green: "En quart"
     - Orange/yellow: "Diner"
     - Grey: "Hors quart"
   - Subtitle (if active session): type + location (e.g. "Menage — 123 Immeuble X")
4. **Pull-to-refresh:** `RefreshIndicator` for manual refresh
5. **Empty state:** Message when no colleagues found

### Provider: `ColleaguesProvider`

**Location:** `gps_tracker/lib/features/colleagues/providers/colleagues_provider.dart`

- Riverpod `StateNotifier` or `AsyncNotifier`
- Calls `get_colleagues_status()` RPC
- Loads data on init + pull-to-refresh (matches existing TeamDashboardProvider pattern)
- No automatic polling — user pulls to refresh when they want fresh data
- Exposes: list of colleagues + loading state + error state

### Model: `ColleagueStatus`

**Location:** `gps_tracker/lib/features/colleagues/models/colleague_status.dart`

```dart
enum WorkStatus { onShift, onLunch, offShift }

@immutable
class ColleagueStatus {
  final String id;
  final String fullName;
  final WorkStatus workStatus;
  final String? activeSessionType;     // 'cleaning', 'maintenance', 'admin'
  final String? activeSessionLocation; // human-readable location

  const ColleagueStatus({
    required this.id,
    required this.fullName,
    required this.workStatus,
    this.activeSessionType,
    this.activeSessionLocation,
  });

  factory ColleagueStatus.fromJson(Map<String, dynamic> json) => ColleagueStatus(
    id: json['id'] as String,
    fullName: json['full_name'] as String,
    workStatus: _parseWorkStatus(json['work_status'] as String),
    activeSessionType: json['active_session_type'] as String?,
    activeSessionLocation: json['active_session_location'] as String?,
  );
}
```

### Menu Entry

Add "Collègues" item to the 3-dot menu in `HomeScreen` (available to all roles, not just managers).
- Icon: `Icons.people`
- Label: "Collègues"
- Navigates to `ColleaguesScreen`

## What This Feature Does NOT Include

- No details beyond name + status + active session (no clock-in time, GPS, duration)
- No Realtime WebSocket subscriptions (polling only)
- No search or filtering
- No navigation to employee profile/detail
- No offline caching (requires network)

## Dependencies

- Existing `employee_profiles` table
- Existing `shifts` table
- Existing `lunch_breaks` table (migration 129)
- Existing `work_sessions` table (with studio/building joins for location display)
- Supabase RPC infrastructure
