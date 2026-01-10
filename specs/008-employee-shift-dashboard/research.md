# Research: Employee & Shift Dashboard

**Feature Branch**: `008-employee-shift-dashboard`
**Date**: 2026-01-10

## Research Topics

### 1. Bar Chart Visualization Library

**Decision**: Use `fl_chart` package version 1.1.1

**Rationale**:
- **Flutter 3.x Compatibility**: Requires Dart >=3.6.0, Flutter >=3.0.0 (matches project requirements)
- **Minimal Dependencies**: Only 3 lightweight deps (equatable, vector_math, flutter core)
- **Horizontal Bar Charts**: Supported via `rotationQuarterTurns: 1` in BarChartData
- **Performance**: Optimized for 10-50 data points (up to hundreds with no optimization needed)
- **Offline-Compatible**: Pure UI library with zero network dependencies
- **Active Maintenance**: 862,000+ downloads, verified publisher

**Alternatives Considered**:
- Syncfusion charts: Heavier dependencies, doesn't align with lightweight offline-first approach
- Native Flutter charts: No built-in horizontal bar chart support

**Implementation Notes**:
```dart
BarChart(
  BarChartData(
    rotationQuarterTurns: 1,  // Horizontal layout
    barGroups: employeeHoursData,
    groupsSpace: 12,
    barTouchData: BarTouchData(enabled: true),
  ),
)
```

---

### 2. Live Timer Implementation

**Decision**: Reuse existing Timer-based pattern from `shift_timer.dart`

**Rationale**:
- **Timer vs Stream**: Timer is better for 1-second updates—lower memory (1 object vs StreamController), simpler lifecycle
- **Drift Prevention**: Calculate from server timestamp, not accumulated value: `DateTime.now().difference(activeShift.clockedInAt)`
- **App Lifecycle**: Use `WidgetsBindingObserver.didChangeAppLifecycleState` for resume recalculation
- **Battery Impact**: ~0.1% battery/hour for timer, 2-5% for UI redraws (same as app being open)

**Existing Pattern Analysis** (shift_timer.dart):
- Proper Timer cleanup in dispose()
- WidgetsBindingObserver mixin for lifecycle handling
- Timestamp-based elapsed time calculation (drift-proof)
- O(1) calculations per tick
- Low memory: 1 Timer object, no streams

**Riverpod Integration**:
```dart
// Pattern: Read global state in timer, use local widget state for UI
void _recalculateElapsed() {
  final activeShift = ref.read(shiftProvider).activeShift;
  setState(() { _elapsed = DateTime.now().difference(activeShift.clockedInAt); });
}
```

---

### 3. Dashboard Caching Strategy

**Decision**: Extend existing SQLCipher local database with dashboard cache table

**Rationale**:
- Follows established singleton pattern from `sync_metadata`
- Integrates with existing sync infrastructure
- Uses proven timestamp-based staleness checking

**Existing Patterns to Reuse**:

| Pattern | Source | Application |
|---------|--------|-------------|
| Singleton table | sync_metadata | Dashboard state persistence |
| StateNotifierProvider | sync_provider.dart | Dashboard Riverpod state |
| Timestamp staleness | StorageMetrics | "Last updated" display |
| Periodic refresh | storage_monitor (30 min) | Dashboard auto-refresh |

**Database Table Design**:
```sql
CREATE TABLE IF NOT EXISTS dashboard_cache (
  id TEXT PRIMARY KEY DEFAULT 'singleton',
  employee_id TEXT NOT NULL,
  cached_data TEXT,                    -- JSON blob of dashboard state
  last_updated TEXT,                   -- ISO8601 UTC timestamp
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX idx_dashboard_cache_employee ON dashboard_cache(employee_id);
```

**Cache Invalidation Strategy**:
- Refresh on app foreground resume
- Refresh after successful sync
- Manual pull-to-refresh
- Cache TTL: 7 days (matches display window per spec)

---

### 4. Foreground Refresh Patterns

**Decision**: Use `WidgetsBindingObserver` with `AppLifecycleState.resumed`

**Rationale**:
- Already used throughout codebase (shift_timer.dart, permission_monitor_service)
- No additional dependencies required
- Platform-agnostic (iOS and Android)

