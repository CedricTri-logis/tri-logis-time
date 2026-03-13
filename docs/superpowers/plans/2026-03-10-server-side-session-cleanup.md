# Server-Side Session Cleanup Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move all session/shift closure logic to the server so it works even when the old phone is dead/offline.

**Architecture:** A single reusable SQL function `server_close_all_sessions()` closes everything for an employee. It's called from `register_device_login()` (device change) and a new `sign_out_cleanup()` RPC (voluntary sign-out). Flutter client is simplified to no longer attempt client-side clock-out during force-logout.

**Tech Stack:** PostgreSQL (Supabase migration), Dart/Flutter (provider + UI changes)

**Spec:** `docs/superpowers/specs/2026-03-10-server-side-session-cleanup-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `supabase/migrations/20260310040000_server_close_all_sessions.sql` | Create | SQL: `server_close_all_sessions()`, `sign_out_cleanup()`, updated `register_device_login()` |
| `gps_tracker/lib/features/auth/providers/device_session_provider.dart` | Modify | Remove client-side clock-out from `_handleForceLogout()` |
| `gps_tracker/lib/features/home/home_screen.dart` | Modify | Enhanced sign-out with server cleanup + active session warning |

---

## Task 1: SQL Migration — `server_close_all_sessions()` + `sign_out_cleanup()` + updated `register_device_login()`

**Files:**
- Create: `supabase/migrations/20260310040000_server_close_all_sessions.sql`

- [ ] **Step 1: Write the migration file**

```sql
-- Migration: Server-side session cleanup on device change or sign-out
--
-- Problem: Session closure depended on the OLD phone detecting device change
-- and executing clock-out locally. If old phone is dead/offline, sessions
-- stay open forever (Celine's 21h18 maintenance session).
--
-- Fix: server_close_all_sessions() atomically closes everything server-side.
-- Called from register_device_login() and sign_out_cleanup().
--
-- Note: Cleaning sessions closed by this function do NOT get is_flagged/flag_reason
-- computed (unlike the shift-complete trigger in 036 which calls _compute_cleaning_flags).
-- This is intentional — server_auto_close is an emergency/abnormal path and these sessions
-- should be reviewed by a supervisor anyway.
--
-- Note: This function is for INTERNAL use only (called by register_device_login and
-- sign_out_cleanup). It is not intended to be called directly as a public RPC.

-- ============ 1. Core function: close all sessions for an employee ============
CREATE OR REPLACE FUNCTION server_close_all_sessions(p_employee_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cleaning_closed INT;
  v_maintenance_closed INT;
  v_shifts_closed INT;
  v_lunch_closed INT;
BEGIN
  -- Step 1: Close active cleaning sessions
  UPDATE cleaning_sessions
  SET status = 'auto_closed',
      completed_at = now(),
      duration_minutes = ROUND(EXTRACT(EPOCH FROM (now() - started_at)) / 60.0, 2),
      updated_at = now()
  WHERE employee_id = p_employee_id
    AND status = 'in_progress';
  GET DIAGNOSTICS v_cleaning_closed = ROW_COUNT;

  -- Step 2: Close active maintenance sessions
  UPDATE maintenance_sessions
  SET status = 'auto_closed',
      completed_at = now(),
      duration_minutes = ROUND(EXTRACT(EPOCH FROM (now() - started_at)) / 60.0, 2),
      updated_at = now()
  WHERE employee_id = p_employee_id
    AND status = 'in_progress';
  GET DIAGNOSTICS v_maintenance_closed = ROW_COUNT;

  -- Step 3: Close active lunch breaks
  UPDATE lunch_breaks
  SET ended_at = now()
  WHERE employee_id = p_employee_id
    AND ended_at IS NULL;
  GET DIAGNOSTICS v_lunch_closed = ROW_COUNT;

  -- Step 4: Close active shifts (AFTER sessions so trigger finds nothing to double-process)
  UPDATE shifts
  SET status = 'completed',
      clocked_out_at = now(),
      clock_out_reason = 'server_auto_close'
  WHERE employee_id = p_employee_id
    AND status = 'active';
  GET DIAGNOSTICS v_shifts_closed = ROW_COUNT;

  RETURN jsonb_build_object(
    'success', true,
    'shifts_closed', v_shifts_closed,
    'cleaning_closed', v_cleaning_closed,
    'maintenance_closed', v_maintenance_closed,
    'lunch_closed', v_lunch_closed
  );
END;
$$;

-- ============ 2. Updated register_device_login: close sessions on device change ============
CREATE OR REPLACE FUNCTION register_device_login(
  p_device_id TEXT,
  p_device_platform TEXT DEFAULT NULL,
  p_device_os_version TEXT DEFAULT NULL,
  p_device_model TEXT DEFAULT NULL,
  p_app_version TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID;
  v_old_device_id TEXT;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('error', 'not_authenticated');
  END IF;

  -- Check if employee has a DIFFERENT active device → close all sessions first
  SELECT device_id INTO v_old_device_id
  FROM active_device_sessions
  WHERE employee_id = v_user_id;

  IF v_old_device_id IS NOT NULL AND v_old_device_id != p_device_id THEN
    PERFORM server_close_all_sessions(v_user_id);
  END IF;

  -- Unmark any current device for this employee
  UPDATE employee_devices
    SET is_current = false
    WHERE employee_id = v_user_id AND is_current = true;

  -- Upsert the device record
  INSERT INTO employee_devices (employee_id, device_id, platform, os_version, model, app_version, is_current)
    VALUES (v_user_id, p_device_id, p_device_platform, p_device_os_version, p_device_model, p_app_version, true)
    ON CONFLICT (employee_id, device_id)
    DO UPDATE SET
      platform = COALESCE(EXCLUDED.platform, employee_devices.platform),
      os_version = COALESCE(EXCLUDED.os_version, employee_devices.os_version),
      model = COALESCE(EXCLUDED.model, employee_devices.model),
      app_version = COALESCE(EXCLUDED.app_version, employee_devices.app_version),
      last_seen_at = now(),
      is_current = true;

  -- Upsert active device session
  INSERT INTO active_device_sessions (employee_id, device_id, session_started_at)
    VALUES (v_user_id, p_device_id, now())
    ON CONFLICT (employee_id)
    DO UPDATE SET
      device_id = EXCLUDED.device_id,
      session_started_at = now();

  -- Update legacy employee_profiles columns
  UPDATE employee_profiles SET
    device_platform = p_device_platform,
    device_os_version = p_device_os_version,
    device_model = p_device_model,
    device_app_version = p_app_version,
    device_updated_at = now()
  WHERE id = v_user_id;

  RETURN jsonb_build_object('success', true, 'device_id', p_device_id);
END;
$$;

-- ============ 3. New RPC: sign_out_cleanup (called before supabase.auth.signOut) ============
CREATE OR REPLACE FUNCTION sign_out_cleanup()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id UUID;
  v_result JSONB;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('error', 'not_authenticated');
  END IF;

  -- Close all active sessions/shifts
  v_result := server_close_all_sessions(v_user_id);

  -- Remove active device session
  DELETE FROM active_device_sessions WHERE employee_id = v_user_id;

  RETURN v_result;
END;
$$;
```

- [ ] **Step 2: Apply the migration**

Run: `supabase MCP apply_migration` or deploy via push

- [ ] **Step 3: Verify with a quick SQL test**

```sql
-- Check functions exist
SELECT proname FROM pg_proc WHERE proname IN ('server_close_all_sessions', 'sign_out_cleanup') ORDER BY proname;
-- Expected: server_close_all_sessions, sign_out_cleanup
```

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260310040000_server_close_all_sessions.sql
git commit -m "feat: server-side session cleanup on device change and sign-out

server_close_all_sessions() atomically closes cleaning, maintenance,
lunch breaks, and shifts. Called from register_device_login() when
device changes, and from new sign_out_cleanup() RPC."
```

---

## Task 2: Simplify Flutter `_handleForceLogout()` — Remove Client-Side Clock-Out

**Files:**
- Modify: `gps_tracker/lib/features/auth/providers/device_session_provider.dart:106-140`

- [ ] **Step 1: Remove the client-side clock-out block**

In `_handleForceLogout()`, remove lines 123-131 (the try/catch that calls `shiftProvider.notifier.clockOut()`). The server already closed everything in `register_device_login()`.

Replace the full method (lines 106-140) with:

```dart
  Future<void> _handleForceLogout({
    required String detectionMethod,
    required String expectedDeviceId,
    required String actualDeviceId,
  }) async {
    _logger?.auth(
      Severity.critical,
      'Force logout triggered',
      metadata: {
        'detection_method': detectionMethod,
        'expected_device_id': expectedDeviceId,
        'actual_device_id': actualDeviceId,
      },
    );
    state = DeviceSessionStatus.forcedOut;
    wasForceLoggedOut = true;

    // Server already closed shift + sessions in register_device_login().
    // Just sign out locally — navigation via authStateChangesProvider.
    try {
      final authService = _ref.read(authServiceProvider);
      await authService.signOut(revokeSession: true);
    } catch (e) {
      _logger?.auth(Severity.error, 'Sign-out during force logout failed',
          metadata: {'error': e.toString()});
    }
  }
```

- [ ] **Step 2: Remove unused import if `shiftProvider` is no longer referenced**

Check if `shift_provider.dart` import (line 10) is still needed elsewhere in the file. If `_handleForceLogout` was the only usage, remove:

```dart
// Remove this line if no longer used:
import '../../shifts/providers/shift_provider.dart';
```

- [ ] **Step 3: Run `flutter analyze`**

```bash
cd gps_tracker && flutter analyze
```

Expected: No errors

- [ ] **Step 4: Commit**

```bash
git add gps_tracker/lib/features/auth/providers/device_session_provider.dart
git commit -m "refactor: remove client-side clock-out from force logout

Server now closes everything in register_device_login() when device
changes. Client only needs to sign out locally."
```

---

## Task 3: Enhanced Sign-Out Flow with Server Cleanup

**Files:**
- Modify: `gps_tracker/lib/features/home/home_screen.dart:22-75`

- [ ] **Step 1: Update `_handleSignOut()` to call `sign_out_cleanup()` and show active session warning**

Replace the method (lines 22-75) with:

```dart
  Future<void> _handleSignOut(BuildContext context, WidgetRef ref) async {
    final bio = ref.read(biometricServiceProvider);
    final biometricEnabled = await bio.isEnabled();

    // Check for active shift/sessions to show appropriate warning
    final shiftState = ref.read(shiftProvider);
    final hasActiveShift = shiftState.activeShift != null;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Déconnexion'),
        content: Text(hasActiveShift
            ? 'Vous avez un quart de travail en cours. '
              'Tout sera fermé automatiquement. '
              'Voulez-vous vous déconnecter ?'
            : 'Voulez-vous vraiment vous déconnecter ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Déconnexion'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // Server-side cleanup: close shift + all sessions atomically
    try {
      final client = ref.read(supabaseClientProvider);
      await client.rpc('sign_out_cleanup');
    } catch (e) {
      // Best effort — don't block sign-out if RPC fails (e.g. offline)
      debugPrint('sign_out_cleanup failed (best effort): $e');
    }

    if (biometricEnabled) {
      // App-lock pattern: save fresh tokens, then lock the app
      // WITHOUT calling signOut() (which would revoke the refresh token).
      final client = ref.read(supabaseClientProvider);
      final session = client.auth.currentSession;
      if (session != null) {
        final phone = client.auth.currentUser?.phone;
        await bio.saveSessionTokens(
          accessToken: session.accessToken,
          refreshToken: session.refreshToken!,
          phone: (phone != null && phone.isNotEmpty) ? phone : null,
        );
      }

      // Lock the app → app.dart shows SignInScreen, session stays alive
      ref.read(appLockProvider.notifier).state = true;
    } else {
      // No biometric → regular sign-out (revokes session)
      final authService = ref.read(authServiceProvider);
      await authService.signOut();
    }
    // Navigation handled automatically by auth/lock state in app.dart
  }
```

- [ ] **Step 2: Add the supabase_provider import if not already present**

Check line 5 — `supabase_provider.dart` is already imported. No change needed.

- [ ] **Step 3: Run `flutter analyze`**

```bash
cd gps_tracker && flutter analyze
```

Expected: No errors

- [ ] **Step 4: Commit**

```bash
git add gps_tracker/lib/features/home/home_screen.dart
git commit -m "feat: call sign_out_cleanup RPC on voluntary sign-out

Shows warning if shift/sessions are active. Server closes everything
atomically before the client signs out."
```

---

## Task 4: Manual Verification

- [ ] **Step 1: Test device change scenario**

1. Log in as test employee on Device A, start a shift + maintenance session
2. Log in as same employee on Device B
3. Verify in DB: shift is `completed` with `clock_out_reason = 'server_auto_close'`, maintenance session is `auto_closed`
4. Verify Device A detects force-logout and shows sign-in screen

```sql
SELECT id, status, clock_out_reason, clocked_out_at
FROM shifts WHERE employee_id = '<test_employee_id>' ORDER BY clocked_in_at DESC LIMIT 1;

SELECT id, status, completed_at, duration_minutes
FROM maintenance_sessions WHERE employee_id = '<test_employee_id>' ORDER BY started_at DESC LIMIT 1;
```

- [ ] **Step 2: Test voluntary sign-out scenario**

1. Log in, start shift + cleaning session
2. Click "Déconnexion" — verify warning mentions active shift
3. Confirm — verify in DB: shift closed, cleaning session closed
4. Verify sign-in screen appears

- [ ] **Step 3: Test sign-out with no active sessions**

1. Log in, do NOT start a shift
2. Click "Déconnexion" — verify simple message (no active shift warning)
3. Confirm — verify clean sign-out

- [ ] **Step 4: Commit final if any tweaks**

```bash
git commit -m "chore: verification complete for server-side session cleanup"
```
