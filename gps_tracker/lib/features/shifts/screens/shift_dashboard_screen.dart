import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/models/diagnostic_event.dart';
import '../../../shared/providers/supabase_provider.dart';
import '../../../shared/services/diagnostic_logger.dart';
import '../../tracking/models/device_location_status.dart';
import '../../tracking/models/location_permission_state.dart';
import '../../tracking/models/permission_change_event.dart';
import '../../tracking/models/permission_guard_state.dart';
import '../../tracking/providers/permission_guard_provider.dart';
import '../../tracking/providers/tracking_provider.dart';
import '../../tracking/screens/battery_health_screen.dart';
import '../../tracking/services/background_execution_service.dart';
import '../../tracking/services/android_battery_health_service.dart';
import '../../tracking/services/background_tracking_service.dart';
import '../../tracking/services/permission_monitor_service.dart';
import '../../tracking/services/significant_location_service.dart';
import '../../tracking/widgets/battery_optimization_dialog.dart';
import '../../tracking/widgets/device_services_dialog.dart';
import '../../tracking/widgets/oem_battery_guide_dialog.dart';
import '../../tracking/widgets/permission_change_alert.dart';
import '../../tracking/widgets/permission_explanation_dialog.dart';
import '../../tracking/widgets/samsung_standby_dialog.dart';
import '../../cleaning/providers/cleaning_session_provider.dart';
import '../../cleaning/screens/qr_scanner_screen.dart';
import '../../cleaning/widgets/active_session_card.dart';
import '../../cleaning/widgets/cleaning_history_list.dart';
import '../../maintenance/providers/maintenance_provider.dart';
import '../../maintenance/widgets/active_maintenance_card.dart';
import '../../maintenance/widgets/building_picker_sheet.dart';
import '../../maintenance/widgets/maintenance_history_list.dart';
import '../../tracking/widgets/permission_status_banner.dart';
import '../../tracking/widgets/precise_location_dialog.dart';
import '../../tracking/widgets/settings_guidance_dialog.dart';
import '../models/geo_point.dart';
import '../models/shift.dart';
import '../providers/connectivity_provider.dart';
import '../providers/location_provider.dart';
import '../providers/shift_provider.dart';
import '../providers/sync_provider.dart';
import '../services/version_check_service.dart';
import '../widgets/clock_button.dart';
import '../widgets/shift_status_card.dart';
import '../widgets/shift_timer.dart';

/// Tab selection for the shift dashboard.
enum _DashboardTab { menager, entretien }

/// Main dashboard screen for shift management.
class ShiftDashboardScreen extends ConsumerStatefulWidget {
  const ShiftDashboardScreen({super.key});

  @override
  ConsumerState<ShiftDashboardScreen> createState() =>
      _ShiftDashboardScreenState();
}

