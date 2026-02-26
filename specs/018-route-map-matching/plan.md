# Implementation Plan: Route Map Matching & Real Route Visualization

**Branch**: `018-route-map-matching` | **Date**: 2026-02-25 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/018-route-map-matching/spec.md`

## Summary

Replace straight-line distance calculation with OSRM-based road distance for detected trips. Store matched route geometry (encoded polyline) and display actual road routes on maps. Matching happens asynchronously via Supabase Edge Functions calling a self-hosted OSRM Docker container, with fallback to existing Haversine × 1.3 estimates when matching fails.

## Technical Context

**Language/Version**: Dart >=3.0.0 / Flutter >=3.29.0 (mobile), TypeScript 5.x / Deno (Edge Functions)
**Primary Dependencies**: supabase_flutter 2.12.0, flutter_riverpod 2.5.0, google_maps_flutter (existing); OSRM v5 (Docker, new infrastructure)
**Storage**: PostgreSQL via Supabase (extended `trips` table — migration 043); SQLCipher local cache (extended `local_trips`)
**Testing**: Flutter unit tests (polyline decoder, model changes), Edge Function integration tests (OSRM calls), manual map verification
**Target Platform**: iOS 14+, Android API 24+, Next.js dashboard (Chrome/Safari)
**Project Type**: Mobile + Dashboard + Edge Functions + Infrastructure
**Performance Goals**: Route matching completes within 2 minutes of clock-out (SC-002); 100 batch trips in <10 minutes (SC-007); no clock-out delay >5s (SC-004)
**Constraints**: GPS data must not be shared with third-party services that retain data (SC-008); offline fallback to Haversine (SC-005)
**Scale/Scope**: ~10-50 trips/day across all employees; Quebec road network (~500MB OSM data)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Mobile App: Flutter Cross-Platform | PASS | All mobile changes in Flutter; no platform-specific code needed |
| II. Desktop Dashboard: TypeScript Web Stack | PASS | Dashboard changes use existing Next.js + react-leaflet + shadcn/ui stack |
| III. Battery-Conscious Design | PASS | No changes to GPS collection; matching happens server-side |
| IV. Privacy & Compliance | PASS | OSRM self-hosted on own infrastructure; GPS data stays private (SC-008) |
| V. Offline-First Architecture | PASS | Fallback to Haversine when matching unavailable; route geometry cached locally |
| VI. Simplicity & Maintainability | PASS | Extends existing trips table (no new tables); polyline decoder is ~20 lines; OSRM is a single Docker container |
| RLS Policies | PASS | Existing trips RLS unchanged; update_trip_match uses SECURITY DEFINER |
| Backend: Supabase | PASS | Edge Functions + RPC pattern consistent with existing architecture |

**Gate Result**: ALL PASS — no violations.

## Project Structure

### Documentation (this feature)

```text
specs/018-route-map-matching/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0: Map matching engine selection, API research
├── data-model.md        # Phase 1: trips table extensions, migration 043
├── quickstart.md        # Phase 1: Setup and testing guide
├── checklists/
│   └── requirements.md  # Requirements checklist
└── contracts/
    ├── match-trip-route.md   # Single trip matching Edge Function contract
    └── batch-match-trips.md  # Batch processing Edge Function contract
```

### Source Code (repository root)

```text
supabase/
├── migrations/
│   └── 043_route_map_matching.sql        # Schema: trips table extensions + update_trip_match RPC
└── functions/
    ├── match-trip-route/
    │   └── index.ts                       # Single trip matching Edge Function
    └── batch-match-trips/
        └── index.ts                       # Batch processing Edge Function

gps_tracker/lib/
├── features/mileage/
│   ├── models/
│   │   ├── trip.dart                     # MODIFIED: Add route matching fields
│   │   └── local_trip.dart               # MODIFIED: Add local cache fields
│   ├── services/
│   │   ├── trip_service.dart             # MODIFIED: Trigger matching after detection
│   │   └── route_match_service.dart      # NEW: Edge Function client for route matching
│   ├── widgets/
│   │   ├── trip_route_map.dart           # MODIFIED: Render matched polyline
│   │   ├── trip_card.dart                # MODIFIED: Add match status badge
│   │   └── match_status_badge.dart       # NEW: Visual match status indicator
│   └── screens/
│       └── trip_detail_screen.dart       # MODIFIED: Show route verified indicator
└── shared/
    └── utils/
        └── polyline_decoder.dart         # NEW: Polyline6 decoding utility

