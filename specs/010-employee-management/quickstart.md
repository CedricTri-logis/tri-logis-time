# Quickstart: Employee Management

**Feature Branch**: `010-employee-management`
**Date**: 2026-01-15

## Prerequisites

Before starting implementation:

1. **Branch Setup**
   ```bash
   git checkout 010-employee-management
   ```

2. **Dashboard Dependencies**
   ```bash
   cd dashboard
   npm install
   ```

3. **Supabase Running**
   ```bash
   cd ../supabase
   supabase start
   supabase status  # Verify services are running
   ```

4. **Existing Schema**
   - Migration 009 (super_admin_role) applied
   - Migration 010 (dashboard_aggregations) applied

---

## Implementation Order

### Phase 1: Database Layer (Migration 011)

1. **Create audit schema and table**
   ```sql
   -- File: supabase/migrations/011_employee_management.sql
   CREATE SCHEMA IF NOT EXISTS audit;
   CREATE TABLE audit.audit_logs (...);
   ```

2. **Create audit trigger function**
   ```sql
   CREATE FUNCTION audit.log_changes() RETURNS TRIGGER ...
   ```

3. **Attach triggers to tables**
   ```sql
   CREATE TRIGGER audit_employee_profiles ...
   CREATE TRIGGER audit_employee_supervisors ...
   ```

4. **Create supervision auto-end trigger**
   ```sql
   CREATE TRIGGER end_supervision_on_status_change ...
   ```

5. **Create RPC functions in order**:
   - `get_employees_paginated` (list)
   - `get_employee_detail` (single)
   - `update_employee_profile` (edit)
   - `update_employee_status` (status change)
   - `assign_supervisor` (assignment)
   - `remove_supervisor` (unassign)
   - `get_managers_list` (dropdown)
   - `check_employee_active_shift` (validation)
   - `get_employee_audit_log` (audit)

6. **Apply migration**
   ```bash
   supabase db push
   ```

7. **Regenerate types**
   ```bash
   cd ../dashboard
   npx supabase gen types typescript --project-id $PROJECT_ID > src/types/database.ts
   ```

### Phase 2: UI Components

1. **Install shadcn/ui components**
   ```bash
   cd dashboard
   npx shadcn@latest add dialog form input label toast pagination
   ```

2. **Create Zod schemas**
   ```typescript
   // File: src/lib/validations/employee.ts
   export const employeeEditSchema = z.object({...});
   ```

3. **Create employee type definitions**
   ```typescript
   // File: src/types/employee.ts
   export interface EmployeeListItem {...}
   ```

4. **Extend data provider for pagination**
   ```typescript
   // File: src/lib/providers/data-provider.ts
   // Add getList override for RPC pagination
   ```

5. **Build components in order**:
   - `src/components/dashboard/employees/status-badge.tsx`
   - `src/components/dashboard/employees/employee-filters.tsx`
   - `src/components/dashboard/employees/employee-table.tsx`
   - `src/components/dashboard/employees/role-selector.tsx`
   - `src/components/dashboard/employees/supervisor-assignment.tsx`
   - `src/components/dashboard/employees/employee-form.tsx`

### Phase 3: Pages

1. **Employee directory page**
   ```typescript
   // File: src/app/dashboard/employees/page.tsx
   // Uses useTable with get_employees_paginated
   ```

2. **Employee detail/edit page**
   ```typescript
   // File: src/app/dashboard/employees/[id]/page.tsx
   // Uses useOne with get_employee_detail
   // Form with useForm for editing
   ```

3. **Update sidebar navigation**
   ```typescript
   // File: src/components/layout/sidebar.tsx
   // Add Employees link with Users icon
   ```

### Phase 4: Testing

1. **Component tests**
   - Employee table renders correctly
   - Filters update search params
   - Forms validate correctly

2. **E2E tests with Playwright**
   - Admin can view employee directory
   - Admin can search/filter employees
   - Admin can edit employee profile
   - Admin can change employee role
   - Admin can assign supervisor
   - Admin can deactivate employee (with warning)
   - Super_admin protection works

---

## Key Files to Create/Modify

### New Files

| Path | Purpose |
|------|---------|
| `supabase/migrations/011_employee_management.sql` | All DB changes |
| `dashboard/src/app/dashboard/employees/page.tsx` | Directory page |
| `dashboard/src/app/dashboard/employees/[id]/page.tsx` | Detail page |
| `dashboard/src/components/dashboard/employees/*.tsx` | UI components |
| `dashboard/src/lib/validations/employee.ts` | Zod schemas |
| `dashboard/src/types/employee.ts` | TypeScript types |

### Modified Files

| Path | Change |
|------|--------|
| `dashboard/src/lib/providers/data-provider.ts` | Add getList for RPC |
| `dashboard/src/components/layout/sidebar.tsx` | Add nav link |
| `dashboard/src/types/database.ts` | Regenerate types |

---

## Development Tips

### Testing RPC Functions

```sql
-- In Supabase SQL Editor, set user context first
SELECT set_config('request.jwt.claims',
  '{"sub":"admin-user-uuid","role":"authenticated"}', false);

-- Then test functions
SELECT * FROM get_employees_paginated(
  p_search := 'john',
  p_status := 'active'
);
```

### Testing Audit Logging

```sql
-- Update an employee and check audit log
UPDATE employee_profiles
SET full_name = 'Test Name'
WHERE email = 'test@example.com';

SELECT * FROM audit.audit_logs
WHERE table_name = 'employee_profiles'
ORDER BY changed_at DESC
LIMIT 1;
```

### Testing Concurrent Edit Toast

1. Open employee detail in two browser tabs
2. Make edit in Tab 1, save
3. Make edit in Tab 2, save
4. Tab 2 should show toast notification

### Role Testing Matrix

| Caller Role | Can Edit Employee | Can Edit Admin | Can Edit Super_Admin |
|-------------|-------------------|----------------|----------------------|
| admin | ✅ | ✅ | ❌ |
| super_admin | ✅ | ✅ | ✅ |
| manager | ❌ | ❌ | ❌ |
| employee | ❌ | ❌ | ❌ |

---

## Common Issues

### "Access denied" on RPC calls

Check that the logged-in user has admin or super_admin role:
```sql
SELECT role FROM employee_profiles
WHERE id = auth.uid();
```

### Audit trigger not firing

Ensure triggers are attached:
```sql
SELECT * FROM information_schema.triggers
WHERE trigger_name LIKE 'audit%';
```

### Types not updating

Regenerate after migration:
```bash
npx supabase gen types typescript --project-id $PROJECT_ID > src/types/database.ts
```

---

## Success Criteria Validation

| Criteria | How to Verify |
|----------|---------------|
| SC-001: Find employee in 10s | Time search operation |
| SC-002: Edit visible in 2s | Check table refresh after save |
| SC-003: Role change immediate | Logout/login as changed user |
| SC-004: Supervisor in 30s | Check manager dashboard after assignment |
| SC-005: 1000 employees | Load test with seed data |
| SC-006: 95% usability | User testing (no documentation) |
| SC-007: Login blocked in 1min | Deactivate and try login |
| SC-008: Audit retrievable | Query audit.audit_logs |