class _ShiftDashboardScreenState extends ConsumerState<ShiftDashboardScreen>
    with WidgetsBindingObserver {
  /// Grace period duration before auto clock-out when GPS is lost (5 minutes).
  static const _gpsGracePeriodDuration = Duration(minutes: 5);

  /// Timer for the GPS grace period countdown.
  Timer? _gpsGracePeriodTimer;

  /// Timer for updating the countdown display.
  Timer? _countdownDisplayTimer;

  /// When GPS was lost (null if GPS is available).
  DateTime? _gpsLostAt;

  /// Whether an auto clock-out warning is currently being shown.
  bool _isShowingGpsWarning = false;
  bool _isClockInPreparing = false;
  bool _cancelClockInPreparing = false;

  /// Currently selected tab (ménager / entretien).
  _DashboardTab _selectedTab = _DashboardTab.menager;

  DiagnosticLogger? get _logger =>
      DiagnosticLogger.isInitialized ? DiagnosticLogger.instance : null;

  Future<void> _logClockInEnvironmentSnapshot() async {
    try {
      final locationService = ref.read(locationServiceProvider);
      final connectivityService = ref.read(connectivityServiceProvider);
      final packageInfo = await PackageInfo.fromPlatform();
      final permission = await locationService.checkPermission();
      final locationServiceEnabled =
          await locationService.isLocationServiceEnabled();
      final networkConnected = await connectivityService.isConnected();
      final networkType = await connectivityService.getNetworkType();
      final guardState = ref.read(permissionGuardProvider);

      bool? batteryOptimizationDisabled;
      bool? backgroundSessionActive;
      bool? significantLocationMonitoring;
      String? locationAccuracy;

      if (Platform.isAndroid) {
        batteryOptimizationDisabled =
            await BackgroundTrackingService.isBatteryOptimizationDisabled;
      }
      if (Platform.isIOS) {
        try {
          final accuracy = await Geolocator.getLocationAccuracy();
          locationAccuracy = accuracy.name;
        } catch (_) {}
        backgroundSessionActive =
            await BackgroundExecutionService.isBackgroundSessionActive();
        significantLocationMonitoring =
            await SignificantLocationService.isMonitoring();
      }

      await _logger?.shift(
        Severity.info,
        Platform.isIOS ? 'Clock-in iOS snapshot' : 'Clock-in Android snapshot',
        metadata: {
          'platform': Platform.isIOS ? 'ios' : 'android',
          'app_version': '${packageInfo.version}+${packageInfo.buildNumber}',
          'location_permission': permission.name,
          if (locationAccuracy != null)
            'location_accuracy_authorization': locationAccuracy,
          'location_service_enabled': locationServiceEnabled,
          'network_connected': networkConnected,
          'network_type': networkType.name,
          if (batteryOptimizationDisabled != null)
            'battery_optimization_disabled': batteryOptimizationDisabled,
          if (backgroundSessionActive != null)
            'background_session_active': backgroundSessionActive,
          if (significantLocationMonitoring != null)
            'significant_location_monitoring': significantLocationMonitoring,
          'guard_should_block_clock_in': guardState.shouldBlockClockIn,
          'guard_should_warn_on_clock_in': guardState.shouldWarnOnClockIn,
          'guard_permission_level': guardState.permission.level.name,
          'guard_device_status': guardState.deviceStatus.name,
          'guard_precise_location_enabled': guardState.isPreciseLocationEnabled,
        },
      );
    } catch (e) {
      await _logger?.shift(
        Severity.warn,
        Platform.isIOS
            ? 'Clock-in iOS snapshot failed'
            : 'Clock-in Android snapshot failed',
        metadata: {'error': e.toString()},
      );
    } finally {
      ref.read(syncProvider.notifier).notifyPendingData();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _cancelGpsGracePeriod();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Refresh shift state when app resumes
      ref.read(shiftProvider.notifier).refresh();
      // Refresh tracking state to sync with background service
      ref.read(trackingProvider.notifier).refreshState();
      // Re-check permission status on resume (e.g., after returning from settings)
      ref.read(permissionGuardProvider.notifier).checkStatus();
      unawaited(_checkBatteryHealthOnResume());
      // Verify shift is still active server-side (catches changes missed while backgrounded)
      _reconcileShiftWithServer();
    }
  }

  Future<void> _checkBatteryHealthOnResume() async {
    if (!Platform.isAndroid || !mounted) return;

    final lostExemption =
        await AndroidBatteryHealthService.hasLostBatteryOptimizationExemption();
    if (!lostExemption || !mounted) return;

    await _logger?.permission(
      Severity.warn,
      'Battery optimization exemption lost on resume',
    );

    await BatteryOptimizationDialog.show(context);
    if (!mounted) return;
    await OemBatteryGuideDialog.showIfNeeded(context, force: true);
    if (!mounted) return;

    await ref.read(permissionGuardProvider.notifier).checkStatus();
  }

  /// Check with Supabase that the active shift hasn't been closed server-side
  /// while the app was in the background (admin action, zombie cleanup, etc.).
  Future<void> _reconcileShiftWithServer() async {
    final activeShift = ref.read(shiftProvider).activeShift;
    if (activeShift?.serverId == null) return;

    try {
      final serverShift = await Supabase.instance.client
          .from('shifts')
          .select('status')
          .eq('id', activeShift!.serverId!)
          .maybeSingle();

      if (serverShift != null && serverShift['status'] != 'active') {
        // Shift was closed server-side while app was backgrounded
        debugPrint('Reconciliation: shift ${activeShift.serverId} '
            'is ${serverShift['status']} on server — refreshing');
        ref.read(shiftProvider.notifier).refresh();
      }
    } catch (_) {
      // Fail-open: if we can't verify, continue with local state
    }
  }

  /// Returns settings navigation instructions matching the device language.
  String _locationSettingsInstructions() {
    final locale = Localizations.localeOf(context).languageCode;
    if (Platform.isIOS) {
      return switch (locale) {
        'en' => 'Go to:\nSettings > Tri-Logis Time > Location > Always',
        _ => 'Allez dans :\nRéglages > Tri-Logis Time > Position > Toujours',
      };
    } else {
      return switch (locale) {
        'en' =>
          'Go to:\nSettings > Apps > Tri-Logis Time > Permissions > Location > Allow all the time',
        _ =>
          'Allez dans :\nParamètres > Applications > Tri-Logis Time > Autorisations > Position > Toujours autoriser',
      };
    }
  }

  Future<void> _handleClockIn() async {
    if (_isClockInPreparing) return;
    setState(() {
      _isClockInPreparing = true;
      _cancelClockInPreparing = false;
    });

    try {
      await _logClockInEnvironmentSnapshot();

      // Version check: block clock-in if app is outdated
      final versionResult = await VersionCheckService(
        ref.read(supabaseClientProvider),
      ).checkVersionForClockIn();

      if (!versionResult.allowed) {
        if (!mounted) return;
        _showUpdateRequiredDialog(versionResult);
        return;
      }

      final locationService = ref.read(locationServiceProvider);
      final shiftNotifier = ref.read(shiftProvider.notifier);

      // Fresh permission check before clock-in to avoid race condition
      // (initial state defaults to optimistic values before async check completes)
      await ref.read(permissionGuardProvider.notifier).checkStatus(immediate: true);
      if (!mounted) return;
      final guardState = ref.read(permissionGuardProvider);

      // Pre-shift permission check: Block if critical permission issue
      if (guardState.shouldBlockClockIn) {
        if (!mounted) return;
        await _handlePermissionBlock(guardState);
        return;
      }

      // Pre-shift permission check: Warn if partial permission
      if (guardState.shouldWarnOnClockIn) {
        if (!mounted) return;
        final proceed = await _showClockInWarningDialog(guardState);
        if (!proceed) return;
      }

      // Check and request location permission (fallback to legacy behavior)
      final hasPermission = await locationService.ensureLocationPermission();

      if (!hasPermission) {
        if (!mounted) return;

        final permission = await locationService.checkPermission();
        if (permission == LocationPermission.deniedForever) {
          _showLocationSettingsDialog();
          return;
        } else {
          _showLocationPermissionDialog();
          return;
        }
      }

      // Show loading indicator
      if (!mounted) return;

      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 16),
              const Expanded(
                child: Text('Validation du démarrage du suivi...'),
              ),
            ],
          ),
          duration: const Duration(days: 1),
          action: SnackBarAction(
            label: 'Annuler',
            textColor: Colors.white,
            onPressed: () {
              _cancelClockInPreparing = true;
            },
          ),
        ),
      );

      final waitStopwatch = Stopwatch()..start();
      var gpsAttempt = 0;
      _logger?.gps(
        Severity.info,
        'Clock-in GPS validation started',
      );

      // Keep trying until a valid GPS point is obtained (or user cancels).
      ({GeoPoint? location, double? accuracy, String? failureReason}) gpsResult;
      while (true) {
        if (_cancelClockInPreparing || !mounted) {
          _logger?.gps(
            Severity.warn,
            'Clock-in GPS validation cancelled',
            metadata: {
              'attempts': gpsAttempt,
              'elapsed_ms': waitStopwatch.elapsedMilliseconds,
            },
          );
          ref.read(syncProvider.notifier).notifyPendingData();
          messenger.hideCurrentSnackBar();
          return;
        }

        gpsAttempt++;
        gpsResult = await locationService.verifyGpsForClockIn();
        final failure = gpsResult.failureReason;

        if (failure == null && gpsResult.location != null) {
          _logger?.gps(
            Severity.info,
            'Clock-in GPS validation succeeded',
            metadata: {
              'attempt': gpsAttempt,
              'elapsed_ms': waitStopwatch.elapsedMilliseconds,
              'accuracy': gpsResult.accuracy,
            },
          );
          ref.read(syncProvider.notifier).notifyPendingData();
          break;
        }

        _logger?.gps(
          Severity.warn,
          'Clock-in GPS validation attempt failed',
          metadata: {
            'attempt': gpsAttempt,
            'failure_reason': failure,
            'elapsed_ms': waitStopwatch.elapsedMilliseconds,
          },
        );
        ref.read(syncProvider.notifier).notifyPendingData();

        if (failure == 'permission_denied') {
          messenger.hideCurrentSnackBar();
          final permission = await locationService.checkPermission();
          if (permission == LocationPermission.deniedForever) {
            _showLocationSettingsDialog();
          } else {
            _showLocationPermissionDialog();
          }
          return;
        }

        await Future<void>.delayed(const Duration(seconds: 2));
      }

      if (!mounted) return;
      messenger.hideCurrentSnackBar();

      // Clock in (location is guaranteed non-null after validation above)
      final success = await shiftNotifier.clockIn(
        location: gpsResult.location!,
        accuracy: gpsResult.accuracy,
      );

      if (!mounted) return;
      messenger.hideCurrentSnackBar();

      if (success) {
        // Notify permission guard of active shift for monitoring
        ref.read(permissionGuardProvider.notifier).setActiveShift(true);
        _startPermissionMonitoring();

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 12),
                Text('Quart débuté!'),
              ],
            ),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      } else {
        final error = ref.read(shiftProvider).error;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(child: Text(error ?? 'Échec du démarrage du quart')),
              ],
            ),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isClockInPreparing = false;
          _cancelClockInPreparing = false;
        });
      } else {
        _isClockInPreparing = false;
        _cancelClockInPreparing = false;
      }
    }
  }

  /// Handle permission blocking - show appropriate dialog based on state.
  Future<void> _handlePermissionBlock(PermissionGuardState guardState) async {
    if (guardState.deviceStatus == DeviceLocationStatus.disabled) {
      await DeviceServicesDialog.show(context);
    } else if (guardState.permission.level ==
        LocationPermissionLevel.deniedForever) {
      await SettingsGuidanceDialog.show(context);
    } else if (guardState.permission.level ==
        LocationPermissionLevel.whileInUse) {
      // Has "While In Use" but needs "Always" for background tracking
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.location_off, color: Colors.orange),
              SizedBox(width: 8),
              Expanded(child: Text('Permission insuffisante')),
            ],
          ),
          content: Text(
            'Le suivi GPS nécessite la permission "Toujours" pour fonctionner '
            'en arrière-plan pendant votre quart.\n\n'
            '${_locationSettingsInstructions()}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await ref
                    .read(permissionGuardProvider.notifier)
                    .openAppSettings();
              },
              child: const Text('Ouvrir réglages'),
            ),
          ],
        ),
      );
    } else if (!guardState.isBatteryOptimizationDisabled) {
      // Battery optimization must be disabled for reliable background tracking
      if (!mounted) return;
      await BatteryOptimizationDialog.show(context);
    } else if (guardState.isAppStandbyRestricted) {
      if (!mounted) return;
      await SamsungStandbyDialog.show(context);
    } else if (!guardState.isPreciseLocationEnabled) {
      // Precise/exact location must be enabled for GPS tracking
      if (!mounted) return;
      await PreciseLocationDialog.show(context);
    } else {
      // Permission not granted yet
      final proceed = await PermissionExplanationDialog.show(context);
      if (proceed && mounted) {
        await ref.read(permissionGuardProvider.notifier).requestPermission();
      }
    }
    // Re-check status after dialog closed
    if (mounted) {
      await ref.read(permissionGuardProvider.notifier).checkStatus();
    }
  }

  /// Show warning dialog for partial permission and allow user to proceed or fix.
  Future<bool> _showClockInWarningDialog(
      PermissionGuardState guardState) async {
    final theme = Theme.of(context);

    // Determine warning type
    final bool isPartialPermission =
        guardState.permission.level == LocationPermissionLevel.whileInUse;
    final bool isBatteryOptimization =
        guardState.isBatteryOptimizationDisabled == false && Platform.isAndroid;

    String title;
    String message;
    String fixLabel;

    if (isPartialPermission) {
      title = 'Suivi limité';
      message =
          'Vous avez la permission "en cours d\'utilisation" seulement. Le suivi en '
          'arrière-plan peut être interrompu quand l\'app n\'est pas visible. Continuer quand même?';
      fixLabel = 'Améliorer permission';
    } else if (isBatteryOptimization) {
      title = 'Optimisation batterie';
      message =
          'L\'optimisation de batterie peut interrompre le suivi GPS pendant votre quart. '
          'Nous recommandons de la désactiver pour cette app. Continuer quand même?';
      fixLabel = 'Désactiver optimisation';
    } else {
      title = 'Avertissement';
      message =
          'Il pourrait y avoir des problèmes avec le suivi GPS. Continuer quand même?';
      fixLabel = 'Corriger';
    }

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning_amber, color: Colors.orange.shade700),
            const SizedBox(width: 8),
            Text(title),
          ],
        ),
        content: Text(
          message,
          style: theme.textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('cancel'),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('fix'),
            child: Text(fixLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop('proceed'),
            child: const Text('Continuer quand même'),
          ),
        ],
      ),
    );

    if (result == 'fix') {
      // Handle fix action
      if (isPartialPermission) {
        // On Android 10+, must open app settings to upgrade from "while in use" to "always"
        await ref.read(permissionGuardProvider.notifier).openAppSettings();
      } else if (isBatteryOptimization) {
        await BatteryOptimizationDialog.show(context);
      }
      // Re-check status
      if (mounted) {
        await ref.read(permissionGuardProvider.notifier).checkStatus();
      }
      return false; // Don't proceed, let user try again
    }

    return result == 'proceed';
  }

  /// Start monitoring for permission changes during active shift.
  void _startPermissionMonitoring() {
    final monitor = ref.read(permissionMonitorProvider);
    monitor.startMonitoring(
      onChanged: _handlePermissionChange,
      intervalSeconds: 30,
    );
  }

  /// Stop monitoring for permission changes.
  void _stopPermissionMonitoring() {
    final monitor = ref.read(permissionMonitorProvider);
    monitor.stopMonitoring();
  }

  /// Start the GPS grace period countdown when GPS is lost.
  void _startGpsGracePeriod() {
    // Don't start if already running
    if (_gpsLostAt != null) return;

    _gpsLostAt = DateTime.now();

    // Start the main timer that will trigger auto clock-out
    _gpsGracePeriodTimer = Timer(_gpsGracePeriodDuration, () {
      _forceClockOut();
    });

    // Start a display timer to update the UI every second
    _countdownDisplayTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (mounted) setState(() {});
      },
    );

    // Show the warning dialog
    _showGpsLostWarningDialog();
  }

  /// Cancel the GPS grace period (called when GPS is restored or shift ends).
  void _cancelGpsGracePeriod() {
    _gpsGracePeriodTimer?.cancel();
    _gpsGracePeriodTimer = null;
    _countdownDisplayTimer?.cancel();
    _countdownDisplayTimer = null;
    _gpsLostAt = null;
    _isShowingGpsWarning = false;
  }

  /// Get remaining seconds in the grace period.
  int get _gracePeriodSecondsRemaining {
    if (_gpsLostAt == null) return 0;
    final elapsed = DateTime.now().difference(_gpsLostAt!);
    final remaining = _gpsGracePeriodDuration - elapsed;
    return remaining.inSeconds.clamp(0, _gpsGracePeriodDuration.inSeconds);
  }

  /// Force clock-out when grace period expires.
  Future<void> _forceClockOut() async {
    if (!mounted) return;

    // Cancel the grace period timers
    _cancelGpsGracePeriod();

    // Dismiss any open dialogs
    Navigator.of(context).popUntil((route) => route.isFirst);

    final shiftNotifier = ref.read(shiftProvider.notifier);

    // Clock out without location (GPS is unavailable — permission revoked)
    final success = await shiftNotifier.clockOut(
      location: null,
      accuracy: null,
      reason: 'auto_permission_revoked',
    );

    if (!mounted) return;

    // Stop permission monitoring
    _stopPermissionMonitoring();
    ref.read(permissionGuardProvider.notifier).setActiveShift(false);

    // Show notification
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.warning, color: Colors.white),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Quart terminé automatiquement - GPS indisponible trop longtemps',
              ),
            ),
          ],
        ),
        backgroundColor: Colors.orange.shade700,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );

    if (!success) {
      final error = ref.read(shiftProvider).error;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(child: Text(error ?? 'Échec de la fin automatique')),
            ],
          ),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      );
    }
  }

  /// Handle permission changes during active shift.
  void _handlePermissionChange(PermissionChangeEvent event) {
    if (!mounted) return;

    // Update permission guard state
    ref.read(permissionGuardProvider.notifier).checkStatus();

    // Check current permission state - if no permission, start grace period
    final hasPermission = event.newState.hasAnyPermission;
    final hadPermission = event.previousState.hasAnyPermission;

    if (!hasPermission && hadPermission) {
      // GPS permission lost - start grace period countdown
      _startGpsGracePeriod();
    } else if (hasPermission && _gpsLostAt != null) {
      // GPS restored - cancel grace period and show success
      _cancelGpsGracePeriod();
      // Dismiss the warning dialog if showing
      if (_isShowingGpsWarning && mounted) {
        Navigator.of(context).pop();
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.check_circle, color: Colors.white),
              SizedBox(width: 12),
              Text('GPS restauré - suivi repris'),
            ],
          ),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      );
    } else if (event.isDowngrade && hasPermission) {
      // Non-critical downgrade (e.g., "always" to "while in use") - show warning only
      PermissionChangeAlert.show(
        context,
        event,
        onAcknowledge: () {
          // User acknowledged the issue
        },
        onFix: () async {
          await ref.read(permissionGuardProvider.notifier).openAppSettings();
          if (mounted) {
            await ref.read(permissionGuardProvider.notifier).checkStatus();
          }
        },
      );
    }
  }

  Future<void> _handleClockOut() async {
    // Show confirmation dialog
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => _ClockOutConfirmationSheet(
        shift: ref.read(shiftProvider).activeShift,
      ),
    );

    if (confirmed != true) return;

    final locationService = ref.read(locationServiceProvider);
    final shiftNotifier = ref.read(shiftProvider.notifier);

    // Try to capture location (optional for clock-out)
    GeoPoint? location;
    double? accuracy;

    final hasPermission = await locationService.ensureLocationPermission();
    if (hasPermission) {
      final locationData = await locationService.captureClockLocation();
      location = locationData.location;
      accuracy = locationData.accuracy;
    }

    // Clock out
    final success = await shiftNotifier.clockOut(
      location: location,
      accuracy: accuracy,
    );

    if (!mounted) return;

    if (success) {
      // Stop permission monitoring and grace period after clock out
      _stopPermissionMonitoring();
      _cancelGpsGracePeriod();
      ref.read(permissionGuardProvider.notifier).setActiveShift(false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.check_circle, color: Colors.white),
              SizedBox(width: 12),
              Text('Quart terminé!'),
            ],
          ),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      );
    } else {
      final error = ref.read(shiftProvider).error;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(child: Text(error ?? 'Échec de la fin du quart')),
            ],
          ),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      );
    }
  }

  void _showLocationPermissionDialog() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permission de localisation requise'),
        content: const Text(
          'Tri-Logis Time a besoin d\'accéder à votre position pour enregistrer vos quarts. '
          'Veuillez accorder la permission de localisation pour continuer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(context).pop();
              final locationService = ref.read(locationServiceProvider);
              await locationService.requestPermission();
            },
            child: const Text('Accorder permission'),
          ),
        ],
      ),
    );
  }

  void _showLocationSettingsDialog() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permission de localisation refusée'),
        content: const Text(
          'La permission de localisation a été refusée de façon permanente. '
          'Veuillez l\'activer dans les paramètres de votre appareil pour débuter.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(context).pop();
              final locationService = ref.read(locationServiceProvider);
              await locationService.openAppSettings();
            },
            child: const Text('Ouvrir paramètres'),
          ),
        ],
      ),
    );
  }

  /// Show dialog when app version is too old to clock in.
  void _showUpdateRequiredDialog(VersionCheckResult result) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.system_update, color: Colors.orange),
            SizedBox(width: 8),
            Text('Mise à jour requise'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result.message ?? 'Veuillez mettre à jour l\'application.',
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.orange, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Contactez votre superviseur si vous avez besoin d\'aide pour la mise à jour.',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Fermer'),
          ),
          FilledButton.icon(
            onPressed: () {
              final storeUrl = Uri.parse('https://time.trilogis.ca/update');
              launchUrl(storeUrl, mode: LaunchMode.externalApplication);
            },
            icon: const Icon(Icons.download),
            label: const Text('Mettre à jour'),
          ),
        ],
      ),
    );
  }

  /// Show warning dialog when GPS is lost mid-shift with countdown to auto clock-out.
  void _showGpsLostWarningDialog() {
    _isShowingGpsWarning = true;

    showDialog<void>(
      context: context,
      barrierDismissible: false, // User must take action
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          // Calculate remaining time
          final remaining = _gracePeriodSecondsRemaining;
          final minutes = remaining ~/ 60;
          final seconds = remaining % 60;
          final timeString =
              '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';

          // Update dialog every second
          Future.delayed(const Duration(seconds: 1), () {
            if (_isShowingGpsWarning && mounted) {
              setDialogState(() {});
            }
          });

          return AlertDialog(
            title: Row(
              children: [
                Icon(Icons.gps_off, color: Colors.red.shade700),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Signal GPS perdu'),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Le suivi de position a arrêté. Votre quart se terminera '
                  'automatiquement si le GPS n\'est pas restauré.',
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border:
                        Border.all(color: Colors.red.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.timer, color: Colors.red),
                      const SizedBox(width: 8),
                      Text(
                        'Fin auto dans $timeString',
                        style: const TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Pour restaurer le suivi:\n'
                  '• Activez les services de localisation\n'
                  '• Accordez la permission à cette app',
                  style: TextStyle(fontSize: 13),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  _isShowingGpsWarning = false;
                  // Immediately clock out
                  _forceClockOut();
                },
                child: const Text('Terminer maintenant'),
              ),
              FilledButton(
                onPressed: () async {
                  Navigator.of(dialogContext).pop();
                  _isShowingGpsWarning = false;
                  // Open settings to fix
                  await ref
                      .read(permissionGuardProvider.notifier)
                      .openAppSettings();
                  if (mounted) {
                    await ref
                        .read(permissionGuardProvider.notifier)
                        .checkStatus();
                  }
                },
                child: const Text('Ouvrir paramètres'),
              ),
            ],
          );
        },
      ),
    ).then((_) {
      _isShowingGpsWarning = false;
    });
  }

  void _openQrScanner() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
  }

  Future<void> _openBuildingPicker() async {
    final result = await BuildingPickerSheet.show(context);
    if (result == null || !mounted) return;

    final activeShift = ref.read(shiftProvider).activeShift;
    if (activeShift == null) return;

    final maintenanceResult =
        await ref.read(maintenanceSessionProvider.notifier).startSession(
              shiftId: activeShift.id,
              buildingId: result.buildingId,
              buildingName: result.buildingName,
              apartmentId: result.apartmentId,
              unitNumber: result.unitNumber,
              serverShiftId: activeShift.serverId,
            );

    if (!mounted) return;

    if (maintenanceResult.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Entretien démarré — ${result.buildingName}'
                  '${result.unitNumber != null ? ' (${result.unitNumber})' : ''}',
                ),
              ),
            ],
          ),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                    maintenanceResult.errorMessage ?? 'Erreur de démarrage'),
              ),
            ],
          ),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final shiftState = ref.watch(shiftProvider);
    final hasActiveShift = shiftState.activeShift != null;
    final hasActiveCleaning = ref.watch(hasActiveCleaningSessionProvider);
    final hasActiveMaintenance = ref.watch(hasActiveMaintenanceSessionProvider);

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async {
          await ref.read(shiftProvider.notifier).refresh();
          await ref.read(cleaningSessionProvider.notifier).loadActiveSession();
          await ref
              .read(maintenanceSessionProvider.notifier)
              .loadActiveSession();
          await ref.read(permissionGuardProvider.notifier).checkStatus();
        },
        child: Column(
          children: [
            // Permission status banner at top
            const PermissionStatusBanner(),
            // Battery health quick status
            const _BatteryHealthQuickIndicator(),
            // Tracking verification failure banner
            _TrackingFailureBanner(
              hasActiveShift: hasActiveShift,
            ),
            Expanded(
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const ShiftStatusCard(),
                    if (hasActiveShift) ...[
                      const SizedBox(height: 16),
                      const ShiftTimer(),

                      // Tab toggle
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<_DashboardTab>(
                          segments: const [
                            ButtonSegment(
                              value: _DashboardTab.menager,
                              label: Text('Ménager'),
                              icon: Icon(Icons.cleaning_services, size: 18),
                            ),
                            ButtonSegment(
                              value: _DashboardTab.entretien,
                              label: Text('Entretien'),
                              icon: Icon(Icons.handyman, size: 18),
                            ),
                          ],
                          selected: {_selectedTab},
                          onSelectionChanged: (selected) {
                            setState(() => _selectedTab = selected.first);
                          },
                        ),
                      ),

                      // Active session — always visible regardless of tab
                      const SizedBox(height: 16),
                      if (hasActiveCleaning) const ActiveSessionCard(),
                      if (hasActiveMaintenance) const ActiveMaintenanceCard(),

                      // Tab-specific content
                      const SizedBox(height: 16),
                      if (_selectedTab == _DashboardTab.menager) ...[
                        if (!hasActiveCleaning && !hasActiveMaintenance)
                          const ActiveSessionCard(),
                        const CleaningHistoryList(),
                      ],
                      if (_selectedTab == _DashboardTab.entretien) ...[
                        const MaintenanceHistoryList(),
                      ],
                    ],
                    const SizedBox(height: 32),
                    Center(
                      child: ClockButton(
                        onClockIn: _handleClockIn,
                        onClockOut: _handleClockOut,
                        isExternallyLoading: _isClockInPreparing,
                      ),
                    ),
                    const SizedBox(height: 32),
                    FutureBuilder<PackageInfo>(
                      future: PackageInfo.fromPlatform(),
                      builder: (context, snapshot) {
                        if (!snapshot.hasData) return const SizedBox.shrink();
                        final info = snapshot.data!;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            'v${info.version} (${info.buildNumber})',
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                          ),
                        );
                      },
                    ),
                    if (shiftState.error != null)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: Colors.red.withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline, color: Colors.red),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                shiftState.error!,
                                style: const TextStyle(color: Colors.red),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, color: Colors.red),
                              onPressed: () =>
                                  ref.read(shiftProvider.notifier).clearError(),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: hasActiveShift
          ? _buildFab(hasActiveCleaning, hasActiveMaintenance)
          : null,
    );
  }

  Widget? _buildFab(bool hasActiveCleaning, bool hasActiveMaintenance) {
    if (_selectedTab == _DashboardTab.menager) {
      // Disable QR scanner if maintenance session is active
      if (hasActiveMaintenance) return null;
      return FloatingActionButton(
        onPressed: _openQrScanner,
        tooltip: 'Scanner QR',
        child: const Icon(Icons.qr_code_scanner),
      );
    } else {
      // Disable building picker if cleaning session is active or maintenance already active
      if (hasActiveCleaning || hasActiveMaintenance) return null;
      return FloatingActionButton(
        onPressed: _openBuildingPicker,
        tooltip: 'Démarrer entretien',
        backgroundColor: Colors.orange,
        child: const Icon(Icons.handyman),
      );
    }
  }
}

