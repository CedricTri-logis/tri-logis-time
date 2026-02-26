# Tasks: Route Map Matching & Real Route Visualization

**Input**: Design documents from `/specs/018-route-map-matching/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: Not explicitly requested — test tasks omitted.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Mobile**: `gps_tracker/lib/` (Flutter)
- **Dashboard**: `dashboard/src/` (Next.js)
- **Backend**: `supabase/migrations/`, `supabase/functions/` (Supabase)
- **Shared utils**: `gps_tracker/lib/shared/utils/`, `dashboard/src/lib/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Database schema changes and OSRM infrastructure

- [X] T001 Create migration `supabase/migrations/043_route_map_matching.sql` — add `route_geometry TEXT`, `road_distance_km DECIMAL(8,3)`, `match_status TEXT` (pending/processing/matched/failed/anomalous), `match_confidence DECIMAL(3,2)`, `match_error TEXT`, `matched_at TIMESTAMPTZ`, `match_attempts INTEGER` columns to `trips` table; add `idx_trips_match_status` index; create `update_trip_match()` SECURITY DEFINER RPC per data-model.md
- [X] T002 Apply migration 043 to local Supabase and verify columns exist on `trips` table with `SELECT column_name FROM information_schema.columns WHERE table_name = 'trips'`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core utilities and model updates that ALL user stories depend on

**CRITICAL**: No user story work can begin until this phase is complete

