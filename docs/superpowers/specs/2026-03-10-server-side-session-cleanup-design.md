# Server-Side Session Cleanup on Disconnect/Device Change

**Date:** 2026-03-10
**Status:** Approved
**Trigger:** Celine's maintenance session stayed open 21h18 because old phone didn't execute force-logout cascade

## Problem

Session closure currently depends on the OLD phone detecting a device change and executing clock-out locally. If the old phone is off, killed, or has no network, the cascade never fires. Sessions accumulate time silently.

Three gaps:
1. `register_device_login()` doesn't touch shifts/sessions — only updates device tables
2. Voluntary sign-out (`supabase.auth.signOut()`) doesn't close shifts/sessions server-side
3. No server-side fallback when the client-side cascade fails

## Design Decisions

- **All closure logic moves to the server** — client no longer responsible for closing shifts/sessions during force-logout or sign-out
- **Time recorded = real time until closure** (not last heartbeat, not manual review)
- **No pg_cron safety net** — fixing the 3 triggers (device change, sign-out, clock-out) eliminates orphans
- **Voluntary sign-out shows confirmation** if shift/session is active, then closes everything silently

## Solution

### 1. New RPC: `server_close_all_sessions(p_employee_id UUID)`

Single reusable function that atomically closes everything for an employee:

1. Close all `cleaning_sessions` where `status = 'in_progress'` for this employee
   - Set `status = 'auto_closed'`, `completed_at = now()`, compute `duration_minutes`
2. Close all `maintenance_sessions` where `status = 'in_progress'` for this employee
   - Set `status = 'auto_closed'`, `completed_at = now()`, compute `duration_minutes`
3. Close active `shift` (if any)
   - Set `status = 'completed'`, `clocked_out_at = now()`, `clock_out_reason = 'server_auto_close'`
4. Return summary: `{ shifts_closed, cleaning_closed, maintenance_closed }`

Properties:
- `SECURITY DEFINER` (callable from any auth context)
- Idempotent (safe to call multiple times)
- Handles case where no sessions/shifts are active (no-op)

### 2. Modify `register_device_login()`

Add at the beginning, BEFORE updating device tables:

```sql
-- If employee already has a different active device, close everything first
IF EXISTS (
  SELECT 1 FROM active_device_sessions
  WHERE employee_id = p_employee_id AND device_id != p_device_id
) THEN
  PERFORM server_close_all_sessions(p_employee_id);
END IF;
```

Result: When employee logs in on phone 2, server closes shift + all sessions from phone 1 in the same transaction. Phone 1 doesn't need to cooperate.

### 3. New RPC: `sign_out_cleanup(p_employee_id UUID)`

Called by Flutter BEFORE `supabase.auth.signOut()`:

1. Call `server_close_all_sessions(p_employee_id)`
2. Delete from `active_device_sessions` where `employee_id = p_employee_id`

### 4. Flutter — Sign-Out Flow Change

In the sign-out button handler:

1. Check if shift or session is active
2. If yes: show confirmation dialog — "Vous avez un quart et une session en cours. Tout fermer et se deconnecter ?"
3. If confirmed: call `sign_out_cleanup()` RPC, then `supabase.auth.signOut()`
4. If no active sessions: call `sign_out_cleanup()` anyway (idempotent), then sign out

### 5. Flutter — Simplify Force-Logout

In `device_session_provider.dart`, `_handleForceLogout()`:

- REMOVE: `shiftProvider.notifier.clockOut()` (server already closed everything)
- KEEP: sign out + navigate to login screen
- The client simply refreshes state on next login

## Files Impacted

| File | Change |
|------|--------|
| New migration SQL | `server_close_all_sessions()`, `sign_out_cleanup()`, modify `register_device_login()` |
| `device_session_provider.dart` | Remove client-side clock-out from `_handleForceLogout()` |
| Sign-out UI (profile/settings screen) | Add confirmation dialog + call `sign_out_cleanup()` before `signOut()` |

## Constraints

- `server_close_all_sessions` must handle the shift-close trigger (`auto_close_sessions_on_shift_complete`) gracefully — since we close sessions BEFORE the shift, the trigger will find no sessions to close (no-op). This avoids double-processing.
- Order matters: close cleaning/maintenance FIRST, then shift. This prevents the shift trigger from racing with explicit session closure.
