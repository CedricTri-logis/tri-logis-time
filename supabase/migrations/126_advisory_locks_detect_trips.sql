-- =============================================================================
-- 126: Advisory locks on detect_trips and detect_carpools
-- =============================================================================
-- Prevents deadlocks from concurrent execution. Uses pg_advisory_xact_lock
-- keyed on shift_id (detect_trips) and date (detect_carpools). Lock is
-- auto-released at transaction end.
--
-- Uses dynamic SQL to inject the lock without reproducing the full 50KB+
-- function bodies. Reads current definition, adds lock after BEGIN, re-creates.
-- =============================================================================

DO $$
DECLARE
  v_funcdef TEXT;
  v_modified TEXT;
BEGIN
  -- 1. Add advisory lock to detect_trips
  SELECT pg_get_functiondef(p.oid) INTO v_funcdef
  FROM pg_proc p
  WHERE p.proname = 'detect_trips'
  AND p.pronamespace = 'public'::regnamespace;

  -- Skip if already has advisory lock
  IF v_funcdef NOT LIKE '%pg_advisory_xact_lock%' THEN
    v_modified := regexp_replace(
      v_funcdef,
      E'\\nBEGIN\\n',
      E'\nBEGIN\n  -- Advisory lock: prevent concurrent execution for the same shift\n  PERFORM pg_advisory_xact_lock(hashtext(p_shift_id::text));\n\n',
      ''  -- no 'g' flag = first occurrence only
    );
    EXECUTE v_modified;
    RAISE NOTICE 'detect_trips updated with advisory lock';
  ELSE
    RAISE NOTICE 'detect_trips already has advisory lock, skipping';
  END IF;

  -- 2. Add advisory lock to detect_carpools
  SELECT pg_get_functiondef(p.oid) INTO v_funcdef
  FROM pg_proc p
  WHERE p.proname = 'detect_carpools'
  AND p.pronamespace = 'public'::regnamespace;

  IF v_funcdef NOT LIKE '%pg_advisory_xact_lock%' THEN
    v_modified := regexp_replace(
      v_funcdef,
      E'\\nBEGIN\\n',
      E'\nBEGIN\n  -- Advisory lock: prevent concurrent execution for the same date\n  PERFORM pg_advisory_xact_lock(hashtext(''carpools_'' || p_date::text));\n\n',
      ''
    );
    EXECUTE v_modified;
    RAISE NOTICE 'detect_carpools updated with advisory lock';
  ELSE
    RAISE NOTICE 'detect_carpools already has advisory lock, skipping';
  END IF;
END;
$$;
