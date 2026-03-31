-- ============================================================
-- Migration: Fix manual time overlap with GPS activities
--
-- Bug: When edit_shift_time extends a clock-out, it creates a
-- manual_time_entry starting at the old clock-out time. But GPS
-- clusters/trips can extend past the clock-out (GPS keeps recording
-- after the punch stops). This creates a visual overlap in the
-- approval detail.
--
-- Example: Yvan Rene 2026-03-30
--   Stop at 44_Taschereau: 13:02 → 13:29
--   Manual time extension: 13:20 → 15:16
--   Overlap: 13:20 → 13:29 (9 minutes)
--
-- Fix:
--   Part 1: _get_day_approval_detail_base — adjust display started_at
--           for clock extensions to start after last GPS activity
--   Part 2: edit_shift_time — prevent future overlaps by adjusting
--           the manual_time_entry starts_at at creation time
--   Part 3: Fix existing data (Yvan's entry)
-- ============================================================

-- ============================================================
-- PART 1: Fix display in _get_day_approval_detail_base
-- ============================================================
DO $patch1$
DECLARE
    v_funcdef TEXT;
    v_old TEXT;
    v_new TEXT;
BEGIN
    SELECT pg_get_functiondef(oid)
    INTO v_funcdef
    FROM pg_proc
    WHERE proname = '_get_day_approval_detail_base'
      AND pronamespace = 'public'::regnamespace;

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');

    v_old := 'mte.starts_at AS started_at,
            mte.ends_at AS ended_at,';

    v_new := 'CASE WHEN mte.shift_id IS NOT NULL THEN
                GREATEST(mte.starts_at, COALESCE(
                    (SELECT MAX(x.t) FROM (
                        SELECT sc.ended_at AS t FROM stationary_clusters sc WHERE sc.shift_id = mte.shift_id
                        UNION ALL
                        SELECT t.ended_at AS t FROM trips t WHERE t.shift_id = mte.shift_id
                    ) x),
                    mte.starts_at
                ))
            ELSE mte.starts_at
            END AS started_at,
            mte.ends_at AS ended_at,';

    IF v_funcdef NOT LIKE '%' || v_old || '%' THEN
        RAISE EXCEPTION 'Part 1: Could not find started_at pattern in _get_day_approval_detail_base';
    END IF;

    v_funcdef := replace(v_funcdef, v_old, v_new);
    EXECUTE v_funcdef;
    RAISE NOTICE 'Part 1: Patched _get_day_approval_detail_base display for clock extensions';
END;
$patch1$;

-- ============================================================
-- PART 2: Fix edit_shift_time to prevent future overlaps
-- ============================================================
DO $patch2$
DECLARE
    v_funcdef TEXT;
    v_old TEXT;
    v_new TEXT;
BEGIN
    SELECT pg_get_functiondef(oid)
    INTO v_funcdef
    FROM pg_proc
    WHERE proname = 'edit_shift_time'
      AND pronamespace = 'public'::regnamespace;

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');

    v_old := '-- Create manual_time_entry if extending
    IF v_extends_shift THEN
        INSERT INTO manual_time_entries (employee_id, date, starts_at, ends_at, reason, shift_id, shift_time_edit_id, created_by)
        VALUES (v_employee_id, v_current_date, v_delta_start, v_delta_end, p_reason, p_shift_id, v_edit_id, v_caller);
    END IF;';

    v_new := '-- Adjust delta boundaries to avoid overlapping with GPS activities in the shift
    IF v_extends_shift AND p_field = ''clocked_out_at'' THEN
        SELECT GREATEST(v_delta_start, COALESCE(MAX(x.t), v_delta_start))
        INTO v_delta_start
        FROM (
            SELECT ended_at AS t FROM stationary_clusters WHERE shift_id = p_shift_id
            UNION ALL
            SELECT ended_at AS t FROM trips WHERE shift_id = p_shift_id
        ) x;
    END IF;
    IF v_extends_shift AND p_field = ''clocked_in_at'' THEN
        SELECT LEAST(v_delta_end, COALESCE(MIN(x.t), v_delta_end))
        INTO v_delta_end
        FROM (
            SELECT started_at AS t FROM stationary_clusters WHERE shift_id = p_shift_id
            UNION ALL
            SELECT started_at AS t FROM trips WHERE shift_id = p_shift_id
        ) x;
    END IF;

    -- Create manual_time_entry if extending and delta is positive
    IF v_extends_shift AND v_delta_start < v_delta_end THEN
        INSERT INTO manual_time_entries (employee_id, date, starts_at, ends_at, reason, shift_id, shift_time_edit_id, created_by)
        VALUES (v_employee_id, v_current_date, v_delta_start, v_delta_end, p_reason, p_shift_id, v_edit_id, v_caller);
    END IF;';

    IF v_funcdef NOT LIKE '%' || v_old || '%' THEN
        RAISE EXCEPTION 'Part 2: Could not find manual_time insert pattern in edit_shift_time';
    END IF;

    v_funcdef := replace(v_funcdef, v_old, v_new);
    EXECUTE v_funcdef;
    RAISE NOTICE 'Part 2: Patched edit_shift_time to prevent GPS overlap in clock extensions';
END;
$patch2$;

-- ============================================================
-- PART 3: Fix existing data — adjust Yvan's manual_time_entry
-- ============================================================
DO $fix_data$
DECLARE
    v_rec RECORD;
    v_last_gps TIMESTAMPTZ;
    v_fixed INTEGER := 0;
BEGIN
    -- Fix ALL existing clock extension entries that overlap with GPS activities
    FOR v_rec IN
        SELECT mte.id, mte.shift_id, mte.starts_at, mte.ends_at
        FROM manual_time_entries mte
        WHERE mte.shift_id IS NOT NULL
    LOOP
        SELECT MAX(x.t) INTO v_last_gps
        FROM (
            SELECT ended_at AS t FROM stationary_clusters WHERE shift_id = v_rec.shift_id
            UNION ALL
            SELECT ended_at AS t FROM trips WHERE shift_id = v_rec.shift_id
        ) x
        WHERE x.t > v_rec.starts_at;

        IF v_last_gps IS NOT NULL AND v_last_gps < v_rec.ends_at THEN
            UPDATE manual_time_entries
            SET starts_at = v_last_gps
            WHERE id = v_rec.id;
            v_fixed := v_fixed + 1;
            RAISE NOTICE 'Fixed manual_time_entry %: starts_at % -> %', v_rec.id, v_rec.starts_at, v_last_gps;
        END IF;
    END LOOP;

    RAISE NOTICE 'Part 3: Fixed % existing manual_time_entries', v_fixed;
END;
$fix_data$;
