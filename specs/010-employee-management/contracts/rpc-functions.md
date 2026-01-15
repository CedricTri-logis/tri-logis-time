# RPC Function Contracts: Employee Management

**Feature Branch**: `010-employee-management`
**Date**: 2026-01-15

## Overview

This document defines the Supabase RPC functions required for the Employee Management feature. All functions follow the existing patterns established in migrations 009 and 010.

---

## 1. get_employees_paginated

**Purpose**: Retrieve paginated employee list with search and filter capabilities (FR-001 through FR-005).

**Authorization**: Admin or Super Admin only

### Signature

```sql
CREATE FUNCTION get_employees_paginated(
  p_search TEXT DEFAULT NULL,
  p_role TEXT DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_sort_field TEXT DEFAULT 'full_name',
  p_sort_order TEXT DEFAULT 'ASC',
  p_limit INT DEFAULT 50,
  p_offset INT DEFAULT 0
) RETURNS TABLE (
  id UUID,
  email TEXT,
  full_name TEXT,
  employee_id TEXT,
  role TEXT,
  status TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  current_supervisor_id UUID,
  current_supervisor_name TEXT,
  current_supervisor_email TEXT,
  total_count BIGINT
)
```

### Parameters

| Name | Type | Default | Description |
|------|------|---------|-------------|
| p_search | TEXT | NULL | Partial match on full_name or email (ILIKE) |
| p_role | TEXT | NULL | Filter by role (employee/manager/admin/super_admin) |
| p_status | TEXT | NULL | Filter by status (active/inactive/suspended) |
| p_sort_field | TEXT | 'full_name' | Column to sort by |
| p_sort_order | TEXT | 'ASC' | Sort direction (ASC/DESC) |
| p_limit | INT | 50 | Page size |
| p_offset | INT | 0 | Records to skip |

### Response

Returns employee records with current supervisor info and total count for pagination.

### Example

```typescript
const { data } = await supabase.rpc('get_employees_paginated', {
  p_search: 'john',
  p_status: 'active',
  p_limit: 50,
  p_offset: 0
});
```

---

## 2. get_employee_detail

**Purpose**: Retrieve single employee with full details including supervision history.

**Authorization**: Admin or Super Admin only

### Signature

```sql
CREATE FUNCTION get_employee_detail(
  p_employee_id UUID
) RETURNS TABLE (
  id UUID,
  email TEXT,
  full_name TEXT,
  employee_id TEXT,
  role TEXT,
  status TEXT,
  privacy_consent_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  current_supervisor JSONB,
  supervision_history JSONB,
  has_active_shift BOOLEAN
)
```

### Parameters

| Name | Type | Description |
|------|------|-------------|
| p_employee_id | UUID | Employee to retrieve |

### Response Fields

| Field | Type | Description |
|-------|------|-------------|
| current_supervisor | JSONB | `{id, full_name, email}` or null |
| supervision_history | JSONB | Array of `{manager_id, manager_name, effective_from, effective_to}` |
| has_active_shift | BOOLEAN | True if employee currently clocked in |

---

## 3. update_employee_profile

**Purpose**: Update employee name and employee_id fields (FR-006, FR-007).

**Authorization**: Admin or Super Admin only; cannot modify super_admin unless caller is super_admin.

### Signature

```sql
CREATE FUNCTION update_employee_profile(
  p_employee_id UUID,
  p_full_name TEXT DEFAULT NULL,
  p_employee_id_value TEXT DEFAULT NULL
) RETURNS JSONB
```

### Parameters

| Name | Type | Description |
|------|------|-------------|
| p_employee_id | UUID | Employee to update |
| p_full_name | TEXT | New full name (NULL = no change) |
| p_employee_id_value | TEXT | New employee ID (NULL = no change) |

### Response

```json
{
  "success": true,
  "employee": { /* updated employee object */ }
}
```

### Errors

| Code | Message |
|------|---------|
| ACCESS_DENIED | Only admins can update employee profiles |
| PROTECTED_USER | Cannot modify super_admin account |
| DUPLICATE_EMPLOYEE_ID | Employee ID already in use |
| NOT_FOUND | Employee not found |

---

## 4. update_employee_role

**Purpose**: Change employee role (FR-008, FR-009, FR-010). Extends existing `update_user_role`.

**Authorization**: Admin or Super Admin; super_admin assignment requires super_admin caller.

### Signature

```sql
-- Already exists from migration 009, no changes needed
CREATE FUNCTION update_user_role(
  p_user_id UUID,
  p_new_role TEXT
) RETURNS BOOLEAN
```

### Business Rules (already implemented)

- Cannot modify super_admin role
- Only super_admin can assign super_admin role
- Cannot change own role (unless super_admin)

---

## 5. update_employee_status

**Purpose**: Change employee status (FR-014 through FR-018).

**Authorization**: Admin or Super Admin only.

### Signature

```sql
CREATE FUNCTION update_employee_status(
  p_employee_id UUID,
  p_new_status TEXT,
  p_force BOOLEAN DEFAULT FALSE
) RETURNS JSONB
```

### Parameters

| Name | Type | Description |
|------|------|-------------|
| p_employee_id | UUID | Employee to update |
| p_new_status | TEXT | New status (active/inactive/suspended) |
| p_force | BOOLEAN | Proceed despite warnings (active shift) |

### Response

```json
{
  "success": true,
  "warning": "Employee has active shift",
  "requires_confirmation": true,
  "employee": { /* updated employee object */ }
}
```

