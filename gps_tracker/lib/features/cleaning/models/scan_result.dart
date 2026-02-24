import 'cleaning_session.dart';

/// Error types for QR scan operations.
enum ScanErrorType {
  invalidQr,
  studioInactive,
  noActiveShift,
  sessionExists,
  noActiveSession;

  String get displayMessage {
    switch (this) {
      case ScanErrorType.invalidQr:
        return 'Code QR non reconnu';
      case ScanErrorType.studioInactive:
        return 'Ce studio n\'est plus actif';
      case ScanErrorType.noActiveShift:
        return 'Veuillez pointer votre quart d\'abord';
      case ScanErrorType.sessionExists:
        return 'Session active existante pour ce studio';
      case ScanErrorType.noActiveSession:
        return 'Aucune session active pour ce studio';
    }
  }
}

/// Result of a QR scan (scan-in or scan-out).
class ScanResult {
  final bool success;
  final CleaningSession? session;
  final ScanErrorType? errorType;
  final String? errorMessage;
  final String? existingSessionId;
  final String? warning;

  const ScanResult({
    required this.success,
    this.session,
    this.errorType,
    this.errorMessage,
    this.existingSessionId,
    this.warning,
  });

  factory ScanResult.success(CleaningSession session, {String? warning}) =>
      ScanResult(
        success: true,
        session: session,
        warning: warning,
      );

  factory ScanResult.error(ScanErrorType type, {String? message, String? existingSessionId}) =>
      ScanResult(
        success: false,
        errorType: type,
        errorMessage: message ?? type.displayMessage,
        existingSessionId: existingSessionId,
      );
}
