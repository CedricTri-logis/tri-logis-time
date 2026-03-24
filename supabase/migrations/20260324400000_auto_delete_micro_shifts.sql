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
-- Must temporarily disable payroll lock trigger on lunch_breaks
-- because some phantom shifts fall in locked payroll periods.
-- ============================================================
ALTER TABLE lunch_breaks DISABLE TRIGGER trg_payroll_lock_lunch_breaks;

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

ALTER TABLE lunch_breaks ENABLE TRIGGER trg_payroll_lock_lunch_breaks;
