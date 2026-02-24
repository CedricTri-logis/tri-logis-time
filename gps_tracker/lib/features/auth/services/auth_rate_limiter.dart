/// Client-side rate limiter for authentication attempts
///
/// Implements a sliding window rate limit of [maxAttempts] attempts
/// per [windowMinutes] minutes. This provides immediate feedback to
/// users before hitting server-side rate limits.
class AuthRateLimiter {
  /// Maximum number of attempts allowed in the window
  static const int maxAttempts = 5;

  /// Window size in minutes
  static const int windowMinutes = 15;

  final List<DateTime> _attempts = [];

  /// Check if an attempt is allowed
  ///
  /// Returns true if under the rate limit, false if blocked.
  bool canAttempt() {
    _cleanOldAttempts();
    return _attempts.length < maxAttempts;
  }

  /// Record a new attempt
  ///
  /// Should be called after each authentication attempt (success or failure).
  void recordAttempt() {
    _attempts.add(DateTime.now());
  }

  /// Get remaining lockout duration if blocked
  ///
  /// Returns null if not blocked, or the duration until the oldest
  /// attempt expires and a new attempt is allowed.
  Duration? getRemainingLockout() {
    _cleanOldAttempts();

    if (_attempts.length < maxAttempts) {
      return null;
    }

    final oldest = _attempts.first;
    final unlockTime = oldest.add(const Duration(minutes: windowMinutes));
    final remaining = unlockTime.difference(DateTime.now());

    return remaining.isNegative ? null : remaining;
  }

  /// Get the number of remaining attempts
  int get remainingAttempts {
    _cleanOldAttempts();
    return (maxAttempts - _attempts.length).clamp(0, maxAttempts);
  }

  /// Reset the rate limiter (e.g., after successful login)
  void reset() {
    _attempts.clear();
  }

  /// Remove attempts older than the window
  void _cleanOldAttempts() {
    final cutoff = DateTime.now().subtract(const Duration(minutes: windowMinutes));
    _attempts.removeWhere((attempt) => attempt.isBefore(cutoff));
  }

  /// Format lockout duration for display
  static String formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;

    if (minutes > 0) {
      return '$minutes minute${minutes == 1 ? '' : 's'} $seconds seconde${seconds == 1 ? '' : 's'}';
    }
    return '$seconds seconde${seconds == 1 ? '' : 's'}';
  }
}