### Errors

| Code | Message |
|------|---------|
| SELF_DEACTIVATION | Cannot deactivate yourself |
| LAST_ADMIN | Cannot deactivate last admin |
| PROTECTED_USER | Cannot deactivate super_admin |
| INVALID_STATUS | Invalid status value |
| ACTIVE_SHIFT_WARNING | Employee has active shift (use p_force=true to proceed) |

---

## 6. assign_supervisor

**Purpose**: Create or update supervisor assignment (FR-011, FR-012).

**Authorization**: Admin or Super Admin only.

### Signature

```sql
CREATE FUNCTION assign_supervisor(
  p_employee_id UUID,
  p_manager_id UUID,
  p_supervision_type TEXT DEFAULT 'direct'
) RETURNS JSONB
```

### Parameters

| Name | Type | Default | Description |
|------|------|---------|-------------|
| p_employee_id | UUID | | Employee to assign |
| p_manager_id | UUID | | Manager to assign to |
| p_supervision_type | TEXT | 'direct' | Type: direct/matrix/temporary |

### Response

```json
{
  "success": true,
  "assignment": {
    "id": "uuid",
    "manager_id": "uuid",
    "employee_id": "uuid",
    "effective_from": "2026-01-15",
    "supervision_type": "direct"
  },
  "previous_assignment_ended": true
}
```

### Business Rules

- Ends any current assignment (sets effective_to = today)
- Creates new assignment with effective_from = today
- Cannot assign manager to themselves
- Manager must have role = 'manager', 'admin', or 'super_admin'

---

## 7. remove_supervisor

**Purpose**: End current supervisor assignment.

**Authorization**: Admin or Super Admin only.

### Signature

```sql
CREATE FUNCTION remove_supervisor(
  p_employee_id UUID
) RETURNS JSONB
```

### Response

```json
{
  "success": true,
  "ended_assignment": { /* assignment that was ended */ }
}
```

---

## 8. get_managers_list

**Purpose**: Get list of users eligible to be supervisors (for assignment dropdown).

**Authorization**: Admin or Super Admin only.

### Signature

```sql
CREATE FUNCTION get_managers_list()
RETURNS TABLE (
  id UUID,
  email TEXT,
  full_name TEXT,
  role TEXT,
  supervised_count BIGINT
)
```

### Response

Returns all users with role in ('manager', 'admin', 'super_admin') who are active, along with their current supervised employee count.

---

## 9. check_employee_active_shift

**Purpose**: Check if employee has active shift (for deactivation warning).

**Authorization**: Admin or Super Admin only.

### Signature

```sql
CREATE FUNCTION check_employee_active_shift(
  p_employee_id UUID
) RETURNS BOOLEAN
```

---

## 10. get_employee_audit_log

**Purpose**: Retrieve audit history for an employee (FR-019, SC-008).

**Authorization**: Admin or Super Admin only.

### Signature

```sql
CREATE FUNCTION get_employee_audit_log(
  p_employee_id UUID,
  p_limit INT DEFAULT 50,
  p_offset INT DEFAULT 0
) RETURNS TABLE (
  id UUID,
  operation TEXT,
  user_id UUID,
  user_email TEXT,
  changed_at TIMESTAMPTZ,
  old_values JSONB,
  new_values JSONB,
  change_reason TEXT,
  total_count BIGINT
)
```

### Response

Returns audit log entries for the employee in reverse chronological order.

---

## 11. check_last_admin

**Purpose**: Verify at least one admin remains after proposed change.

**Authorization**: Internal use (called by other functions).

### Signature

```sql
CREATE FUNCTION check_last_admin(
  p_exclude_user_id UUID
) RETURNS BOOLEAN
```

### Returns

`TRUE` if at least one admin/super_admin would remain active after excluding the given user.

---

## Error Response Format

All functions return errors in a consistent format:

```json
{
  "success": false,
  "error": {
    "code": "ERROR_CODE",
    "message": "Human-readable error message"
  }
}
```

Or raise exceptions for RPC-level errors:

```sql
RAISE EXCEPTION 'Error message'
  USING ERRCODE = 'error_code';
```

---

## TypeScript Types for Frontend

```typescript
// Request/Response types for RPC calls
interface GetEmployeesPaginatedParams {
  p_search?: string;
  p_role?: 'employee' | 'manager' | 'admin' | 'super_admin';
  p_status?: 'active' | 'inactive' | 'suspended';
  p_sort_field?: string;
  p_sort_order?: 'ASC' | 'DESC';
  p_limit?: number;
  p_offset?: number;
}

interface EmployeeListResponse {
  id: string;
  email: string;
  full_name: string | null;
  employee_id: string | null;
  role: string;
  status: string;
  created_at: string;
  updated_at: string;
  current_supervisor_id: string | null;
  current_supervisor_name: string | null;
  current_supervisor_email: string | null;
  total_count: number;
}

interface UpdateEmployeeProfileParams {
  p_employee_id: string;
  p_full_name?: string;
  p_employee_id_value?: string;
}

interface UpdateEmployeeStatusParams {
  p_employee_id: string;
  p_new_status: 'active' | 'inactive' | 'suspended';
  p_force?: boolean;
}

interface AssignSupervisorParams {
  p_employee_id: string;
  p_manager_id: string;
  p_supervision_type?: 'direct' | 'matrix' | 'temporary';
}
```
