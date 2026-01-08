import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../tracking/providers/tracking_provider.dart';
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
    }
  }

  Future<void> _handleClockIn() async {
    final locationService = ref.read(locationServiceProvider);
    final shiftNotifier = ref.read(shiftProvider.notifier);

    // Check and request location permission
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
      onRefresh: () => ref.read(shiftProvider.notifier).refresh(),
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
                  border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
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
