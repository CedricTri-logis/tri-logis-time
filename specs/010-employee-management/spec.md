# Feature Specification: Employee Management

**Feature Branch**: `010-employee-management`
**Created**: 2026-01-15
**Status**: Draft
**Input**: User description: "Spec 010: Employee Management"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Admin Views Employee Directory (Priority: P1)

An administrator needs to view all employees in the organization to understand the workforce composition, locate specific employees, and identify their current status and role assignments. They access an employee directory that shows a comprehensive list of all employees with key information at a glance.

**Why this priority**: Before administrators can manage employees (edit, assign, deactivate), they must be able to find and view them. The employee directory is the foundation for all other employee management tasks.

**Independent Test**: Can be fully tested by logging in as an admin/super_admin, accessing the employee management section, and verifying a paginated list of employees displays with their name, email, role, status, and employee ID.

**Acceptance Scenarios**:

1. **Given** an admin is logged in, **When** they navigate to employee management, **Then** they see a list of all employees sorted by name with their email, role, status, and employee ID visible.
2. **Given** an admin is viewing the employee directory, **When** they search by name or email, **Then** the list filters to show only matching employees.
3. **Given** an admin is viewing the employee directory, **When** they filter by role or status, **Then** the list updates to show only employees matching the selected criteria.
4. **Given** an organization has more than 50 employees, **When** an admin views the directory, **Then** the list is paginated and loads progressively without performance degradation.

---

### User Story 2 - Admin Edits Employee Details (Priority: P1)

An administrator needs to update an employee's profile information when changes occur (name corrections, employee ID updates, status changes). They select an employee from the directory and modify their details through an edit form.

**Why this priority**: Keeping employee information accurate is essential for payroll, reporting, and organizational management. This is a fundamental HR function that administrators must perform regularly.

**Independent Test**: Can be tested by selecting an employee, modifying their full name and employee ID, saving changes, and verifying the updates persist in the directory and database.

**Acceptance Scenarios**:

1. **Given** an admin selects an employee from the directory, **When** they click edit, **Then** they see a form pre-populated with the employee's current information.
2. **Given** an admin is editing an employee, **When** they update the full name and save, **Then** the change is persisted and reflected immediately in the directory.
3. **Given** an admin is editing an employee, **When** they change the employee ID to a value already in use, **Then** they see an error message and the duplicate is rejected.
4. **Given** an admin edits a super_admin user, **When** they attempt to change protected fields (like role), **Then** the action is blocked with a clear explanation.

---

### User Story 3 - Admin Manages Employee Roles (Priority: P1)

An administrator needs to assign or change employee roles (employee, manager, admin) to reflect organizational changes such as promotions, team restructuring, or access adjustments. They select an employee and update their role through a dedicated interface.

**Why this priority**: Role assignment directly affects what actions users can perform and what data they can access. This is a critical security and organizational function that enables proper access control.

**Independent Test**: Can be tested by selecting an employee, changing their role from employee to manager, and verifying the new role is applied and the employee gains manager-level access.

**Acceptance Scenarios**:

1. **Given** an admin views an employee's details, **When** they select a different role from the role dropdown, **Then** the role change is saved and takes effect immediately.
2. **Given** a regular admin is managing roles, **When** they attempt to assign the super_admin role, **Then** the option is either hidden or disabled with explanation that only super_admins can assign this role.
3. **Given** an admin changes an employee's role to manager, **When** the change is saved, **Then** the employee can access manager features (team dashboard, supervised employee list).
4. **Given** a role change is made, **When** the employee next accesses the system, **Then** their navigation and permissions reflect their new role.

---

### User Story 4 - Admin Manages Supervisor Assignments (Priority: P2)

An administrator needs to assign employees to managers to establish reporting relationships. This determines which managers can view which employees' shifts and GPS data. They select an employee and assign or reassign them to a manager.

**Why this priority**: Supervisor relationships enable proper data visibility and reporting hierarchy. While employees can clock in without assignments, managers need assignments to view their team's data.

**Independent Test**: Can be tested by selecting an unassigned employee, assigning them to a manager, and verifying the manager can now see that employee in their team dashboard.

**Acceptance Scenarios**:

