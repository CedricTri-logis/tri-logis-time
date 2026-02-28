-- Migration 090: Backfill all completed shifts to merge split clusters
-- and populate gps_gap_seconds/gps_gap_count fields.
-- Re-runs detect_trips for every completed shift.

DO $$
DECLARE
    v_shift RECORD;
    v_count INTEGER := 0;
BEGIN
    FOR v_shift IN
        SELECT id FROM shifts WHERE status = 'completed' ORDER BY clocked_in_at ASC
    LOOP
        PERFORM detect_trips(v_shift.id);
        v_count := v_count + 1;
        IF v_count % 100 = 0 THEN
            RAISE NOTICE 'Processed % shifts', v_count;
        END IF;
    END LOOP;
    RAISE NOTICE 'Backfill complete: % shifts processed', v_count;
END $$;
