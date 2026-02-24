# Quickstart: 017-mileage-tracking

## What This Feature Does

Adds **automatic mileage tracking for employee reimbursement** to the Tri-Logis Clock app. The system detects vehicle trips from existing background GPS points, calculates distances, and lets employees generate reimbursement reports. This provides a direct, tangible employee benefit from background location — resolving the Apple App Store rejection under Guideline 2.5.4.

## Why It Matters

Apple rejected the app because background location was used *only* for employer tracking. This feature flips the narrative: background location now **helps employees get paid for their driving**. Mileage tracking apps (MileIQ, Everlance, TripLog) are routinely approved with "Always" location because they provide clear user benefit.

## Key Design Decisions

1. **No additional GPS collection** — trip detection runs on existing `gps_points` from spec 004. Zero extra battery impact.
2. **Server-side trip detection** — runs as a Supabase Edge Function after GPS sync for consistency.
3. **CRA/ARC default rate** — Canadian standard mileage rate, customizable per organization.
4. **Business/personal classification** — employees can reclassify trips, only business trips count for reimbursement.
5. **PDF reports** — reusable `pdf` package from spec 006, shareable via system share sheet.

## Scope

### In Scope
- Automatic trip detection from GPS points (speed-based segmentation)
- Trip distance calculation (Haversine + smoothing + correction factor)
- Mileage summary per shift, per period
- Reimbursement PDF report generation (employee self-service)
- Trip classification (business/personal)
- Manager mileage dashboard tab
- Team mileage export (CSV/PDF)
- Reimbursement rate configuration (admin)
- Offline trip caching

### Out of Scope
- Real-time turn-by-turn navigation
- Integration with accounting/payroll software (future spec)
- Multi-vehicle tracking per employee
- Fuel cost calculation
- Tax filing or tax advice
- Route optimization suggestions

## Dependencies

| Spec | Status | Dependency Type |
|------|--------|----------------|
| 004 (Background GPS) | Implemented | **Required** — provides GPS points |
| 005 (Offline Resilience) | Implemented | **Required** — ensures GPS data syncs |
| 009 (Dashboard Foundation) | Implemented | **Required** — manager dashboard shell |
| 013 (Reports & Export) | Implemented | Beneficial — reuse export patterns |
| 015 (Location Geofences) | Implemented | Beneficial — auto-label trip endpoints |

## Getting Started with Speckit

To continue developing this spec:

```bash
# Clarify any open questions
/speckit.clarify

# Generate implementation plan
/speckit.plan

# Generate tasks
/speckit.tasks

# Analyze consistency
/speckit.analyze

# Execute implementation
/speckit.implement
```
