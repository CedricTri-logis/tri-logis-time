import 'dart:math';

/// Exponential backoff strategy with jitter for sync retry logic.
class ExponentialBackoff {
  /// Base delay (30 seconds as per spec).
  static const Duration baseDelay = Duration(seconds: 30);

  /// Maximum delay (15 minutes as per spec).
  static const Duration maxDelay = Duration(minutes: 15);

  /// Jitter factor (±10% as per spec).
  static const double jitterFactor = 0.1;

  /// Rate limit multiplier (double backoff for HTTP 429).
  static const double rateLimitMultiplier = 2.0;

  final Random _random;

  /// Current attempt number (0-based).
  int _attempt;

  /// Whether rate limiting was detected.
  bool _isRateLimited;

  ExponentialBackoff({int initialAttempt = 0})
      : _random = Random(),
        _attempt = initialAttempt,
        _isRateLimited = false;

  /// Get current attempt number.
  int get attempt => _attempt;

  /// Check if any retries have occurred.
  bool get hasRetried => _attempt > 0;

  /// Get the delay for the current attempt.
  Duration getDelay() {
    // Calculate exponential delay: baseDelay * 2^attempt
    final exponentialMs = baseDelay.inMilliseconds * pow(2, _attempt).toInt();

    // Apply rate limit multiplier if needed
    final adjustedMs = _isRateLimited
        ? (exponentialMs * rateLimitMultiplier).toInt()
        : exponentialMs;

    // Cap at max delay
    final cappedMs = adjustedMs > maxDelay.inMilliseconds
        ? maxDelay.inMilliseconds
        : adjustedMs;

    // Apply jitter (±10%)
    final jitterRange = cappedMs * jitterFactor;
    final jitter = (_random.nextDouble() - 0.5) * 2 * jitterRange;
    final finalMs = (cappedMs + jitter).round();

    return Duration(milliseconds: finalMs);
  }

  /// Get the delay for the next attempt (increments attempt counter).
  Duration getNextDelay() {
    _attempt++;
    return getDelay();
  }

  /// Mark that rate limiting was detected (HTTP 429).
  void markRateLimited() {
    _isRateLimited = true;
  }

  /// Reset the backoff state after successful sync.
  void reset() {
    _attempt = 0;
    _isRateLimited = false;
  }

  /// Create from persisted state.
  factory ExponentialBackoff.fromState({
    required int consecutiveFailures,
    bool isRateLimited = false,
  }) {
    final backoff = ExponentialBackoff(initialAttempt: consecutiveFailures);
    if (isRateLimited) {
      backoff.markRateLimited();
    }
    return backoff;
  }

  /// Calculate delay without modifying state (for display purposes).
  Duration calculateDelay(int attempt, {bool isRateLimited = false}) {
    final exponentialMs = baseDelay.inMilliseconds * pow(2, attempt).toInt();

    final adjustedMs = isRateLimited
        ? (exponentialMs * rateLimitMultiplier).toInt()
        : exponentialMs;

    final cappedMs = adjustedMs > maxDelay.inMilliseconds
        ? maxDelay.inMilliseconds
        : adjustedMs;

    // Apply jitter
    final jitterRange = cappedMs * jitterFactor;
    final jitter = (_random.nextDouble() - 0.5) * 2 * jitterRange;
    final finalMs = (cappedMs + jitter).round();

    return Duration(milliseconds: finalMs);
  }

  /// Get approximate retry schedule (without jitter) for display.
  static List<Duration> getRetrySchedule({int maxAttempts = 10}) {
    final schedule = <Duration>[];
    for (int i = 0; i < maxAttempts; i++) {
      final ms = baseDelay.inMilliseconds * pow(2, i).toInt();
      final capped = ms > maxDelay.inMilliseconds ? maxDelay.inMilliseconds : ms;
      schedule.add(Duration(milliseconds: capped));
    }
    return schedule;
  }

  @override
  String toString() {
    final delay = getDelay();
    return 'ExponentialBackoff(attempt: $_attempt, delay: ${delay.inSeconds}s, '
        'rateLimited: $_isRateLimited)';
  }
}
