# Implementation Plan: Mileage Tracking for Reimbursement

**Branch**: `017-mileage-tracking` | **Date**: 2026-02-24 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/017-mileage-tracking/spec.md`

## Summary

Add automatic mileage tracking to the Tri-Logis Clock app, transforming background GPS from "employer surveillance" into "employee reimbursement tool." The system detects vehicle trips from existing `gps_points` (spec 004), calculates distances, and generates CRA-compliant reimbursement reports. This is the primary strategy to resolve the Apple App Store rejection under Guideline 2.5.4.

**Key architectural insight**: No additional GPS collection is required. Trip detection runs as a PostgreSQL RPC function on existing `gps_points` data, triggered when a shift ends or on-demand. This means zero extra battery impact and zero changes to the background tracking infrastructure.

## Technical Context

**Language/Version**: Dart >=3.0.0 / Flutter >=3.29.0 (mobile), TypeScript 5.x / Node.js 18.x LTS (dashboard)
**Primary Dependencies**:
- Mobile: flutter_riverpod 2.5.0, supabase_flutter 2.12.0, google_maps_flutter (existing), pdf (existing), share_plus (existing)
- Dashboard: Next.js 14+ (App Router), Refine (@refinedev/supabase), shadcn/ui, react-leaflet 5.0.0, date-fns 4.1.0
**Storage**: PostgreSQL via Supabase (new: `trips`, `trip_gps_points`, `reimbursement_rates`, `mileage_reports` tables); SQLCipher local (new: `local_trips`)
**Testing**: `flutter test` (mobile), Playwright (dashboard)
**Target Platform**: iOS 14+, Android API 24+, Web (Chrome/Safari/Firefox latest 2)
**Project Type**: Mobile + Web Dashboard
**Performance Goals**: Trip detection <3s per shift (~120 GPS points max), PDF generation <5s for 100 trips, dashboard team view <3s for 50 employees
**Constraints**: Offline-capable (mobile), no additional GPS collection, no new background services
**Scale/Scope**: ~50 employees, ~10 trips/day/employee, 90-day data retention

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Flutter Cross-Platform | PASS | Mobile mileage UI built entirely in Flutter |
| II. TypeScript Web Stack | PASS | Dashboard mileage tab uses Next.js/Refine/shadcn/ui |
| III. Battery-Conscious | PASS | Zero additional GPS collection; reuses existing gps_points |
| IV. Privacy & Compliance | PASS | Trips only from shift GPS points (work hours only); RLS enforced; employee controls classification |
| V. Offline-First | PASS | local_trips SQLCipher table; sync on connectivity return |
| VI. Simplicity & Maintainability | PASS | Reuses existing infrastructure (pdf, maps, export, RLS patterns); single PG function for trip detection |

**Post-Phase 1 Re-check**: All gates still PASS. Trip detection as a PostgreSQL RPC is simpler than an Edge Function. No new background services needed.

## Project Structure

### Documentation (this feature)

```text
specs/017-mileage-tracking/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0: App Store context, CRA rates, algorithm research
├── data-model.md        # Phase 1: Database schema (trips, rates, reports)
├── quickstart.md        # Phase 1: Implementation quick reference
├── contracts/           # Phase 1: RPC signatures, type contracts
│   ├── rpcs.md          # PostgreSQL RPC function contracts
│   └── types.md         # Dart & TypeScript type definitions
└── tasks.md             # Phase 2: Implementation tasks (via /speckit.tasks)
```

### Source Code (repository root)

```text
# Mobile (Flutter) — new feature module
gps_tracker/lib/features/mileage/
├── models/
│   ├── trip.dart                      # Trip entity (from Supabase + local)
│   ├── mileage_summary.dart           # Aggregated mileage for a period
│   ├── reimbursement_rate.dart        # Rate config entity
│   └── local_trip.dart                # SQLCipher local trip cache
├── services/
│   ├── trip_service.dart              # Fetch trips, trigger detection, update classification
│   ├── mileage_report_service.dart    # PDF generation (reuse pdf package)
│   ├── mileage_local_db.dart          # SQLCipher CRUD for local_trips
│   └── reverse_geocode_service.dart   # Lazy address resolution (Nominatim)
├── providers/
│   ├── trip_provider.dart             # Trips for a shift or period
│   ├── mileage_summary_provider.dart  # Aggregated mileage stats
│   └── reimbursement_rate_provider.dart # Current rate
├── screens/
│   ├── mileage_screen.dart            # Main mileage view (period summary + trip list)
│   ├── trip_detail_screen.dart        # Single trip with route map
│   └── mileage_report_screen.dart     # Report generation + date range picker
├── widgets/
│   ├── trip_card.dart                 # Trip list item (from, to, distance, $$)
│   ├── trip_route_map.dart            # Map with trip polyline
│   ├── mileage_summary_card.dart      # Total km, total $$, trip count
│   ├── trip_classification_chip.dart  # Business/Personal toggle
│   ├── mileage_period_picker.dart     # Week/pay period/custom range
│   └── report_share_sheet.dart        # Share/export bottom sheet
└── mileage.dart                       # Barrel export

