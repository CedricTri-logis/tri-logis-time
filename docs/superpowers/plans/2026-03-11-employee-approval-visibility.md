# Employee Approval Visibility — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let employees see their approval status (approved/rejected/pending), activity breakdown by location, and OSRM trip routes directly in the Flutter app's ShiftHistory → ShiftDetail flow.

**Architecture:** Enrich the existing ShiftHistoryScreen and ShiftDetailScreen with approval data fetched live from Supabase. No new tables or local cache. New Riverpod providers call existing RPCs (`get_day_approval_detail`) and query `day_approvals` directly (RLS already allows employee SELECT own). New model + widgets display activities grouped by location with status badges.

**Tech Stack:** Dart/Flutter, flutter_riverpod, supabase_flutter, flutter_map (existing), latlong2 (existing)

---

## File Structure

```
lib/features/shifts/
├── models/
│   └── day_approval.dart              # NEW — DayApproval + Activity models
├── providers/
│   └── approval_provider.dart         # NEW — Riverpod providers for approval data
├── widgets/
│   ├── shift_card.dart                # MODIFY — add approval badge
│   ├── approval_summary_card.dart     # NEW — header with approved/rejected hours
│   ├── location_breakdown_card.dart   # NEW — grouped hours by location
│   ├── activity_timeline.dart         # NEW — scrollable activity list with status badges
│   └── trip_routes_map.dart           # NEW — interactive OSRM trip map with tap-to-popup
└── screens/
    ├── shift_history_screen.dart      # MODIFY — pass approval data to ShiftCard
    └── shift_detail_screen.dart       # MODIFY — add approval sections + pull-to-refresh
```

---

## Task 0: Verify RPC Access for Employees (FIRST — blocks Task 2)

**Files:**
- Potentially create: `supabase/migrations/XXX_employee_approval_rpc_access.sql`
- Potentially modify: `gps_tracker/lib/features/shifts/providers/approval_provider.dart` (if wrapper needed)

**Dependencies:** None

This task MUST run first. The employee must be able to call `get_day_approval_detail` with their own ID. The base function `_get_day_approval_detail_base` is `SECURITY DEFINER`, but the wrapper `get_day_approval_detail` may have an admin check.

- [ ] **Step 1: Check if get_day_approval_detail has admin guard**

Run via Supabase MCP `execute_sql`:
```sql
SELECT prosrc FROM pg_proc WHERE proname = 'get_day_approval_detail';
```

Look for `is_admin_or_super_admin` or similar guard. If found, we need an employee-safe wrapper.

- [ ] **Step 2: If admin guard exists, create employee wrapper RPC**

Only if needed — create a migration:

```sql
-- Employee-safe wrapper: uses auth.uid() so employee can only see own data
CREATE OR REPLACE FUNCTION get_my_day_approval_detail(p_date DATE)
RETURNS JSONB AS $$
BEGIN
    RETURN _get_day_approval_detail_base(auth.uid(), p_date);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

If this migration is created, note it for Task 2 — the provider will call `get_my_day_approval_detail` instead of `get_day_approval_detail`.

- [ ] **Step 3: If NO admin guard, no migration needed — proceed to Task 1**

- [ ] **Step 4: Commit (only if migration was needed)**

```bash
git add supabase/migrations/XXX_employee_approval_rpc_access.sql
git commit -m "feat: add employee-safe RPC wrapper for approval detail"
```

---

## Task 1: DayApproval Model

**Files:**
- Create: `gps_tracker/lib/features/shifts/models/day_approval.dart`

- [ ] **Step 1: Create the DayApproval and Activity model classes**

```dart
// gps_tracker/lib/features/shifts/models/day_approval.dart
import 'package:flutter/foundation.dart';

enum ApprovalStatus {
  pending,
  approved;

  factory ApprovalStatus.fromJson(String value) {
    switch (value) {
      case 'approved':
        return ApprovalStatus.approved;
      default:
        return ApprovalStatus.pending;
    }
  }
}

enum ActivityFinalStatus {
  approved,
  rejected,
  needsReview;

  factory ActivityFinalStatus.fromJson(String value) {
    switch (value) {
      case 'approved':
        return ActivityFinalStatus.approved;
      case 'rejected':
        return ActivityFinalStatus.rejected;
      default:
        return ActivityFinalStatus.needsReview;
    }
  }

  String get displayName {
    switch (this) {
      case ActivityFinalStatus.approved:
        return 'Approuvé';
      case ActivityFinalStatus.rejected:
        return 'Rejeté';
      case ActivityFinalStatus.needsReview:
        return 'En attente';
    }
  }
}

/// Day-level approval summary (from day_approvals table).
@immutable
class DayApprovalSummary {
  final String employeeId;
  final DateTime date;
  final ApprovalStatus status;
  final int? approvedMinutes;
  final int? rejectedMinutes;
  final int? totalShiftMinutes;

  const DayApprovalSummary({
    required this.employeeId,
    required this.date,
    required this.status,
    this.approvedMinutes,
    this.rejectedMinutes,
    this.totalShiftMinutes,
  });

