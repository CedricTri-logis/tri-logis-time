# Data Model: Employee Management

**Feature Branch**: `010-employee-management`
**Date**: 2026-01-15

## Entity Overview

```
┌─────────────────────┐       ┌────────────────────────┐
│  employee_profiles  │──────<│  employee_supervisors  │
│  (existing)         │       │  (existing)            │
└─────────────────────┘       └────────────────────────┘
         │                              │
         │                              │
         ▼                              ▼
┌─────────────────────┐       ┌────────────────────────┐
│  audit.audit_logs   │       │       shifts           │
│  (NEW)              │       │  (existing - ref only) │
└─────────────────────┘       └────────────────────────┘
```

## Entities

### 1. Employee Profile (existing - extended)

**Table**: `employee_profiles`
**Purpose**: Core user record containing identity, role, and status information.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| id | UUID | PK, FK → auth.users(id) | Links to Supabase Auth user |
| email | TEXT | UNIQUE, NOT NULL | User's email (read-only via admin) |
| full_name | TEXT | | Display name (editable) |
| employee_id | TEXT | UNIQUE when not null | Company employee ID (editable) |
| role | TEXT | NOT NULL, DEFAULT 'employee' | Permission level |
| status | TEXT | NOT NULL, DEFAULT 'active' | Account state |
| privacy_consent_at | TIMESTAMPTZ | | Privacy policy acceptance |
| created_at | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Account creation |
| updated_at | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Last modification |

**Role Values**: `employee`, `manager`, `admin`, `super_admin`
**Status Values**: `active`, `inactive`, `suspended`

**Validation Rules**:
- `full_name`: Max 100 characters
- `employee_id`: Max 50 characters, alphanumeric + dashes
- `role`: Only super_admin can assign super_admin role
- `status`: Cannot deactivate self; at least one admin must remain active

**State Transitions**:
```
active ──────► inactive    (permanent departure)
active ──────► suspended   (temporary hold)
inactive ────► active      (reactivation)
suspended ───► active      (reactivation)
suspended ───► inactive    (permanent departure)
```

---

### 2. Supervisor Assignment (existing - no changes)

**Table**: `employee_supervisors`
**Purpose**: Tracks manager-employee relationships with effective dates.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| id | UUID | PK, DEFAULT gen_random_uuid() | Assignment ID |
| manager_id | UUID | FK → employee_profiles(id), NOT NULL | The supervising manager |
| employee_id | UUID | FK → employee_profiles(id), NOT NULL | The supervised employee |
| supervision_type | TEXT | NOT NULL, DEFAULT 'direct' | Relationship type |
| effective_from | DATE | NOT NULL, DEFAULT CURRENT_DATE | Start of supervision |
| effective_to | DATE | | End of supervision (NULL = active) |
| created_at | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Record creation |

**Constraints**:
- `no_self_supervision`: manager_id != employee_id
- `valid_date_range`: effective_to IS NULL OR effective_to > effective_from
- `unique_active_supervision`: UNIQUE(manager_id, employee_id, effective_from)

**Supervision Types**: `direct`, `matrix`, `temporary`

**Business Rules**:
- Only one active supervision per employee-manager pair
- When employee is deactivated/suspended, active assignments auto-end
- Reassignment creates new record; does not update existing

---

### 3. Audit Log (NEW)

**Table**: `audit.audit_logs`
**Purpose**: Immutable record of all changes to audited tables for compliance (FR-019).

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| id | UUID | PK, DEFAULT gen_random_uuid() | Log entry ID |
| table_name | TEXT | NOT NULL | Source table name |
| table_schema | TEXT | NOT NULL, DEFAULT 'public' | Source schema |
| operation | TEXT | NOT NULL | INSERT, UPDATE, DELETE |
| record_id | UUID | NOT NULL | PK of affected record |
| user_id | UUID | | auth.uid() of person making change |
| email | TEXT | | Email for reference (even if user deleted) |
| changed_at | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() | Timestamp of change |
| old_values | JSONB | | Previous state (NULL for INSERT) |
| new_values | JSONB | | New state (NULL for DELETE) |
| ip_address | INET | | Client IP (optional) |
| change_reason | TEXT | | Admin-provided reason (optional) |

**Constraints**:
- `audit_logs_operation_check`: operation IN ('INSERT', 'UPDATE', 'DELETE')

**Indexes**:
- `idx_audit_logs_table_name`: B-tree on table_name
- `idx_audit_logs_user_id`: B-tree on user_id
- `idx_audit_logs_record_id`: B-tree on record_id
- `idx_audit_logs_changed_at`: B-tree DESC on changed_at
- `idx_audit_logs_table_record`: B-tree on (table_name, record_id)
- `idx_audit_logs_new_values`: GIN on new_values for JSONB queries

**Notes**:
- Append-only table (no updates/deletes via application)
- JSONB stores complete row state for historical reconstruction
- Triggers attached to employee_profiles and employee_supervisors

---

## Relationships

### Employee → Supervisor Assignments
```sql
-- Employee can have multiple supervision records (historical + current)
SELECT * FROM employee_supervisors
WHERE employee_id = :employee_id
ORDER BY effective_from DESC;

-- Current supervisor only
SELECT * FROM employee_supervisors
WHERE employee_id = :employee_id
  AND effective_to IS NULL;
```

