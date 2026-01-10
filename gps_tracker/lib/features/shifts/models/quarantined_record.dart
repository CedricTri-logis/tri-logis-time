import 'dart:convert';

/// Type of record that was quarantined.
enum RecordType {
  shift,
  gpsPoint;

  String get value {
    switch (this) {
      case RecordType.shift:
        return 'shift';
      case RecordType.gpsPoint:
        return 'gps_point';
    }
  }

  static RecordType fromString(String value) {
    switch (value) {
      case 'shift':
        return RecordType.shift;
      case 'gps_point':
        return RecordType.gpsPoint;
      default:
        throw ArgumentError('Unknown RecordType: $value');
    }
  }
}

/// Review status for quarantined records.
enum ReviewStatus {
  pending,
  resolved,
  discarded;

  String get value => name;

  static ReviewStatus fromString(String value) {
    switch (value) {
      case 'pending':
        return ReviewStatus.pending;
      case 'resolved':
        return ReviewStatus.resolved;
      case 'discarded':
        return ReviewStatus.discarded;
      default:
        throw ArgumentError('Unknown ReviewStatus: $value');
    }
  }
}

/// Model for records that failed sync and were quarantined for review.
class QuarantinedRecord {
  static const String tableName = 'quarantined_records';

  final String id;
  final RecordType recordType;
  final String originalId;
  final Map<String, dynamic> recordData;
  final String? errorCode;
  final String? errorMessage;
  final DateTime quarantinedAt;
  final ReviewStatus reviewStatus;
  final String? resolutionNotes;
  final DateTime createdAt;

  const QuarantinedRecord({
    required this.id,
    required this.recordType,
    required this.originalId,
    required this.recordData,
    this.errorCode,
    this.errorMessage,
    required this.quarantinedAt,
    this.reviewStatus = ReviewStatus.pending,
    this.resolutionNotes,
    required this.createdAt,
  });

  /// Check if record is pending review.
  bool get isPending => reviewStatus == ReviewStatus.pending;

  /// Check if record was resolved.
  bool get isResolved => reviewStatus == ReviewStatus.resolved;

  /// Check if record was discarded.
  bool get isDiscarded => reviewStatus == ReviewStatus.discarded;

  /// Create a copy with modified fields.
  QuarantinedRecord copyWith({
    String? id,
    RecordType? recordType,
    String? originalId,
    Map<String, dynamic>? recordData,
    String? errorCode,
    String? errorMessage,
    DateTime? quarantinedAt,
    ReviewStatus? reviewStatus,
    String? resolutionNotes,
    DateTime? createdAt,
  }) {
    return QuarantinedRecord(
      id: id ?? this.id,
      recordType: recordType ?? this.recordType,
      originalId: originalId ?? this.originalId,
      recordData: recordData ?? this.recordData,
      errorCode: errorCode ?? this.errorCode,
      errorMessage: errorMessage ?? this.errorMessage,
      quarantinedAt: quarantinedAt ?? this.quarantinedAt,
      reviewStatus: reviewStatus ?? this.reviewStatus,
      resolutionNotes: resolutionNotes ?? this.resolutionNotes,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  /// Convert to database map.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'record_type': recordType.value,
      'original_id': originalId,
      'record_data': jsonEncode(recordData),
      'error_code': errorCode,
      'error_message': errorMessage,
      'quarantined_at': quarantinedAt.toUtc().toIso8601String(),
      'review_status': reviewStatus.value,
      'resolution_notes': resolutionNotes,
      'created_at': createdAt.toUtc().toIso8601String(),
    };
  }

  /// Create from database map.
  factory QuarantinedRecord.fromMap(Map<String, dynamic> map) {
    return QuarantinedRecord(
      id: map['id'] as String,
      recordType: RecordType.fromString(map['record_type'] as String),
      originalId: map['original_id'] as String,
      recordData: jsonDecode(map['record_data'] as String) as Map<String, dynamic>,
      errorCode: map['error_code'] as String?,
      errorMessage: map['error_message'] as String?,
      quarantinedAt: DateTime.parse(map['quarantined_at'] as String),
      reviewStatus: ReviewStatus.fromString(map['review_status'] as String? ?? 'pending'),
      resolutionNotes: map['resolution_notes'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  @override
  String toString() {
    return 'QuarantinedRecord(type: $recordType, originalId: $originalId, '
        'status: $reviewStatus, error: $errorMessage)';
  }
}
