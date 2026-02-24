# Research: Employee Management

**Feature Branch**: `010-employee-management`
**Research Date**: 2026-01-15
**Status**: Complete

## Research Topics

### 1. Refine Data Hooks for Large Datasets

**Decision**: Use extended `dataProvider.getList` with RPC support for server-side pagination

**Rationale**: The existing data provider already supports RPC calls via `meta.rpc`. Extending `getList` to support pagination parameters allows using `useTable` hook with full server-side pagination, sorting, and filtering.

**Alternatives Considered**:
- `useCustom` with manual pagination state: Rejected - more code, less reusable
- Direct Supabase queries without Refine: Rejected - loses query caching and refetch logic
- Client-side pagination: Rejected - fails at 1000+ employees (SC-005 requirement)

**Implementation Pattern**:
```typescript
// Extend dataProvider.getList to handle RPC pagination
getList: async ({ resource, pagination, filters, sorters, meta }) => {
  if (meta?.rpc) {
    const { current = 1, pageSize = 50 } = pagination ?? {};
    const { data, count } = await supabaseClient.rpc(meta.rpc, {
      p_limit: pageSize,
      p_offset: (current - 1) * pageSize,
      ...filterParams,
      ...sortParams,
    });
    return { data, total: count ?? 0 };
  }
  return baseDataProvider.getList(...);
};
```

---

### 2. Server-Side Search and Filtering

**Decision**: Use ILIKE pattern matching for search, enum parameters for filters

**Rationale**: PostgreSQL ILIKE provides case-insensitive partial matching. For 1000 employees, database-level filtering is essential for performance (SC-001: search within 10 seconds).

**Alternatives Considered**:
- Full-text search (tsvector): Rejected - overkill for simple name/email search
- Client-side filtering: Rejected - requires loading all data first
- Supabase filters via SDK: Rejected - cannot combine complex conditions in RPC

**Implementation Pattern**:
```sql
-- RPC function with combined search/filter
CREATE FUNCTION get_employees_paginated(
  p_search TEXT DEFAULT NULL,
  p_role TEXT DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_limit INT DEFAULT 50,
  p_offset INT DEFAULT 0
) RETURNS TABLE (...) AS $$
  SELECT * FROM employee_profiles
  WHERE (p_search IS NULL OR
         full_name ILIKE '%' || p_search || '%' OR
         email ILIKE '%' || p_search || '%')
    AND (p_role IS NULL OR role = p_role)
    AND (p_status IS NULL OR status = p_status)
  ORDER BY full_name
  LIMIT p_limit OFFSET p_offset;
$$
```

---

### 3. Audit Logging Implementation

**Decision**: Use database trigger-based logging with JSONB storage in `audit.audit_logs` table

**Rationale**:
- Trigger-based ensures ALL changes are captured (FR-019)
- JSONB allows flexible schema as employee_profiles evolves
- Single generic trigger works for all audited tables
- Matches industry best practices for compliance

**Alternatives Considered**:
- Application-level logging: Rejected - can be bypassed, harder to maintain
- Separate audit table per source table: Rejected - more maintenance, less flexibility
- Only store changed fields: Rejected - harder to reconstruct historical state
- Supabase supa_audit extension: Considered - but custom solution gives more control

**Implementation Pattern**:
```sql
CREATE SCHEMA IF NOT EXISTS audit;

CREATE TABLE audit.audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    table_name TEXT NOT NULL,
    operation TEXT NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    record_id UUID NOT NULL,
    user_id UUID,
    email TEXT,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    old_values JSONB,
    new_values JSONB
);

CREATE FUNCTION audit.log_changes() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO audit.audit_logs (...)
    VALUES (TG_TABLE_NAME, TG_OP, ..., row_to_json(OLD), row_to_json(NEW));
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

---

### 4. shadcn/ui Components for Employee Management

**Decision**: Use existing shadcn/ui Table, Dialog, Form, Input components; add new Form primitives

**Rationale**: Constitution mandates shadcn/ui (Principle II). Existing components cover most needs; missing Form/Input components need to be installed.

**Required New Components**:
- `Dialog` - confirmation modals (deactivation warning)
- `Form` - react-hook-form integration with Zod
- `Input` - text input for employee name/ID
- `Label` - form labels
- `Toast` / `Toaster` - notifications for concurrent edits (per spec clarification)
- `Pagination` - employee list pagination UI

**Already Available**:
- `Table`, `TableHeader`, `TableBody`, `TableRow`, `TableCell`
- `Button`, `Badge`, `Card`, `Select`, `DropdownMenu`, `Skeleton`

---

### 5. Concurrent Edit Conflict Handling

**Decision**: Last-write-wins with toast notification prompting refresh

**Rationale**: Per spec clarification session (2026-01-15), the earlier editor sees a toast notification on their next action prompting them to refresh.

**Alternatives Considered**:
- Optimistic locking (version field): Rejected - more complex, spec chose simpler approach
- Merge conflicts UI: Rejected - overkill for this use case
- Real-time Supabase subscriptions: Considered but not required by spec

**Implementation Pattern**:
```typescript
// On save, check if updated_at has changed since last fetch
const handleSave = async (data) => {
  const result = await saveEmployee(data);
  if (result.error?.code === 'CONCURRENT_EDIT') {
    toast({
      title: 'Employee was modified',
      description: 'This employee was modified by another user. Please refresh to see current data.',
      action: <Button onClick={refetch}>Refresh</Button>,
    });
  }
};
```

---

### 6. Role Assignment Security

**Decision**: Enforce role restrictions at both RPC and UI levels

**Rationale**:
- FR-009: super_admin assignment restricted to super_admin users
- FR-010: super_admin accounts protected from non-super_admin modification
- Existing `update_user_role` RPC already enforces these rules

**Implementation Pattern**:
```typescript
// UI hides super_admin option for non-super_admin users
const roleOptions = useMemo(() => {
  const base = ['employee', 'manager', 'admin'];
  if (currentUser.role === 'super_admin') {
    base.push('super_admin');
  }
  return base;
}, [currentUser.role]);

