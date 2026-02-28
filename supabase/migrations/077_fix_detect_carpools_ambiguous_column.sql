-- Migration 077: Fix ambiguous column reference in detect_carpools
-- The RETURNS TABLE includes 'carpool_group_id' as output column, which conflicts
-- with carpool_members.carpool_group_id in the DELETE statement (line 31).
-- Fix: qualify with table alias.

CREATE OR REPLACE FUNCTION detect_carpools(p_date DATE)
RETURNS TABLE (
    carpool_group_id UUID,
    member_count INTEGER,
    driver_employee_id UUID,
    review_needed BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_trip RECORD;
    v_other RECORD;
    v_overlap_seconds DOUBLE PRECISION;
    v_shorter_duration DOUBLE PRECISION;
    v_start_dist DOUBLE PRECISION;
    v_end_dist DOUBLE PRECISION;
    v_group_id UUID;
    v_existing_group UUID;
    v_other_group UUID;
    v_personal_count INTEGER;
    v_driver_id UUID;
    v_needs_review BOOLEAN;
    v_member RECORD;
BEGIN
    -- Step 0: Delete existing carpool data for this date (idempotent)
    DELETE FROM carpool_members cm_del
    WHERE cm_del.carpool_group_id IN (
        SELECT id FROM carpool_groups WHERE trip_date = p_date
    );
    DELETE FROM carpool_groups WHERE trip_date = p_date;

    -- Step 1: Create temp table for trip pairs
    CREATE TEMP TABLE IF NOT EXISTS temp_trip_pairs (
        trip_a UUID,
        trip_b UUID,
        employee_a UUID,
        employee_b UUID
    ) ON COMMIT DROP;
    TRUNCATE temp_trip_pairs;

    -- Step 2: Find all driving trips on this date
    CREATE TEMP TABLE IF NOT EXISTS temp_day_trips AS
    SELECT id, employee_id, started_at, ended_at,
           start_latitude, start_longitude,
           end_latitude, end_longitude,
           EXTRACT(EPOCH FROM (ended_at - started_at)) AS duration_seconds
    FROM trips
    WHERE started_at::DATE = p_date
      AND transport_mode = 'driving'
      AND EXTRACT(EPOCH FROM (ended_at - started_at)) > 0
    ORDER BY started_at;

    -- Step 3: Compare all pairs (O(n^2) but n is small per day)
    FOR v_trip IN SELECT * FROM temp_day_trips LOOP
        FOR v_other IN
            SELECT * FROM temp_day_trips
            WHERE id > v_trip.id  -- avoid duplicate pairs
              AND employee_id != v_trip.employee_id
        LOOP
            -- Calculate haversine distances for start and end points
            v_start_dist := haversine_km(
                v_trip.start_latitude, v_trip.start_longitude,
                v_other.start_latitude, v_other.start_longitude
            );
            v_end_dist := haversine_km(
                v_trip.end_latitude, v_trip.end_longitude,
                v_other.end_latitude, v_other.end_longitude
            );

            -- Check proximity: both start and end within 200m (0.2 km)
            IF v_start_dist < 0.2 AND v_end_dist < 0.2 THEN
                -- Check temporal overlap > 80%
                v_overlap_seconds := GREATEST(0,
                    EXTRACT(EPOCH FROM (
                        LEAST(v_trip.ended_at, v_other.ended_at) -
                        GREATEST(v_trip.started_at, v_other.started_at)
                    ))
                );
                v_shorter_duration := LEAST(v_trip.duration_seconds, v_other.duration_seconds);

                IF v_shorter_duration > 0 AND (v_overlap_seconds / v_shorter_duration) >= 0.8 THEN
                    INSERT INTO temp_trip_pairs (trip_a, trip_b, employee_a, employee_b)
                    VALUES (v_trip.id, v_other.id, v_trip.employee_id, v_other.employee_id);
                END IF;
            END IF;
        END LOOP;
    END LOOP;

    -- Step 4: Group pairs transitively using union-find via temp table
    CREATE TEMP TABLE IF NOT EXISTS temp_trip_groups (
        trip_id UUID PRIMARY KEY,
        group_id UUID
    ) ON COMMIT DROP;
    TRUNCATE temp_trip_groups;

    FOR v_trip IN SELECT * FROM temp_trip_pairs LOOP
        -- Check if either trip already has a group
        SELECT group_id INTO v_existing_group FROM temp_trip_groups WHERE trip_id = v_trip.trip_a;
        SELECT group_id INTO v_other_group FROM temp_trip_groups WHERE trip_id = v_trip.trip_b;

        IF v_existing_group IS NOT NULL AND v_other_group IS NOT NULL THEN
            -- Both have groups: merge (update all of other_group to existing_group)
            IF v_existing_group != v_other_group THEN
                UPDATE temp_trip_groups SET group_id = v_existing_group
                WHERE group_id = v_other_group;
            END IF;
        ELSIF v_existing_group IS NOT NULL THEN
            -- Only A has a group: add B to it
            INSERT INTO temp_trip_groups (trip_id, group_id) VALUES (v_trip.trip_b, v_existing_group)
            ON CONFLICT (trip_id) DO NOTHING;
        ELSIF v_other_group IS NOT NULL THEN
            -- Only B has a group: add A to it
            INSERT INTO temp_trip_groups (trip_id, group_id) VALUES (v_trip.trip_a, v_other_group)
            ON CONFLICT (trip_id) DO NOTHING;
        ELSE
            -- Neither has a group: create new group
            v_group_id := gen_random_uuid();
            INSERT INTO temp_trip_groups (trip_id, group_id) VALUES (v_trip.trip_a, v_group_id);
            INSERT INTO temp_trip_groups (trip_id, group_id) VALUES (v_trip.trip_b, v_group_id)
            ON CONFLICT (trip_id) DO NOTHING;
        END IF;
    END LOOP;

    -- Step 5: Create carpool_groups and members for each group
    FOR v_trip IN
        SELECT DISTINCT group_id FROM temp_trip_groups
    LOOP
        -- Count members with active personal vehicle period
        SELECT COUNT(*) INTO v_personal_count
        FROM temp_trip_groups tg
        JOIN trips t ON t.id = tg.trip_id
        WHERE tg.group_id = v_trip.group_id
          AND has_active_vehicle_period(t.employee_id, 'personal', p_date);

        -- Determine driver and review status
        IF v_personal_count = 1 THEN
            SELECT t.employee_id INTO v_driver_id
            FROM temp_trip_groups tg
            JOIN trips t ON t.id = tg.trip_id
            WHERE tg.group_id = v_trip.group_id
              AND has_active_vehicle_period(t.employee_id, 'personal', p_date)
            LIMIT 1;
            v_needs_review := false;
        ELSIF v_personal_count = 0 THEN
            v_driver_id := NULL;
            v_needs_review := true;
        ELSE
            SELECT t.employee_id INTO v_driver_id
            FROM temp_trip_groups tg
            JOIN trips t ON t.id = tg.trip_id
            JOIN employee_profiles ep ON ep.id = t.employee_id
            WHERE tg.group_id = v_trip.group_id
              AND has_active_vehicle_period(t.employee_id, 'personal', p_date)
            ORDER BY ep.name ASC
            LIMIT 1;
            v_needs_review := true;
        END IF;

        -- Create carpool group
        v_group_id := gen_random_uuid();
        INSERT INTO carpool_groups (id, trip_date, driver_employee_id, review_needed)
        VALUES (v_group_id, p_date, v_driver_id, v_needs_review);

        -- Create members with roles
        FOR v_member IN
            SELECT tg.trip_id, t.employee_id
            FROM temp_trip_groups tg
            JOIN trips t ON t.id = tg.trip_id
            WHERE tg.group_id = v_trip.group_id
        LOOP
            INSERT INTO carpool_members (carpool_group_id, trip_id, employee_id, role)
            VALUES (
                v_group_id,
                v_member.trip_id,
                v_member.employee_id,
                CASE
                    WHEN v_driver_id IS NULL THEN 'unassigned'
                    WHEN v_member.employee_id = v_driver_id THEN 'driver'
                    ELSE 'passenger'
                END
            );
        END LOOP;
    END LOOP;

    -- Cleanup temp tables
    DROP TABLE IF EXISTS temp_day_trips;

    -- Return results
    RETURN QUERY
    SELECT
        cg.id AS carpool_group_id,
        (SELECT COUNT(*)::INTEGER FROM carpool_members cm WHERE cm.carpool_group_id = cg.id) AS member_count,
        cg.driver_employee_id,
        cg.review_needed
    FROM carpool_groups cg
    WHERE cg.trip_date = p_date;
END;
$$;

COMMENT ON FUNCTION detect_carpools IS 'Detect carpooling trips on a given date based on proximity and temporal overlap';
