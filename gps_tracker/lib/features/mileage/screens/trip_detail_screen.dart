import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/carpool_info.dart';
import '../models/trip.dart';
import '../providers/reimbursement_rate_provider.dart';
import '../providers/trip_provider.dart';
import '../services/reverse_geocode_service.dart';
import '../services/route_match_service.dart';
import '../widgets/match_status_badge.dart';
import '../widgets/trip_route_map.dart';

/// Screen showing detailed information about a single trip.
class TripDetailScreen extends ConsumerStatefulWidget {
  final Trip trip;

  const TripDetailScreen({super.key, required this.trip});

  @override
  ConsumerState<TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends ConsumerState<TripDetailScreen> {
  late Trip _trip;
  final _geocodeService = ReverseGeocodeService();
  bool _isGeocoding = false;

  @override
  void initState() {
    super.initState();
    _trip = widget.trip;
    _geocodeAddresses();
  }

  Future<void> _geocodeAddresses() async {
    if (_trip.startAddress != null && _trip.endAddress != null) return;

    setState(() => _isGeocoding = true);

    try {
      String? startAddress = _trip.startAddress;
      String? endAddress = _trip.endAddress;

      if (startAddress == null) {
        startAddress = await _geocodeService.reverseGeocode(
          _trip.startLatitude,
          _trip.startLongitude,
        );
      }

      if (endAddress == null) {
        endAddress = await _geocodeService.reverseGeocode(
          _trip.endLatitude,
          _trip.endLongitude,
        );
      }

      if (startAddress != null || endAddress != null) {
        // Update in Supabase for caching
        final tripService = ref.read(tripServiceProvider);
        await tripService.updateTripAddress(
          tripId: _trip.id,
          startAddress: startAddress,
          endAddress: endAddress,
        );

        setState(() {
          _trip = _trip.copyWith(
            startAddress: startAddress,
            endAddress: endAddress,
          );
        });
      }
    } catch (_) {
      // Geocoding is best-effort
    } finally {
      if (mounted) setState(() => _isGeocoding = false);
    }
  }

  Future<void> _retryRouteMatch() async {
    final routeMatchService = ref.read(routeMatchServiceProvider);
    final tripService = ref.read(tripServiceProvider);

    await routeMatchService.matchTrip(_trip.id);

    // Refresh trip data to get updated match results
    final refreshed = await tripService.refreshTrip(_trip.id);
    if (refreshed != null && mounted) {
      setState(() => _trip = refreshed);
    }
  }

  Future<void> _toggleClassification() async {
    final newClassification = _trip.isBusiness
        ? TripClassification.personal
        : TripClassification.business;

    // Optimistic update
    setState(() {
      _trip = _trip.copyWith(classification: newClassification);
    });

    final service = ref.read(tripServiceProvider);
    final success = await service.updateTripClassification(
      _trip.id,
      newClassification,
    );

    if (!success && mounted) {
      // Revert on failure
      setState(() {
        _trip = _trip.copyWith(
          classification: newClassification == TripClassification.business
              ? TripClassification.personal
              : TripClassification.business,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rateAsync = ref.watch(reimbursementRateProvider);

    // Fetch carpool info for this trip
    final carpoolAsync = ref.watch(carpoolInfoProvider([_trip.id]));
    final carpoolInfo = carpoolAsync.valueOrNull?[_trip.id];

    // Fetch company vehicle dates for the trip's date
    final tripDate = _trip.startedAt.toLocal();
    final dayStart = DateTime(tripDate.year, tripDate.month, tripDate.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final userId =
        Supabase.instance.client.auth.currentUser?.id ?? '';
    final companyVehicleAsync = ref.watch(companyVehicleDatesProvider(
      TripPeriodParams(employeeId: userId, start: dayStart, end: dayEnd),
    ));
    final isCompanyVehicle = companyVehicleAsync.valueOrNull?.contains(
          tripDate.toIso8601String().substring(0, 10),
        ) ??
        false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Détails du trajet'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Map
            TripRouteMap(trip: _trip, height: 250),
            // Route status indicator below map
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  MatchStatusBadge(trip: _trip),
                  const SizedBox(width: 8),
                  Text(
                    _trip.isRouteMatched
                        ? 'Route vérifié par GPS'
                        : 'Trajet estimé',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.grey.shade600,
                      fontSize: 11,
                    ),
                  ),
                  if (_trip.isMatchFailed && _trip.canRetryMatch) ...[
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _retryRouteMatch,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Réessayer'),
                      style: TextButton.styleFrom(
                        textStyle: const TextStyle(fontSize: 12),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 30),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),

            // Trip info card
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildAddressRow(
                      context,
                      icon: Icons.trip_origin,
                      color: Colors.green,
                      label: 'Départ',
                      address: _trip.startDisplayName,
                      isGeocoding: _isGeocoding && _trip.startAddress == null,
                    ),
                    const Padding(
                      padding: EdgeInsets.only(left: 11),
                      child: SizedBox(
                        height: 20,
                        child: VerticalDivider(thickness: 2),
                      ),
                    ),
                    _buildAddressRow(
                      context,
                      icon: Icons.location_on,
                      color: Colors.red,
                      label: 'Arrivée',
                      address: _trip.endDisplayName,
                      isGeocoding: _isGeocoding && _trip.endAddress == null,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Metrics card
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _buildMetricRow(
                      context,
                      icon: Icons.straighten,
                      label: 'Distance',
                      value: '${_trip.effectiveDistanceKm.toStringAsFixed(1)} km',
                    ),
                    const Divider(),
                    _buildMetricRow(
                      context,
                      icon: Icons.timer_outlined,
                      label: 'Durée',
                      value: _formatDuration(_trip.durationMinutes),
                    ),
                    const Divider(),
                    _buildMetricRow(
                      context,
                      icon: Icons.speed,
                      label: 'Vitesse moy.',
                      value: _trip.durationMinutes > 0
                          ? '${(_trip.effectiveDistanceKm / (_trip.durationMinutes / 60)).toStringAsFixed(0)} km/h'
                          : '—',
                    ),
                    const Divider(),
                    rateAsync.when(
                      data: (rate) {
                        final reimbursement = rate != null
                            ? rate.calculateReimbursement(_trip.distanceKm, 0)
                            : 0.0;
                        return _buildMetricRow(
                          context,
                          icon: Icons.attach_money,
                          label: 'Remb. estimé',
                          value: '\$${reimbursement.toStringAsFixed(2)}',
                          valueColor: Colors.green.shade700,
                        );
                      },
                      loading: () => _buildMetricRow(
                        context,
                        icon: Icons.attach_money,
                        label: 'Remb. estimé',
                        value: '...',
                      ),
                      error: (_, __) => const SizedBox.shrink(),
                    ),
                    const Divider(),
                    _buildMetricRow(
                      context,
                      icon: Icons.gps_fixed,
                      label: 'Points GPS',
                      value: '${_trip.gpsPointCount}',
                    ),
                    const Divider(),
                    _buildMetricRow(
                      context,
                      icon: Icons.verified,
                      label: 'Fiabilité',
                      value: '${(_trip.confidenceScore * 100).toStringAsFixed(0)}%',
                      valueColor: _trip.isLowConfidence
                          ? Colors.amber.shade700
                          : Colors.green.shade700,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Classification (tappable to toggle)
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: InkWell(
                onTap: _toggleClassification,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(
                        _trip.isBusiness ? Icons.business : Icons.person,
                        color: _trip.isBusiness
                            ? theme.colorScheme.primary
                            : Colors.grey,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _trip.isBusiness ? 'Trajet affaires' : 'Trajet personnel',
                              style: theme.textTheme.titleSmall,
                            ),
                            Text(
                              'Toucher pour modifier',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.grey.shade500,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        _trip.detectionMethod == TripDetectionMethod.auto
                            ? 'Auto-détecté'
                            : 'Manuel',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Carpool section
            if (carpoolInfo != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.people,
                                color: theme.colorScheme.primary),
                            const SizedBox(width: 12),
                            Text(
                              'Covoiturage',
                              style: theme.textTheme.titleSmall,
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          carpoolInfo.isPassenger
                              ? 'Vous \u00e9tiez passager'
                              : 'Vous \u00eates le conducteur',
                          style: theme.textTheme.bodyMedium,
                        ),
                        if (carpoolInfo.isPassenger &&
                            carpoolInfo.driverName != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Conducteur : ${carpoolInfo.driverName}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                        if (carpoolInfo.isPassenger) ...[
                          const SizedBox(height: 4),
                          Text(
                            '0 km rembours\u00e9',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.orange.shade700,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                        if (carpoolInfo.members.isNotEmpty) ...[
                          const Divider(height: 24),
                          Text(
                            'Membres du groupe',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.grey.shade600,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          ...carpoolInfo.members.map(
                            (member) => Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                children: [
                                  Icon(
                                    member.role == CarpoolRole.driver
                                        ? Icons.drive_eta
                                        : Icons.person,
                                    size: 16,
                                    color: Colors.grey.shade600,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      member.employeeName,
                                      style:
                                          theme.textTheme.bodySmall,
                                    ),
                                  ),
                                  Text(
                                    member.role.displayName,
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(
                                      color: Colors.grey.shade500,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),

            // Company vehicle section
            if (isCompanyVehicle)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Card(
                  color: Colors.purple.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.business,
                                color: Colors.purple.shade700),
                            const SizedBox(width: 12),
                            Text(
                              'V\u00e9hicule d\u2019entreprise',
                              style: theme.textTheme.titleSmall,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Ce trajet a \u00e9t\u00e9 effectu\u00e9 avec un v\u00e9hicule de l\u2019entreprise',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.grey.shade600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '0 km rembours\u00e9',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.purple.shade700,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            if (_trip.isLowConfidence)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Card(
                  color: Colors.amber.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          color: Colors.amber.shade700,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Certains segments GPS avaient une faible précision. '
                            'La distance peut être estimée.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.amber.shade900,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildAddressRow(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String label,
    required String address,
    bool isGeocoding = false,
  }) {
    return Row(
      children: [
        Icon(icon, size: 22, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey.shade600,
                    ),
              ),
              if (isGeocoding)
                const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Text(
                  address,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMetricRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    Color? valueColor,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.grey),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: valueColor,
                ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(int minutes) {
    if (minutes < 60) return '${minutes}m';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m > 0 ? '${h}h ${m}m' : '${h}h';
  }
}
