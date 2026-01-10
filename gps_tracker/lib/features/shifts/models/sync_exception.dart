/// Error codes for sync operations.
enum SyncErrorCode {
  /// Network unavailable
  noConnection,

  /// Server returned an error response
  serverError,

  /// Request timed out
  timeout,

  /// Authentication failed
  authError,

  /// Rate limited by server
  rateLimited,

  /// Data validation failed
  validationError,

  /// Conflict with server data
  conflict,

  /// Unknown error
  unknown,
}

/// Exception thrown during sync operations.
class SyncException implements Exception {
  /// The error code for this exception.
  final SyncErrorCode code;

  /// Human-readable error message.
  final String message;

  /// HTTP status code if applicable.
  final int? httpStatusCode;

  /// Original error that caused this exception.
  final Object? originalError;

  /// Stack trace from original error.
  final StackTrace? stackTrace;

  const SyncException({
    required this.code,
    required this.message,
    this.httpStatusCode,
    this.originalError,
    this.stackTrace,
  });

  /// Check if this error is retryable.
  bool get isRetryable {
    switch (code) {
      case SyncErrorCode.noConnection:
      case SyncErrorCode.serverError:
      case SyncErrorCode.timeout:
      case SyncErrorCode.rateLimited:
        return true;
      case SyncErrorCode.authError:
      case SyncErrorCode.validationError:
      case SyncErrorCode.conflict:
      case SyncErrorCode.unknown:
        return false;
    }
  }

  /// Check if this error should trigger extended backoff.
  bool get shouldExtendBackoff {
    return code == SyncErrorCode.rateLimited;
  }

  /// Check if record should be quarantined.
  bool get shouldQuarantine {
    return code == SyncErrorCode.validationError ||
        code == SyncErrorCode.conflict;
  }

  /// Create from HTTP status code.
  factory SyncException.fromHttpStatus(int statusCode, [String? message]) {
    final code = _httpStatusToErrorCode(statusCode);
    return SyncException(
      code: code,
      message: message ?? _defaultMessageForCode(code),
      httpStatusCode: statusCode,
    );
  }

  /// Create from generic error.
  factory SyncException.fromError(Object error, [StackTrace? stackTrace]) {
    final message = error.toString();

    // Try to detect network errors
    if (message.contains('SocketException') ||
        message.contains('Connection refused') ||
        message.contains('No address associated')) {
      return SyncException(
        code: SyncErrorCode.noConnection,
        message: 'Network connection unavailable',
        originalError: error,
        stackTrace: stackTrace,
      );
    }

    // Try to detect timeout
    if (message.contains('TimeoutException') ||
        message.contains('timed out')) {
      return SyncException(
        code: SyncErrorCode.timeout,
        message: 'Request timed out',
        originalError: error,
        stackTrace: stackTrace,
      );
    }

    return SyncException(
      code: SyncErrorCode.unknown,
      message: message,
      originalError: error,
      stackTrace: stackTrace,
    );
  }

  /// Create a no connection exception.
  factory SyncException.noConnection() => const SyncException(
        code: SyncErrorCode.noConnection,
        message: 'No network connection available',
      );

  /// Create a timeout exception.
  factory SyncException.timeout() => const SyncException(
        code: SyncErrorCode.timeout,
        message: 'Request timed out',
      );

  /// Create a validation error exception.
  factory SyncException.validation(String message) => SyncException(
        code: SyncErrorCode.validationError,
        message: message,
      );

  /// Create a conflict exception.
  factory SyncException.conflict(String message) => SyncException(
        code: SyncErrorCode.conflict,
        message: message,
      );

  static SyncErrorCode _httpStatusToErrorCode(int statusCode) {
    if (statusCode == 401 || statusCode == 403) {
      return SyncErrorCode.authError;
    }
    if (statusCode == 429) {
      return SyncErrorCode.rateLimited;
    }
    if (statusCode == 409) {
      return SyncErrorCode.conflict;
    }
    if (statusCode >= 400 && statusCode < 500) {
      return SyncErrorCode.validationError;
    }
    if (statusCode >= 500) {
      return SyncErrorCode.serverError;
    }
    return SyncErrorCode.unknown;
  }

  static String _defaultMessageForCode(SyncErrorCode code) {
    switch (code) {
      case SyncErrorCode.noConnection:
        return 'No network connection available';
      case SyncErrorCode.serverError:
        return 'Server error occurred';
      case SyncErrorCode.timeout:
        return 'Request timed out';
      case SyncErrorCode.authError:
        return 'Authentication failed';
      case SyncErrorCode.rateLimited:
        return 'Too many requests, please wait';
      case SyncErrorCode.validationError:
        return 'Data validation failed';
      case SyncErrorCode.conflict:
        return 'Data conflict detected';
      case SyncErrorCode.unknown:
        return 'An unknown error occurred';
    }
  }

  @override
  String toString() =>
      'SyncException(${code.name}: $message${httpStatusCode != null ? ' [HTTP $httpStatusCode]' : ''})';
}