class _BatteryHealthQuickIndicator extends ConsumerWidget {
  const _BatteryHealthQuickIndicator();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!Platform.isAndroid) return const SizedBox.shrink();

    final guardState = ref.watch(permissionGuardProvider);
    final optimizationOk = guardState.isBatteryOptimizationDisabled;
    final standbyOk = !guardState.isAppStandbyRestricted;
    final isHealthy = optimizationOk && standbyOk;

    final bgColor = isHealthy
        ? Colors.green.withValues(alpha: 0.08)
        : Colors.red.withValues(alpha: 0.08);
    final borderColor = isHealthy
        ? Colors.green.withValues(alpha: 0.25)
        : Colors.red.withValues(alpha: 0.25);
    final iconColor = isHealthy ? Colors.green.shade800 : Colors.red.shade800;

    final subtitle = isHealthy
        ? 'Optimisation desactivee et app non restreinte'
        : _buildIssueSubtitle(
            optimizationOk: optimizationOk, standbyOk: standbyOk);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Icon(
            isHealthy ? Icons.check_circle : Icons.error,
            color: iconColor,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isHealthy
                      ? 'Sante batterie: OK'
                      : 'Sante batterie: A corriger',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: iconColor,
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: iconColor.withValues(alpha: 0.9),
                      ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const BatteryHealthScreen(),
                ),
              );
            },
            child: const Text('Verifier'),
          ),
        ],
      ),
    );
  }

  String _buildIssueSubtitle({
    required bool optimizationOk,
    required bool standbyOk,
  }) {
    if (!optimizationOk && !standbyOk) {
      return 'Optimisation active et app restreinte par Android';
    }
    if (!optimizationOk) {
      return 'Optimisation batterie active';
    }
    return 'Android a place l app en mode restreint';
  }
}

/// Bottom sheet for clock-out confirmation.
class _ClockOutConfirmationSheet extends StatelessWidget {
  final Shift? shift;

  const _ClockOutConfirmationSheet({required this.shift});

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Duration duration = shift?.duration ?? Duration.zero;

    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.outline.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),
          Icon(
            Icons.logout,
            size: 48,
            color: theme.colorScheme.error,
          ),
          const SizedBox(height: 16),
          Text(
            'Terminer le quart?',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Durée du quart actuel',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _formatDuration(duration),
            style: theme.textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.bold,
              fontFeatures: [const FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Annuler'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                  ),
                  child: const Text('Terminer'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// Banner shown when background GPS tracking fails to start within 15 seconds.
class _TrackingFailureBanner extends ConsumerWidget {
  final bool hasActiveShift;

  const _TrackingFailureBanner({required this.hasActiveShift});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trackingState = ref.watch(trackingProvider);
    if (!hasActiveShift || !trackingState.trackingStartFailed) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.orange.shade100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.orange),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Le suivi GPS ne fonctionne pas. Vos déplacements ne sont pas enregistrés. '
              'Essayez de fermer et rouvrir l\'application.',
              style: TextStyle(color: Colors.orange.shade900, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
