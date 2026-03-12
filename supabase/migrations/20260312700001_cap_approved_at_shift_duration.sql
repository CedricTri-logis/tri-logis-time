-- =============================================================================
-- Cap approved_minutes at total_shift_minutes
-- =============================================================================
-- When a cluster (stop) starts before clock-in, its duration_minutes exceeds
-- the shift duration. The approved_minutes sum could exceed total_shift_minutes,
-- showing e.g. "Approuvé: 6h40" when "Total: 6h36".
-- Fix: LEAST(v_approved_minutes, v_total_shift_minutes) after computation.
-- =============================================================================

DO $$
DECLARE
    v_funcdef TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_funcdef
    FROM pg_proc WHERE proname = '_get_day_approval_detail_base';

    v_funcdef := REPLACE(v_funcdef,
        'IF v_day_approval.status = ''approved'' THEN
        v_approved_minutes := v_day_approval.approved_minutes;
        v_rejected_minutes := v_day_approval.rejected_minutes;
        v_needs_review_count := 0;
    END IF;

    v_result := jsonb_build_object(',
        'IF v_day_approval.status = ''approved'' THEN
        v_approved_minutes := v_day_approval.approved_minutes;
        v_rejected_minutes := v_day_approval.rejected_minutes;
        v_needs_review_count := 0;
    END IF;

    -- Cap approved minutes at shift duration (activities can extend beyond shift boundaries)
    v_approved_minutes := LEAST(v_approved_minutes, v_total_shift_minutes);

    v_result := jsonb_build_object('
    );

    EXECUTE v_funcdef;
END $$;

-- =============================================================================
-- Same cap for get_weekly_approval_summary
-- Weekly total_shift_minutes already subtracts lunch, so cap at (raw - lunch)
-- =============================================================================
DO $$
DECLARE
    v_funcdef TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_funcdef
    FROM pg_proc WHERE proname = 'get_weekly_approval_summary';

    v_funcdef := REPLACE(v_funcdef,
        '''approved_minutes'', CASE WHEN pds.approval_status = ''approved'' THEN pds.frozen_approved ELSE COALESCE(pds.live_approved, 0) END',
        '''approved_minutes'', LEAST(CASE WHEN pds.approval_status = ''approved'' THEN pds.frozen_approved ELSE COALESCE(pds.live_approved, 0) END, GREATEST(COALESCE(pds.total_shift_minutes, 0) - COALESCE(pds.lunch_minutes, 0), 0))'
    );

    EXECUTE v_funcdef;
END $$;
