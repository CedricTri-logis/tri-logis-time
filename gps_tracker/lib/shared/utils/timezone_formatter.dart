import 'package:intl/intl.dart';

/// Utility class for formatting timestamps with timezone indicators.
///
/// All timestamps are stored in UTC and converted to local time for display.
/// This class provides methods that append timezone abbreviations to formatted times.
class TimezoneFormatter {
  /// Get the local timezone abbreviation (e.g., "EST", "PST", "UTC")
  static String get timezoneAbbreviation {
    final now = DateTime.now();
    return now.timeZoneName;
  }

  /// Format time with timezone indicator (e.g., "2:30 PM EST")
  static String formatTimeWithTz(DateTime utcTime) {
    final localTime = utcTime.toLocal();
    final timeStr = DateFormat.jm().format(localTime);
    return '$timeStr $timezoneAbbreviation';
  }

  /// Format time with seconds and timezone (e.g., "2:30:45 PM EST")
  static String formatTimeWithSecondsTz(DateTime utcTime) {
    final localTime = utcTime.toLocal();
    final timeStr = DateFormat.jms().format(localTime);
    return '$timeStr $timezoneAbbreviation';
  }

  /// Format date and time with timezone (e.g., "Jan 15, 2:30 PM EST")
  static String formatDateTimeWithTz(DateTime utcTime) {
    final localTime = utcTime.toLocal();
    final dateTimeStr = DateFormat('MMM d, h:mm a').format(localTime);
    return '$dateTimeStr $timezoneAbbreviation';
  }

  /// Format date with timezone context (e.g., "Jan 15, 2025 (EST)")
  static String formatDateWithTz(DateTime utcTime) {
    final localTime = utcTime.toLocal();
    final dateStr = DateFormat.yMMMd().format(localTime);
    return '$dateStr ($timezoneAbbreviation)';
  }

  /// Format full date with timezone (e.g., "January 15, 2025 (EST)")
  static String formatFullDateWithTz(DateTime utcTime) {
    final localTime = utcTime.toLocal();
    final dateStr = DateFormat.yMMMMd().format(localTime);
    return '$dateStr ($timezoneAbbreviation)';
  }

  /// Format time for marker info windows (e.g., "Jan 15, 2:30 PM")
  /// Returns format without timezone for space-constrained UI elements
  static String formatForMarker(DateTime utcTime) {
    final localTime = utcTime.toLocal();
    return DateFormat('MMM d, h:mm a').format(localTime);
  }

  /// Format time with seconds for marker info windows
  static String formatTimeWithSecondsForMarker(DateTime utcTime) {
    final localTime = utcTime.toLocal();
    return DateFormat('h:mm:ss a').format(localTime);
  }

  /// Get a compact timezone indicator widget text
  /// Returns just the timezone abbreviation
  static String get compactTzIndicator => timezoneAbbreviation;
}
