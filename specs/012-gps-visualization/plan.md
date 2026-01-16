# Implementation Plan: GPS Visualization

**Branch**: `012-gps-visualization` | **Date**: 2026-01-15 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/012-gps-visualization/spec.md`

## Summary

Extend the manager dashboard with historical GPS visualization capabilities including trail viewing for completed shifts, animated playback, multi-shift aggregation, and data export (CSV/GeoJSON). Builds on Spec 011's react-leaflet map infrastructure with new RPC functions for historical GPS data access.

## Technical Context

**Language/Version**: TypeScript 5.x, Node.js 18.x LTS
**Primary Dependencies**: Next.js 14+ (App Router), Refine (@refinedev/supabase), shadcn/ui, Tailwind CSS, Zod, react-leaflet 5.0.0, Leaflet 1.9.4, date-fns 4.1.0
**Storage**: PostgreSQL via Supabase (existing: employee_profiles, shifts, gps_points, employee_supervisors tables)
**Testing**: Playwright (E2E), Component testing
**Target Platform**: Web/Desktop (Chrome, Safari, Firefox - latest 2 versions)
**Project Type**: Web application (manager dashboard extension)
**Performance Goals**: GPS trails ≤1,000 points render in <3s; Playback animation at 30+ FPS; Multi-day view loads in <5s for 7 days; Export completes in <10s for single shifts
**Constraints**: Trail simplification at >500 points for performance; 90-day data retention; Supervisor authorization via RLS; Client-side export for standard datasets
**Scale/Scope**: Extension to existing dashboard (2-3 new pages/components); ~500-5,000 GPS points per visualization

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Pre-Design Compliance

| Principle | Status | Notes |
|-----------|--------|-------|
| II. Desktop Dashboard: TypeScript Web Stack | ✅ PASS | Using existing Next.js 14+/Refine/shadcn stack from Spec 011 |
| II. Must use Refine data hooks | ✅ PASS | Will use useCustom for RPC calls (existing pattern) |
| II. Must use shadcn/ui components | ✅ PASS | Extending existing UI component library |
| II. Tailwind CSS only | ✅ PASS | No custom CSS files planned |
| II. Zod validation | ✅ PASS | Will add schemas for GPS export options |
| IV. Privacy & Compliance | ✅ PASS | Manager dashboard shows only supervised employees via RLS |
| IV. Data retention policy | ✅ PASS | 90-day retention documented and enforced |
| VI. Simplicity & Maintainability | ✅ PASS | Building on existing map infrastructure |
| Backend: RLS enabled | ✅ PASS | New RPC functions will use SECURITY DEFINER with authorization checks |
| Backend: Manager role enforced | ✅ PASS | Existing supervisor authorization patterns from Spec 011 |

**Gate Status**: ✅ PASS - No violations detected. Proceed to Phase 0.

## Project Structure

### Documentation (this feature)

```text
specs/012-gps-visualization/
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output (/speckit.plan command)
├── data-model.md        # Phase 1 output (/speckit.plan command)
├── quickstart.md        # Phase 1 output (/speckit.plan command)
├── contracts/           # Phase 1 output (/speckit.plan command)
│   └── rpc-functions.md # PostgreSQL RPC function specifications
└── tasks.md             # Phase 2 output (/speckit.tasks command - NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
dashboard/                          # Manager dashboard (Next.js 14+)
├── src/
│   ├── app/
│   │   └── dashboard/
│   │       ├── monitoring/         # Existing real-time monitoring
│   │       └── history/            # NEW: Historical GPS visualization
│   │           ├── page.tsx        # Shift history list with search
│   │           └── [shiftId]/
│   │               └── page.tsx    # Individual shift GPS visualization
│   ├── components/
│   │   ├── monitoring/             # Existing map components (extend)
│   │   │   ├── gps-trail-map.tsx   # Extend for historical + playback
│   │   │   └── ...
│   │   └── history/                # NEW: History-specific components
│   │       ├── shift-history-table.tsx
│   │       ├── gps-playback-controls.tsx
│   │       ├── multi-shift-map.tsx
│   │       └── export-dialog.tsx
│   ├── lib/
│   │   ├── hooks/                  # NEW hooks for historical data
│   │   │   └── use-historical-gps.ts
│   │   └── utils/
│   │       ├── export-gps.ts       # NEW: CSV/GeoJSON export utilities
│   │       └── trail-simplify.ts   # NEW: Douglas-Peucker simplification
│   └── types/
│       └── history.ts              # NEW: Historical GPS types
└── tests/
    └── e2e/
        └── history.spec.ts         # Playwright E2E tests

supabase/
└── migrations/
    └── 013_gps_visualization.sql   # NEW: RPC functions for historical GPS
```

**Structure Decision**: Web application extending existing dashboard. No new projects created - adds pages/components to existing dashboard/ structure following Spec 011 patterns.

## Complexity Tracking

No violations - all implementations align with constitution principles.

---

## Post-Design Constitution Check

*Re-evaluation after Phase 1 design completion*

### Design Compliance Review

| Principle | Status | Evidence |
|-----------|--------|----------|
| II. Desktop Dashboard: TypeScript Web Stack | ✅ PASS | All components use TypeScript, Next.js App Router |
| II. Must use Refine data hooks | ✅ PASS | `useCustom` for all RPC calls (see data-model.md) |
| II. Must use shadcn/ui components | ✅ PASS | Export dialog, buttons, tables from shadcn/ui |
| II. Tailwind CSS only | ✅ PASS | No custom CSS files; all styling via Tailwind classes |
| II. Zod validation | ✅ PASS | Schemas defined for date range, export options, playback speed |
| IV. Privacy & Compliance | ✅ PASS | All RPC functions enforce supervisor authorization; 90-day retention enforced |
| IV. Data retention policy | ✅ PASS | `get_historical_shift_trail` rejects shifts older than 90 days |
| VI. Simplicity & Maintainability | ✅ PASS | No new npm dependencies; pure TypeScript utilities |
| Backend: RLS enabled | ✅ PASS | All 4 RPC functions use SECURITY DEFINER with auth checks |
| Backend: Manager role enforced | ✅ PASS | Authorization checks for admin/super_admin OR supervisor relationship |

### New Components Introduced

| Component | Constitution Alignment |
|-----------|----------------------|
| Douglas-Peucker trail simplification | VI. Simplicity - pure TS, no external deps |
| requestAnimationFrame playback | VI. Simplicity - native browser API |
| Blob-based export | VI. Simplicity - no server-side processing |
| HSL color generation | VI. Simplicity - programmatic, no color library |

### Dependencies Analysis

```
New npm dependencies: 0
Reused from Spec 011: react-leaflet, leaflet, date-fns
```

**Post-Design Gate Status**: ✅ PASS - Design adheres to all constitution principles.

---

## Generated Artifacts Summary

| Artifact | Path | Description |
|----------|------|-------------|
| research.md | `specs/012-gps-visualization/research.md` | Algorithm decisions and implementation patterns |
| data-model.md | `specs/012-gps-visualization/data-model.md` | TypeScript types, Zod schemas, entity relationships |
| rpc-functions.md | `specs/012-gps-visualization/contracts/rpc-functions.md` | PostgreSQL RPC function specifications |
| quickstart.md | `specs/012-gps-visualization/quickstart.md` | Developer setup and usage guide |

---

## Next Steps

Run `/speckit.tasks` to generate the implementation task list (`tasks.md`) based on this plan.
