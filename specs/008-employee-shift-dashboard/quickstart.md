# Quickstart: Employee & Shift Dashboard

**Feature Branch**: `008-employee-shift-dashboard`
**Date**: 2026-01-10

## Prerequisites

- Completed Specs 002-007 (Authentication, Shift Management, GPS Tracking, Offline Resilience, Employee History, Location Permission Guard)
- Flutter 3.x environment configured
- Supabase local or cloud instance running

## Setup Steps

### 1. Add fl_chart Dependency

```yaml
# gps_tracker/pubspec.yaml
dependencies:
  fl_chart: ^1.1.1
```

```bash
cd gps_tracker && flutter pub get
```

### 2. Apply Database Migration

Create migration file: `supabase/migrations/008_employee_dashboard.sql`

```sql
-- GPS Clock-In Tracker: Employee Dashboard Feature
-- Migration: 008_employee_dashboard
-- Date: 2026-01-10

-- Dashboard summary RPC function
CREATE OR REPLACE FUNCTION get_dashboard_summary(
    p_include_recent_shifts BOOLEAN DEFAULT true,
    p_recent_shifts_limit INT DEFAULT 10
)
RETURNS JSONB AS $$
-- [Full implementation from contracts/dashboard-api.md]
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Team employee hours RPC function
CREATE OR REPLACE FUNCTION get_team_employee_hours(
    p_start_date TIMESTAMPTZ DEFAULT NULL,
    p_end_date TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
    employee_id UUID,
    display_name TEXT,
    total_hours DECIMAL
) AS $$
-- [Full implementation from contracts/dashboard-api.md]
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

Apply migration:
```bash
cd supabase && supabase db push
```

### 3. Create Feature Directory Structure

```bash
cd gps_tracker/lib/features
mkdir -p dashboard/{models,providers,services,screens,widgets}
touch dashboard/dashboard.dart
```

### 4. Create Core Models

**lib/features/dashboard/models/dashboard_state.dart**:
```dart
import 'package:flutter/foundation.dart';
import '../../shifts/models/shift.dart';
import '../../history/models/history_statistics.dart';
import '../../shifts/providers/sync_provider.dart';

@immutable
class ShiftStatusInfo {
  final bool isActive;
  final Shift? activeShift;
  final DateTime? lastClockOutAt;

  const ShiftStatusInfo({
    this.isActive = false,
    this.activeShift,
    this.lastClockOutAt,
  });

  Duration get elapsedDuration => isActive && activeShift != null
      ? DateTime.now().difference(activeShift!.clockedInAt)
      : Duration.zero;
}

@immutable
class DailyStatistics {
  final DateTime date;
  final int completedShiftCount;
  final Duration totalDuration;
  final Duration activeShiftDuration;

  const DailyStatistics({
    required this.date,
    this.completedShiftCount = 0,
    this.totalDuration = Duration.zero,
    this.activeShiftDuration = Duration.zero,
  });

  Duration get totalIncludingActive => totalDuration + activeShiftDuration;
}

@immutable
class EmployeeDashboardState {
  final ShiftStatusInfo currentShiftStatus;
  final DailyStatistics todayStats;
  final HistoryStatistics monthlyStats;
  final List<Shift> recentShifts;
  final SyncState syncStatus;
  final DateTime? lastUpdated;
  final bool isLoading;
  final String? error;

  const EmployeeDashboardState({
    this.currentShiftStatus = const ShiftStatusInfo(),
    this.todayStats = const DailyStatistics(date: null),
    this.monthlyStats = HistoryStatistics.empty,
    this.recentShifts = const [],
    this.syncStatus = const SyncState(),
    this.lastUpdated,
    this.isLoading = false,
    this.error,
  });

