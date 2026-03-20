# GPS Diagnostics Dashboard — Design Spec

## Overview

Admin-only diagnostic page at `/dashboard/diagnostics` providing real-time monitoring and historical analysis of GPS tracking issues across all employees. Dense single-page layout with KPIs, trend chart, employee ranking, incident feed, and a detail drawer.

## Audience

Admin and super_admin only — technical diagnostic tool. Not visible to supervisors or employees. Both `admin` and `super_admin` roles have access (consistent with existing dashboard access).

## Message Classification

All RPCs and frontend type badges rely on classifying `diagnostic_logs.message` into logical categories. The canonical predicates:

| Category | SQL predicate | Severity |
|----------|--------------|----------|
| **gap** | `message LIKE 'GPS gap detected%'` | warn |
| **service_died** | `message LIKE 'Foreground service died%' OR message LIKE 'Service dead%' OR message LIKE 'Foreground service start failed%' OR message LIKE 'Tracking service error%'` | error |
| **slc** | `message LIKE 'GPS lost — SLC activated%'` | warn |
| **recovery** | `message LIKE 'GPS stream recovered%' OR message LIKE 'GPS restored%'` | info |
| **lifecycle** | All other `event_category = 'gps'` messages | info |

These predicates are used in RPCs (server-side classification) and in frontend badge mapping. The RPCs return a `event_type` field using these category names so the frontend never does message matching.

## Layout

Grid-based dense dashboard. No tabs, no sub-navigation. Everything visible at once.

### Header

- Page title "GPS Diagnostics"
- Auto-refresh indicator (30s cycle, toggleable)
- Filters row:
  - **Date range**: "Aujourd'hui" (default for feed), configurable up to 30 days for stats/chart/ranking
  - **Employee**: dropdown populated from `employee_profiles WHERE status = 'active'`, ordered by `full_name`, showing platform badge (iOS/Android) next to name
  - **Severity**: multi-select (info, warn, error, critical) — default: warn + error

### KPI Cards (6 cards, full width row)

| Card | Metric | Source | Color |
|------|--------|--------|-------|
| Gaps détectés | Count of `gap` events | diagnostic_logs | amber |
| Service died | Count of `service_died` events | diagnostic_logs | red |
| SLC activations | Count of `slc` events | diagnostic_logs | purple |
| Recovery rate | recoveries / (gaps + service_died) as % | diagnostic_logs | green |
| Gap moyen | Median duration of calculated GPS gaps | gps_points LAG() | blue |
| Plus long gap | Max gap duration + employee name + time | gps_points LAG() | red |

**Delta comparison**: Each card shows a comparison vs the previous equivalent period. The comparison period is always the same-length range immediately preceding the selected range. For "Aujourd'hui", compare to yesterday. For March 1-15, compare to February 14-28. The `get_gps_diagnostics_summary` RPC accepts both primary and comparison date ranges and returns both sets of values so the frontend computes deltas client-side.

### Grid Row (2 columns)

**Left (60%) — Trend Chart**

Grouped bar chart showing daily counts over the selected date range:
- Amber bars: GPS gaps detected
- Red bars: Errors (service died, start failed)
- Green bars: Recoveries

Library: recharts (to be added as dependency — `npm install recharts`).

**Right (40%) — Employee Ranking**

Sorted list of employees with the most GPS issues in the selected period. Each row shows:
- Rank number (color-coded: red for top 3, neutral for rest)
- Employee name
- Platform + device model
- Total gaps count
- SLC activations (if iOS)
- Service died count
- Chevron indicator (clickable → opens drawer)

Background color: red tint for top offenders, amber for moderate, neutral for rest.

### Incident Feed (full width, below grid)

Filterable table of GPS diagnostic events. Columns:
- **Heure**: timestamp (HH:mm:ss, monospace)
- **Employé**: full name
- **Événement**: diagnostic message text
- **Type**: badge — GPS gap (amber), Service died (red), SLC (purple), Recovery (green), Lifecycle (gray)
- **Appareil**: device model (short form)
- **Version**: app version (short, e.g., "+146")
- **Sévérité**: badge — info (blue), warn (amber), error (red), critical (red bold)

Default sort: newest first. Default filter: warn + error only (info hidden by default, toggleable via filter badges above the table).

Pagination: cursor-based, load 50 rows per page, "Charger plus" button.

Rows are clickable → opens the drawer with that employee's detail.