### Manager → Supervised Employees
```sql
-- All actively supervised employees
SELECT ep.* FROM employee_profiles ep
JOIN employee_supervisors es ON es.employee_id = ep.id
WHERE es.manager_id = :manager_id
  AND es.effective_to IS NULL;
```

### Employee → Audit History
```sql
-- All changes to an employee profile
SELECT * FROM audit.audit_logs
WHERE table_name = 'employee_profiles'
  AND record_id = :employee_id
ORDER BY changed_at DESC;
```

---

## TypeScript Interfaces

```typescript
// Employee Profile
interface EmployeeProfile {
  id: string;
  email: string;
  full_name: string | null;
  employee_id: string | null;
  role: 'employee' | 'manager' | 'admin' | 'super_admin';
  status: 'active' | 'inactive' | 'suspended';
  privacy_consent_at: string | null;
  created_at: string;
  updated_at: string;
}

// For directory listing (subset of fields + computed)
interface EmployeeListItem {
  id: string;
  email: string;
  full_name: string | null;
  employee_id: string | null;
  role: EmployeeProfile['role'];
  status: EmployeeProfile['status'];
  created_at: string;
  current_supervisor?: {
    id: string;
    full_name: string;
    email: string;
  };
}

// Supervisor Assignment
interface SupervisorAssignment {
  id: string;
  manager_id: string;
  employee_id: string;
  supervision_type: 'direct' | 'matrix' | 'temporary';
  effective_from: string;
  effective_to: string | null;
  created_at: string;
  // Joined fields
  manager_name?: string;
  manager_email?: string;
}

// Audit Log Entry
interface AuditLogEntry {
  id: string;
  table_name: string;
  operation: 'INSERT' | 'UPDATE' | 'DELETE';
  record_id: string;
  user_id: string | null;
  email: string | null;
  changed_at: string;
  old_values: Record<string, any> | null;
  new_values: Record<string, any> | null;
  change_reason: string | null;
}

// Form schemas (Zod)
import { z } from 'zod';

export const employeeEditSchema = z.object({
  full_name: z.string().max(100).nullable(),
  employee_id: z.string()
    .max(50)
    .regex(/^[a-zA-Z0-9-]*$/, 'Only letters, numbers, and dashes allowed')
    .nullable(),
});

export const roleChangeSchema = z.object({
  role: z.enum(['employee', 'manager', 'admin', 'super_admin']),
});

export const statusChangeSchema = z.object({
  status: z.enum(['active', 'inactive', 'suspended']),
});

export const supervisorAssignmentSchema = z.object({
  manager_id: z.string().uuid(),
  supervision_type: z.enum(['direct', 'matrix', 'temporary']).default('direct'),
});
```

---

## Database Triggers

### Auto-Update Timestamp
```sql
-- Already exists from migration 001
CREATE TRIGGER set_updated_at
  BEFORE UPDATE ON employee_profiles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
```

### Audit Logging Trigger
```sql
-- NEW: Captures all changes to employee_profiles
CREATE TRIGGER audit_employee_profiles
  AFTER INSERT OR UPDATE OR DELETE ON employee_profiles
  FOR EACH ROW EXECUTE FUNCTION audit.log_changes();

-- NEW: Captures all changes to employee_supervisors
CREATE TRIGGER audit_employee_supervisors
  AFTER INSERT OR UPDATE OR DELETE ON employee_supervisors
  FOR EACH ROW EXECUTE FUNCTION audit.log_changes();
```

### Auto-End Supervision on Deactivation
```sql
-- NEW: When employee status changes to inactive/suspended
CREATE TRIGGER end_supervision_on_status_change
  AFTER UPDATE OF status ON employee_profiles
  FOR EACH ROW
  WHEN (NEW.status IN ('inactive', 'suspended') AND OLD.status = 'active')
  EXECUTE FUNCTION end_active_supervisions();
```

### Super Admin Protection
```sql
-- Already exists from migration 009
CREATE TRIGGER protect_super_admin_trigger
  BEFORE UPDATE OR DELETE ON employee_profiles
  FOR EACH ROW EXECUTE FUNCTION protect_super_admin();
```

---

## RLS Policies Summary

### employee_profiles (existing, sufficient)

| Policy | Operation | Effect |
|--------|-----------|--------|
| View own profile | SELECT | auth.uid() = id |
| View as admin | SELECT | Caller role IN (admin, super_admin) |
| View supervised | SELECT | Caller is manager with active supervision |
| Update own | UPDATE | auth.uid() = id |
| Update as admin | UPDATE | Caller is admin; target is not super_admin |
| Super_admin protection | UPDATE | Only super_admin can modify super_admin |

### employee_supervisors (existing, sufficient)

| Policy | Operation | Effect |
|--------|-----------|--------|
| View own assignments | SELECT | auth.uid() = employee_id OR manager_id |
| View as admin | SELECT | Caller role IN (admin, super_admin) |
| Insert as admin | INSERT | Caller role IN (admin, super_admin) |
| Update as admin | UPDATE | Caller role IN (admin, super_admin) |

### audit.audit_logs (NEW)

| Policy | Operation | Effect |
|--------|-----------|--------|
| View as admin | SELECT | Caller role IN (admin, super_admin) |
| No direct writes | INSERT/UPDATE/DELETE | Only via trigger (SECURITY DEFINER) |
