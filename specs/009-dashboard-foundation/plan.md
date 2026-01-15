# Implementation Plan: Dashboard Foundation

**Branch**: `009-dashboard-foundation` | **Date**: 2026-01-15 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/009-dashboard-foundation/spec.md`

## Summary

Build an organization-wide admin dashboard for admin/super_admin users to monitor workforce status, view team comparisons, and access aggregate metrics. The dashboard will be implemented as a **Next.js 14+ web application** using the TypeScript stack mandated by the constitution (shadcn/ui + Refine + Supabase provider), deployed via Vercel.

## Technical Context

**Language/Version**: TypeScript 5.x, Node.js 18.x LTS
**Primary Dependencies**: Next.js 14+ (App Router), shadcn/ui, Refine (@refinedev/supabase), Tailwind CSS, Zod
**Storage**: PostgreSQL via Supabase (existing schema), client-side cache (React Query via Refine)
**Testing**: Playwright E2E, Vitest for unit tests
**Target Platform**: Web browsers (Chrome, Firefox, Safari, Edge - latest 2 versions)
**Project Type**: Web application (separate from mobile Flutter app)
**Performance Goals**: Dashboard load <3s, team comparison <2s, support 1000+ employees
**Constraints**: Server-side aggregation only, 30-second auto-refresh, offline shows stale indicator
**Scale/Scope**: Organizations with up to 1000 employees, 50 managers

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Mobile App: Flutter Cross-Platform | N/A | This feature is web-only dashboard |
| II. Desktop Dashboard: TypeScript Web Stack | **CONFLICT RESOLVED** | Spec requested Flutter Web; constitution mandates TypeScript/Next.js. **Following constitution.** |
| III. Battery-Conscious Design | N/A | Web-only feature |
| IV. Privacy & Compliance | PASS | Dashboard only shows data for authorized admin/super_admin users via existing RLS |
| V. Offline-First Architecture | N/A | Web dashboard - "Admin/super_admin users have reliable internet access when using the web dashboard (offline web support is out of scope)" per spec |
| VI. Simplicity & Maintainability | PASS | Using proven stack (Refine + shadcn) with existing Supabase backend |

### Constitution Conflict Resolution

**Conflict**: Feature spec clarification stated "Flutter Web (compile existing app for web with responsive layouts)" but constitution Principle II mandates:
> "The manager dashboard MUST be built with the approved TypeScript web stack for optimal AI assistance and ADMIN project compatibility."

**Resolution**: Constitution takes precedence. The dashboard will be built with:
- Next.js 14+ with App Router
- shadcn/ui components
- Refine data layer with @refinedev/supabase
- Tailwind CSS for styling

**Rationale**:
1. Constitution explicitly states this stack is "non-negotiable"
2. Enables future integration with ADMIN Data Room project
3. Better AI code generation support (shadcn/v0.dev)
4. Refine eliminates CRUD boilerplate

## Project Structure

### Documentation (this feature)

```text
specs/009-dashboard-foundation/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
└── tasks.md             # Phase 2 output (/speckit.tasks command)
```

### Source Code (repository root)

```text
# Mobile App (existing - no changes in this spec)
gps_tracker/
└── lib/features/        # Flutter mobile app

# Admin Dashboard (new - this spec)
dashboard/
├── src/
│   ├── app/                    # Next.js App Router pages
│   │   ├── layout.tsx          # Root layout with providers
│   │   ├── page.tsx            # Redirect to /dashboard
│   │   ├── login/
│   │   │   └── page.tsx        # Auth page
│   │   └── dashboard/
│   │       ├── layout.tsx      # Dashboard layout with nav
│   │       ├── page.tsx        # Organization overview (FR-001 to FR-004)
│   │       └── teams/
│   │           └── page.tsx    # Team comparison view (FR-005, FR-006)
│   ├── components/
│   │   ├── ui/                 # shadcn/ui components
│   │   ├── dashboard/          # Dashboard-specific components
│   │   │   ├── stats-cards.tsx
│   │   │   ├── activity-feed.tsx
│   │   │   ├── team-comparison-table.tsx
│   │   │   └── data-freshness.tsx
│   │   └── layout/             # Layout components
│   │       ├── sidebar.tsx
│   │       └── header.tsx
│   ├── lib/
│   │   ├── supabase/           # Supabase client setup
│   │   │   ├── client.ts
│   │   │   └── server.ts
│   │   ├── auth/               # Auth utilities
│   │   └── utils.ts            # Shared utilities
│   ├── providers/
│   │   ├── refine-provider.tsx # Refine configuration
│   │   └── auth-provider.tsx   # Supabase auth provider for Refine
│   └── types/
│       ├── database.ts         # Generated Supabase types
│       └── dashboard.ts        # Dashboard-specific types
├── public/
├── tests/
│   └── e2e/                    # Playwright tests
├── package.json
├── tailwind.config.ts
├── next.config.js
└── tsconfig.json

# Supabase (existing + new migrations)
supabase/
├── migrations/
│   ├── ...existing...
│   └── 010_dashboard_aggregations.sql  # New RPC functions for dashboard
└── config.toml
```

**Structure Decision**: Separate `dashboard/` directory at repository root for the Next.js web application, coexisting with the existing `gps_tracker/` Flutter mobile app. This follows the constitution's platform separation (mobile vs desktop).

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Separate web project | Constitution mandates TypeScript stack for dashboard | Flutter Web (single codebase) rejected per constitution Principle II |

## Phase Completion Status

| Phase | Output | Status |
|-------|--------|--------|
| Phase 0 | `research.md` | COMPLETE |
| Phase 1 | `data-model.md` | COMPLETE |
| Phase 1 | `contracts/api-contracts.md` | COMPLETE |
| Phase 1 | `quickstart.md` | COMPLETE |
| Phase 2 | `tasks.md` | PENDING (run `/speckit.tasks`) |

## Constitution Re-Check (Post-Design)

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Mobile App: Flutter Cross-Platform | N/A | Web-only feature |
| II. Desktop Dashboard: TypeScript Web Stack | PASS | Using Next.js 14+, shadcn/ui, Refine, Tailwind CSS |
| III. Battery-Conscious Design | N/A | Web-only feature |
| IV. Privacy & Compliance | PASS | RLS policies enforce admin-only access |
| V. Offline-First Architecture | N/A | Web dashboard per spec assumptions |
| VI. Simplicity & Maintainability | PASS | Standard patterns, no custom abstractions |

All gates pass. Ready for task generation.

## Next Steps

Run `/speckit.tasks` to generate implementation tasks.