### Detail Drawer (right panel)

Slides in from the right when clicking an employee (from ranking) or an incident row (from feed). Does not navigate away from the page.

**Header**: Employee name, close button (✕)

**Device Info Card**: Platform, OS version, app version, battery level. Battery sourced from `SELECT battery_level FROM gps_points WHERE employee_id = ? AND battery_level IS NOT NULL ORDER BY captured_at DESC LIMIT 1`. Display "N/A" if no battery data within last 30 minutes.

**Mini KPI Row (3 cards)**: Service died / GPS gaps / Recoveries counts for this employee in the selected period.

**Calculated GPS Gaps Section**: Real gaps computed from `gps_points` using LAG() window function. Shows:
- Gap duration (bold, color-coded: red >30min, amber >5min)
- Date
- Time range (start → end)

Sorted by duration descending.

**Correlated Events Timeline**: Vertical timeline (left border + dots) showing all `diagnostic_logs` entries for this employee across ALL event_category values (not just GPS — includes doze, thermal, battery, service, lifecycle, crash, memory, satellite, sync, network, etc.). Each entry shows:
- Colored dot by severity (red = error, amber = warn, purple = SLC-specific, blue = info)
- Timestamp
- Message
- Category + severity + metadata highlights (e.g., battery level if present in metadata JSONB)

Sorted chronologically, newest first.

## Data Architecture

### New Supabase RPCs

#### `get_gps_diagnostics_summary(p_start_date, p_end_date, p_compare_start_date, p_compare_end_date, p_employee_id?)`

Returns aggregated KPI data for both primary and comparison periods:
```sql
-- Counts from diagnostic_logs WHERE event_category = 'gps'
-- Classified using message predicates from Message Classification table
-- Gap median/max: JOIN shifts ON clocked_in_at in date range,
--   then LAG(captured_at) OVER (PARTITION BY shift_id ORDER BY captured_at)
--   on gps_points for those shifts only (leverages idx on shift_id, captured_at)
-- Returns both primary and comparison period values
```

Returns:
```typescript
{
  primary: { gaps_count, service_died_count, slc_count, recovery_count, recovery_rate, median_gap_minutes, max_gap_minutes, max_gap_employee_name, max_gap_time },
  comparison: { gaps_count, service_died_count, slc_count, recovery_count, recovery_rate, median_gap_minutes, max_gap_minutes, max_gap_employee_name, max_gap_time }
}
```

#### `get_gps_diagnostics_trend(p_start_date, p_end_date, p_employee_id?)`

Returns daily breakdown for the chart:
```sql
-- Per-day counts from diagnostic_logs WHERE event_category = 'gps'
-- Classified using message predicates
-- date, gaps_count, error_count, recovery_count
```

Returns: array of `{ date, gaps_count, error_count, recovery_count }`

#### `get_gps_diagnostics_ranking(p_start_date, p_end_date)`

Returns employee ranking:
```sql
-- Per-employee aggregation from diagnostic_logs WHERE event_category = 'gps'
-- Classified using message predicates
-- Joined with employee_profiles for name/device info
-- Sorted by total_gaps DESC
```

Returns: array of `{ employee_id, full_name, device_platform, device_model, total_gaps, total_slc, total_service_died, total_recoveries }`

#### `get_gps_diagnostics_feed(p_start_date, p_end_date, p_employee_id?, p_severities?, p_cursor?, p_limit?)`

Returns paginated incident feed with server-side classification:
```sql
-- Query diagnostic_logs WHERE event_category = 'gps'
-- Classify each row using message predicates → event_type field
-- Join employee_profiles for full_name, device_model, device_platform
-- Filter by severity array, employee_id, date range
-- Cursor-based pagination using (created_at, id) for stable ordering
-- Default p_limit = 50
```

Returns: `{ items: array of { id, created_at, employee_id, full_name, device_platform, device_model, message, event_type, severity, app_version, metadata }, next_cursor }`

#### `get_employee_gps_gaps(p_employee_id, p_start_date, p_end_date, p_min_gap_minutes?)`

Calculates real GPS gaps from gps_points using LAG():
```sql
-- Join shifts WHERE employee_id = p_employee_id AND clocked_in_at BETWEEN dates
-- Then LAG(captured_at) OVER (PARTITION BY shift_id ORDER BY captured_at)
--   on gps_points for those shift_ids only
-- Filter where gap > p_min_gap_minutes (default 5)
-- This approach scans only the relevant shifts' GPS points,
--   leveraging the existing index on (shift_id, captured_at DESC)
```

