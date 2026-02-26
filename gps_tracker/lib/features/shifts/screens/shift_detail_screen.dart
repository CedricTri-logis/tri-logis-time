import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../mileage/providers/trip_provider.dart';
import '../../mileage/screens/trip_detail_screen.dart';
import '../../mileage/widgets/trip_card.dart';
import '../../tracking/providers/route_provider.dart';
import '../../tracking/widgets/point_detail_sheet.dart';
import '../../tracking/widgets/route_map_widget.dart';
import '../../tracking/widgets/route_stats_card.dart';
import '../models/shift.dart';
import '../providers/shift_provider.dart';
import '../widgets/sync_status_indicator.dart';

/// Screen showing detailed information about a specific shift.
class ShiftDetailScreen extends ConsumerWidget {
  final String shiftId;

  const ShiftDetailScreen({super.key, required this.shiftId});

  String _formatTime(DateTime dateTime) {
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    final second = dateTime.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  String _formatDate(DateTime dateTime) {
    final months = [
      'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
      'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'
    ];
    final weekdays = [
      'lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'
    ];
    return '${weekdays[dateTime.weekday - 1]} ${dateTime.day} ${months[dateTime.month - 1]} ${dateTime.year}';
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  String _formatCoordinates(double lat, double lng) {
    final latDir = lat >= 0 ? 'N' : 'S';
    final lngDir = lng >= 0 ? 'E' : 'W';
    return '${lat.abs().toStringAsFixed(6)}°$latDir, ${lng.abs().toStringAsFixed(6)}°$lngDir';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Détails du quart'),
        centerTitle: true,
      ),
      body: FutureBuilder<Shift?>(
        future: ref.read(shiftServiceProvider).getShiftById(shiftId),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final shift = snapshot.data;
          if (shift == null) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 64,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Quart introuvable',
                    style: theme.textTheme.titleLarge,
                  ),
                ],
              ),
            );
          }

          return _buildShiftDetails(context, theme, shift);
        },
      ),
    );
  }

  Widget _buildShiftDetails(BuildContext context, ThemeData theme, Shift shift) {
    final localClockIn = shift.clockedInAt.toLocal();
    final localClockOut = shift.clockedOutAt?.toLocal();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header card with status and duration
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: shift.isCompleted ? Colors.blue : Colors.green,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            shift.isCompleted ? 'Terminé' : 'Actif',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: shift.isCompleted ? Colors.blue : Colors.green,
                            ),
                          ),
                        ],
                      ),
                      SimpleSyncStatusIndicator(syncStatus: shift.syncStatus),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Durée totale',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _formatDuration(shift.duration),
                    style: theme.textTheme.displayMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      fontFeatures: [const FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Date
          Card(
            elevation: 1,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.calendar_today,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Date',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _formatDate(localClockIn),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Clock In details
          _buildTimeCard(
            theme,
            title: 'Pointage',
            time: _formatTime(localClockIn),
            icon: Icons.login,
            iconColor: Colors.green,
            location: shift.clockInLocation != null
                ? _formatCoordinates(
                    shift.clockInLocation!.latitude,
                    shift.clockInLocation!.longitude,
                  )
                : null,
            accuracy: shift.clockInAccuracy,
          ),
          const SizedBox(height: 16),

          // Clock Out details
          if (shift.isCompleted && localClockOut != null)
            _buildTimeCard(
              theme,
              title: 'Dépointage',
              time: _formatTime(localClockOut),
              icon: Icons.logout,
              iconColor: Colors.red,
              location: shift.clockOutLocation != null
                  ? _formatCoordinates(
                      shift.clockOutLocation!.latitude,
                      shift.clockOutLocation!.longitude,
                    )
                  : null,
              accuracy: shift.clockOutAccuracy,
            )
          else
            Card(
              elevation: 1,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.logout,
                        color: Colors.orange,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      'Quart en cours...',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.orange,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),

          // Route Map Section
          _buildRouteSection(context, shift.id),
          const SizedBox(height: 16),

          // Mileage Section (only for completed shifts)
          if (shift.isCompleted)
            _buildMileageSection(context, shift.id),
        ],
      ),
    );
  }

  Widget _buildRouteSection(BuildContext context, String shiftId) {
    return Consumer(
      builder: (context, ref, _) {
        final routeAsync = ref.watch(routeProvider(shiftId));

        return routeAsync.when(
          data: (points) {
            if (points.isEmpty) {
              return Card(
                elevation: 1,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Icon(
                        Icons.location_off,
                        size: 48,
                        color: Colors.grey.shade400,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Aucune donnée GPS',
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
              );
            }

            final stats = ref.watch(routeStatsProvider(points));

            return Consumer(
              builder: (context, tripRef, _) {
                final tripsAsync = tripRef.watch(tripsForShiftProvider(shiftId));
                final trips = tripsAsync.valueOrNull ?? [];

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    RouteStatsCard(stats: stats),
                    const SizedBox(height: 16),
                    Card(
                      elevation: 1,
                      clipBehavior: Clip.antiAlias,
                      child: SizedBox(
                        height: 300,
                        child: RouteMapWidget(
                          points: points,
                          onPointTap: (point) => PointDetailSheet.show(context, point),
                          trips: trips.isNotEmpty ? trips : null,
                        ),
                      ),
                    ),
                  ],
                );
              },
            );
          },
          loading: () => const Card(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
          error: (e, _) => Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Erreur de chargement du tracé : $e'),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMileageSection(BuildContext context, String shiftId) {
    return Consumer(
      builder: (context, ref, _) {
        final tripsAsync = ref.watch(tripsForShiftProvider(shiftId));

        return tripsAsync.when(
          data: (trips) {
            if (trips.isEmpty) return const SizedBox.shrink();

            final totalKm = trips.fold<double>(
              0,
              (sum, trip) => sum + trip.distanceKm,
            );

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Icon(
                        Icons.directions_car,
                        size: 20,
                        color: Colors.grey.shade600,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Kilométrage (${trips.length} trajet${trips.length == 1 ? '' : 's'} — ${totalKm.toStringAsFixed(1)} km)',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: Colors.grey.shade600,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                  ),
                ),
                ...trips.map(
                  (trip) => TripCard(
                    trip: trip,
                    onTap: () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => TripDetailScreen(trip: trip),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
          loading: () => const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
          error: (_, __) => const SizedBox.shrink(),
        );
      },
    );
  }

  Widget _buildTimeCard(
    ThemeData theme, {
    required String title,
    required String time,
    required IconData icon,
    required Color iconColor,
    String? location,
    double? accuracy,
  }) {
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: iconColor),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        time,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          fontFeatures: [const FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (location != null) ...[
              const Divider(height: 24),
              Row(
                children: [
                  Icon(
                    Icons.location_on,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      location,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontFeatures: [const FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
              if (accuracy != null) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      Icons.gps_fixed,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Précision : ±${accuracy.toStringAsFixed(1)}m',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
