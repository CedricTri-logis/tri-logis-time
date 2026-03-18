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
        return 'Approuv\u00e9';
      case ActivityFinalStatus.rejected:
        return 'Rejet\u00e9';
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
    final status =
        ApprovalStatus.fromJson(json['status'] as String? ?? 'pending');
    final isDayApproved = status == ApprovalStatus.approved;

    return DayApprovalSummary(
      employeeId: json['employee_id'] as String,
      date: DateTime.parse(json['date'] as String),
      status: status,
      // Hide per-status breakdown until the day is fully approved
      approvedMinutes:
          isDayApproved ? (json['approved_minutes'] as num?)?.toInt() : null,
      rejectedMinutes:
          isDayApproved ? (json['rejected_minutes'] as num?)?.toInt() : null,
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

  /// Return a copy with a different [finalStatus].
  ApprovalActivity withStatus(ActivityFinalStatus status) {
    if (status == finalStatus) return this;
    return ApprovalActivity(
      activityType: activityType,
      activityId: activityId,
      shiftId: shiftId,
      startedAt: startedAt,
      endedAt: endedAt,
      durationMinutes: durationMinutes,
      finalStatus: status,
      autoReason: autoReason,
      locationName: locationName,
      locationType: locationType,
      latitude: latitude,
      longitude: longitude,
      distanceKm: distanceKm,
      transportMode: transportMode,
      startLocationName: startLocationName,
      endLocationName: endLocationName,
      shiftType: shiftType,
    );
  }

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
    final approvalStatus = ApprovalStatus.fromJson(
        json['approval_status'] as String? ?? 'pending');
    final isDayApproved = approvalStatus == ApprovalStatus.approved;

    final rawActivities = activitiesJson
        .map((a) => ApprovalActivity.fromJson(a as Map<String, dynamic>))
        .toList();

    // Until the day is fully approved, mask all per-activity statuses as
    // "needs_review" so employees cannot see individual approved/rejected
    // decisions before the supervisor finalizes the day.
    final activities = isDayApproved
        ? rawActivities
        : rawActivities
            .map((a) => a.withStatus(ActivityFinalStatus.needsReview))
            .toList();

    return DayApprovalDetail(
      employeeId: json['employee_id'] as String,
      date: DateTime.parse(json['date'] as String),
      hasActiveShift: json['has_active_shift'] as bool? ?? false,
      approvalStatus: approvalStatus,
      notes: json['notes'] as String?,
      activities: activities,
      totalShiftMinutes:
          (summary['total_shift_minutes'] as num?)?.toInt() ?? 0,
      // Hide per-status breakdown until the day is fully approved
      approvedMinutes: isDayApproved
          ? (summary['approved_minutes'] as num?)?.toInt() ?? 0
          : 0,
      rejectedMinutes: isDayApproved
          ? (summary['rejected_minutes'] as num?)?.toInt() ?? 0
          : 0,
      needsReviewCount: isDayApproved
          ? (summary['needs_review_count'] as num?)?.toInt() ?? 0
          : activities.length,
    );
  }
}