Returns: array of `{ shift_id, gap_start, gap_end, gap_minutes, shift_clocked_in_at }`

#### `get_employee_gps_events(p_employee_id, p_start_date, p_end_date)`

Returns all diagnostic events for one employee across all categories (for drawer timeline):
```sql
-- Query diagnostic_logs WHERE employee_id = p_employee_id
--   AND created_at BETWEEN dates
-- No event_category filter — returns ALL categories
-- Ordered by created_at DESC
-- Limit 200 (enough for drawer context)
```

Returns: array of `{ id, created_at, event_category, severity, message, metadata, app_version }`

### Performance Considerations

- **gps_points LAG() queries**: Always filter through `shifts` first (by employee_id + date range on `clocked_in_at`), then query `gps_points` only for those shift_ids. This leverages the existing composite index `(shift_id, captured_at DESC)` and avoids full-table scans.
- **diagnostic_logs queries**: The table has ~163K rows (Feb-Mar 2026) and grows ~5K-6K rows/day. An index on `(event_category, created_at DESC)` should be added if query times exceed 200ms. For now, the existing indexes should suffice for date-range filtered queries.
- **Summary RPC gap stats**: The median/max gap calculation operates per-shift (PARTITION BY shift_id), not globally. The RPC first identifies shifts in the date range, then computes gaps only for those shifts. This limits the scan.

### Refresh Strategy

- **Feed**: Auto-refresh every 30 seconds via `refetchInterval: 30000`
- **KPIs + Ranking + Chart**: Refresh when date range changes or every 60 seconds
- **Drawer data**: Fetched on open, no auto-refresh (user can close and reopen)

## Dashboard Components

```
dashboard/src/
├── app/dashboard/diagnostics/
│   └── page.tsx                          # Main page
├── components/diagnostics/
│   ├── gps-kpi-cards.tsx                 # 6 KPI cards row
│   ├── gps-trend-chart.tsx               # Recharts grouped bar chart
│   ├── gps-employee-ranking.tsx          # Sorted employee list
│   ├── gps-incident-feed.tsx             # Filterable incident table
│   ├── gps-detail-drawer.tsx             # Right drawer panel
│   ├── gps-employee-detail.tsx           # Drawer content for employee
│   ├── gps-gaps-list.tsx                 # Calculated gaps display
│   ├── gps-correlated-timeline.tsx       # Multi-category event timeline
│   └── gps-severity-badge.tsx            # Reusable severity/type badges
├── lib/hooks/
│   ├── use-gps-diagnostics-summary.ts    # KPI data hook
│   ├── use-gps-diagnostics-trend.ts      # Chart data hook
│   ├── use-gps-diagnostics-ranking.ts    # Employee ranking hook
│   ├── use-gps-diagnostics-feed.ts       # Feed data hook (paginated)
│   ├── use-employee-gps-gaps.ts          # Calculated gaps hook
│   └── use-employee-gps-events.ts        # Correlated events hook
└── types/
    └── gps-diagnostics.ts                # TypeScript interfaces
```

## Navigation

Add entry in sidebar (`sidebar.tsx`) under a new "Diagnostics" section. Icon: `Activity` from lucide-react (pulse/signal icon). Visible to `admin` and `super_admin` roles. Add a `roles?: string[]` field to sidebar navigation items and filter based on the current user's role from the auth provider.

## Empty & Error States

- **KPI cards**: Show `0` with gray coloring and no delta when no data for the period
- **Trend chart**: Show zero-height bars for days with no events; if entire range is empty, show centered "Aucune donnée pour cette période"
- **Employee ranking**: Show "Aucun problème GPS détecté pour cette période" centered
- **Incident feed**: Show "Aucun événement pour les filtres sélectionnés" centered with suggestion to adjust filters
- **Drawer gaps**: Show "Aucun trou GPS détecté" if no gaps above threshold
- **Drawer timeline**: Show "Aucun événement" if no logs
- **RPC errors**: Red alert banner at the top of the page with error message and "Réessayer" button. Individual sections show skeleton placeholders during loading.

## Out of Scope

- Real-time WebSocket subscriptions (polling at 30s is sufficient for diagnostics)
- Map visualization of gap locations (future enhancement)
- Alerting/notifications when GPS issues exceed thresholds
- Export to CSV/PDF