1. **Given** an admin views an employee's details, **When** they access the supervisor assignment section, **Then** they see the current supervisor (if any) and can select a different manager.
2. **Given** an admin assigns an employee to a manager, **When** the assignment is saved, **Then** the manager immediately sees the employee in their supervised employee list.
3. **Given** an employee is already assigned to a manager, **When** an admin reassigns them to a different manager, **Then** the old assignment ends and the new assignment begins (no gap in supervision).
4. **Given** an admin views an employee with supervision history, **When** they expand the history section, **Then** they see previous supervisor assignments with effective dates.

---

### User Story 5 - Admin Deactivates Employee Accounts (Priority: P2)

An administrator needs to deactivate employee accounts when employees leave the organization or need temporary access suspension. Deactivation prevents login while preserving historical data (shifts, GPS points) for reporting and compliance.

**Why this priority**: Proper offboarding is essential for security and data integrity. Deactivation rather than deletion preserves audit trails and historical records required for payroll and legal compliance.

**Independent Test**: Can be tested by selecting an active employee, changing their status to inactive, and verifying they can no longer log in while their historical shift data remains accessible to administrators.

**Acceptance Scenarios**:

1. **Given** an admin views an active employee, **When** they change the status to inactive, **Then** the employee cannot log in to the mobile app.
2. **Given** an employee has been deactivated, **When** an admin searches the directory, **Then** the deactivated employee appears with clear visual indication of their inactive status.
3. **Given** an employee has been deactivated, **When** an admin views reports, **Then** the employee's historical shift and GPS data remains accessible.
4. **Given** an admin deactivates an employee with an active shift, **When** they confirm deactivation, **Then** they receive a warning that the active shift will remain open and can choose to proceed or cancel.

---

### User Story 6 - Admin Reactivates Employee Accounts (Priority: P3)

An administrator needs to reactivate previously deactivated employee accounts when employees return (seasonal workers, leave of absence ends) or when deactivation was done in error. Reactivation restores login access while maintaining continuous data history.

**Why this priority**: Reactivation supports common workforce scenarios (seasonal employees, return from leave) without requiring new account creation. This is less frequent than deactivation but necessary for workforce flexibility.

**Independent Test**: Can be tested by selecting an inactive employee, changing their status to active, and verifying they can log in and see their historical data.

**Acceptance Scenarios**:

1. **Given** an admin views an inactive employee, **When** they change the status to active, **Then** the employee can immediately log in to the mobile app.
2. **Given** an employee is reactivated, **When** they log in, **Then** they see their historical shift data and can clock in as normal.
3. **Given** an admin filters the directory by inactive status, **When** they find and reactivate an employee, **Then** the employee moves to the active list.
4. **Given** an employee is reactivated, **When** the admin views their profile, **Then** they see no current supervisor assigned and must manually assign one if needed.

---

### Edge Cases

- What happens when an admin tries to deactivate themselves? The system prevents self-deactivation with a clear error message.
- How does the system handle deactivating the last admin? The system prevents this action, requiring at least one admin or super_admin to remain active.
- What happens when searching for an employee with special characters in their name? The search handles unicode and special characters correctly.
- How does the system handle concurrent edits to the same employee? The most recent save wins (last-write-wins), and the earlier editor sees a toast notification on their next action prompting them to refresh to see current data.
- What happens when assigning an employee to a manager who is subsequently demoted? Existing assignments persist until explicitly changed; the system does not auto-cascade role demotions.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST provide an employee directory accessible only to admin and super_admin users.
- **FR-002**: System MUST display employee list with name, email, role, status, employee ID, and creation date.
- **FR-003**: System MUST support searching employees by name or email with partial matching.
- **FR-004**: System MUST support filtering employees by role (employee, manager, admin, super_admin) and status (active, inactive, suspended).
- **FR-005**: System MUST paginate the employee list to handle organizations with 1000+ employees.
- **FR-005a**: System MUST display an empty state message with current filter criteria and a "Clear filters" button when no employees match the search/filter.
- **FR-006**: System MUST allow admins to edit employee profile fields (full name, employee ID).
- **FR-007**: System MUST enforce unique employee ID constraint when editing.
- **FR-008**: System MUST allow admins to change employee roles (employee, manager, admin).
- **FR-009**: System MUST restrict super_admin role assignment to super_admin users only.
- **FR-010**: System MUST prevent modification of super_admin accounts by non-super_admin users.
- **FR-011**: System MUST allow admins to assign employees to managers (create supervisor relationships).
- **FR-012**: System MUST allow admins to reassign employees to different managers.
- **FR-013**: System MUST display current and historical supervisor assignments for an employee.
- **FR-014**: System MUST allow admins to change employee status (active, inactive, suspended).
- **FR-014a**: System MUST automatically end active supervisor assignments (set end_date) when an employee is deactivated or suspended.
- **FR-015**: System MUST prevent deactivated employees from logging in while preserving their historical data.
- **FR-016**: System MUST warn administrators when deactivating an employee with an active shift.
- **FR-017**: System MUST prevent admins from deactivating themselves.
- **FR-018**: System MUST ensure at least one admin or super_admin remains active in the system.
- **FR-019**: System MUST log all employee profile changes for audit purposes.
- **FR-020**: System MUST provide visual distinction for inactive and suspended employees in the directory.