  bool get hasRejections => (rejectedMinutes ?? 0) > 0;

  factory DayApprovalSummary.fromJson(Map<String, dynamic> json) {
    return DayApprovalSummary(
      employeeId: json['employee_id'] as String,
      date: DateTime.parse(json['date'] as String),
      status: ApprovalStatus.fromJson(json['status'] as String? ?? 'pending'),
      approvedMinutes: (json['approved_minutes'] as num?)?.toInt(),
      rejectedMinutes: (json['rejected_minutes'] as num?)?.toInt(),
      totalShiftMinutes: (json['total_shift_minutes'] as num?)?.toInt(),
    );
  }
}

/// Single activity from get_day_approval_detail RPC.
@immutable
class ApprovalActivity {
  final String activityType; // stop, trip, clock_in, clock_out, lunch, gap
  final String activityId;
  final String? shiftId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int durationMinutes;
  final ActivityFinalStatus finalStatus;
  final String? autoReason;
  final String? locationName;
  final String? locationType;
  final double? latitude;
  final double? longitude;
  final double? distanceKm;
  final String? transportMode;
  final String? startLocationName;
  final String? endLocationName;
  final String? shiftType;

  const ApprovalActivity({
    required this.activityType,
    required this.activityId,
    this.shiftId,
    required this.startedAt,
    this.endedAt,
    required this.durationMinutes,
    required this.finalStatus,
    this.autoReason,
    this.locationName,
    this.locationType,
    this.latitude,
    this.longitude,
    this.distanceKm,
    this.transportMode,
    this.startLocationName,
    this.endLocationName,
    this.shiftType,
  });

  bool get isTrip => activityType == 'trip';
  bool get isStop => activityType == 'stop';
  bool get isClockIn => activityType == 'clock_in';
  bool get isClockOut => activityType == 'clock_out';
  bool get isLunch => activityType == 'lunch';
  bool get isGap => activityType == 'gap';

  factory ApprovalActivity.fromJson(Map<String, dynamic> json) {
    return ApprovalActivity(
      activityType: json['activity_type'] as String,
      activityId: json['activity_id'] as String,
      shiftId: json['shift_id'] as String?,
      startedAt: DateTime.parse(json['started_at'] as String),
      endedAt: json['ended_at'] != null
          ? DateTime.parse(json['ended_at'] as String)
          : null,
      durationMinutes: (json['duration_minutes'] as num?)?.toInt() ?? 0,
      finalStatus: ActivityFinalStatus.fromJson(
          json['final_status'] as String? ?? 'needs_review'),
      autoReason: json['auto_reason'] as String?,
      locationName: json['location_name'] as String?,
      locationType: json['location_type'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      distanceKm: (json['distance_km'] as num?)?.toDouble(),
      transportMode: json['transport_mode'] as String?,
      startLocationName: json['start_location_name'] as String?,
      endLocationName: json['end_location_name'] as String?,
      shiftType: json['shift_type'] as String?,
    );
  }
}

/// Full day approval detail (from get_day_approval_detail RPC).
@immutable
class DayApprovalDetail {
  final String employeeId;
  final DateTime date;
  final bool hasActiveShift;
  final ApprovalStatus approvalStatus;
  final String? notes;
  final List<ApprovalActivity> activities;
  final int totalShiftMinutes;
  final int approvedMinutes;
  final int rejectedMinutes;
  final int needsReviewCount;

  const DayApprovalDetail({
    required this.employeeId,
    required this.date,
    required this.hasActiveShift,
    required this.approvalStatus,
    this.notes,
    required this.activities,
    required this.totalShiftMinutes,
    required this.approvedMinutes,
    required this.rejectedMinutes,
    required this.needsReviewCount,
  });

  bool get hasRejections => rejectedMinutes > 0;

  /// Group stop activities by location name for the location breakdown card.
  Map<String, List<ApprovalActivity>> get activitiesByLocation {
    final stops = activities.where((a) => a.isStop).toList();
    final grouped = <String, List<ApprovalActivity>>{};
    for (final stop in stops) {
      final key = stop.locationName ?? 'Lieu inconnu';
      grouped.putIfAbsent(key, () => []).add(stop);
    }
    return grouped;
  }

