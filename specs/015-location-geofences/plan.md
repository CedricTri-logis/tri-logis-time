# Implementation Plan: Location Geofences & Shift Segmentation

**Branch**: `015-location-geofences` | **Date**: 2026-01-16 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/015-location-geofences/spec.md`

## Summary

Implement workplace location management (geofences) with automatic shift timeline segmentation based on GPS position. Supervisors can create and manage geographic zones with configurable radii, and view employee shift timelines segmented by location type (office, building, vendor, home, travel, unmatched).

## Technical Context

**Language/Version**: TypeScript 5.x / Node.js 18.x LTS (Dashboard)
**Primary Dependencies**: Next.js 14+ (App Router), Refine (@refinedev/supabase), shadcn/ui, Tailwind CSS, Zod, react-leaflet 5.0.0, Leaflet 1.9.4, date-fns 4.1.0
**Storage**: PostgreSQL via Supabase (new: `locations`, `location_matches` tables), PostGIS extension for spatial queries
**Testing**: Playwright for E2E (existing infrastructure from Spec 013)
**Target Platform**: Desktop browsers (Chrome, Safari, Firefox - latest 2 versions)
**Project Type**: Web dashboard (manager/supervisor application)
**Performance Goals**: Timeline visualization loads for 500+ GPS points in <3 seconds (SC-002)
**Constraints**: Desktop-first design, must work with existing RLS policies
**Scale/Scope**: 77 seed locations, typical shifts with 50-500 GPS points

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| **II. Desktop Dashboard: TypeScript Web Stack** | ✅ PASS | Using Next.js 14+ App Router, shadcn/ui, Refine, Tailwind CSS, Zod |
| **II. Refine data hooks** | ✅ PASS | Will use useTable, useForm, useList for location CRUD |
| **II. shadcn/ui components** | ✅ PASS | Building on existing UI component library |
| **IV. Privacy & Compliance** | ✅ PASS | Dashboard only displays supervised employees (existing RLS); home locations accessible to all supervisors per FR-023 |
| **VI. Simplicity & Maintainability** | ✅ PASS | Feature directly serves core use case (workforce monitoring); no feature creep |
| **Backend: RLS enabled** | ✅ PASS | New tables will have RLS policies aligned with existing patterns |
| **Backend: Manager access** | ✅ PASS | Supervisors access locations (company-wide) and shifts (supervised employees only) |

**Gate Result**: ✅ PASS - Proceed with Phase 0

## Project Structure

### Documentation (this feature)

```text
specs/015-location-geofences/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output (RPC function signatures)
└── tasks.md             # Phase 2 output (/speckit.tasks command)
```

### Source Code (repository root)

```text
dashboard/
├── src/
│   ├── app/
│   │   └── dashboard/
│   │       └── locations/           # NEW: Location management pages
│   │           ├── page.tsx         # Location list with map view
│   │           ├── [id]/
│   │           │   └── page.tsx     # Location detail/edit
│   │           └── import/
│   │               └── page.tsx     # CSV bulk import
│   ├── components/
│   │   ├── locations/               # NEW: Location-specific components
│   │   │   ├── location-form.tsx    # Create/edit form with map
│   │   │   ├── location-map.tsx     # Map with geofence circles
│   │   │   ├── csv-import-dialog.tsx
│   │   │   └── geofence-circle.tsx  # Leaflet circle component
│   │   ├── timeline/                # NEW: Shift timeline components
│   │   │   ├── timeline-bar.tsx     # Horizontal segment bar
│   │   │   ├── timeline-segment.tsx # Individual segment
│   │   │   ├── timeline-summary.tsx # Statistics panel
│   │   │   └── segmented-trail-map.tsx # GPS trail colored by segment
│   │   └── ui/                      # Existing shadcn/ui
│   ├── lib/
│   │   ├── hooks/
│   │   │   ├── use-locations.ts     # NEW: Location CRUD hooks
│   │   │   ├── use-location-matches.ts # NEW: GPS matching hooks
│   │   │   └── use-timeline-segments.ts # NEW: Timeline computation
│   │   ├── validations/
│   │   │   └── location.ts          # NEW: Zod schemas for locations
│   │   └── utils/
│   │       ├── segment-colors.ts    # NEW: Location type color mapping
│   │       └── csv-parser.ts        # NEW: CSV validation/parsing
│   └── types/
│       └── location.ts              # NEW: Location types

supabase/
└── migrations/
    └── 015_location_geofences.sql   # NEW: Tables, RPC functions, RLS
```

**Structure Decision**: Extending existing dashboard structure with new `/locations/` route and components. Follows established patterns from Specs 010-013.

## Complexity Tracking

> No constitution violations requiring justification.

---

## Phase 0: Research Topics

1. **PostGIS spatial queries** - Best practices for geofence containment queries (ST_DWithin, ST_Distance)
2. **Geocoding API integration** - Google Maps Geocoding API patterns for address-to-coordinates
3. **Timeline segment computation** - Algorithm for grouping consecutive GPS points by location match
4. **CSV bulk import patterns** - Validation, preview, and error handling for file uploads in Next.js
5. **Leaflet circle/polygon rendering** - react-leaflet patterns for interactive geofence visualization

---

## Phase 1: Design Outputs

After research phase completes:
- `data-model.md`: Entity definitions, relationships, state transitions
- `contracts/`: RPC function signatures for location matching
- `quickstart.md`: Development environment setup for new dependencies
