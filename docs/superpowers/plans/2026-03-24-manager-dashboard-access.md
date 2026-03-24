# Manager Dashboard Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give managers full dashboard access (view, override, approve) scoped to their supervised employees.

**Architecture:** Single Supabase migration adds a `can_manage_employee()` helper and patches 6 existing RPCs. Frontend changes are limited to middleware (1 line) and sidebar (role-aware filtering). No new UI components — managers use the same pages as admins.

**Tech Stack:** PostgreSQL (Supabase), Next.js 14+ (App Router), TypeScript, Refine

**Spec:** `docs/superpowers/specs/2026-03-24-manager-dashboard-access-design.md`

---

### Task 1: Database Migration — Helper Function + RPC Updates + RLS

**Files:**
- Create: `supabase/migrations/20260324500000_manager_dashboard_access.sql`

This single migration contains all DB changes: helper function, RPC patches, and RLS policies.

- [ ] **Step 1: Create the migration file**

```sql
-- Migration: Manager Dashboard Access
-- Gives managers (role='manager') the ability to use approval RPCs
-- scoped to their supervised employees via employee_supervisors.

-- ============================================================
-- 1. Helper function: can_manage_employee()
-- ============================================================
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

-- ============================================================
-- 2. Patch get_weekly_approval_summary: scope employee_list
-- ============================================================
-- The employee_list CTE currently selects ALL active employees.
-- We add a filter so managers only see their supervised employees.

DO $patch_weekly$
DECLARE
    v_funcdef TEXT;
    v_old TEXT;
    v_new TEXT;
BEGIN
    SELECT pg_get_functiondef(oid)
    INTO v_funcdef
    FROM pg_proc
    WHERE proname = 'get_weekly_approval_summary'
      AND pronamespace = 'public'::regnamespace;

    IF v_funcdef IS NULL THEN
        RAISE EXCEPTION 'get_weekly_approval_summary not found';
    END IF;

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');

    v_old := $str$SELECT ep.id AS employee_id, ep.full_name AS employee_name
        FROM employee_profiles ep
        WHERE ep.status = 'active'
        ORDER BY ep.full_name$str$;

    v_new := $str$SELECT ep.id AS employee_id, ep.full_name AS employee_name
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
        ORDER BY ep.full_name$str$;

    IF v_funcdef NOT LIKE '%' || v_old || '%' THEN
        RAISE EXCEPTION 'employee_list CTE pattern not found in get_weekly_approval_summary';
    END IF;

    v_funcdef := replace(v_funcdef, v_old, v_new);
    EXECUTE v_funcdef;

    RAISE NOTICE 'Patched get_weekly_approval_summary: employee_list now scoped by role';
END;
$patch_weekly$;

-- ============================================================
-- 3. Patch get_day_approval_detail: add auth check
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_day_approval_detail(
    p_employee_id UUID,
    p_date DATE
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
    v_base JSONB;
    v_ps JSONB;
BEGIN
    -- Auth check: caller must be admin or supervisor of this employee
    IF NOT can_manage_employee(auth.uid(), p_employee_id) THEN
        RAISE EXCEPTION 'Not authorized to view this employee';
    END IF;

    v_base := _get_day_approval_detail_base(p_employee_id, p_date);
    v_ps := _get_project_sessions(p_employee_id, p_date);
    RETURN v_base || jsonb_build_object('project_sessions', v_ps);
END;
$function$;

-- ============================================================
-- 4. Patch approval action RPCs: replace admin check with can_manage_employee
-- ============================================================

-- 4a. save_activity_override
DO $patch_save$
DECLARE
    v_funcdef TEXT;
BEGIN
    SELECT pg_get_functiondef(oid)
    INTO v_funcdef
    FROM pg_proc
    WHERE proname = 'save_activity_override'
      AND pronamespace = 'public'::regnamespace;

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');

    v_funcdef := replace(v_funcdef,
        'IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION ''Only admins can save overrides'';
    END IF;',
        'IF NOT can_manage_employee(v_caller, p_employee_id) THEN
        RAISE EXCEPTION ''Not authorized to manage this employee'';
    END IF;');

    EXECUTE v_funcdef;
    RAISE NOTICE 'Patched save_activity_override: manager access enabled';
END;
$patch_save$;

-- 4b. remove_activity_override
DO $patch_remove$
DECLARE
    v_funcdef TEXT;
BEGIN
    SELECT pg_get_functiondef(oid)
    INTO v_funcdef
    FROM pg_proc
    WHERE proname = 'remove_activity_override'
      AND pronamespace = 'public'::regnamespace;

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');

    v_funcdef := replace(v_funcdef,
        'IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION ''Only admins can remove overrides'';
    END IF;',
        'IF NOT can_manage_employee(v_caller, p_employee_id) THEN
        RAISE EXCEPTION ''Not authorized to manage this employee'';
    END IF;');

    EXECUTE v_funcdef;
    RAISE NOTICE 'Patched remove_activity_override: manager access enabled';
END;
$patch_remove$;

-- 4c. approve_day
DO $patch_approve$
DECLARE
    v_funcdef TEXT;
BEGIN
    SELECT pg_get_functiondef(oid)
    INTO v_funcdef
    FROM pg_proc
    WHERE proname = 'approve_day'
      AND pronamespace = 'public'::regnamespace;

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');

    v_funcdef := replace(v_funcdef,
        'IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION ''Only admins can approve days'';
    END IF;',
        'IF NOT can_manage_employee(v_caller, p_employee_id) THEN
        RAISE EXCEPTION ''Not authorized to manage this employee'';
    END IF;');

    EXECUTE v_funcdef;
    RAISE NOTICE 'Patched approve_day: manager access enabled';
END;
$patch_approve$;

-- 4d. reopen_day
DO $patch_reopen$
DECLARE
    v_funcdef TEXT;
BEGIN
    SELECT pg_get_functiondef(oid)
    INTO v_funcdef
    FROM pg_proc
    WHERE proname = 'reopen_day'
      AND pronamespace = 'public'::regnamespace;

    v_funcdef := replace(v_funcdef, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');

    v_funcdef := replace(v_funcdef,
        'IF NOT is_admin_or_super_admin(v_caller) THEN
        RAISE EXCEPTION ''Only admins can reopen days'';
    END IF;',
        'IF NOT can_manage_employee(v_caller, p_employee_id) THEN
        RAISE EXCEPTION ''Not authorized to manage this employee'';
    END IF;');

    EXECUTE v_funcdef;
    RAISE NOTICE 'Patched reopen_day: manager access enabled';
END;
$patch_reopen$;

-- ============================================================
-- 5. RLS Policies: manager write access
-- ============================================================

-- 5a. day_approvals: managers can manage subordinate approvals
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

-- 5b. activity_overrides: managers can manage subordinate overrides
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

- [ ] **Step 2: Apply the migration**

Run via Supabase MCP `apply_migration` tool.

- [ ] **Step 3: Verify helper function works**

```sql
-- Test: admin should manage any employee
SELECT can_manage_employee(
    (SELECT id FROM employee_profiles WHERE email = 'cedric@tri-logis.ca'),
    (SELECT id FROM employee_profiles WHERE status = 'active' LIMIT 1)
);
-- Expected: true

