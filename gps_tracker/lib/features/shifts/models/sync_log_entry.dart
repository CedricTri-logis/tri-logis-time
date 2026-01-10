import 'dart:convert';

/// Log level for sync operations.
enum SyncLogLevel {
  debug,
  info,
  warn,
  error;

  String get value => name;

  static SyncLogLevel fromString(String value) {
    switch (value) {
      case 'debug':
        return SyncLogLevel.debug;
      case 'info':
        return SyncLogLevel.info;
      case 'warn':
        return SyncLogLevel.warn;
      case 'error':
        return SyncLogLevel.error;
      default:
        return SyncLogLevel.info;
    }
  }

  /// Check if this level is at or above another level.
  bool isAtLeast(SyncLogLevel other) {
    return index >= other.index;
  }
}

/// Model for structured sync log entries.
class SyncLogEntry {
  static const String tableName = 'sync_log_entries';
  static const int maxEntries = 10000;

  final int? id;
  final DateTime timestamp;
  final SyncLogLevel level;
  final String message;
  final Map<String, dynamic>? metadata;
  final DateTime createdAt;

  const SyncLogEntry({
    this.id,
    required this.timestamp,
    required this.level,
    required this.message,
    this.metadata,
    required this.createdAt,
  });

  /// Get formatted log entry for display.
  String get formattedEntry =>
      '[${timestamp.toIso8601String()}] ${level.name.toUpperCase()}: $message';

  /// Get formatted entry with metadata.
  String get formattedEntryWithMetadata {
    if (metadata == null || metadata!.isEmpty) {
      return formattedEntry;
    }
    return '$formattedEntry ${jsonEncode(metadata)}';
  }

  /// Create a copy with modified fields.
  SyncLogEntry copyWith({
    int? id,
    DateTime? timestamp,
    SyncLogLevel? level,
    String? message,
    Map<String, dynamic>? metadata,
    DateTime? createdAt,
  }) {
    return SyncLogEntry(
      id: id ?? this.id,
      timestamp: timestamp ?? this.timestamp,
      level: level ?? this.level,
      message: message ?? this.message,
      metadata: metadata ?? this.metadata,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  /// Convert to database map (for insert).
  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'timestamp': timestamp.toUtc().toIso8601String(),
      'level': level.value,
      'message': message,
      'created_at': createdAt.toUtc().toIso8601String(),
    };

    if (metadata != null) {
      map['metadata'] = jsonEncode(metadata);
    }

    // Don't include id for insert (auto-increment)
    if (id != null) {
      map['id'] = id;
    }

    return map;
  }

  /// Create from database map.
  factory SyncLogEntry.fromMap(Map<String, dynamic> map) {
    Map<String, dynamic>? metadata;
    if (map['metadata'] != null) {
      metadata = jsonDecode(map['metadata'] as String) as Map<String, dynamic>;
    }

    return SyncLogEntry(
      id: map['id'] as int?,
      timestamp: DateTime.parse(map['timestamp'] as String),
      level: SyncLogLevel.fromString(map['level'] as String),
      message: map['message'] as String,
      metadata: metadata,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  /// Create a new log entry with current timestamp.
  factory SyncLogEntry.create({
    required SyncLogLevel level,
    required String message,
    Map<String, dynamic>? metadata,
  }) {
    final now = DateTime.now().toUtc();
    return SyncLogEntry(
      timestamp: now,
      level: level,
      message: message,
      metadata: metadata,
      createdAt: now,
    );
  }

  @override
  String toString() => formattedEntry;
}