- [X] T003 [P] Create polyline6 decoder utility in `gps_tracker/lib/shared/utils/polyline_decoder.dart` — implement `decodePolyline6(String encoded)` returning `List<LatLng>` using the Google encoded polyline algorithm with precision=6; include `combinePolylines(List<String>)` for multi-segment routes
- [X] T004 [P] Create polyline6 decoder utility in `dashboard/src/lib/polyline.ts` — implement `decodePolyline6(encoded: string): [number, number][]` returning lat/lng pairs; include `combinePolylines(encodedList: string[]): [number, number][]` for multi-segment routes
- [X] T005 [P] Update Trip model in `gps_tracker/lib/features/mileage/models/trip.dart` — add fields: `routeGeometry` (String?), `roadDistanceKm` (double?), `matchStatus` (String, default 'pending'), `matchConfidence` (double?), `matchError` (String?), `matchedAt` (DateTime?), `matchAttempts` (int, default 0); add computed getters: `isRouteMatched`, `isRouteEstimated`, `isMatchPending`, `isMatchFailed`, `isMatchAnomalous`, `canRetryMatch`, `effectiveDistanceKm`; update `fromJson`/`toJson`/`copyWith`
- [X] T006 [P] Update LocalTrip model in `gps_tracker/lib/features/mileage/models/local_trip.dart` — add fields: `routeGeometry` (String?), `roadDistanceKm` (double?), `matchStatus` (String), `matchConfidence` (double?); update `toTrip()`/`fromTrip()` conversions and `toMap()`/`fromMap()` serialization
- [X] T007 Update MileageLocalDb in `gps_tracker/lib/features/mileage/services/mileage_local_db.dart` — add `route_geometry TEXT`, `road_distance_km REAL`, `match_status TEXT DEFAULT 'pending'`, `match_confidence REAL` columns to `local_trips` table creation; handle schema migration for existing local databases (add columns if not exist)
- [X] T008 [P] Update Trip type in `dashboard/src/types/trip.ts` — add fields: `route_geometry: string | null`, `road_distance_km: number | null`, `match_status: 'pending' | 'processing' | 'matched' | 'failed' | 'anomalous'`, `match_confidence: number | null`, `match_error: string | null`, `matched_at: string | null`, `match_attempts: number`
- [X] T009 Create RouteMatchService in `gps_tracker/lib/features/mileage/services/route_match_service.dart` — implement `matchTrip(String tripId)` that invokes the `match-trip-route` Supabase Edge Function via `Supabase.instance.client.functions.invoke('match-trip-route', body: {'trip_id': tripId})`; implement `matchTripsForShift(String shiftId)` that calls matchTrip for each trip sequentially; handle errors gracefully (log via DiagnosticLogger, don't throw); add `routeMatchServiceProvider` Riverpod provider

**Checkpoint**: Foundation ready — user story implementation can now begin

---

## Phase 3: User Story 1 — Accurate Road-Based Mileage (Priority: P1) MVP

**Goal**: Automatically match GPS traces to roads and calculate accurate road-based distance, replacing the Haversine × 1.3 estimate

**Independent Test**: Complete a shift with GPS data along a known route, detect trips, trigger matching, and verify `distance_km` is updated to a road-based value within 10% of actual driving distance

### Implementation for User Story 1

- [X] T010 [US1] Create `match-trip-route` Edge Function in `supabase/functions/match-trip-route/index.ts` — implement per contracts/match-trip-route.md: fetch trip + GPS points from Supabase via service role, validate (min 3 points, max 3 attempts), simplify trace if >100 points, call OSRM Match API at `OSRM_BASE_URL/match/v1/driving/{coords}?timestamps=...&radiuses=...&geometries=polyline6&overview=full&gaps=split`, validate response (anomaly check >3× haversine, confidence ≥0.3, ≥50% points matched), combine multiple matchings if gaps=split produced them, call `update_trip_match` RPC to store results; include CORS headers for dashboard calls
- [X] T011 [US1] Integrate route matching into TripService in `gps_tracker/lib/features/mileage/services/trip_service.dart` — after `detectTrips(shiftId)` returns trips, call `routeMatchService.matchTripsForShift(shiftId)` asynchronously (fire-and-forget, do not block trip detection result); add `refreshTrip(tripId)` method that re-fetches a single trip from Supabase to get updated match results
- [X] T012 [US1] Update trip providers in `gps_tracker/lib/features/mileage/providers/` — ensure `tripsForShiftProvider` and `tripsForPeriodProvider` include the new route matching columns in their Supabase select queries; ensure trip list refreshes when match results arrive (invalidate provider after matching completes)

**Checkpoint**: At this point, trips automatically get road-based distances after shift completion. distance_km is updated when matching succeeds, mileage summary and reimbursement calculations automatically use the improved distance.

---

## Phase 4: User Story 2 — Real Route Displayed on Map (Priority: P1)

**Goal**: Display the matched road route as a smooth polyline on the trip detail map, following actual streets instead of straight lines between GPS dots

**Independent Test**: Open a trip detail screen for a matched trip and verify the route line follows real streets on the map (curves around blocks, follows highways)

### Implementation for User Story 2

- [X] T013 [US2] Update TripRouteMap widget in `gps_tracker/lib/features/mileage/widgets/trip_route_map.dart` — when `trip.isRouteMatched` and `trip.routeGeometry` is not null, decode the polyline6 string using `decodePolyline6()` from `polyline_decoder.dart` and render as solid `Polyline` (width 4, primary color); when trip is not matched, keep existing behavior (dashed line between start/end, or straight lines through GPS points if `routePoints` provided)
- [X] T014 [US2] Update TripDetailScreen in `gps_tracker/lib/features/mileage/screens/trip_detail_screen.dart` — pass `trip.routeGeometry` decoded points to TripRouteMap when available; show the road-based distance (`trip.effectiveDistanceKm`) in the metrics section; add a small info text below the map: "Route vérifié par GPS" when matched, "Trajet estimé" when not matched

**Checkpoint**: At this point, matched trips show real road routes on their detail maps, unmatched trips gracefully fall back to existing behavior

---

## Phase 5: User Story 3 — Route Matching Status Indicator (Priority: P2)

**Goal**: Show employees whether each trip's distance is verified (road-matched) or estimated (Haversine fallback) via visual indicators on trip cards

**Independent Test**: View the mileage list — matched trips show a green "Vérifié" badge, pending/failed trips show an orange "Estimé" badge

### Implementation for User Story 3

- [X] T015 [P] [US3] Create MatchStatusBadge widget in `gps_tracker/lib/features/mileage/widgets/match_status_badge.dart` — display a compact badge: matched → green chip with checkmark icon and "Vérifié", pending/processing → orange chip with clock icon and "En cours", failed → orange chip with info icon and "Estimé", anomalous → red chip with warning icon and "À vérifier"; accept `Trip` and render based on `trip.matchStatus`
- [X] T016 [US3] Update TripCard widget in `gps_tracker/lib/features/mileage/widgets/trip_card.dart` — add `MatchStatusBadge` to each trip card, positioned next to the distance text; ensure it doesn't overflow on narrow screens (use `Flexible` or `Expanded` as needed)
- [X] T017 [US3] Update TripDetailScreen in `gps_tracker/lib/features/mileage/screens/trip_detail_screen.dart` — add a prominent MatchStatusBadge in the header/metrics area; when `trip.isMatchFailed && trip.canRetryMatch`, show a "Réessayer" button that calls `routeMatchService.matchTrip(trip.id)` and refreshes the trip data

**Checkpoint**: At this point, employees can instantly see whether each trip's distance is verified or estimated in both the list and detail views

---

## Phase 6: User Story 4 — Shift Detail Shows Real Routes (Priority: P2)

**Goal**: Display all matched trip routes on shift detail maps with distinct colors per trip, in both the Flutter app and the dashboard

**Independent Test**: View a shift with 2+ matched trips — each trip's route appears in a different color on the map

### Implementation for User Story 4

- [X] T018 [P] [US4] Create trip route map component in `dashboard/src/components/trips/trip-route-map.tsx` — Leaflet map using react-leaflet that accepts an array of trips, decodes each trip's `route_geometry` using `decodePolyline6()` from `dashboard/src/lib/polyline.ts`, renders each trip as a `Polyline` with a distinct color from a palette; unmatched trips render as dashed lines between start/end coordinates; include start (green) and end (red) circle markers; auto-fit bounds to all routes
- [X] T019 [P] [US4] Create MatchStatusBadge component in `dashboard/src/components/trips/match-status-badge.tsx` — shadcn/ui Badge component: matched → green "Verified", pending → yellow "Pending", failed → gray "Estimated", anomalous → red "Anomalous"; accept `match_status` prop
- [X] T020 [US4] Update GpsTrailMap in `dashboard/src/components/monitoring/gps-trail-map.tsx` — add optional `trips` prop (array of Trip objects with route_geometry); when trips are provided, overlay matched routes on the existing GPS trail using distinct colors; matched routes render as solid polylines, unmatched as dashed
- [X] T021 [US4] Update shift detail map in Flutter app — in the shift history/detail screen (if it shows a map with GPS points), overlay matched trip routes from the shift's trips; use a color palette to distinguish trips (blue, green, purple, orange); matched trips render as solid polylines, unmatched as dashed lines between start/end points

**Checkpoint**: At this point, shift-level map views show complete route picture with distinct trip routes in both mobile app and dashboard

---

## Phase 7: User Story 5 — Re-Process Historical Trips (Priority: P3)

**Goal**: Allow administrators to batch re-process historical trips through route matching to retroactively correct distances and add route geometry

**Independent Test**: Trigger batch re-processing from the dashboard and confirm that pending/failed trips are updated with road-based distances

### Implementation for User Story 5

- [X] T022 [US5] Create `batch-match-trips` Edge Function in `supabase/functions/batch-match-trips/index.ts` — implement per contracts/batch-match-trips.md: accept `trip_ids`, `shift_id`, `reprocess_failed`, or `reprocess_all` params; resolve trip IDs from Supabase; process each trip sequentially using same OSRM matching logic as match-trip-route (extract shared matching logic into a helper module `supabase/functions/_shared/osrm-matcher.ts`); add 200ms delay between OSRM calls; return structured summary with counts (processed, matched, failed, anomalous, skipped) and per-trip results; enforce max 500 trips per request
- [X] T023 [US5] Extract shared OSRM matching logic into `supabase/functions/_shared/osrm-matcher.ts` — move the core matching logic (fetch GPS points, call OSRM, validate response, store results) from match-trip-route into a shared module; refactor match-trip-route to use this shared module; batch-match-trips also uses this shared module
- [X] T024 [US5] Add batch re-process UI in dashboard — add a "Re-process routes" button in the appropriate admin/reports section; on click, call the `batch-match-trips` Edge Function with `reprocess_failed: true`; show a progress dialog with the returned summary (matched, failed, anomalous counts); use shadcn/ui Dialog and Button components

**Checkpoint**: At this point, historical trips can be retroactively matched to improve data accuracy

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Edge case handling, error resilience, and cleanup

- [X] T025 Handle edge cases in match-trip-route Edge Function — ensure graceful handling of: trips with <3 GPS points (fail with INSUFFICIENT_POINTS), OSRM server unavailable (fail with OSRM_UNAVAILABLE, preserve Haversine distance), GPS points with no nearby roads (accept partial match or fail gracefully), large time gaps >5min between points (gaps=split handles this), impossible results >3× haversine (flag as anomalous)
- [X] T026 Add retry logic in RouteMatchService `gps_tracker/lib/features/mileage/services/route_match_service.dart` — when matchTrip returns a failed status and `canRetryMatch` is true, schedule a retry with exponential backoff (30s, 120s); integrate with DiagnosticLogger to log matching outcomes (info: matched, warn: failed, error: anomalous)
- [X] T027 Update mileage PDF report in `gps_tracker/lib/features/mileage/services/mileage_report_service.dart` — add a "Source" column to the PDF report table showing "GPS" for matched trips and "Est." for estimated trips; distance values automatically reflect road-based distances (no change needed since `distance_km` is already updated)
- [X] T028 Run quickstart.md validation — follow the steps in `specs/018-route-map-matching/quickstart.md` to verify end-to-end flow: OSRM setup, migration applied, Edge Function deployed, trip detection → route matching → map display

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 (migration must be applied) — BLOCKS all user stories
- **User Stories (Phase 3+)**: All depend on Foundational phase completion
  - US1 (P1) and US2 (P1) can proceed in parallel after Foundation
  - US3 (P2) can start after Foundation (independent of US1/US2 but more meaningful after)
  - US4 (P2) can start after Foundation (uses polyline decoder from Foundation)
  - US5 (P3) depends on US1 (reuses matching logic from match-trip-route Edge Function)
- **Polish (Phase 8)**: Can start after US1 is complete

### User Story Dependencies

- **US1 (P1)**: Can start after Foundational (Phase 2) — no dependencies on other stories
- **US2 (P1)**: Can start after Foundational (Phase 2) — independent of US1 (uses route_geometry field which may be null)
- **US3 (P2)**: Can start after Foundational (Phase 2) — independent (uses match_status field)
- **US4 (P2)**: Can start after Foundational (Phase 2) — independent (uses route_geometry + match_status)
- **US5 (P3)**: Depends on US1 completion (T023 extracts shared logic from T010)

### Within Each User Story

- Models before services (already in Foundation)
- Services before UI components
- Core implementation before integration

### Parallel Opportunities

- All Foundational tasks marked [P] can run in parallel (T003, T004, T005, T006, T008)
- After Foundation: US1, US2, US3, US4 can all start in parallel
- Within US4: T018, T019 can run in parallel (different frameworks/files)
- T025, T026, T027 in Polish phase can all run in parallel

---

## Parallel Example: Foundational Phase

```bash
# Launch all independent foundational tasks together:
Task: "Create polyline6 decoder in gps_tracker/lib/shared/utils/polyline_decoder.dart"
Task: "Create polyline6 decoder in dashboard/src/lib/polyline.ts"
Task: "Update Trip model in gps_tracker/lib/features/mileage/models/trip.dart"
Task: "Update LocalTrip model in gps_tracker/lib/features/mileage/models/local_trip.dart"
Task: "Update Trip type in dashboard/src/types/trip.ts"
```

## Parallel Example: User Stories After Foundation

```bash
# US1 and US2 can run in parallel:
Task: "Create match-trip-route Edge Function in supabase/functions/match-trip-route/index.ts"  # US1
Task: "Update TripRouteMap to render matched polyline in gps_tracker/lib/features/mileage/widgets/trip_route_map.dart"  # US2

# US3 and US4 dashboard work can run in parallel:
Task: "Create MatchStatusBadge widget in gps_tracker/lib/features/mileage/widgets/match_status_badge.dart"  # US3
Task: "Create trip route map component in dashboard/src/components/trips/trip-route-map.tsx"  # US4
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (migration 043)
2. Complete Phase 2: Foundational (models, decoders, services)
3. Complete Phase 3: User Story 1 (Edge Function + TripService integration)
4. **STOP and VALIDATE**: Trigger matching for a real trip, verify road distance replaces Haversine
5. Deploy Edge Function + migration if ready

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add US1 → Road-based distances working → Deploy (MVP!)
3. Add US2 → Routes visible on trip maps → Deploy
4. Add US3 → Status badges on trip cards → Deploy
5. Add US4 → Shift-level route maps → Deploy
6. Add US5 → Historical batch re-processing → Deploy
7. Each story adds visible value without breaking previous stories

### Parallel Team Strategy

With multiple developers:

1. Team completes Setup + Foundational together
2. Once Foundational is done:
   - Developer A: US1 (Edge Function + backend integration)
   - Developer B: US2 + US3 (Flutter UI — map + badges)
   - Developer C: US4 (Dashboard components)
3. After US1 complete: Developer A → US5 (batch processing)
4. Stories complete and integrate independently

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- OSRM Docker container must be running for Edge Function testing (see quickstart.md)
- Edge Functions require `OSRM_BASE_URL` secret set in Supabase
- Migration 043 sets existing trips to `match_status = 'pending'` automatically
- `distance_km` is updated in-place when matching succeeds — no changes needed to `get_mileage_summary` or reimbursement calculations