### Key Entities

- **Employee Profile**: Core user record containing identity information (name, email, employee ID), role (employee/manager/admin/super_admin), and status (active/inactive/suspended). Linked to authentication identity.
- **Supervisor Assignment**: Relationship between an employee and their manager with effective dates. Determines data visibility and reporting hierarchy. Supports historical tracking with start and end dates.
- **Role**: Permission level determining system access. Four levels: employee (basic clock-in/out), manager (view supervised employees), admin (manage all employees), super_admin (protected full access).
- **Status**: Employee account state determining login access. Three states: active (can log in normally), inactive (permanent departure from organization, cannot log in, historical data preserved), suspended (temporary hold such as investigation or leave without pay, cannot log in, may be reactivated).
- **Audit Log**: Record of changes made to employee profiles, including who made the change, what changed, and when. Used for compliance and troubleshooting.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Administrators can find any employee in the directory within 10 seconds using search or filters.
- **SC-002**: Employee profile edits are saved and visible within 2 seconds of confirmation.
- **SC-003**: Role changes take effect immediately, with the affected user seeing updated permissions on their next action.
- **SC-004**: Supervisor assignments are reflected in manager dashboards within 30 seconds of assignment.
- **SC-005**: System handles organizations with up to 1,000 employees without noticeable performance degradation.
- **SC-006**: 95% of administrators can successfully complete common tasks (edit profile, change role, assign supervisor) without documentation.
- **SC-007**: Deactivated employees are prevented from logging in within 1 minute of status change.
- **SC-008**: All employee profile changes are logged and retrievable for audit purposes.

## Clarifications

### Session 2026-01-15

- Q: What is the distinction between "inactive" and "suspended" employee statuses? → A: Inactive = permanent departure (employee left organization), Suspended = temporary hold (under investigation, leave without pay, may return).
- Q: How should concurrent edit conflicts be surfaced to the earlier editor? → A: Toast notification on next action with refresh prompt ("This employee was modified by another user. Please refresh to see current data.").
- Q: What should be displayed when search or filter returns no matching employees? → A: Empty state message showing current filter criteria with a "Clear filters" action button for immediate recovery.
- Q: Should supervisor assignments be automatically ended when an employee is deactivated or suspended? → A: Yes, automatically end the assignment (set end_date) when employee is deactivated or suspended to keep manager dashboards accurate.
- Q: Should reactivating an employee automatically restore their previous supervisor assignment? → A: No, require admin to manually reassign supervisor upon reactivation (organizational structure may have changed during absence).

## Assumptions

- The existing employee_profiles table and role system from previous specifications provides the data foundation.
- The employee_supervisors table from Spec 006 supports supervisor assignment functionality.
- The update_user_role and get_all_users RPC functions from Spec 009 can be extended for this feature.
- Admin users have reliable internet connectivity when performing employee management tasks (offline management is out of scope).
- Self-registration is disabled or controlled; employee accounts are created through a separate onboarding process not covered in this spec.
- Email addresses cannot be changed by administrators (email changes would require re-verification through the authentication system).

## Out of Scope

- Employee account creation/onboarding (separate feature for invitation-based registration).
- Bulk import/export of employee data.
- Employee self-service profile editing (covered in Spec 002).
- Custom fields or extensible employee attributes.
- Integration with external HR systems (HRIS, payroll).
- Detailed audit log viewing interface (audit data is stored but a dedicated audit viewer is future work).
- Employee photo/avatar management.