  EmployeeDashboardState copyWith({
    ShiftStatusInfo? currentShiftStatus,
    DailyStatistics? todayStats,
    HistoryStatistics? monthlyStats,
    List<Shift>? recentShifts,
    SyncState? syncStatus,
    DateTime? lastUpdated,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return EmployeeDashboardState(
      currentShiftStatus: currentShiftStatus ?? this.currentShiftStatus,
      todayStats: todayStats ?? this.todayStats,
      monthlyStats: monthlyStats ?? this.monthlyStats,
      recentShifts: recentShifts ?? this.recentShifts,
      syncStatus: syncStatus ?? this.syncStatus,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}
```

### 5. Create Dashboard Provider

**lib/features/dashboard/providers/dashboard_provider.dart**:
```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/dashboard_state.dart';
import '../services/dashboard_service.dart';

final dashboardServiceProvider = Provider<DashboardService>((ref) {
  return DashboardService(ref);
});

class DashboardNotifier extends StateNotifier<EmployeeDashboardState>
    with WidgetsBindingObserver {
  final Ref _ref;

  DashboardNotifier(this._ref) : super(const EmployeeDashboardState()) {
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      refresh();
    }
  }

  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final service = _ref.read(dashboardServiceProvider);
      final data = await service.loadDashboard();
      state = state.copyWith(
        currentShiftStatus: data.shiftStatus,
        todayStats: data.todayStats,
        monthlyStats: data.monthlyStats,
        recentShifts: data.recentShifts,
        lastUpdated: DateTime.now(),
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> refresh() async => load();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

final dashboardProvider =
    StateNotifierProvider<DashboardNotifier, EmployeeDashboardState>((ref) {
  return DashboardNotifier(ref);
});
```

### 6. Create Dashboard Screen

**lib/features/dashboard/screens/employee_dashboard_screen.dart**:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/dashboard_provider.dart';
import '../widgets/shift_status_tile.dart';
import '../widgets/daily_summary_card.dart';
import '../widgets/monthly_summary_card.dart';
import '../widgets/recent_shifts_list.dart';
import '../widgets/sync_status_badge.dart';

class EmployeeDashboardScreen extends ConsumerWidget {
  const EmployeeDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(dashboardProvider);

    if (state.isLoading && state.recentShifts.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: () => ref.read(dashboardProvider.notifier).refresh(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ShiftStatusTile(status: state.currentShiftStatus),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: DailySummaryCard(stats: state.todayStats)),
              const SizedBox(width: 16),
              Expanded(child: MonthlySummaryCard(stats: state.monthlyStats)),
            ],
          ),
          const SizedBox(height: 16),
          SyncStatusBadge(syncState: state.syncStatus),
          const SizedBox(height: 16),
          const Text('Recent Shifts', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          RecentShiftsList(shifts: state.recentShifts),
        ],
      ),
    );
  }
}
```

### 7. Wire Up Navigation

Update **lib/features/home/home_screen.dart** to show dashboard based on role:
```dart
// In build method, replace body:
body: profileAsync.when(
  data: (profile) => profile?.isManager == true
      ? const _RoleTabView()  // TabBarView for manager
      : const EmployeeDashboardScreen(),
  loading: () => const Center(child: CircularProgressIndicator()),
  error: (_, __) => const EmployeeDashboardScreen(),
),
```

### 8. Test the Feature

```bash
cd gps_tracker
flutter test
flutter run -d ios  # or android
```

## Key Files Reference

| File | Purpose |
|------|---------|
| `lib/features/dashboard/models/dashboard_state.dart` | State models |
| `lib/features/dashboard/providers/dashboard_provider.dart` | Riverpod providers |
| `lib/features/dashboard/services/dashboard_service.dart` | Data fetching |
| `lib/features/dashboard/screens/employee_dashboard_screen.dart` | Employee view |
| `lib/features/dashboard/screens/team_dashboard_screen.dart` | Manager view |
| `lib/features/dashboard/widgets/live_shift_timer.dart` | 1-second timer |
| `supabase/migrations/008_employee_dashboard.sql` | RPC functions |

## Verification Checklist

- [ ] Dashboard loads within 2 seconds (SC-001)
- [ ] Live timer updates every second without lag (SC-002)
- [ ] Shift status visible within 3 seconds (SC-003)
- [ ] Manager can find employee in 10 seconds (SC-004)
- [ ] Cached data displays when offline (SC-005)
- [ ] Dashboard refreshes on foreground within 3 seconds (SC-006)
- [ ] Navigation to detail views completes in 1 second (SC-007)
- [ ] Summary matches detailed view data (SC-008)