// Super_admin users show as read-only for regular admins
const isEditable = targetUser.role !== 'super_admin' ||
                   currentUser.role === 'super_admin';
```

---

### 7. Status Management with Active Shift Warning

**Decision**: Check for active shifts before deactivation, show confirmation dialog

**Rationale**: FR-016 requires warning when deactivating employee with active shift. Per spec, admin can choose to proceed or cancel.

**Implementation Pattern**:
```typescript
// Pre-deactivation check
const handleStatusChange = async (newStatus) => {
  if (newStatus === 'inactive' || newStatus === 'suspended') {
    const hasActiveShift = await checkActiveShift(employeeId);
    if (hasActiveShift) {
      setShowDeactivationWarning(true);
      return;
    }
  }
  await updateStatus(newStatus);
};

// Dialog with proceed/cancel
<Dialog open={showDeactivationWarning}>
  <DialogContent>
    <DialogTitle>Active Shift Warning</DialogTitle>
    <DialogDescription>
      This employee has an active shift that will remain open.
    </DialogDescription>
    <DialogFooter>
      <Button variant="outline" onClick={() => setShowDeactivationWarning(false)}>
        Cancel
      </Button>
      <Button variant="destructive" onClick={confirmDeactivation}>
        Deactivate Anyway
      </Button>
    </DialogFooter>
  </DialogContent>
</Dialog>
```

---

### 8. Supervisor Assignment Management

**Decision**: Use existing `employee_supervisors` table with end_date tracking

**Rationale**: Table already exists from Spec 006. FR-014a requires auto-ending assignments when employee deactivated.

**Implementation Pattern**:
```sql
-- Auto-end supervision when employee deactivated/suspended
CREATE FUNCTION end_supervision_on_deactivate()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status IN ('inactive', 'suspended') AND OLD.status = 'active' THEN
    UPDATE employee_supervisors
    SET effective_to = CURRENT_DATE
    WHERE employee_id = NEW.id AND effective_to IS NULL;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

---

### 9. Empty State and No Results Handling

**Decision**: Display filter-aware empty state with "Clear filters" action

**Rationale**: FR-005a specifies showing current filter criteria and a "Clear filters" button when no employees match.

**Implementation Pattern**:
```typescript
const EmptyState = ({ filters, onClearFilters }) => (
  <div className="text-center py-12">
    <Users className="mx-auto h-12 w-12 text-muted-foreground" />
    <h3 className="mt-4 text-lg font-semibold">No employees found</h3>
    {hasActiveFilters(filters) && (
      <>
        <p className="text-muted-foreground">
          No employees match: {formatFilters(filters)}
        </p>
        <Button variant="outline" onClick={onClearFilters} className="mt-4">
          Clear filters
        </Button>
      </>
    )}
  </div>
);
```

---

## Summary of Decisions

| Topic | Decision | Key Rationale |
|-------|----------|---------------|
| Data fetching | Extended dataProvider with RPC pagination | Reuses existing pattern, enables useTable |
| Search/filter | Server-side ILIKE + enum params | Required for 1000+ employees (SC-005) |
| Audit logging | Trigger-based with JSONB | Compliance (FR-019), schema flexibility |
| UI components | shadcn/ui with new Form primitives | Constitution mandate |
| Concurrent edits | Last-write-wins + toast | Per spec clarification |
| Role security | RPC + UI dual enforcement | Existing update_user_role handles it |
| Status changes | Pre-check active shifts | FR-016 requirement |
| Supervision | Auto-end on deactivation | FR-014a requirement |
| Empty states | Filter-aware with clear action | FR-005a requirement |

## Dependencies Identified

**New shadcn/ui components to install**:
- `dialog`, `form`, `input`, `label`, `toast`, `pagination`

**New RPC functions needed**:
- `get_employees_paginated` - directory listing with search/filter/pagination
- `update_employee_profile` - edit name, employee ID
- `get_employee_supervision_history` - historical assignments
- `assign_supervisor` - create/update supervision
- `check_active_shift` - pre-deactivation check
- `get_employee_audit_log` - fetch audit history for employee

**Database migrations**:
- `audit.audit_logs` table and triggers
- Trigger for auto-ending supervision on deactivation
