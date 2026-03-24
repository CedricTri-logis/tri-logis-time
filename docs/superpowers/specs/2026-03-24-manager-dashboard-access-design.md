# Manager Dashboard Access

**Date:** 2026-03-24
**Status:** Approved

## Summary

Give managers (`role = 'manager'`) full dashboard access scoped to their supervised employees. Managers get all admin capabilities (view, override, approve) but only for employees linked via `employee_supervisors` with `effective_to IS NULL`.

## Scope

### In scope
- Middleware: allow `manager` role to access `/dashboard/*`
- Sidebar: role-aware navigation (hide admin-only pages for managers)
- Approval RPCs: extend auth checks to accept managers for supervised employees
- RLS: add manager write policies on `day_approvals` and `activity_overrides`
- Auth check on `get_day_approval_detail` (currently unprotected)

### Out of scope
- New UI for manager-specific views (they use the same pages as admins)
- Employee management write access for managers (read-only)
- Changes to monitoring RPCs (already support managers)

## Design

### 1. Middleware (`dashboard/src/middleware.ts`)

**Change:** Line 82 — add `manager` to allowed roles.

```ts
// Before
if (!userRole || !['admin', 'super_admin'].includes(userRole))

// After
if (!userRole || !['admin', 'super_admin', 'manager'].includes(userRole))
```

### 2. Database: Helper function `can_manage_employee()`

New reusable `SECURITY DEFINER` function. Returns `true` if caller is admin/super_admin OR has active supervision over the target employee.

```sql
CREATE OR REPLACE FUNCTION public.can_manage_employee(
    caller_id UUID,
    target_employee_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql SECURITY DEFINER STABLE
SET search_path = public
AS $$
    SELECT public.is_admin_or_super_admin(caller_id)
        OR EXISTS (
            SELECT 1 FROM employee_supervisors es
            WHERE es.manager_id = caller_id
              AND es.employee_id = target_employee_id
              AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
        );
$$;
```

### 3. RPC Updates

#### `get_weekly_approval_summary`

Modify the `employee_list` CTE to filter by supervision when caller is manager:

```sql
employee_list AS (
    SELECT ep.id AS employee_id, ep.full_name AS employee_name
    FROM employee_profiles ep
    WHERE ep.status = 'active'
      AND (
          public.is_admin_or_super_admin(auth.uid())
          OR EXISTS (
              SELECT 1 FROM employee_supervisors es
              WHERE es.manager_id = auth.uid()
                AND es.employee_id = ep.id
                AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
          )
      )
    ORDER BY ep.full_name
)
```

#### `save_activity_override`, `remove_activity_override`, `approve_day`, `reopen_day`

Replace the admin-only check with the new helper:

```sql
-- Before
IF NOT is_admin_or_super_admin(v_caller) THEN
    RAISE EXCEPTION 'Only admins can ...';
END IF;

-- After
IF NOT can_manage_employee(v_caller, p_employee_id) THEN
    RAISE EXCEPTION 'Not authorized to manage this employee';
END IF;
```

#### `get_day_approval_detail`

Add auth check in the wrapper function (currently has none):

```sql
IF NOT can_manage_employee(auth.uid(), p_employee_id) THEN
    RAISE EXCEPTION 'Not authorized to view this employee';
END IF;
```

### 4. RLS Policy Updates

#### `day_approvals` — manager write access

```sql
CREATE POLICY "manager_manage_subordinate_day_approvals"
    ON day_approvals FOR ALL TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM employee_supervisors es
            WHERE es.manager_id = auth.uid()
              AND es.employee_id = day_approvals.employee_id
              AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM employee_supervisors es
            WHERE es.manager_id = auth.uid()
              AND es.employee_id = day_approvals.employee_id
              AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
        )
    );
```

#### `activity_overrides` — manager write access

```sql
CREATE POLICY "manager_manage_subordinate_activity_overrides"
    ON activity_overrides FOR ALL TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM day_approvals da
            JOIN employee_supervisors es ON es.employee_id = da.employee_id
            WHERE da.id = activity_overrides.day_approval_id
              AND es.manager_id = auth.uid()
              AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM day_approvals da
            JOIN employee_supervisors es ON es.employee_id = da.employee_id
            WHERE da.id = activity_overrides.day_approval_id
              AND es.manager_id = auth.uid()
              AND (es.effective_to IS NULL OR es.effective_to >= CURRENT_DATE)
        )
    );
```

### 5. Sidebar Navigation (`dashboard/src/components/layout/sidebar.tsx`)

Add an `adminOnly` flag to navigation items and filter based on user role from `useGetIdentity()`.

**Manager-visible pages:**
- Vue d'ensemble (`/dashboard`)
- En direct (`/dashboard/monitoring`)
- Employes (`/dashboard/employees`) — read-only, data scoped by RLS
- Historique (`/dashboard/history`)
- Sessions de travail (`/dashboard/work-sessions`)
- Activites (`/dashboard/activity`)
- Approbation (`/dashboard/approvals`)
- Kilometrage (`/dashboard/mileage-approval`)
- Remuneration (`/dashboard/remuneration`)
- Paie (`/dashboard/remuneration/payroll`)

**Admin-only pages (hidden for managers):**
- Equipes (`/dashboard/teams`)
- Emplacements (`/dashboard/locations`)
- Diagnostics GPS (`/dashboard/diagnostics`)
- Rapports (`/dashboard/reports`)

### 6. No Changes Required

- **Auth provider** — already returns `role` via `getIdentity()` and `getPermissions()`
- **Monitoring RPCs** — `get_monitored_team()` already filters by supervisor
- **Data table RLS** — `shifts`, `gps_points`, `employee_profiles` already have supervisor-based SELECT policies

## Migration Strategy

Single migration file containing:
1. `can_manage_employee()` helper function
2. Updated `get_weekly_approval_summary` (patch `employee_list` CTE)
3. Updated approval action RPCs (4 functions)
4. Updated `get_day_approval_detail` (add auth check)
5. New RLS policies on `day_approvals` and `activity_overrides`

## Risk Assessment

- **Low risk:** Middleware change is additive (new role allowed, no existing access removed)
- **Low risk:** RLS policies are additive (new policies, existing ones untouched)
- **Medium risk:** RPC changes modify existing functions — careful testing needed to ensure admin behavior is preserved
- **Mitigation:** `can_manage_employee()` delegates to `is_admin_or_super_admin()` first, so admin path is unchanged