**Implementation Pattern**:
```dart
class DashboardNotifier extends StateNotifier<DashboardState>
    with WidgetsBindingObserver {

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      refresh(); // Refresh within 3 seconds per SC-006
    }
  }
}
```

**Refresh Timing Requirements** (from spec):
- SC-001: Dashboard loads <2 seconds
- SC-006: Auto-refresh on foreground within 3 seconds

---

### 5. Team Dashboard Search/Filter

**Decision**: Client-side filtering using existing pattern from supervised_employees_provider

**Rationale**:
- Already implemented in `filterBySearch()` method
- Works offline (no network required)
- Handles up to ~100 employees efficiently
- Matches existing user experience

**Existing Implementation**:
```dart
List<EmployeeSummary> filterBySearch(String query) {
  if (query.isEmpty) return state.employees;
  final lowerQuery = query.toLowerCase();
  return state.employees.where((employee) {
    return employee.displayName.toLowerCase().contains(lowerQuery) ||
        (employee.employeeId?.toLowerCase().contains(lowerQuery) ?? false) ||
        employee.email.toLowerCase().contains(lowerQuery);
  }).toList();
}
```

---

### 6. Date Range Presets

**Decision**: Custom DateRangePicker widget with preset buttons

**Rationale**:
- Spec requires: Today, This Week, This Month, Custom Range
- Material DateRangePicker handles custom selection
- Presets can be computed from `DateTime.now()`

**Preset Calculations**:
```dart
// Today: midnight to now
final today = DateTimeRange(
  start: DateTime.now().copyWith(hour: 0, minute: 0, second: 0),
  end: DateTime.now(),
);

// This Week: Monday midnight to now
final weekStart = DateTime.now().subtract(Duration(days: DateTime.now().weekday - 1));
final thisWeek = DateTimeRange(
  start: weekStart.copyWith(hour: 0, minute: 0, second: 0),
  end: DateTime.now(),
);

// This Month: 1st of month to now
final thisMonth = DateTimeRange(
  start: DateTime(DateTime.now().year, DateTime.now().month, 1),
  end: DateTime.now(),
);
```

---

## Existing Infrastructure Reuse

### RPC Functions Already Available

| Function | Purpose | Used For |
|----------|---------|----------|
| `get_supervised_employees()` | List employees with monthly stats | Team dashboard |
| `get_employee_statistics()` | Employee shift aggregates | Statistics cards |
| `get_team_statistics()` | Team aggregate metrics | Team statistics |
| `get_employee_shifts()` | Paginated shift history | Recent shifts list |

### Existing Models to Reuse

| Model | Location | Dashboard Use |
|-------|----------|---------------|
| `EmployeeSummary` | history/models | Team employee list |
| `HistoryStatistics` | history/models | Personal stats |
| `TeamStatistics` | history/models | Team aggregate stats |
| `Shift` | shifts/models | Active shift, recent history |
| `SyncState` | shifts/providers | Sync status display |

### Existing Widgets to Reuse/Extend

| Widget | Location | Dashboard Use |
|--------|----------|---------------|
| `ShiftTimer` | shifts/widgets | Live timer (extend) |
| `SyncStatusIndicator` | shifts/widgets | Sync badge |
| `ShiftCard` | shifts/widgets | Recent shifts list |
| `StatisticsCard` | history/widgets | Stats display |

---

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| fl_chart version compatibility | Pin to 1.1.1, test on both platforms |
| Timer drift on long shifts | Already mitigated by timestamp-based calculation |
| Large team lists (100+ employees) | Client-side filtering is O(n), acceptable for 100 |
| Cache staleness confusion | Clear "Last updated" timestamp, pull-to-refresh |

---

## Unknowns Resolved

All NEEDS CLARIFICATION items from Technical Context have been resolved:

1. **Chart Library**: fl_chart 1.1.1 (confirmed compatible)
2. **Timer Pattern**: Existing shift_timer.dart pattern (proven)
3. **Cache Strategy**: Extend local_database.dart with singleton pattern (established)
4. **Refresh Pattern**: WidgetsBindingObserver (already in use)
5. **Search/Filter**: Client-side from supervised_employees_provider (implemented)
