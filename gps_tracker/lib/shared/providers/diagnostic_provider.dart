import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/services/device_id_service.dart';
import '../services/diagnostic_logger.dart';
import '../services/local_database.dart';
import 'supabase_provider.dart';

/// Provider that initializes and manages the DiagnosticLogger singleton.
///
/// Ensures logger is initialized with current auth context and updates
/// employeeId when auth state changes.
final diagnosticLoggerProvider = Provider<DiagnosticLogger?>((ref) {
  // Watch auth state to update employeeId on sign-in/out
  final user = ref.watch(currentUserProvider);

  if (DiagnosticLogger.isInitialized) {
    DiagnosticLogger.instance.setEmployeeId(user?.id);
    return DiagnosticLogger.instance;
  }

  return null;
});

/// Initialize the DiagnosticLogger singleton.
///
/// Called once at app startup after LocalDatabase is ready.
/// Returns the initialized logger instance.
Future<DiagnosticLogger> initializeDiagnosticLogger({
  String? employeeId,
}) async {
  final deviceId = await DeviceIdService.getDeviceId();

  return DiagnosticLogger.initialize(
    localDb: LocalDatabase(),
    deviceId: deviceId,
    employeeId: employeeId,
  );
}
