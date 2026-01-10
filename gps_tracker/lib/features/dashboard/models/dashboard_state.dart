import 'package:flutter/foundation.dart';

import '../../history/models/history_statistics.dart';
import '../../shifts/models/shift.dart';
import '../../shifts/providers/sync_provider.dart';

/// Current shift status indicator for dashboard display.
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

  /// Whether to show clock-in prompt.
  bool get showClockInPrompt => !isActive;

  /// Whether to show live timer.
  bool get showLiveTimer => isActive && activeShift != null;

  /// Calculate elapsed duration since clock-in.
  Duration get elapsedDuration {
    if (!isActive || activeShift == null) return Duration.zero;
    return DateTime.now().difference(activeShift!.clockedInAt);
  }

  factory ShiftStatusInfo.fromJson(Map<String, dynamic> json) {
    return ShiftStatusInfo(
      isActive: json['is_active'] as bool? ?? false,
      activeShift: json['active_shift'] != null
          ? Shift.fromJson(json['active_shift'] as Map<String, dynamic>)
          : null,
      lastClockOutAt: json['last_clock_out_at'] != null
          ? DateTime.parse(json['last_clock_out_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'is_active': isActive,
        'active_shift': activeShift?.toJson(),
        'last_clock_out_at': lastClockOutAt?.toIso8601String(),
      };

  ShiftStatusInfo copyWith({
    bool? isActive,
    Shift? activeShift,
    DateTime? lastClockOutAt,
    bool clearActiveShift = false,
  }) {
    return ShiftStatusInfo(
      isActive: isActive ?? this.isActive,
      activeShift: clearActiveShift ? null : (activeShift ?? this.activeShift),
      lastClockOutAt: lastClockOutAt ?? this.lastClockOutAt,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ShiftStatusInfo &&
        other.isActive == isActive &&
        other.activeShift == activeShift &&
        other.lastClockOutAt == lastClockOutAt;
  }

  @override
  int get hashCode => Object.hash(isActive, activeShift, lastClockOutAt);
}

/// Today's work summary for dashboard display.
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

  /// Create for today with empty stats.
  factory DailyStatistics.today() => DailyStatistics(
        date: DateTime.now(),
      );

  /// Total including active shift duration.
  Duration get totalIncludingActive => totalDuration + activeShiftDuration;

  /// Format hours as human-readable string.
  String get formattedHours {
    final total = totalIncludingActive;
    final hours = total.inHours;
    final minutes = total.inMinutes.remainder(60);
    if (hours == 0 && minutes == 0) return '0h';
    if (minutes == 0) return '${hours}h';
    return '${hours}h ${minutes}m';
  }

  /// Whether employee has worked today.
  bool get hasWorkedToday =>
      completedShiftCount > 0 || activeShiftDuration > Duration.zero;

  factory DailyStatistics.fromJson(Map<String, dynamic> json) {
    return DailyStatistics(
      date: json['date'] != null
          ? DateTime.parse(json['date'] as String)
          : DateTime.now(),
      completedShiftCount: json['completed_shifts'] as int? ?? 0,
      totalDuration:
          Duration(seconds: (json['total_seconds'] as num?)?.toInt() ?? 0),
      activeShiftDuration: Duration(
          seconds: (json['active_shift_seconds'] as num?)?.toInt() ?? 0),
    );
  }

  Map<String, dynamic> toJson() => {
        'date': date.toIso8601String(),
        'completed_shifts': completedShiftCount,
        'total_seconds': totalDuration.inSeconds,
        'active_shift_seconds': activeShiftDuration.inSeconds,
      };

  DailyStatistics copyWith({
    DateTime? date,
    int? completedShiftCount,
    Duration? totalDuration,
    Duration? activeShiftDuration,
  }) {
    return DailyStatistics(
      date: date ?? this.date,
      completedShiftCount: completedShiftCount ?? this.completedShiftCount,
      totalDuration: totalDuration ?? this.totalDuration,
      activeShiftDuration: activeShiftDuration ?? this.activeShiftDuration,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DailyStatistics &&
        other.date.year == date.year &&
        other.date.month == date.month &&
        other.date.day == date.day &&
        other.completedShiftCount == completedShiftCount &&
        other.totalDuration == totalDuration &&
        other.activeShiftDuration == activeShiftDuration;
  }

  @override
  int get hashCode => Object.hash(
        date.year,
        date.month,
        date.day,
        completedShiftCount,
        totalDuration,
        activeShiftDuration,
      );
}

/// Complete state of an employee's personal dashboard.
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

  EmployeeDashboardState({
    ShiftStatusInfo? currentShiftStatus,
    DailyStatistics? todayStats,
    HistoryStatistics? monthlyStats,
    List<Shift>? recentShifts,
    SyncState? syncStatus,
    this.lastUpdated,
    this.isLoading = false,
    this.error,
  })  : currentShiftStatus = currentShiftStatus ?? const ShiftStatusInfo(),
        todayStats = todayStats ?? DailyStatistics.today(),
        monthlyStats = monthlyStats ?? HistoryStatistics.empty,
        recentShifts = recentShifts ?? const [],
        syncStatus = syncStatus ?? const SyncState();

  /// Initial loading state.
  factory EmployeeDashboardState.loading() =>
      EmployeeDashboardState(isLoading: true);

  /// Error state.
  factory EmployeeDashboardState.error(String message) =>
      EmployeeDashboardState(error: message);

  /// Whether there are recent shifts to display.
  bool get hasRecentShifts => recentShifts.isNotEmpty;

  /// Whether dashboard has loaded successfully.
  bool get isLoaded => !isLoading && error == null && lastUpdated != null;

  /// Whether data is from cache (offline).
  bool get isFromCache => lastUpdated != null && !syncStatus.isConnected;

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

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is EmployeeDashboardState &&
        other.currentShiftStatus == currentShiftStatus &&
        other.todayStats == todayStats &&
        other.monthlyStats == monthlyStats &&
        listEquals(other.recentShifts, recentShifts) &&
        other.lastUpdated == lastUpdated &&
        other.isLoading == isLoading &&
        other.error == error;
  }

  @override
  int get hashCode => Object.hash(
        currentShiftStatus,
        todayStats,
        monthlyStats,
        Object.hashAll(recentShifts),
        lastUpdated,
        isLoading,
        error,
      );
}
