# Implementation Plan: Employee Management

**Branch**: `010-employee-management` | **Date**: 2026-01-15 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/010-employee-management/spec.md`

## Summary

This feature implements a comprehensive employee management interface for administrators in the Next.js dashboard. Administrators can view an employee directory with search/filter/pagination, edit employee profiles (name, employee ID), manage roles, assign supervisors, and activate/deactivate employee accounts. All changes are logged for audit purposes. The feature builds on existing `employee_profiles` and `employee_supervisors` tables, extending the dashboard with new pages and RPC functions.

## Technical Context

**Language/Version**: TypeScript 5.x / Node.js 18.x LTS
**Primary Dependencies**: Next.js 14+ (App Router), Refine (@refinedev/supabase), shadcn/ui, Tailwind CSS, Zod, @tanstack/react-table
**Storage**: PostgreSQL via Supabase (existing `employee_profiles`, `employee_supervisors` tables)
**Testing**: Playwright (E2E), React Testing Library (component)
**Target Platform**: Web (Chrome, Safari, Firefox - latest 2 versions)
**Project Type**: web - dashboard application
**Performance Goals**: Directory search within 10 seconds (SC-001), edits visible within 2 seconds (SC-002), 1000+ employees without degradation (SC-005)
**Constraints**: Admin/super_admin role required, online connectivity required (spec assumption)
**Scale/Scope**: Up to 1,000 employees per organization, 6 user stories, 20 functional requirements

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| II. Desktop Dashboard: TypeScript Web Stack | ✅ PASS | Using Next.js 14+, Refine, shadcn/ui, Tailwind, Zod |
| II. Must use Refine data hooks | ✅ PASS | Will use useTable, useForm, useList, useOne for CRUD |
| II. Must use shadcn/ui components | ✅ PASS | Will extend existing UI components (Table, Button, Badge, etc.) |
| II. Zod validation required | ✅ PASS | Will define schemas for employee edit forms |
| IV. Privacy & Compliance | ✅ PASS | RLS ensures admin-only access, role-based visibility |
| IV. Manager access to supervised employees only | ✅ PASS | This feature is admin-only, but respects existing RLS |
| VI. Simplicity & Maintainability | ✅ PASS | Building on existing patterns from Spec 009 |
| VI. YAGNI principle | ✅ PASS | Only implementing specified requirements, no extras |

**Gate Status**: ✅ PASSED - All constitutional principles satisfied

## Project Structure

### Documentation (this feature)

```text
specs/010-employee-management/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output (RPC function contracts)
└── tasks.md             # Phase 2 output (/speckit.tasks command)
```

### Source Code (repository root)

```text
dashboard/
├── src/
│   ├── app/
│   │   └── dashboard/
│   │       └── employees/           # NEW: Employee management pages
│   │           ├── page.tsx         # Employee directory (list view)
│   │           └── [id]/
│   │               └── page.tsx     # Employee detail/edit page
│   ├── components/
│   │   ├── dashboard/
│   │   │   └── employees/           # NEW: Employee-specific components
│   │   │       ├── employee-table.tsx
│   │   │       ├── employee-filters.tsx
│   │   │       ├── employee-form.tsx
│   │   │       ├── role-selector.tsx
│   │   │       ├── supervisor-assignment.tsx
│   │   │       └── status-badge.tsx
│   │   ├── layout/
│   │   │   └── sidebar.tsx          # UPDATE: Add Employees nav link
│   │   └── ui/                      # EXISTING: shadcn/ui components
│   │       ├── dialog.tsx           # ADD: For modals/confirmations
│   │       ├── form.tsx             # ADD: Form primitives
│   │       ├── input.tsx            # ADD: Text input
│   │       ├── label.tsx            # ADD: Form labels
│   │       ├── toast.tsx            # ADD: Notifications
│   │       └── pagination.tsx       # ADD: For employee list
│   ├── lib/
│   │   └── validations/
│   │       └── employee.ts          # NEW: Zod schemas for employee forms
│   └── types/
│       ├── database.ts              # UPDATE: Regenerate with new RPC types
│       └── employee.ts              # NEW: Employee management types

supabase/
└── migrations/
    └── 011_employee_management.sql  # NEW: Audit log, additional RPC functions
```

**Structure Decision**: Extends existing dashboard structure following established patterns. New employee management pages under `/dashboard/employees/`, new components in `components/dashboard/employees/`, and new Supabase migration for audit logging and management RPCs.

## Complexity Tracking

> No constitutional violations requiring justification.

| Item | Approach | Rationale |
|------|----------|-----------|
| Audit logging | New `audit.audit_logs` table | Required by FR-019; simple append-only table |
| Concurrent edits | Last-write-wins with toast | Per spec clarification; simplest conflict resolution |
| Super admin protection | Existing database trigger | Reuse from migration 009; no new complexity |

---

## Post-Design Constitution Check

*Re-evaluated after Phase 1 design artifacts completed.*

| Principle | Status | Verification |
|-----------|--------|--------------|
| II. Desktop Dashboard: TypeScript Web Stack | ✅ PASS | All pages/components use Next.js 14+, TypeScript strict mode |
| II. Must use Refine data hooks | ✅ PASS | `useTable` for directory, `useOne` for detail, `useForm` for editing |
| II. Must use shadcn/ui components | ✅ PASS | Adding Dialog, Form, Input, Label, Toast, Pagination via `npx shadcn@latest add` |
| II. Zod validation required | ✅ PASS | `employeeEditSchema`, `roleChangeSchema`, `statusChangeSchema` defined |
| IV. Privacy & Compliance | ✅ PASS | RLS policies enforce admin-only access; audit logging for compliance |
| IV. Manager dashboard data visibility | ✅ PASS | This feature is admin-only; existing RLS unchanged |
| VI. Simplicity & Maintainability | ✅ PASS | Follows existing patterns from Spec 009; generic audit trigger |
| VI. YAGNI principle | ✅ PASS | No audit viewer UI (out of scope); no bulk import/export |
| Backend: RLS enabled | ✅ PASS | audit.audit_logs has SELECT for admin only, no direct writes |
| Backend: Supabase client | ✅ PASS | All RPC calls via @refinedev/supabase data provider |

**Final Gate Status**: ✅ PASSED - All constitutional principles satisfied post-design
