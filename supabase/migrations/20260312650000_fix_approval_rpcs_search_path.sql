-- =============================================================================
-- Fix search_path for approval RPCs (add extensions for PostGIS)
-- =============================================================================
-- save_activity_override and approve_day had SET search_path TO 'public'
-- but they call get_day_approval_detail which uses PostGIS geography types
-- in the extensions schema. This caused: "type geography does not exist"
-- =============================================================================

DO $$
DECLARE
    v_funcdef TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_funcdef
    FROM pg_proc WHERE proname = 'save_activity_override';
    v_funcdef := REPLACE(v_funcdef,
        'SET search_path TO ''public''',
        'SET search_path TO ''public'', ''extensions'''
    );
    EXECUTE v_funcdef;
END $$;

DO $$
DECLARE
    v_funcdef TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_funcdef
    FROM pg_proc WHERE proname = 'approve_day';
    v_funcdef := REPLACE(v_funcdef,
        'SET search_path TO ''public''',
        'SET search_path TO ''public'', ''extensions'''
    );
    EXECUTE v_funcdef;
END $$;
