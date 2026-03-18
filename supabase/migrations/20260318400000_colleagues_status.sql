-- Colleagues status: returns work status + active session for all active employees
-- Accessible by any authenticated user (company-wide peer visibility)

CREATE OR REPLACE FUNCTION get_colleagues_status()
RETURNS TABLE(
    id UUID,
    full_name TEXT,
    work_status TEXT,
    active_session_type TEXT,
    active_session_location TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
    RETURN QUERY
    SELECT
        ep.id,
        COALESCE(ep.full_name, ep.email)::TEXT as full_name,
        CASE
            WHEN lb_active.id IS NOT NULL THEN 'on-lunch'
            WHEN active_shift.id IS NOT NULL THEN 'on-shift'
            ELSE 'off-shift'
        END::TEXT as work_status,
        ws_active.active_session_type,
        ws_active.active_session_location
    FROM employee_profiles ep
    LEFT JOIN LATERAL (
        SELECT s.id
        FROM shifts s
        WHERE s.employee_id = ep.id AND s.status = 'active'
        LIMIT 1
    ) active_shift ON true
    LEFT JOIN LATERAL (
        SELECT lb.id
        FROM lunch_breaks lb
        WHERE lb.shift_id = active_shift.id AND lb.ended_at IS NULL
        LIMIT 1
    ) lb_active ON active_shift.id IS NOT NULL
    LEFT JOIN LATERAL (
        SELECT
            ws.activity_type::TEXT AS active_session_type,
            CASE
                WHEN ws.activity_type = 'cleaning' THEN
                    st.studio_number || ' — ' || b.name
                WHEN ws.activity_type = 'maintenance' THEN
                    CASE WHEN a.unit_number IS NOT NULL
                        THEN pb.name || ' — ' || a.unit_number
                        ELSE pb.name
                    END
                WHEN ws.activity_type = 'admin' THEN 'Administration'
                ELSE ws.activity_type
            END AS active_session_location
        FROM work_sessions ws
        LEFT JOIN studios st ON st.id = ws.studio_id
        LEFT JOIN buildings b ON b.id = st.building_id
        LEFT JOIN property_buildings pb ON pb.id = ws.building_id
        LEFT JOIN apartments a ON a.id = ws.apartment_id
        WHERE ws.employee_id = ep.id AND ws.status = 'in_progress'
        ORDER BY ws.started_at DESC LIMIT 1
    ) ws_active ON true
    WHERE ep.status = 'active'
      AND ep.id != (SELECT auth.uid())
    ORDER BY
        CASE
            WHEN lb_active.id IS NOT NULL THEN 1
            WHEN active_shift.id IS NOT NULL THEN 0
            ELSE 2
        END,
        COALESCE(ep.full_name, ep.email);
END;
$function$;

GRANT EXECUTE ON FUNCTION get_colleagues_status TO authenticated;
