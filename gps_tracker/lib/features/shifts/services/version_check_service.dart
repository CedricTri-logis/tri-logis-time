import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../shared/models/diagnostic_event.dart';
import '../../../shared/services/diagnostic_logger.dart';

/// Result of a version check before clock-in.
class VersionCheckResult {
  final bool allowed;
  final String? currentVersion;
  final String? minimumVersion;
  final String? message;

  const VersionCheckResult({
    required this.allowed,
    this.currentVersion,
    this.minimumVersion,
    this.message,
  });

  factory VersionCheckResult.ok() => const VersionCheckResult(allowed: true);

  factory VersionCheckResult.updateRequired({
    required String currentVersion,
    required String minimumVersion,
  }) =>
      VersionCheckResult(
        allowed: false,
        currentVersion: currentVersion,
        minimumVersion: minimumVersion,
        message:
            'Votre version ($currentVersion) est trop ancienne. '
            'Veuillez mettre à jour vers la version $minimumVersion ou plus récente.',
      );

  factory VersionCheckResult.error(String message) =>
      VersionCheckResult(allowed: true, message: message);
}

/// Service to check if the current app version meets minimum requirements.
class VersionCheckService {
  final SupabaseClient _client;

  VersionCheckService(this._client);

  /// Check if the current app version is allowed to clock in.
  /// Returns [VersionCheckResult.ok] if allowed, or [VersionCheckResult.updateRequired]
  /// if the app needs updating. On network errors, allows clock-in (fail-open).
  Future<VersionCheckResult> checkVersionForClockIn() async {
    try {
      final response = await _client
          .from('app_config')
          .select('value')
          .eq('key', 'minimum_app_version')
          .maybeSingle();

      if (response == null) {
        // No minimum version configured — allow clock-in
        return VersionCheckResult.ok();
      }

      final minimumVersion = response['value'] as String;
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = '${packageInfo.version}+${packageInfo.buildNumber}';

      if (_isVersionSufficient(currentVersion, minimumVersion)) {
        return VersionCheckResult.ok();
      }

      return VersionCheckResult.updateRequired(
        currentVersion: currentVersion,
        minimumVersion: minimumVersion,
      );
    } catch (e) {
      // Fail-open: if we can't check, allow clock-in
      if (DiagnosticLogger.isInitialized) {
        DiagnosticLogger.instance.lifecycle(Severity.warn, 'Version check failed', metadata: {'error': e.toString()});
      }
      return VersionCheckResult.error(e.toString());
    }
  }

  /// Compare versions. Returns true if [current] >= [minimum].
  /// Format: "major.minor.patch+build" (e.g., "1.0.0+9").
  static bool _isVersionSufficient(String current, String minimum) {
    try {
      final currentParts = _parseVersion(current);
      final minimumParts = _parseVersion(minimum);

      // Compare major.minor.patch
      for (var i = 0; i < 3; i++) {
        if (currentParts[i] > minimumParts[i]) return true;
        if (currentParts[i] < minimumParts[i]) return false;
      }

      // Versions equal in major.minor.patch — compare build number
      return currentParts[3] >= minimumParts[3];
    } catch (e) {
      if (DiagnosticLogger.isInitialized) {
        DiagnosticLogger.instance.lifecycle(Severity.warn, 'Version parse failed', metadata: {'error': e.toString()});
      }
      return true; // Fail-open on parse error
    }
  }

  /// Parse "major.minor.patch+build" into [major, minor, patch, build].
  /// Also handles build-number-only strings like "73" → [1, 0, 0, 73].
  static List<int> _parseVersion(String version) {
    // Split on '+' to separate version from build number
    final plusParts = version.split('+');
    final versionPart = plusParts[0]; // "1.0.0" or "73"
    final buildPart = plusParts.length > 1 ? plusParts[1] : '0';

    // If the version part has no dots and no '+', it's just a build number
    // (e.g., "73" stored by accident instead of "1.0.0+73").
    if (!version.contains('.') && !version.contains('+')) {
      return [1, 0, 0, int.parse(version)];
    }

    final versionNumbers = versionPart.split('.').map((s) => int.parse(s)).toList();

    // Pad to 3 elements if needed
    while (versionNumbers.length < 3) {
      versionNumbers.add(0);
    }

    // Add build number
    versionNumbers.add(int.parse(buildPart));

    return versionNumbers;
  }
}