-- Test: a manager should manage their supervised employee
SELECT can_manage_employee(es.manager_id, es.employee_id)
FROM employee_supervisors es
WHERE es.effective_to IS NULL
LIMIT 1;
-- Expected: true
```

- [ ] **Step 4: Verify weekly summary scoping**

```sql
-- Set role to a manager to test
-- (Manual verification: call get_weekly_approval_summary as a manager user
-- and confirm only supervised employees appear)
```

- [ ] **Step 5: Commit migration**

```bash
git add supabase/migrations/20260324500000_manager_dashboard_access.sql
git commit -m "feat: add manager dashboard access — DB migration

- can_manage_employee() helper function
- get_weekly_approval_summary scoped by supervisor
- get_day_approval_detail auth check added
- Approval RPCs (save/remove override, approve/reopen day) accept managers
- RLS policies for manager write on day_approvals and activity_overrides"
```

---

### Task 2: Middleware — Allow Manager Role

**Files:**
- Modify: `dashboard/src/middleware.ts:82`

- [ ] **Step 1: Update the role check**

In `dashboard/src/middleware.ts`, line 82, change:

```ts
// Before
if (!userRole || !['admin', 'super_admin'].includes(userRole)) {

// After
if (!userRole || !['admin', 'super_admin', 'manager'].includes(userRole)) {
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/middleware.ts
git commit -m "feat: allow manager role to access dashboard"
```

---

### Task 3: Sidebar — Role-Aware Navigation

**Files:**
- Modify: `dashboard/src/components/layout/sidebar.tsx`

- [ ] **Step 1: Add adminOnly flag to navigation items and filter by role**

Update `sidebar.tsx` to:
1. Add an `adminOnly?: boolean` property to navigation items that managers should not see
2. Import `useGetIdentity` from `@refinedev/core`
3. Filter navigation based on role

```tsx
'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useGetIdentity } from '@refinedev/core';
import { LayoutDashboard, Users, MapPin, MapPinned, UserCog, Radio, History, FileBarChart, ClipboardList, Car, ClipboardCheck, UtensilsCrossed, DollarSign, Activity, Receipt } from 'lucide-react';
import { cn } from '@/lib/utils';
import { useMonitoringBadges } from '@/lib/hooks/use-monitoring-badges';
import type { UserIdentity } from '@/types/dashboard';

const navigation = [
  {
    name: 'Vue d\'ensemble',
    href: '/dashboard',
    icon: LayoutDashboard,
  },
  {
    name: 'En direct',
    href: '/dashboard/monitoring',
    icon: Radio,
  },
  {
    name: 'Équipes',
    href: '/dashboard/teams',
    icon: Users,
    adminOnly: true,
  },
  {
    name: 'Employés',
    href: '/dashboard/employees',
    icon: UserCog,
  },
  {
    name: 'Historique',
    href: '/dashboard/history',
    icon: History,
  },
  {
    name: 'Emplacements',
    href: '/dashboard/locations',
    icon: MapPinned,
    adminOnly: true,
  },
  {
    name: 'Sessions de travail',
    href: '/dashboard/work-sessions',
    icon: ClipboardList,
  },
  {
    name: 'Activités',
    href: '/dashboard/activity',
    icon: Car,
  },
  {
    name: 'Approbation',
    href: '/dashboard/approvals',
    icon: ClipboardCheck,
  },
  {
    name: 'Kilométrage',
    href: '/dashboard/mileage-approval',
    icon: Car,
  },
  {
    name: 'Rémunération',
    href: '/dashboard/remuneration',
    icon: DollarSign,
  },
  {
    name: 'Paie',
    href: '/dashboard/remuneration/payroll',
    icon: Receipt,
  },
  {
    name: 'Diagnostics GPS',
    href: '/dashboard/diagnostics',
    icon: Activity,
    adminOnly: true,
  },
  {
    name: 'Rapports',
    href: '/dashboard/reports',
    icon: FileBarChart,
    adminOnly: true,
  },
];
```

In the `Sidebar` component, add role check:

```tsx
export function Sidebar() {
  const pathname = usePathname();
  const badges = useMonitoringBadges();
  const { data: user } = useGetIdentity<UserIdentity>();
  const isAdmin = user?.role === 'admin' || user?.role === 'super_admin';

  const visibleNavigation = navigation.filter(
    (item) => !item.adminOnly || isAdmin
  );

  return (
    // ... same JSX but iterate over visibleNavigation instead of navigation
```

- [ ] **Step 2: Verify build passes**

```bash
cd dashboard && npm run build
```

- [ ] **Step 3: Commit**

```bash
git add dashboard/src/components/layout/sidebar.tsx
git commit -m "feat: role-aware sidebar navigation for managers"
```

---

### Task 4: Manual Verification

- [ ] **Step 1: Assign manager role to a test user**

```sql
UPDATE employee_profiles SET role = 'manager' WHERE email = '<test-user-email>';
```

- [ ] **Step 2: Ensure test user has active supervisions**

```sql
SELECT * FROM employee_supervisors
WHERE manager_id = (SELECT id FROM employee_profiles WHERE email = '<test-user-email>')
  AND effective_to IS NULL;
```

- [ ] **Step 3: Log in as manager and verify**

Verify:
- Dashboard loads (not redirected to login)
- Sidebar shows correct pages (no Equipes, Emplacements, Diagnostics, Rapports)
- Approvals page shows only supervised employees
- Can click into day detail for a supervised employee
- Can save an activity override
- Can approve a day
- Monitoring shows only supervised employees

- [ ] **Step 4: Verify admin still works**

Log back in as admin and verify:
- All pages visible
- All employees visible in approvals
- All actions still work