  factory DayApprovalDetail.fromJson(Map<String, dynamic> json) {
    final activitiesJson = json['activities'] as List<dynamic>? ?? [];
    final summary = json['summary'] as Map<String, dynamic>? ?? {};

    return DayApprovalDetail(
      employeeId: json['employee_id'] as String,
      date: DateTime.parse(json['date'] as String),
      hasActiveShift: json['has_active_shift'] as bool? ?? false,
      approvalStatus: ApprovalStatus.fromJson(
          json['approval_status'] as String? ?? 'pending'),
      notes: json['notes'] as String?,
      activities: activitiesJson
          .map((a) => ApprovalActivity.fromJson(a as Map<String, dynamic>))
          .toList(),
      totalShiftMinutes:
          (summary['total_shift_minutes'] as num?)?.toInt() ?? 0,
      approvedMinutes: (summary['approved_minutes'] as num?)?.toInt() ?? 0,
      rejectedMinutes: (summary['rejected_minutes'] as num?)?.toInt() ?? 0,
      needsReviewCount:
          (summary['needs_review_count'] as num?)?.toInt() ?? 0,
    );
  }
}
```

- [ ] **Step 2: Verify the file compiles**

Run: `cd gps_tracker && flutter analyze lib/features/shifts/models/day_approval.dart`
Expected: No issues found

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/shifts/models/day_approval.dart
git commit -m "feat: add DayApproval model for employee approval visibility"
```

---

## Task 2: Approval Providers

**Files:**
- Create: `gps_tracker/lib/features/shifts/providers/approval_provider.dart`

**Dependencies:** Task 0 (to know which RPC to call), Task 1

- [ ] **Step 1: Create approval providers**

```dart
// gps_tracker/lib/features/shifts/providers/approval_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/day_approval.dart';

/// Fetch day approval summaries for a date range (employee's own data).
/// Uses direct table query — RLS policy allows employee SELECT own.
final dayApprovalSummariesProvider = FutureProvider.family<
    List<DayApprovalSummary>, ({DateTime from, DateTime to})>(
  (ref, range) async {
    final supabase = Supabase.instance.client;
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return [];

    final fromStr =
        '${range.from.year}-${range.from.month.toString().padLeft(2, '0')}-${range.from.day.toString().padLeft(2, '0')}';
    final toStr =
        '${range.to.year}-${range.to.month.toString().padLeft(2, '0')}-${range.to.day.toString().padLeft(2, '0')}';

    final response = await supabase
        .from('day_approvals')
        .select('employee_id, date, status, approved_minutes, rejected_minutes, total_shift_minutes')
        .eq('employee_id', userId)
        .gte('date', fromStr)
        .lte('date', toStr)
        .order('date', ascending: false);

    return (response as List<dynamic>)
        .map((row) => DayApprovalSummary.fromJson(row as Map<String, dynamic>))
        .toList();
  },
);

/// Fetch full day approval detail for a specific date.
/// If Task 0 created get_my_day_approval_detail, use that (no p_employee_id param).
/// Otherwise use get_day_approval_detail with p_employee_id = userId.
final dayApprovalDetailProvider =
    FutureProvider.family<DayApprovalDetail?, DateTime>(
  (ref, date) async {
    final supabase = Supabase.instance.client;
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return null;

    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

    try {
      // Use employee-safe RPC if Task 0 created it, otherwise use original
      // Adjust the RPC name based on Task 0 findings:
      final response = await supabase.rpc('get_day_approval_detail', params: {
        'p_employee_id': userId,
        'p_date': dateStr,
      });

      if (response == null) return null;
      return DayApprovalDetail.fromJson(response as Map<String, dynamic>);
    } catch (_) {
      // Graceful degradation — approval data is supplementary
      return null;
    }
  },
);
```

- [ ] **Step 2: Verify the file compiles**

Run: `cd gps_tracker && flutter analyze lib/features/shifts/providers/approval_provider.dart`
Expected: No issues found

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/shifts/providers/approval_provider.dart
git commit -m "feat: add Riverpod providers for employee approval data"
```

---

## Task 3: Approval Badge on ShiftCard

**Files:**
- Modify: `gps_tracker/lib/features/shifts/widgets/shift_card.dart`
- Modify: `gps_tracker/lib/features/shifts/screens/shift_history_screen.dart`

**Dependencies:** Task 2

- [ ] **Step 1: Add optional approval summary parameter to ShiftCard**

In `shift_card.dart`, add:
- An optional `DayApprovalSummary? approval` parameter
- A status badge row below the existing content showing:
  - Green badge "Approuvé" with `✓ Xh Ym` for approved days
  - Red badge with rejected minutes if `hasRejections` (shown alongside main badge)
  - Grey badge "En attente" for pending days OR when `approval` is null (completed shift with no review yet)
  - No badge only for active (non-completed) shifts

```dart
// Add to ShiftCard constructor:
final DayApprovalSummary? approval;

// Add at the bottom of the Card's Column children, after the location row:
// Show badge for completed shifts (even if no approval row = "En attente")
if (shift.isCompleted) ...[
  const SizedBox(height: 8),
  _ApprovalBadge(approval: approval),
],
```

The `_ApprovalBadge` widget (handles null = "En attente"):
```dart
class _ApprovalBadge extends StatelessWidget {
  final DayApprovalSummary? approval;
  const _ApprovalBadge({this.approval});

