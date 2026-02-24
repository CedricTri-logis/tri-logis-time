# Implementation Plan: Shift Monitoring

**Branch**: `011-shift-monitoring` | **Date**: 2026-01-15 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/011-shift-monitoring/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command. See `.specify/templates/commands/plan.md` for the execution workflow.

## Summary

Real-time supervisor dashboard for monitoring team shift activity and GPS locations. Extends the existing Next.js admin dashboard (`/dashboard`) with a new monitoring section that displays supervised employees' current shift status, live map locations, and GPS trails. Uses Supabase Realtime WebSocket subscriptions for push-based updates and an interactive map for location visualization.

## Technical Context

**Language/Version**: TypeScript 5.x, Node.js 18.x LTS
**Primary Dependencies**: Next.js 14+ (App Router), Refine (@refinedev/supabase), shadcn/ui, Tailwind CSS, Zod, react-leaflet (map), Supabase Realtime
**Storage**: PostgreSQL via Supabase (existing tables: employee_profiles, shifts, gps_points, employee_supervisors)
**Testing**: Playwright (E2E), component testing with Jest/React Testing Library
**Target Platform**: Web (Chrome, Safari, Firefox - latest 2 versions), desktop-first
**Project Type**: Web application (extends existing Next.js dashboard)
**Performance Goals**: 5s initial load, 60s max update latency, 3s GPS trail load for 500 points
**Constraints**: Real-time updates within 60 seconds, teams up to 50 employees, location display for active shifts only
**Scale/Scope**: Up to 50 employees per supervisor, 500 GPS points per shift trail

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Requirement | Status | Notes |
|-----------|-------------|--------|-------|
| II. Desktop Dashboard | Must use Next.js 14+ App Router, TypeScript, shadcn/ui, Refine, Tailwind CSS, Zod | PASS | Extends existing dashboard with same stack |
| II. Desktop Dashboard | Must use Refine data hooks instead of custom fetch | PASS | Will use useList, useOne, and custom RPC calls |
| II. Desktop Dashboard | Must use shadcn/ui components | PASS | Will use existing components + add new ones as needed |
| IV. Privacy & Compliance | Location tracking only while clocked in | PASS | GPS display only for active shifts per FR-007 |
| IV. Privacy & Compliance | Manager dashboard shows only supervised employees | PASS | RLS policies enforce this at database level |
| V. Simplicity & Maintainability | No feature creep | PASS | Read-only monitoring, no editing/approval features |
| VI. Platform - Web/Desktop | Desktop-first design | PASS | Spec explicitly targets admin dashboard |
| VI. Backend | Uses same Supabase instance as mobile | PASS | Existing database with supervisor relationships |

**Gate Result**: PASS - All constitution requirements satisfied. Proceed with Phase 0.

## Project Structure

### Documentation (this feature)

```text
specs/011-shift-monitoring/
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output (/speckit.plan command)
├── data-model.md        # Phase 1 output (/speckit.plan command)
├── quickstart.md        # Phase 1 output (/speckit.plan command)
├── contracts/           # Phase 1 output (/speckit.plan command)
└── tasks.md             # Phase 2 output (/speckit.tasks command - NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
dashboard/
├── src/
│   ├── app/
│   │   └── dashboard/
│   │       └── monitoring/              # NEW: Shift monitoring feature
│   │           ├── page.tsx             # Team overview with list + map
│   │           └── [employeeId]/
│   │               └── page.tsx         # Individual shift detail view
│   ├── components/
│   │   ├── ui/                          # Existing shadcn/ui components
│   │   └── monitoring/                  # NEW: Monitoring-specific components
│   │       ├── team-list.tsx            # Employee list with status
│   │       ├── team-filters.tsx         # Search and status filter
│   │       ├── team-map.tsx             # Map with employee markers
│   │       ├── location-marker.tsx      # Individual map marker
│   │       ├── shift-detail-card.tsx    # Shift info display
│   │       ├── gps-trail-map.tsx        # Trail visualization
│   │       ├── duration-counter.tsx     # Live duration display
│   │       ├── staleness-indicator.tsx  # Data freshness badge
│   │       └── empty-states.tsx         # No data/no team states
│   ├── lib/
│   │   ├── hooks/                       # NEW: Monitoring hooks
│   │   │   ├── use-realtime-shifts.ts   # Supabase realtime for shifts
│   │   │   ├── use-realtime-gps.ts      # Supabase realtime for GPS
│   │   │   └── use-supervised-team.ts   # Team data with realtime
│   │   ├── providers/                   # Existing providers
│   │   └── validations/
│   │       └── monitoring.ts            # NEW: Zod schemas for monitoring
│   └── types/
│       └── monitoring.ts                # NEW: Monitoring data types
└── package.json                         # Add react-leaflet, leaflet deps
```

**Structure Decision**: Extends existing dashboard structure with new `/monitoring` route and dedicated components directory. Follows established patterns from employee management (spec 010).

## Complexity Tracking

No constitution violations to justify - all requirements align with established patterns.
