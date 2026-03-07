-- =============================================================================
-- 133: Backfill - re-run detect_trips on all completed shifts
-- =============================================================================
-- Creates synthetic trips for all missing cluster pairs.
-- Safe: detect_trips deletes and re-creates everything for completed shifts.
-- =============================================================================

DO $$
DECLARE
    v_shift RECORD;
    v_count INTEGER := 0;
BEGIN
    FOR v_shift IN
        SELECT id FROM shifts
        WHERE status = 'completed'
        ORDER BY clocked_in_at DESC
    LOOP
        PERFORM detect_trips(v_shift.id);
        v_count := v_count + 1;
        IF v_count % 50 = 0 THEN
            RAISE NOTICE 'Processed % shifts', v_count;
        END IF;
    END LOOP;
    RAISE NOTICE 'Backfill complete: % shifts processed', v_count;
END $$;