dashboard/src/
├── types/
│   └── trip.ts                           # MODIFIED: Add route matching fields
├── components/
│   ├── trips/
│   │   ├── trip-route-map.tsx            # NEW: Matched route on Leaflet map
│   │   └── match-status-badge.tsx        # NEW: Visual match status indicator
│   └── monitoring/
│       └── gps-trail-map.tsx             # MODIFIED: Support matched route overlay
└── lib/
    └── polyline.ts                       # NEW: Polyline6 decoder utility
```

**Structure Decision**: Extends existing mobile (Flutter) + dashboard (Next.js) + backend (Supabase) structure. New OSRM infrastructure deployed separately as a Docker container. Two new Supabase Edge Functions for matching orchestration.

## Architecture

### Processing Flow

```
Shift Completes
    ↓
detect_trips() RPC (existing, unchanged)
    ↓
Trips created with match_status='pending', distance_km = Haversine × 1.3
    ↓
App calls route_match_service.matchTrip(tripId) for each trip
    ↓
Supabase Edge Function "match-trip-route"
    ↓
    ├── Fetch trip GPS points from Supabase (via service role)
    ├── Simplify trace if >100 points
    ├── Call OSRM Match API (self-hosted VPS)
    ├── Validate: confidence ≥ 0.3, ≥50% points matched, distance ≤ 3× haversine
    └── Store: route_geometry, road_distance_km, match_status
              Update distance_km if matched (replaces Haversine estimate)
    ↓
App refreshes trip data → UI shows:
    ├── Matched: solid polyline on map, "Route verified" badge, road distance
    ├── Failed: dashed line (GPS points), "Distance estimated" badge, Haversine distance
    └── Anomalous: dashed line, "Distance estimated" badge, flagged for review
```

### OSRM Infrastructure

```
┌──────────────────────┐     ┌───────────────────────┐
│  Supabase Edge Fn    │────▶│  OSRM Docker (VPS)    │
│  match-trip-route    │◀────│  Quebec OSM data       │
│                      │     │  Port 5000             │
│  batch-match-trips   │     │  ~2GB RAM, ~2GB disk   │
└──────────────────────┘     └───────────────────────┘
         │                              │
         ▼                              │
┌──────────────────────┐                │
│  Supabase PostgreSQL │                │
│  trips table         │    No GPS data leaves
│  (route_geometry,    │    our infrastructure
│   road_distance_km)  │
└──────────────────────┘
```

### Key Design Decisions

1. **OSRM over Valhalla**: Simpler deployment, proven at scale, adequate accuracy (90-95%) for 30-60s GPS intervals. Valhalla's HMM advantage (93-97%) doesn't justify additional complexity for Phase 1.

2. **Edge Function over pg_net**: Cleaner HTTP handling, better error management, easier to test. pg_net is async-only and can't easily process OSRM responses in-transaction.

3. **Polyline6 storage over coordinate arrays**: 5-10× more compact in database. Both Google Maps Flutter and react-leaflet have decoder support. OSRM outputs polyline6 natively.

4. **State on trips table over separate match_jobs table**: YAGNI — the matching lifecycle is simple (pending → processing → matched/failed/anomalous). No need for a separate entity.

5. **distance_km replacement over separate column**: When matched, `distance_km` is updated to road distance. `road_distance_km` keeps the OSRM value for audit. This means `get_mileage_summary` and reimbursement calculations automatically use the best available distance with zero changes.

6. **Existing trips default to 'pending'**: Migration 043 sets `match_status = 'pending'` for all existing trips, enabling batch re-processing (User Story 5) without special handling.

## Complexity Tracking

No constitution violations — no entries needed.
