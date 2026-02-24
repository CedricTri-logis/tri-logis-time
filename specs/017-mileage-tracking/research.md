# Research: Mileage Tracking for Reimbursement

## Apple App Store Rejection Context

### Rejection Details
- **Submission ID**: 6af8ffa6-a3cc-4bef-9d27-58ba11cf48de
- **Review Date**: February 22, 2026
- **Review Device**: iPad Air 11-inch (M3)
- **Version Reviewed**: 1.0
- **Guideline**: 2.5.4 - Performance - Software Requirements
- **Issue**: App declares `UIBackgroundModes: location` but the only feature using it is employee tracking, which Apple considers insufficient for public App Store distribution.

### Apple's Exact Feedback
> "The app declares support for location in the UIBackgroundModes key in your Info.plist file but we are unable to locate any features besides employee tracking that require persistent location. Using the location background mode for the sole purpose of tracking employees is not appropriate."

### Apple's Suggestions
1. Add a feature **besides employee tracking** that requires persistent background location
2. OR use alternative distribution (Apple Business Manager, Custom Apps, Enterprise)

### Strategy: Add Employee-Facing Mileage Tracking

Rather than switching to enterprise/custom distribution (which limits reach and adds complexity), we add **mileage tracking for reimbursement** — a feature that:

1. **Requires background location** — must track movement continuously to detect trips accurately
2. **Directly benefits the employee** — saves time on manual logging, ensures accurate reimbursement
3. **Is a standard app category** — many apps (MileIQ, Everlance, TripLog) use background location for mileage tracking and are approved on the App Store
4. **Leverages existing infrastructure** — uses GPS points already being collected (spec 004), so minimal additional battery impact

## CRA/ARC Automobile Allowance Rates (2026)

Source: Canada Revenue Agency / Agence du revenu du Canada

| Tier | Rate |
|------|------|
| First 5,000 km | $0.72/km |
| Each additional km | $0.66/km |
| Northern Canada supplement | +$0.04/km |

Note: Rates for Quebec provincial deductions may differ slightly. The app should clearly state the rate source and allow customization.

## Trip Detection Algorithm (Research)

### Speed-Based Segmentation
- **Stationary**: Speed < 5 km/h — employee at a location
- **Walking/on-site**: 5-15 km/h — movement but not vehicle travel
- **Vehicle travel**: > 15 km/h sustained for > 2 minutes — trip detected
- **Trip end**: Speed drops below 5 km/h for > 3 minutes

### Distance Calculation
- **Haversine formula** for point-to-point distance on GPS coordinates
- **Cumulative distance** = sum of all point-to-point segments during a trip
- **Smoothing**: Remove GPS outliers (points with accuracy > 200m or impossible speed jumps > 200 km/h)

### Challenges with 5-Minute GPS Intervals
- At 5-minute intervals, a vehicle traveling 60 km/h covers ~5 km between points
- Trip detection may miss very short trips (< 5 minutes)
- Distance calculation will underestimate actual driving distance (straight-line between points vs. road distance)
- **Mitigation**: Apply a road-distance correction factor (~1.3x straight-line distance based on industry studies)

## Competitive Analysis

### MileIQ (Microsoft)
- Automatic trip detection via background location
- Swipe to classify business/personal
- IRS-compliant reports
- Uses "Always" location — approved on App Store

### Everlance
- Automatic mileage tracking
- Expense tracking integration
- Business/personal classification
- Uses "Always" location — approved on App Store

### TripLog
- GPS-based mileage tracking
- Multiple vehicle support
- CRA-compliant reports (Canada)
- Uses "Always" location — approved on App Store

**Key takeaway**: All major mileage tracking apps use "Always" location and are approved. Apple's issue is not with background location for mileage — it's with background location used *only* for employer surveillance.

## Existing Codebase Assets to Reuse

| Asset | Source Spec | Reuse For |
|-------|------------|-----------|
| `gps_points` table + sync | 004, 005 | Input data for trip detection |
| `google_maps_flutter` | 006 | Display trip routes on map |
| `pdf` package | 006 | Generate mileage PDF reports |
| `csv` package | 006 | CSV export for team mileage |
| Dashboard framework | 009-013 | Manager mileage tab |
| `locations` table | 015 | Auto-label trip endpoints |
| Export infrastructure | 013 | Team mileage CSV/PDF export |
| RLS patterns | All | Secure trip data access |
