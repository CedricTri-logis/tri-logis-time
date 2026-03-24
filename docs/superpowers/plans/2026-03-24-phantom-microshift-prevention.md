# Phantom Micro-Shift Prevention Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate phantom micro-shifts (< 1 minute) via defense-in-depth: prevent at UI, reject at DB, clean up existing.

**Architecture:** Three-layer defense: (1) Flutter debounce on clock-in/clock-out prevents double-taps, (2) Supabase trigger auto-deletes shifts < 1 min when completed, (3) one-shot cleanup of existing phantom shifts. All 9 FK-dependent tables on `shifts` use `ON DELETE CASCADE`, so deleting a shift automatically cleans up gps_points, trips, stationary_clusters, cleaning_sessions, maintenance_sessions, work_sessions, gps_gaps, shift_time_edits, and lunch_breaks.

**Tech Stack:** Dart/Flutter (Riverpod state), PostgreSQL/Supabase (trigger + migration)

---

### Task 1: Database trigger + cleanup — auto-delete shifts < 1 minute

**Files:**
- Create: `supabase/migrations/20260324400000_auto_delete_micro_shifts.sql`

Safety net trigger: when any shift transitions to `completed` and duration < 1 minute, delete it. All dependents cascade-delete automatically. Includes one-shot cleanup of existing phantoms.

- [ ] **Step 1: Write the migration**

```sql
-- ============================================================
-- Migration: Auto-delete micro-shifts (< 1 minute)
--
-- Safety net: when a shift is completed and its duration is
-- less than 1 minute, it's a phantom (double-tap, glitch).
-- All 9 FK-dependent tables use ON DELETE CASCADE, so a single
-- DELETE FROM shifts cascades to gps_points, trips,
-- stationary_clusters, cleaning_sessions, maintenance_sessions,
-- work_sessions, gps_gaps, shift_time_edits, lunch_breaks.
-- ============================================================

CREATE OR REPLACE FUNCTION delete_micro_shift()
RETURNS TRIGGER AS $$
BEGIN
    -- Only act on shifts that just got completed with < 1 min duration
    IF NEW.status = 'completed'
       AND NEW.clocked_out_at IS NOT NULL
       AND NEW.clocked_in_at IS NOT NULL
       AND (NEW.clocked_out_at - NEW.clocked_in_at) < INTERVAL '1 minute'
    THEN
        -- Single DELETE — ON DELETE CASCADE handles all 9 dependent tables
        DELETE FROM shifts WHERE id = NEW.id;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;

-- AFTER UPDATE: the UPDATE commits first, then the trigger fires and deletes.
-- The net effect is the row disappears. Other AFTER triggers that fire on the
-- same event will see the row via NEW but it may already be deleted — they
-- handle this gracefully (no-op on missing rows).
CREATE TRIGGER trg_delete_micro_shift
    AFTER UPDATE OF status ON shifts
    FOR EACH ROW
    WHEN (NEW.status = 'completed' AND OLD.status != 'completed')
    EXECUTE FUNCTION delete_micro_shift();

COMMENT ON FUNCTION delete_micro_shift() IS
    'Safety net: auto-deletes shifts shorter than 1 minute on completion. '
    'These are phantom shifts from double-taps or app glitches. '
    'ON DELETE CASCADE on all FK-dependent tables handles cleanup.';

-- ============================================================
-- One-shot cleanup: delete existing micro-shifts (< 1 minute)
-- ON DELETE CASCADE handles all dependent rows automatically.
-- ============================================================
DO $$
DECLARE
    v_count INTEGER;
BEGIN
    -- Delete phantom shifts — CASCADE handles dependents
    DELETE FROM shifts
    WHERE status = 'completed'
      AND clocked_in_at IS NOT NULL
      AND clocked_out_at IS NOT NULL
      AND (clocked_out_at - clocked_in_at) < INTERVAL '1 minute';

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RAISE NOTICE 'Deleted % phantom micro-shifts', v_count;
END;
$$;
```

- [ ] **Step 2: Apply migration to Supabase**

Run: `mcp__supabase__apply_migration` with the SQL above.

- [ ] **Step 3: Test the trigger**

```sql
-- Insert a test shift, complete it with < 1 min duration, verify it gets deleted
INSERT INTO shifts (id, employee_id, clocked_in_at, status)
VALUES ('00000000-0000-0000-0000-000000000099',
        (SELECT id FROM employee_profiles LIMIT 1),
        NOW(), 'active');

UPDATE shifts SET status = 'completed', clocked_out_at = NOW() + INTERVAL '30 seconds'
WHERE id = '00000000-0000-0000-0000-000000000099';

-- Should return 0 rows — the trigger deleted it
SELECT * FROM shifts WHERE id = '00000000-0000-0000-0000-000000000099';
```

- [ ] **Step 4: Verify cleanup worked**

```sql
-- Should return 0
SELECT count(*) FROM shifts
WHERE status = 'completed'
  AND clocked_out_at IS NOT NULL
  AND (clocked_out_at - clocked_in_at) < INTERVAL '1 minute';
```

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260324400000_auto_delete_micro_shifts.sql
git commit -m "feat: auto-delete micro-shifts < 1 min via DB trigger + cleanup existing"
```

---

### Task 2: Flutter debounce — prevent double-tap on clock-in/clock-out

**Files:**
- Modify: `gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart`

Add a timestamp-based debounce in both `_handleClockIn` and `_handleClockOut` to prevent rapid successive calls. The existing `_isClockInPreparing` guard has a race condition with the Riverpod state; a timestamp check is simpler and bulletproof.

- [ ] **Step 1: Add debounce field to `_ShiftDashboardScreenState`**

Find the state class fields and add:

```dart
DateTime? _lastClockActionAt;
```

- [ ] **Step 2: Add debounce check to `_handleClockIn`**

At the very top of `_handleClockIn()`, before the existing `_isClockInPreparing` check (line 341), add:

```dart
// Debounce: ignore if last clock action was < 10 seconds ago
final now = DateTime.now();
if (_lastClockActionAt != null &&
    now.difference(_lastClockActionAt!) < const Duration(seconds: 10)) {
  return;
}
_lastClockActionAt = now;
```

- [ ] **Step 3: Add debounce check to `_handleClockOut`**

At the very top of `_handleClockOut()`, before the confirmation sheet (line 975), add the same debounce:

```dart
// Debounce: ignore if last clock action was < 10 seconds ago
final now = DateTime.now();
if (_lastClockActionAt != null &&
    now.difference(_lastClockActionAt!) < const Duration(seconds: 10)) {
  return;
}
_lastClockActionAt = now;
```

- [ ] **Step 4: Run flutter analyze**

```bash
cd gps_tracker && flutter analyze
```

Expected: No new errors or warnings.

- [ ] **Step 5: Commit**

```bash
git add gps_tracker/lib/features/shifts/screens/shift_dashboard_screen.dart
git commit -m "feat: add 10s debounce on clock-in/clock-out to prevent phantom shifts"
```
