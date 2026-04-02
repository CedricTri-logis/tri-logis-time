import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';

import '../../../shared/utils/timezone_formatter.dart';
import '../../mileage/providers/trip_provider.dart';
import '../../shifts/models/day_approval.dart';
import '../../shifts/models/shift.dart';
import '../../shifts/providers/approval_provider.dart';
import '../../shifts/widgets/activity_timeline.dart';
import '../../shifts/widgets/approval_summary_card.dart';
import '../../shifts/widgets/location_breakdown_card.dart';
import '../../shifts/widgets/activity_map_sheet.dart';
import '../../shifts/widgets/trip_routes_map.dart';
import '../../mileage/models/trip.dart';
import '../providers/employee_history_provider.dart';
import '../providers/supervised_employees_provider.dart';
import '../services/history_service.dart';
import '../widgets/gps_route_map.dart';

/// Screen displaying detailed information for a specific shift
class ShiftDetailScreen extends ConsumerStatefulWidget {
  final String shiftId;
  final String employeeId;
  final String employeeName;

  const ShiftDetailScreen({
    super.key,
    required this.shiftId,
    required this.employeeId,
    required this.employeeName,
  });

  @override
  ConsumerState<ShiftDetailScreen> createState() => _ShiftDetailScreenState();
}

class _ShiftDetailScreenState extends ConsumerState<ShiftDetailScreen> {
  Shift? _shift;
  List<GpsPointData>? _gpsPoints;
  bool _isLoadingGps = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadShiftData();
  }

  void _loadShiftData() {
    // Find shift from already loaded history
    final historyState = ref.read(employeeHistoryProvider);
    final shift =
        historyState.shifts.where((s) => s.id == widget.shiftId).firstOrNull;
    if (shift != null) {
      setState(() => _shift = shift);
      _loadGpsPoints();
    }
  }

  Future<void> _loadGpsPoints() async {
    setState(() => _isLoadingGps = true);

    try {
      final historyService = ref.read(historyServiceProvider);
      final points = await historyService.getShiftGpsPoints(widget.shiftId);
      setState(() {
        _gpsPoints = points;
        _isLoadingGps = false;
      });
    } on HistoryServiceException catch (e) {
      setState(() {
        _error = e.message;
        _isLoadingGps = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Erreur de chargement GPS : $e';
        _isLoadingGps = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Détails du quart'),
            Text(
              widget.employeeName,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      body: _shift == null
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildStatusCard(theme),
                  if (_shift!.isCallback) ...[
                    const SizedBox(height: 8),
                    _buildCallbackCard(theme),
                  ],
                  const SizedBox(height: 16),
                  _buildTimeCard(theme),
                  const SizedBox(height: 16),
                  _buildLocationCard(theme),
                  if (_shift!.isCompleted) ...[
                    const SizedBox(height: 16),
                    _buildApprovalSection(),
                    const SizedBox(height: 16),
                    _buildTripRoutesSection(),
                  ],
                  const SizedBox(height: 16),
                  _buildGpsCard(theme),
                ],
              ),
            ),
    );
  }

  Widget _buildCallbackCard(ThemeData theme) {
    final shift = _shift!;
    return Card(
      color: Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.phone_callback, color: Colors.orange.shade700, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Rappel au travail',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: Colors.orange.shade800,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (shift.duration.inMinutes < 180)
                    Text(
                      'Minimum 3h facturées (Art. 58 LNT)',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.orange.shade700,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard(ThemeData theme) {
    final shift = _shift!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: shift.isActive
                    ? Colors.green.withValues(alpha: 0.1)
                    : theme.colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                shift.isActive ? Icons.play_circle : Icons.check_circle,
                color: shift.isActive
                    ? Colors.green
                    : theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    shift.isActive ? 'Quart actif' : 'Quart terminé',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    DateFormat.yMMMMd().format(shift.clockedInAt.toLocal()),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                _formatDuration(shift.duration),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimeCard(ThemeData theme) {
    final shift = _shift!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Horaires',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    TimezoneFormatter.compactTzIndicator,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _buildTimeSection(
                    theme,
                    icon: Icons.login,
                    label: 'Pointage',
                    time: shift.clockedInAt,
                    color: Colors.green,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildTimeSection(
                    theme,
                    icon: Icons.logout,
                    label: 'Dépointage',
                    time: shift.clockedOutAt,
                    color: Colors.blue,
                    isActive: shift.isActive,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimeSection(
    ThemeData theme, {
    required IconData icon,
    required String label,
    DateTime? time,
    required Color color,
    bool isActive = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (time != null)
            Text(
              DateFormat.jm().format(time.toLocal()),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            )
          else if (isActive)
            Text(
              'Actif',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: Colors.green,
              ),
            )
          else
            Text(
              '--:--',
              style: theme.textTheme.headlineSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          if (time != null)
            Text(
              DateFormat('EEEE').format(time.toLocal()),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLocationCard(ThemeData theme) {
    final shift = _shift!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Emplacements',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            _buildLocationRow(
              theme,
              label: 'Position au pointage',
              location: shift.clockInLocation,
              accuracy: shift.clockInAccuracy,
            ),
            if (shift.clockOutLocation != null) ...[
              const SizedBox(height: 12),
              _buildLocationRow(
                theme,
                label: 'Position au dépointage',
                location: shift.clockOutLocation,
                accuracy: shift.clockOutAccuracy,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLocationRow(
    ThemeData theme, {
    required String label,
    required dynamic location,
    double? accuracy,
  }) {
    final hasLocation = location != null;
    return Row(
      children: [
        Icon(
          Icons.location_on,
          size: 20,
          color: hasLocation
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (hasLocation)
                Text(
                  '${location.latitude.toStringAsFixed(6)}, ${location.longitude.toStringAsFixed(6)}',
                  style: theme.textTheme.bodyMedium,
                )
              else
                Text(
                  'Aucune position enregistrée',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
        if (accuracy != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '${accuracy.toStringAsFixed(0)}m',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  void _onActivityTap(ApprovalActivity activity, List<Trip> trips) {
    if (activity.isStop && activity.latitude != null && activity.longitude != null) {
      ActivityMapSheet.showStop(
        context,
        locationName: activity.locationName ?? 'Lieu inconnu',
        latitude: activity.latitude!,
        longitude: activity.longitude!,
        locationType: activity.locationType,
      );
    } else if (activity.isTrip) {
      final trip = trips.where((t) => t.id == activity.activityId).firstOrNull;
      if (trip != null) {
        ActivityMapSheet.showTrip(
          context,
          trip: trip,
          startName: activity.startLocationName,
          endName: activity.endLocationName,
        );
      }
    }
  }

  void _onLocationTap(String locationName, List<ApprovalActivity> stops) {
    final stop = stops.firstWhere(
      (s) => s.latitude != null && s.longitude != null,
      orElse: () => stops.first,
    );
    if (stop.latitude != null && stop.longitude != null) {
      ActivityMapSheet.showStop(
        context,
        locationName: locationName,
        latitude: stop.latitude!,
        longitude: stop.longitude!,
        locationType: stop.locationType,
      );
    }
  }

  Widget _buildApprovalSection() {
    final shift = _shift!;
    final date = DateTime(
      shift.clockedInAt.toLocal().year,
      shift.clockedInAt.toLocal().month,
      shift.clockedInAt.toLocal().day,
    );

    return Consumer(
      builder: (context, ref, _) {
        final detailAsync = ref.watch(dayApprovalDetailProvider(
            (employeeId: widget.employeeId, date: date)));
        final tripsAsync = ref.watch(tripsForPeriodProvider(TripPeriodParams(
          employeeId: widget.employeeId,
          start: date,
          end: date.add(const Duration(days: 1)),
        )));
        final trips = tripsAsync.valueOrNull ?? [];

        return detailAsync.when(
          data: (detail) {
            if (detail == null) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ApprovalSummaryCard(detail: detail),
                const SizedBox(height: 12),
                LocationBreakdownCard(
                  detail: detail,
                  onLocationTap: _onLocationTap,
                ),
                const SizedBox(height: 12),
                ActivityTimeline(
                  activities: detail.activities,
                  onActivityTap: (activity) => _onActivityTap(activity, trips),
                ),
              ],
            );
          },
          loading: () => const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          ),
          error: (error, _) => Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.warning_amber, size: 20, color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Impossible de charger les approbations : $error',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTripRoutesSection() {
    return Consumer(
      builder: (context, ref, _) {
        final tripsAsync = ref.watch(tripsForShiftProvider(widget.shiftId));
        return tripsAsync.when(
          data: (trips) {
            if (trips.isEmpty) return const SizedBox.shrink();
            return TripRoutesMap(trips: trips);
          },
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
        );
      },
    );
  }

  Widget _buildGpsCard(ThemeData theme) {
    final shift = _shift!;
    final hasGpsPoints = _gpsPoints != null && _gpsPoints!.isNotEmpty;
    final hasClockLocations = shift.clockInLocation != null || shift.clockOutLocation != null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Text(
                      'Tracé GPS',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        TimezoneFormatter.compactTzIndicator,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                if (hasGpsPoints)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${_gpsPoints!.length} points',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (_isLoadingGps)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_error != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              )
            else ...[
              // GPS Route Map (shows clock-in/out locations even without GPS points)
              GpsRouteMap(
                gpsPoints: _gpsPoints ?? [],
                clockInLocation: shift.clockInLocation != null
                    ? LatLng(shift.clockInLocation!.latitude, shift.clockInLocation!.longitude)
                    : null,
                clockOutLocation: shift.clockOutLocation != null
                    ? LatLng(shift.clockOutLocation!.latitude, shift.clockOutLocation!.longitude)
                    : null,
                clockedInAt: shift.clockedInAt,
                clockedOutAt: shift.clockedOutAt,
                height: 250,
                shiftTitle: 'Shift - ${DateFormat('MMM d, yyyy').format(shift.clockedInAt)}',
                onPointTapped: (point) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Point at ${TimezoneFormatter.formatTimeWithSecondsTz(point.capturedAt)}',
                      ),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
              ),
              if (!hasGpsPoints && !hasClockLocations)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Aucune donnée GPS pour ce quart',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              if (hasGpsPoints) ...[
                const SizedBox(height: 16),
                // Point list toggle
                ExpansionTile(
                  title: Text(
                    'Voir tous les points',
                    style: theme.textTheme.titleSmall,
                  ),
                  tilePadding: EdgeInsets.zero,
                  children: [
                    _buildGpsPointsList(theme),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGpsPointsList(ThemeData theme) {
    final points = _gpsPoints!;
    final displayPoints = points.length > 10 ? points.take(10).toList() : points;

    return Column(
      children: [
        ...displayPoints.asMap().entries.map((entry) {
          final index = entry.key;
          final point = entry.value;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${index + 1}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}',
                        style: theme.textTheme.bodySmall,
                      ),
                      Text(
                        DateFormat.jms().format(point.capturedAt.toLocal()),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (point.accuracy != null)
                  Text(
                    '${point.accuracy!.toStringAsFixed(0)}m',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          );
        }),
        if (points.length > 10)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '...et ${points.length - 10} points de plus',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);

    if (hours == 0) return '${minutes}m';
    if (minutes == 0) return '${hours}h';
    return '${hours}h ${minutes}m';
  }
}
