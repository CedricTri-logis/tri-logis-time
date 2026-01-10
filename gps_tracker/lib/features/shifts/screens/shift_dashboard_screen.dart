import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../tracking/models/device_location_status.dart';
import '../../tracking/models/location_permission_state.dart';
import '../../tracking/models/permission_change_event.dart';
import '../../tracking/models/permission_guard_state.dart';
import '../../tracking/providers/permission_guard_provider.dart';
import '../../tracking/providers/tracking_provider.dart';
import '../../tracking/services/permission_monitor_service.dart';
import '../../tracking/widgets/battery_optimization_dialog.dart';
import '../../tracking/widgets/device_services_dialog.dart';
import '../../tracking/widgets/permission_change_alert.dart';
import '../../tracking/widgets/permission_explanation_dialog.dart';
import '../../tracking/widgets/permission_status_banner.dart';
import '../../tracking/widgets/settings_guidance_dialog.dart';
import '../models/geo_point.dart';
import '../models/shift.dart';
import '../providers/location_provider.dart';
import '../providers/shift_provider.dart';
import '../widgets/clock_button.dart';
import '../widgets/shift_status_card.dart';
import '../widgets/shift_timer.dart';

/// Main dashboard screen for shift management.
class ShiftDashboardScreen extends ConsumerStatefulWidget {
  const ShiftDashboardScreen({super.key});

  @override
  ConsumerState<ShiftDashboardScreen> createState() =>
      _ShiftDashboardScreenState();
}

class _ShiftDashboardScreenState extends ConsumerState<ShiftDashboardScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
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
    }
  }

  Future<void> _handleClockIn() async {
    final locationService = ref.read(locationServiceProvider);
    final shiftNotifier = ref.read(shiftProvider.notifier);
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

    // Show loading indicator and capture location
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            SizedBox(width: 16),
            Text('Getting your location...'),
          ],
        ),
        duration: Duration(seconds: 2),
      ),
    );

    // Capture location
    final locationData = await locationService.captureClockLocation();

    // Clock in
    final success = await shiftNotifier.clockIn(
      location: locationData.location,
      accuracy: locationData.accuracy,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

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
              Text('Successfully clocked in!'),
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
              Expanded(child: Text(error ?? 'Failed to clock in')),
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

  /// Handle permission blocking - show appropriate dialog based on state.
  Future<void> _handlePermissionBlock(PermissionGuardState guardState) async {
    if (guardState.deviceStatus == DeviceLocationStatus.disabled) {
      await DeviceServicesDialog.show(context);
    } else if (guardState.permission.level ==
        LocationPermissionLevel.deniedForever) {
      await SettingsGuidanceDialog.show(context);
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
  Future<bool> _showClockInWarningDialog(PermissionGuardState guardState) async {
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
      title = 'Limited Tracking';
      message =
          'You have "while in use" permission only. Background tracking may be '
          'interrupted when the app is not visible. Do you want to continue anyway?';
      fixLabel = 'Upgrade Permission';
    } else if (isBatteryOptimization) {
      title = 'Battery Optimization';
      message =
          'Battery optimization may interrupt GPS tracking during your shift. '
          'We recommend disabling it for this app. Continue anyway?';
      fixLabel = 'Disable Optimization';
    } else {
      title = 'Warning';
      message =
          'There may be issues with GPS tracking. Do you want to continue anyway?';
      fixLabel = 'Fix';
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
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('fix'),
            child: Text(fixLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop('proceed'),
            child: const Text('Continue Anyway'),
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

  /// Handle permission changes during active shift.
  void _handlePermissionChange(PermissionChangeEvent event) {
    if (!mounted) return;

    // Update permission guard state
    ref.read(permissionGuardProvider.notifier).checkStatus();

    // Show alert for downgrades
    if (event.isDowngrade) {
      PermissionChangeAlert.show(
        context,
        event,
        onAcknowledge: () {
          // User acknowledged the issue
        },
        onFix: () async {
          // User wants to fix the issue
          if (event.affectsTracking) {
            await SettingsGuidanceDialog.show(context);
          } else {
            await ref
                .read(permissionGuardProvider.notifier)
                .requestPermission();
          }
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
      // Stop permission monitoring after clock out
      _stopPermissionMonitoring();
      ref.read(permissionGuardProvider.notifier).setActiveShift(false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.check_circle, color: Colors.white),
              SizedBox(width: 12),
              Text('Successfully clocked out!'),
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
              Expanded(child: Text(error ?? 'Failed to clock out')),
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
        title: const Text('Location Permission Required'),
        content: const Text(
          'GPS Tracker needs location access to record where you clock in and out. '
          'Please grant location permission to continue.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(context).pop();
              final locationService = ref.read(locationServiceProvider);
              await locationService.requestPermission();
            },
            child: const Text('Grant Permission'),
          ),
        ],
      ),
    );
  }

  void _showLocationSettingsDialog() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Location Permission Denied'),
        content: const Text(
          'Location permission has been permanently denied. '
          'Please enable it in your device settings to clock in.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(context).pop();
              final locationService = ref.read(locationServiceProvider);
              await locationService.openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shiftState = ref.watch(shiftProvider);
    final hasActiveShift = shiftState.activeShift != null;

    return RefreshIndicator(
      onRefresh: () async {
        await ref.read(shiftProvider.notifier).refresh();
        await ref.read(permissionGuardProvider.notifier).checkStatus();
      },
      child: Column(
        children: [
          // Permission status banner at top
          const PermissionStatusBanner(),
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
                  ],
                  const SizedBox(height: 32),
                  Center(
                    child: ClockButton(
                      onClockIn: _handleClockIn,
                      onClockOut: _handleClockOut,
                    ),
                  ),
                  const SizedBox(height: 32),
                  if (shiftState.error != null)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border:
                            Border.all(color: Colors.red.withValues(alpha: 0.3)),
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
    );
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
            'Clock Out?',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Current shift duration',
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
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                  ),
                  child: const Text('Clock Out'),
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