# Dashboard (Next.js) — new mileage section
dashboard/src/
├── app/dashboard/mileage/
│   ├── page.tsx                       # Team mileage overview table
│   └── [employeeId]/page.tsx          # Employee mileage drill-down
├── components/mileage/
│   ├── team-mileage-table.tsx         # Team summary with sorting/filtering
│   ├── employee-mileage-detail.tsx    # Individual employee trip history
│   ├── trip-table.tsx                 # Trip list with columns
│   ├── trip-route-map.tsx             # Leaflet map with trip polyline
│   ├── mileage-summary-cards.tsx      # KPI cards (total km, $$, trips)
│   ├── mileage-filters.tsx            # Date range, employee filter
│   ├── rate-config-dialog.tsx         # Admin rate configuration modal
│   └── team-export-dialog.tsx         # CSV/PDF team export
├── lib/
│   ├── hooks/
│   │   ├── use-trips.ts              # Fetch trips (Refine useList)
│   │   ├── use-mileage-summary.ts    # Aggregated mileage (Supabase RPC)
│   │   └── use-reimbursement-rates.ts # Rate CRUD
│   └── validations/
│       └── mileage.ts                # Zod schemas for rate config
└── types/
    └── mileage.ts                    # TypeScript type definitions

# Supabase — new migrations
supabase/migrations/
├── 032_mileage_trips.sql             # trips + trip_gps_points tables, RLS, indexes
├── 033_reimbursement_rates.sql       # reimbursement_rates table, seed CRA 2026 rate
├── 034_mileage_reports.sql           # mileage_reports table, RLS
└── 035_trip_detection_rpc.sql        # detect_trips() + get_mileage_summary() RPCs
```

**Structure Decision**: New `mileage` feature module in Flutter follows the established feature-based pattern (models/services/providers/screens/widgets). Dashboard adds a `mileage` section following the existing pattern (page + components + hooks + types). Database uses 4 migrations to keep concerns separated and reviewable.

## Architecture Decisions

### AD-1: Trip Detection as PostgreSQL RPC (not Edge Function)

**Decision**: Implement trip detection as a PL/pgSQL function (`detect_trips(shift_id)`) callable via Supabase RPC.

**Rationale**:
- GPS points are already in PostgreSQL — no need to move data to an Edge Function runtime
- A typical shift has ~120 GPS points (10h @ 5min intervals) — trivial for PL/pgSQL
- No Edge Function deployment infrastructure needed
- Simpler to test, debug, and maintain
- Can be called from both mobile (supabase_flutter) and dashboard (@supabase/supabase-js)

**Alternatives rejected**:
- Edge Function: adds deployment complexity for no performance benefit at this scale
- Client-side detection: inconsistent results across devices, harder to audit

### AD-2: Lazy Reverse Geocoding

**Decision**: Store trip start/end as lat/lng only. Reverse-geocode to human-readable addresses on first view, then cache in the `trips` table.

**Rationale**:
- Avoids bulk geocoding API calls for trips never viewed
- Nominatim (OpenStreetMap) is free but rate-limited (1 req/sec)
- Dashboard already has `/api/geocode/route.ts` for server-side geocoding
- Mobile can call the same Nominatim endpoint directly

**Implementation**:
- Mobile: call Nominatim on trip detail view, update `start_address`/`end_address` via Supabase
- Dashboard: use existing geocode API route
- Both: if address is already cached (non-null), skip API call

### AD-3: Distance Correction Factor

**Decision**: Apply a 1.3x correction factor to Haversine straight-line distances to approximate road distance.

**Rationale**:
- At 5-minute GPS intervals, straight-line distance underestimates actual road distance by ~20-35%
- Industry standard correction factor for urban/suburban driving is 1.2-1.4x
- 1.3x is a reasonable middle ground, validated by MileIQ/Everlance approaches
- Can be tuned later with real-world data comparison against Google Maps distances

### AD-4: Trip Detection Trigger

**Decision**: Detect trips automatically when a shift is completed (clock-out), and allow on-demand re-detection.

**Rationale**:
- Clock-out is the natural trigger — all GPS points for the shift are available
- No need for real-time trip detection during the shift (adds complexity, battery concern)
- On-demand re-detection handles edge cases (late GPS sync, shift corrections)
- The RPC is idempotent: it deletes existing trips for the shift and re-detects

### AD-5: Reimbursement Rate Tiers (CRA Model)

**Decision**: Support tiered rates matching the CRA structure (different rate after 5,000 km threshold).

**Rationale**:
- CRA 2026: $0.72/km for first 5,000 km, $0.66/km thereafter
- The threshold is per calendar year per employee
- The `reimbursement_rates` table has `rate_per_km`, `threshold_km`, and `rate_after_threshold`
- The `get_mileage_summary()` RPC calculates cumulative km for the year to determine the applicable rate

## Trip Detection Algorithm

### Input
- All `gps_points` for a given `shift_id`, ordered by `captured_at ASC`

### Steps

1. **Filter outliers**: Remove points with `accuracy > 200m` or impossible speed jumps (>200 km/h between consecutive points)

2. **Calculate inter-point metrics**: For each consecutive pair of points:
   - Distance (Haversine formula)
   - Time delta
   - Speed (distance / time)

3. **Classify points**:
   - `stationary`: speed < 5 km/h
   - `walking`: 5-15 km/h
   - `vehicle`: > 15 km/h

4. **Segment into trips**:
   - Trip starts when >=2 consecutive points are `vehicle` speed
   - Trip ends when speed drops to `stationary` for >= 3 minutes (or shift ends)
   - Walking segments between vehicle segments within 2 minutes are included in the trip

5. **Apply minimum distance filter**: Discard trips with total distance < 500m (configurable)

6. **Calculate final metrics per trip**:
   - `distance_km` = sum of Haversine segments * 1.3 (correction factor)
   - `duration_minutes` = ended_at - started_at
   - `confidence_score` = 1.0 - (low_accuracy_points / total_points)
   - `start_latitude/longitude` = first point of trip
   - `end_latitude/longitude` = last point of trip

7. **Insert trips**: Upsert into `trips` table + `trip_gps_points` junction

### Edge Cases
- Shift with 0-1 GPS points: no trips detected, return empty
- All points stationary: no trips detected
- Single long trip covering entire shift: one trip from first moving point to last
- GPS gap > 15 minutes: split into separate trips (data gap = uncertainty)

## Integration Points

### Existing Code Reuse

| Component | Source | Reuse |
|-----------|--------|-------|
| GPS points data | `gps_points` table (spec 004) | Input for trip detection |
| PDF generation | `pdf` package + `export_service.dart` (spec 006) | Mileage report PDF |
| Map display | `google_maps_flutter` / `flutter_map` (spec 006) | Trip route map |
| Export infrastructure | `export_service.dart` (spec 006/013) | PDF/CSV sharing |
| Offline sync pattern | `sync_service.dart` (spec 005) | Trip sync pattern |
| Local DB pattern | `local_database.dart` + SQLCipher | local_trips table |
| Dashboard layout | `sidebar.tsx` + page pattern (spec 009) | Mileage nav + pages |
| Team data hooks | `use-supervised-team.ts` (spec 011) | Manager access control |
| Report components | `reports/` components (spec 013) | Report generation UI |
| Geocoding API | `app/api/geocode/route.ts` (spec 015) | Reverse geocoding |
| Location matching | `locations` table (spec 015) | Auto-label trip endpoints |
| Haversine utility | `lib/utils/distance.ts` (dashboard) | Distance calculation |

### New Integration Required

1. **Shift detail screen**: Add "Mileage" tab to existing shift detail view showing trips for that shift
2. **Home screen navigation**: Add "Mileage" entry in bottom nav or feature menu
3. **Dashboard sidebar**: Add "Mileage" nav item after existing "Reports" section
4. **Clock-out flow**: After successful clock-out, trigger trip detection RPC (fire-and-forget)
5. **Sync service**: When offline GPS points sync, re-trigger trip detection for affected shifts

## Complexity Tracking

No constitution violations. All decisions align with existing patterns and principles.

| Decision | Justification | Simpler Alternative |
|----------|---------------|---------------------|
| Tiered rate structure | CRA requires it | Flat rate — but wouldn't match Canadian tax rules |
| trip_gps_points junction table | Audit trail linking trips to source GPS data | Array column — but loses referential integrity |
| 4 separate migrations | Review isolation | Single migration — harder to review and rollback |
