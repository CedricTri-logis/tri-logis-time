/// Model for storage capacity monitoring.
/// Singleton pattern - only one row exists in the database.
class StorageMetrics {
  static const String tableName = 'storage_metrics';
  static const String singletonId = 'singleton';
  static const int defaultCapacity = 52428800; // 50 MB

  final String id;
  final int totalCapacityBytes;
  final int usedBytes;
  final int shiftsBytes;
  final int gpsPointsBytes;
  final int logsBytes;
  final DateTime? lastCalculated;
  final int warningThresholdPercent;
  final int criticalThresholdPercent;
  final DateTime createdAt;
  final DateTime updatedAt;

  const StorageMetrics({
    this.id = singletonId,
    this.totalCapacityBytes = defaultCapacity,
    this.usedBytes = 0,
    this.shiftsBytes = 0,
    this.gpsPointsBytes = 0,
    this.logsBytes = 0,
    this.lastCalculated,
    this.warningThresholdPercent = 80,
    this.criticalThresholdPercent = 95,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Get available bytes remaining.
  int get availableBytes => totalCapacityBytes - usedBytes;

  /// Get usage percentage (0-100).
  double get usagePercent =>
      totalCapacityBytes > 0 ? (usedBytes / totalCapacityBytes) * 100 : 0;

  /// Check if storage is at warning level (80%+).
  bool get isWarning => usagePercent >= warningThresholdPercent;

  /// Check if storage is at critical level (95%+).
  bool get isCritical => usagePercent >= criticalThresholdPercent;

  /// Check if storage metrics are stale (>1 hour old).
  bool get isStale {
    if (lastCalculated == null) return true;
    final age = DateTime.now().difference(lastCalculated!);
    return age.inHours >= 1;
  }

  /// Get storage status description.
  String get statusDescription {
    if (isCritical) return 'Critical';
    if (isWarning) return 'Warning';
    return 'OK';
  }

  /// Format bytes to human-readable string.
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Get formatted used storage string.
  String get formattedUsed => formatBytes(usedBytes);

  /// Get formatted total storage string.
  String get formattedTotal => formatBytes(totalCapacityBytes);

  /// Get formatted available storage string.
  String get formattedAvailable => formatBytes(availableBytes);

  /// Create a copy with modified fields.
  StorageMetrics copyWith({
    String? id,
    int? totalCapacityBytes,
    int? usedBytes,
    int? shiftsBytes,
    int? gpsPointsBytes,
    int? logsBytes,
    DateTime? lastCalculated,
    int? warningThresholdPercent,
    int? criticalThresholdPercent,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return StorageMetrics(
      id: id ?? this.id,
      totalCapacityBytes: totalCapacityBytes ?? this.totalCapacityBytes,
      usedBytes: usedBytes ?? this.usedBytes,
      shiftsBytes: shiftsBytes ?? this.shiftsBytes,
      gpsPointsBytes: gpsPointsBytes ?? this.gpsPointsBytes,
      logsBytes: logsBytes ?? this.logsBytes,
      lastCalculated: lastCalculated ?? this.lastCalculated,
      warningThresholdPercent:
          warningThresholdPercent ?? this.warningThresholdPercent,
      criticalThresholdPercent:
          criticalThresholdPercent ?? this.criticalThresholdPercent,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Convert to database map.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'total_capacity_bytes': totalCapacityBytes,
      'used_bytes': usedBytes,
      'shifts_bytes': shiftsBytes,
      'gps_points_bytes': gpsPointsBytes,
      'logs_bytes': logsBytes,
      'last_calculated': lastCalculated?.toUtc().toIso8601String(),
      'warning_threshold_percent': warningThresholdPercent,
      'critical_threshold_percent': criticalThresholdPercent,
      'created_at': createdAt.toUtc().toIso8601String(),
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }

  /// Create from database map.
  factory StorageMetrics.fromMap(Map<String, dynamic> map) {
    return StorageMetrics(
      id: map['id'] as String? ?? singletonId,
      totalCapacityBytes: map['total_capacity_bytes'] as int? ?? defaultCapacity,
      usedBytes: map['used_bytes'] as int? ?? 0,
      shiftsBytes: map['shifts_bytes'] as int? ?? 0,
      gpsPointsBytes: map['gps_points_bytes'] as int? ?? 0,
      logsBytes: map['logs_bytes'] as int? ?? 0,
      lastCalculated: map['last_calculated'] != null
          ? DateTime.parse(map['last_calculated'] as String)
          : null,
      warningThresholdPercent: map['warning_threshold_percent'] as int? ?? 80,
      criticalThresholdPercent: map['critical_threshold_percent'] as int? ?? 95,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  /// Create default metrics.
  factory StorageMetrics.defaults() {
    final now = DateTime.now().toUtc();
    return StorageMetrics(
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  String toString() {
    return 'StorageMetrics($formattedUsed / $formattedTotal, '
        '${usagePercent.toStringAsFixed(1)}%, status: $statusDescription)';
  }
}