  String _formatMinutes(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '${m}m';
    return '${h}h${m.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isApproved = approval?.status == ApprovalStatus.approved;
    final hasRejections = approval?.hasRejections ?? false;

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: isApproved
                ? Colors.green.withValues(alpha: 0.1)
                : Colors.grey.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isApproved ? Icons.check_circle : Icons.schedule,
                size: 14,
                color: isApproved ? Colors.green : Colors.grey,
              ),
              const SizedBox(width: 4),
              Text(
                isApproved
                    ? '${_formatMinutes(approval!.approvedMinutes ?? 0)} approuvé'
                    : 'En attente',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isApproved ? Colors.green.shade700 : Colors.grey.shade600,
                ),
              ),
            ],
          ),
        ),
        if (hasRejections) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cancel, size: 14, color: Colors.red),
                const SizedBox(width: 4),
                Text(
                  '${_formatMinutes(approval!.rejectedMinutes ?? 0)} rejeté',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.red.shade700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
```

- [ ] **Step 2: Update ShiftHistoryScreen to fetch and pass approval summaries**

In `shift_history_screen.dart`:
- Import `approval_provider.dart` and `day_approval.dart`
- After building the shift list, compute the date range from loaded shifts
- Watch `dayApprovalSummariesProvider` for that range
- Build a `Map<String, DayApprovalSummary>` keyed by date string (YYYY-MM-DD)
- Pass matching approval to each `ShiftCard`

```dart
// In _buildShiftList, before the ListView.builder:
final approvalRange = _getDateRange(historyState.shifts);
final approvalsAsync = approvalRange != null
    ? ref.watch(dayApprovalSummariesProvider(approvalRange))
    : const AsyncValue<List<DayApprovalSummary>>.data([]);
final approvalMap = _buildApprovalMap(approvalsAsync.valueOrNull ?? []);

// In the itemBuilder, when creating ShiftCard:
ShiftCard(
  shift: shift,
  approval: approvalMap[_dateKey(shift.clockedInAt)],
  onTap: () => _navigateToDetail(shift.id),
),
```

Helper methods:
```dart
({DateTime from, DateTime to})? _getDateRange(List<Shift> shifts) {
  if (shifts.isEmpty) return null;
  final dates = shifts.map((s) => s.clockedInAt.toLocal()).toList();
  final earliest = dates.reduce((a, b) => a.isBefore(b) ? a : b);
  final latest = dates.reduce((a, b) => a.isAfter(b) ? a : b);
  return (
    from: DateTime(earliest.year, earliest.month, earliest.day),
    to: DateTime(latest.year, latest.month, latest.day),
  );
}

Map<String, DayApprovalSummary> _buildApprovalMap(List<DayApprovalSummary> approvals) {
  return {
    for (final a in approvals)
      '${a.date.year}-${a.date.month.toString().padLeft(2, '0')}-${a.date.day.toString().padLeft(2, '0')}': a,
  };
}

String _dateKey(DateTime dt) {
  final local = dt.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
}
```

- [ ] **Step 3: Verify compilation**

Run: `cd gps_tracker && flutter analyze`
Expected: No issues found

- [ ] **Step 4: Commit**

```bash
git add gps_tracker/lib/features/shifts/widgets/shift_card.dart \
       gps_tracker/lib/features/shifts/screens/shift_history_screen.dart
git commit -m "feat: show approval status badges on shift history cards"
```

---

## Task 4: Approval Summary Card Widget

**Files:**
- Create: `gps_tracker/lib/features/shifts/widgets/approval_summary_card.dart`

**Dependencies:** Task 1

- [ ] **Step 1: Create the approval summary card**

A card showing:
- Day approval status badge (approved/pending)
- Total shift time, approved hours (green), rejected hours (red)
- Needs review count (if > 0)

```dart
// gps_tracker/lib/features/shifts/widgets/approval_summary_card.dart
import 'package:flutter/material.dart';

import '../models/day_approval.dart';

class ApprovalSummaryCard extends StatelessWidget {
  final DayApprovalDetail detail;
  const ApprovalSummaryCard({super.key, required this.detail});

  String _formatMinutes(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '${m}m';
    return '${h}h${m.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isApproved = detail.approvalStatus == ApprovalStatus.approved;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isApproved ? Icons.check_circle : Icons.schedule,
                  color: isApproved ? Colors.green : Colors.grey,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  isApproved ? 'Journée approuvée' : 'En attente d\'approbation',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: isApproved ? Colors.green.shade700 : Colors.grey.shade600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _StatChip(
                  label: 'Total',
                  value: _formatMinutes(detail.totalShiftMinutes),
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                _StatChip(
                  label: 'Approuvé',
                  value: _formatMinutes(detail.approvedMinutes),
                  color: Colors.green,
                ),
                if (detail.rejectedMinutes > 0) ...[
                  const SizedBox(width: 12),
                  _StatChip(
                    label: 'Rejeté',
                    value: _formatMinutes(detail.rejectedMinutes),
                    color: Colors.red,
                  ),
                ],
                if (detail.needsReviewCount > 0) ...[
                  const SizedBox(width: 12),
                  _StatChip(
                    label: 'À réviser',
                    value: '${detail.needsReviewCount}',
                    color: Colors.orange,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _StatChip({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: color.withValues(alpha: 0.8)),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Verify compilation**

Run: `cd gps_tracker && flutter analyze lib/features/shifts/widgets/approval_summary_card.dart`
Expected: No issues found

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/shifts/widgets/approval_summary_card.dart
git commit -m "feat: add ApprovalSummaryCard widget"
```

---

## Task 5: Location Breakdown Card Widget

**Files:**
- Create: `gps_tracker/lib/features/shifts/widgets/location_breakdown_card.dart`

**Dependencies:** Task 1

- [ ] **Step 1: Create the location breakdown card**

Groups stops by location name, shows total approved/rejected minutes per location.

```dart
// gps_tracker/lib/features/shifts/widgets/location_breakdown_card.dart
import 'package:flutter/material.dart';

import '../models/day_approval.dart';

class LocationBreakdownCard extends StatelessWidget {
  final DayApprovalDetail detail;
  const LocationBreakdownCard({super.key, required this.detail});

  String _formatMinutes(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '${m}m';
    return '${h}h${m.toString().padLeft(2, '0')}';
  }

  IconData _iconForLocationType(String? type) {
    switch (type) {
      case 'office':
        return Icons.business;
      case 'building':
        return Icons.apartment;
      case 'vendor':
        return Icons.store;
      case 'gaz':
        return Icons.local_gas_station;
      case 'home':
        return Icons.home;
      case 'cafe_restaurant':
        return Icons.restaurant;
      default:
        return Icons.location_on;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final byLocation = detail.activitiesByLocation;
    if (byLocation.isEmpty) return const SizedBox.shrink();

    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Répartition par lieu',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            ...byLocation.entries.map((entry) {
              final locationName = entry.key;
              final stops = entry.value;
              final approvedMins = stops
                  .where((s) => s.finalStatus == ActivityFinalStatus.approved)
                  .fold<int>(0, (sum, s) => sum + s.durationMinutes);
              final rejectedMins = stops
                  .where((s) => s.finalStatus == ActivityFinalStatus.rejected)
                  .fold<int>(0, (sum, s) => sum + s.durationMinutes);
              final pendingMins = stops
                  .where((s) => s.finalStatus == ActivityFinalStatus.needsReview)
                  .fold<int>(0, (sum, s) => sum + s.durationMinutes);
              final locationType = stops.first.locationType;

              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(
                      _iconForLocationType(locationType),
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        locationName,
                        style: theme.textTheme.bodyMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (approvedMins > 0)
                      _MiniBadge(
                        text: _formatMinutes(approvedMins),
                        color: Colors.green,
                      ),
                    if (rejectedMins > 0) ...[
                      const SizedBox(width: 4),
                      _MiniBadge(
                        text: _formatMinutes(rejectedMins),
                        color: Colors.red,
                      ),
                    ],
                    if (pendingMins > 0) ...[
                      const SizedBox(width: 4),
                      _MiniBadge(
                        text: _formatMinutes(pendingMins),
                        color: Colors.orange,
                      ),
                    ],
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _MiniBadge extends StatelessWidget {
  final String text;
  final Color color;
  const _MiniBadge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Verify compilation**

Run: `cd gps_tracker && flutter analyze lib/features/shifts/widgets/location_breakdown_card.dart`
Expected: No issues found

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/shifts/widgets/location_breakdown_card.dart
git commit -m "feat: add LocationBreakdownCard widget"
```

---

## Task 6: Activity Timeline Widget

**Files:**
- Create: `gps_tracker/lib/features/shifts/widgets/activity_timeline.dart`

**Dependencies:** Task 1

- [ ] **Step 1: Create the activity timeline widget**

A scrollable list of activities sorted by time, each showing type icon, details, duration, time range, and status badge.

```dart
// gps_tracker/lib/features/shifts/widgets/activity_timeline.dart
import 'package:flutter/material.dart';

import '../models/day_approval.dart';

class ActivityTimeline extends StatelessWidget {
  final List<ApprovalActivity> activities;
  const ActivityTimeline({super.key, required this.activities});

  String _formatTime(DateTime dt) {
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  String _formatDuration(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '${m}m';
    return '${h}h${m.toString().padLeft(2, '0')}';
  }

  IconData _activityIcon(ApprovalActivity activity) {
    if (activity.isTrip) return Icons.directions_car;
    if (activity.isStop) return Icons.location_on;
    if (activity.isClockIn) return Icons.login;
    if (activity.isClockOut) return Icons.logout;
    if (activity.isLunch) return Icons.restaurant;
    if (activity.isGap) return Icons.warning_amber;
    return Icons.help_outline;
  }

  Color _statusColor(ActivityFinalStatus status) {
    switch (status) {
      case ActivityFinalStatus.approved:
        return Colors.green;
      case ActivityFinalStatus.rejected:
        return Colors.red;
      case ActivityFinalStatus.needsReview:
        return Colors.orange;
    }
  }

  String _activityLabel(ApprovalActivity activity) {
    if (activity.isTrip) {
      final from = activity.startLocationName ?? '?';
      final to = activity.endLocationName ?? '?';
      final dist = activity.distanceKm != null
          ? ' (${activity.distanceKm!.toStringAsFixed(1)} km)'
          : '';
      return '$from → $to$dist';
    }
    if (activity.isStop) return activity.locationName ?? 'Lieu inconnu';
    if (activity.isClockIn) return 'Pointage';
    if (activity.isClockOut) return 'Dépointage';
    if (activity.isLunch) return 'Pause dîner';
    if (activity.isGap) return 'Interruption GPS';
    return activity.activityType;
  }

  @override
  Widget build(BuildContext context) {
    if (activities.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);

    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Activités',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            ...activities.map((activity) => _ActivityRow(
                  activity: activity,
                  icon: _activityIcon(activity),
                  label: _activityLabel(activity),
                  time: _formatTime(activity.startedAt),
                  duration: _formatDuration(activity.durationMinutes),
                  statusColor: _statusColor(activity.finalStatus),
                  statusLabel: activity.finalStatus.displayName,
                )),
          ],
        ),
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  final ApprovalActivity activity;
  final IconData icon;
  final String label;
  final String time;
  final String duration;
  final Color statusColor;
  final String statusLabel;

  const _ActivityRow({
    required this.activity,
    required this.icon,
    required this.label,
    required this.time,
    required this.duration,
    required this.statusColor,
    required this.statusLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '$time · $duration',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              statusLabel,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: statusColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Verify compilation**

Run: `cd gps_tracker && flutter analyze lib/features/shifts/widgets/activity_timeline.dart`
Expected: No issues found

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/shifts/widgets/activity_timeline.dart
git commit -m "feat: add ActivityTimeline widget for approval detail view"
```

---

## Task 7: Enrich ShiftDetailScreen with Approval Data

**Files:**
- Modify: `gps_tracker/lib/features/shifts/screens/shift_detail_screen.dart`

**Dependencies:** Tasks 2, 4, 5, 6

- [ ] **Step 1: Add approval section to ShiftDetailScreen**

In `shift_detail_screen.dart`, after the existing header card and before the route section:

1. Import the new models, providers, and widgets
2. Add a new `_buildApprovalSection` method that:
   - Computes the date from the shift's `clockedInAt`
   - Watches `dayApprovalDetailProvider(date)`
   - On loading: shows a small spinner
   - On error: shows nothing (graceful degradation)
   - On data: shows `ApprovalSummaryCard`, `LocationBreakdownCard`, and `ActivityTimeline`

```dart
// Add imports:
import '../models/day_approval.dart';
import '../providers/approval_provider.dart';
import '../widgets/approval_summary_card.dart';
import '../widgets/location_breakdown_card.dart';
import '../widgets/activity_timeline.dart';

// In _buildShiftDetails, add after the clock-out card and before _buildRouteSection:
// Approval Section
_buildApprovalSection(context, shift),
const SizedBox(height: 16),
```

The `_buildApprovalSection` method:
```dart
Widget _buildApprovalSection(BuildContext context, Shift shift) {
  final date = DateTime(
    shift.clockedInAt.toLocal().year,
    shift.clockedInAt.toLocal().month,
    shift.clockedInAt.toLocal().day,
  );

  return Consumer(
    builder: (context, ref, _) {
      final detailAsync = ref.watch(dayApprovalDetailProvider(date));

      return detailAsync.when(
        data: (detail) {
          if (detail == null) return const SizedBox.shrink();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ApprovalSummaryCard(detail: detail),
              const SizedBox(height: 12),
              LocationBreakdownCard(detail: detail),
              const SizedBox(height: 12),
              ActivityTimeline(activities: detail.activities),
            ],
          );
        },
        loading: () => const Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        ),
        error: (_, __) => const SizedBox.shrink(),
      );
    },
  );
}
```

- [ ] **Step 2: Verify compilation**

Run: `cd gps_tracker && flutter analyze`
Expected: No issues found

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/shifts/screens/shift_detail_screen.dart
git commit -m "feat: show approval summary, location breakdown, and activity timeline in shift detail"
```

---

## Task 8: Interactive OSRM Trip Map Widget

**Files:**
- Create: `gps_tracker/lib/features/shifts/widgets/trip_routes_map.dart`

**Dependencies:** Task 1 (for ApprovalActivity model)

The existing `RouteMapWidget` shows trip polylines but does NOT support tap-to-popup with distance/duration. This task creates a dedicated trip map widget for the approval detail view.

- [ ] **Step 1: Create the TripRoutesMap widget**

```dart
// gps_tracker/lib/features/shifts/widgets/trip_routes_map.dart
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../mileage/models/trip.dart';

/// Decode polyline6 to latlong2 LatLng.
List<LatLng> _decodePolyline6(String encoded) {
  final List<LatLng> points = [];
  int index = 0;
  int lat = 0;
  int lng = 0;
  while (index < encoded.length) {
    int shift = 0;
    int result = 0;
    int byte;
    do {
      byte = encoded.codeUnitAt(index++) - 63;
      result |= (byte & 0x1F) << shift;
      shift += 5;
    } while (byte >= 0x20);
    lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
    shift = 0;
    result = 0;
    do {
      byte = encoded.codeUnitAt(index++) - 63;
      result |= (byte & 0x1F) << shift;
      shift += 5;
    } while (byte >= 0x20);
    lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
    points.add(LatLng(lat / 1e6, lng / 1e6));
  }
  return points;
}

const _tripColors = [
  Color(0xFF8b5cf6), Color(0xFF22c55e), Color(0xFFf97316),
  Color(0xFFec4899), Color(0xFF14b8a6), Color(0xFFeab308),
];

/// Interactive map showing OSRM-matched trip routes with tap-to-popup.
class TripRoutesMap extends StatefulWidget {
  final List<Trip> trips;
  const TripRoutesMap({super.key, required this.trips});

  @override
  State<TripRoutesMap> createState() => _TripRoutesMapState();
}

class _TripRoutesMapState extends State<TripRoutesMap> {
  late final MapController _mapController;
  Trip? _selectedTrip;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  LatLngBounds? get _bounds {
    final allPoints = <LatLng>[];
    for (final trip in widget.trips) {
      allPoints.add(LatLng(trip.startLatitude, trip.startLongitude));
      allPoints.add(LatLng(trip.endLatitude, trip.endLongitude));
      if (trip.isRouteMatched && trip.routeGeometry != null) {
        allPoints.addAll(_decodePolyline6(trip.routeGeometry!));
      }
    }
    if (allPoints.isEmpty) return null;
    double minLat = allPoints.first.latitude, maxLat = allPoints.first.latitude;
    double minLng = allPoints.first.longitude, maxLng = allPoints.first.longitude;
    for (final pt in allPoints) {
      if (pt.latitude < minLat) minLat = pt.latitude;
      if (pt.latitude > maxLat) maxLat = pt.latitude;
      if (pt.longitude < minLng) minLng = pt.longitude;
      if (pt.longitude > maxLng) maxLng = pt.longitude;
    }
    const pad = 0.002;
    return LatLngBounds(LatLng(minLat - pad, minLng - pad), LatLng(maxLat + pad, maxLng + pad));
  }

  String _formatDuration(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '${m} min';
    return '${h}h${m.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.trips.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Trajets',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 250,
                child: Stack(
                  children: [
                    FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter: const LatLng(45.5, -73.6),
                        initialZoom: 12,
                        initialCameraFit: _bounds != null
                            ? CameraFit.bounds(bounds: _bounds!, padding: const EdgeInsets.all(40))
                            : null,
                        onTap: (_, __) => setState(() => _selectedTrip = null),
                      ),
                      children: [
                        TileLayer(
                          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.gps_tracker.app',
                        ),
                        PolylineLayer(polylines: _buildPolylines()),
                        MarkerLayer(markers: _buildMarkers()),
                      ],
                    ),
                    // Popup for selected trip
                    if (_selectedTrip != null)
                      Positioned(
                        bottom: 8,
                        left: 8,
                        right: 8,
                        child: _TripPopup(
                          trip: _selectedTrip!,
                          color: _tripColors[widget.trips.indexOf(_selectedTrip!) % _tripColors.length],
                          onClose: () => setState(() => _selectedTrip = null),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Polyline> _buildPolylines() {
    return widget.trips.asMap().entries.map((entry) {
      final trip = entry.value;
      final color = _tripColors[entry.key % _tripColors.length];
      final isMatched = trip.isRouteMatched && trip.routeGeometry != null;
      final points = isMatched
          ? _decodePolyline6(trip.routeGeometry!)
          : [LatLng(trip.startLatitude, trip.startLongitude), LatLng(trip.endLatitude, trip.endLongitude)];
      return Polyline(
        points: points,
        color: color,
        strokeWidth: _selectedTrip == trip ? 6 : 4,
        isDotted: !isMatched,
      );
    }).toList();
  }

  List<Marker> _buildMarkers() {
    final markers = <Marker>[];
    for (int i = 0; i < widget.trips.length; i++) {
      final trip = widget.trips[i];
      final color = _tripColors[i % _tripColors.length];
      // Start marker
      markers.add(Marker(
        point: LatLng(trip.startLatitude, trip.startLongitude),
        width: 20, height: 20,
        child: GestureDetector(
          onTap: () => setState(() => _selectedTrip = trip),
          child: Container(
            decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
          ),
        ),
      ));
      // End marker
      markers.add(Marker(
        point: LatLng(trip.endLatitude, trip.endLongitude),
        width: 20, height: 20,
        child: GestureDetector(
          onTap: () => setState(() => _selectedTrip = trip),
          child: Container(
            decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
            child: const Icon(Icons.flag, size: 12, color: Colors.white),
          ),
        ),
      ));
    }
    return markers;
  }
}

class _TripPopup extends StatelessWidget {
  final Trip trip;
  final Color color;
  final VoidCallback onClose;
  const _TripPopup({required this.trip, required this.color, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dist = trip.effectiveDistanceKm.toStringAsFixed(1);
    final dur = trip.durationMinutes;
    final h = dur ~/ 60;
    final m = dur % 60;
    final durStr = h == 0 ? '${m} min' : '${h}h${m.toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 8)],
      ),
      child: Row(
        children: [
          Container(width: 4, height: 40, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${trip.startDisplayName} → ${trip.endDisplayName}',
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  '$dist km · $durStr${trip.isRouteMatched ? '' : ' (estimé)'}',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(icon: const Icon(Icons.close, size: 18), onPressed: onClose, padding: EdgeInsets.zero, constraints: const BoxConstraints()),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Verify compilation**

Run: `cd gps_tracker && flutter analyze lib/features/shifts/widgets/trip_routes_map.dart`
Expected: No issues found

- [ ] **Step 3: Commit**

```bash
git add gps_tracker/lib/features/shifts/widgets/trip_routes_map.dart
git commit -m "feat: add interactive OSRM trip routes map with tap-to-popup"
```

---

## Task 9: Add Trip Map to ShiftDetailScreen + Pull-to-Refresh

**Files:**
- Modify: `gps_tracker/lib/features/shifts/screens/shift_detail_screen.dart`

**Dependencies:** Tasks 7, 8

- [ ] **Step 1: Add TripRoutesMap to the approval section**

In `shift_detail_screen.dart`, import the new widget:
```dart
import '../widgets/trip_routes_map.dart';
import '../../mileage/providers/trip_provider.dart';
```

Add a `_buildTripRoutesSection` method that fetches trips for the shift and shows them on the interactive map:

```dart
Widget _buildTripRoutesSection(BuildContext context, String shiftId) {
  return Consumer(
    builder: (context, ref, _) {
      final tripsAsync = ref.watch(tripsForShiftProvider(shiftId));
      return tripsAsync.when(
        data: (trips) {
          if (trips.isEmpty) return const SizedBox.shrink();
          return TripRoutesMap(trips: trips);
        },
        loading: () => const SizedBox.shrink(),
        error: (_, __) => const SizedBox.shrink(),
      );
    },
  );
}
```

In `_buildShiftDetails`, add after `_buildApprovalSection` and before `_buildRouteSection`:
```dart
// OSRM Trip Routes Map (interactive, tap-to-popup)
if (shift.isCompleted)
  _buildTripRoutesSection(context, shift.id),
const SizedBox(height: 16),
```

- [ ] **Step 2: Add pull-to-refresh to ShiftDetailScreen**

Wrap the `SingleChildScrollView` body in a `RefreshIndicator`. Since the screen currently uses `FutureBuilder`, convert the shift loading to use a `StatefulWidget` with manual refresh:

```dart
// In _buildShiftDetails, wrap SingleChildScrollView in RefreshIndicator:
return RefreshIndicator(
  onRefresh: () async {
    // Invalidate approval data to refetch
    // (shift data from FutureBuilder will also rebuild on setState)
  },
  child: SingleChildScrollView(
    physics: const AlwaysScrollableScrollPhysics(), // needed for RefreshIndicator
    padding: const EdgeInsets.all(16),
    child: Column(
      // ... existing children
    ),
  ),
);
```

**Note:** The existing `FutureBuilder` for the shift itself does not support invalidation. For now, pull-to-refresh will only reload approval data (by invalidating `dayApprovalDetailProvider`). This is acceptable since shift data doesn't change after completion.

- [ ] **Step 3: Verify compilation**

Run: `cd gps_tracker && flutter analyze`
Expected: No issues found

- [ ] **Step 4: Commit**

```bash
git add gps_tracker/lib/features/shifts/screens/shift_detail_screen.dart
git commit -m "feat: add OSRM trip map and pull-to-refresh to shift detail"
```

---

## Task 10: Full Integration Test

**Dependencies:** All previous tasks

- [ ] **Step 1: Run flutter analyze**

Run: `cd gps_tracker && flutter analyze`
Expected: No issues found

- [ ] **Step 2: Manual test on device/simulator**

Test the following flow:
1. Open the app as an employee
2. Go to Shift History — verify:
   - Completed shifts show approval badges (green "Approuvé", grey "En attente")
   - Shifts with no `day_approvals` row show grey "En attente" (not blank)
   - Red rejected badge appears alongside green when rejections exist
   - Active shifts show no badge
3. Tap a completed shift — verify:
   - Approval summary card shows (total, approved, rejected hours)
   - Location breakdown shows stops grouped by location name with color-coded minutes
   - Activity timeline shows all activities with status badges
   - **OSRM trip routes map** shows trip polylines (solid=matched, dotted=unmatched)
   - Tap a trip marker/route → popup shows distance + duration
   - Existing route map + mileage section still works below
4. Test a day with no approval data — verify graceful empty state (no crash)
5. Test pull-to-refresh on both screens — verify data updates
6. Test with no network — verify graceful degradation (no crash, approval section just hidden)

- [ ] **Step 3: Commit final state**

```bash
git add -A
git commit -m "feat: employee approval visibility in shift history"
```
