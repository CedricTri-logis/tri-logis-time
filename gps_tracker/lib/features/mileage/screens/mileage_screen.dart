import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/trip.dart';
import '../providers/mileage_summary_provider.dart';
import '../providers/trip_provider.dart';
import '../widgets/mileage_period_picker.dart';
import '../widgets/mileage_summary_card.dart';
import '../widgets/trip_card.dart';
import 'mileage_report_screen.dart';
import 'trip_detail_screen.dart';

/// Main mileage view showing period summary and trip list.
class MileageScreen extends ConsumerStatefulWidget {
  const MileageScreen({super.key});

  @override
  ConsumerState<MileageScreen> createState() => _MileageScreenState();
}

enum _TripFilter { all, business, personal }

class _MileageScreenState extends ConsumerState<MileageScreen> {
  late DateTime _periodStart;
  late DateTime _periodEnd;
  _TripFilter _filter = _TripFilter.all;

  @override
  void initState() {
    super.initState();
    // Default to this week
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    _periodStart = DateTime(monday.year, monday.month, monday.day);
    _periodEnd = _periodStart.add(const Duration(days: 7));
  }

  String? get _currentUserId => Supabase.instance.client.auth.currentUser?.id;

  TripPeriodParams get _periodParams => TripPeriodParams(
        employeeId: _currentUserId ?? '',
        start: _periodStart,
        end: _periodEnd,
      );

  @override
  Widget build(BuildContext context) {
    if (_currentUserId == null) {
      return const Scaffold(
        body: Center(child: Text('Non authentifié')),
      );
    }

    final tripsAsync = ref.watch(tripsForPeriodProvider(_periodParams));
    final summaryAsync = ref.watch(mileageSummaryProvider(_periodParams));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Kilométrage'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.description_outlined),
            tooltip: 'Générer un rapport',
            onPressed: () => _navigateToReport(context),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(tripsForPeriodProvider(_periodParams));
          ref.invalidate(mileageSummaryProvider(_periodParams));
        },
        child: ListView(
          children: [
            MileagePeriodPicker(
              periodStart: _periodStart,
              periodEnd: _periodEnd,
              onPeriodChanged: (range) {
                setState(() {
                  _periodStart = range.start;
                  _periodEnd = range.end;
                });
              },
            ),
            summaryAsync.when(
              data: (summary) => MileageSummaryCard(summary: summary),
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (_, __) => const SizedBox.shrink(),
            ),
            const SizedBox(height: 8),
            // Classification filter chips
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _buildFilterChip('Tous', _TripFilter.all),
                  const SizedBox(width: 8),
                  _buildFilterChip('Affaires', _TripFilter.business),
                  const SizedBox(width: 8),
                  _buildFilterChip('Personnel', _TripFilter.personal),
                ],
              ),
            ),
            const SizedBox(height: 8),
            tripsAsync.when(
              data: (trips) {
                final filtered = _applyFilter(trips);
                if (filtered.isEmpty) {
                  return _buildEmptyState();
                }
                return Column(
                  children: _buildGroupedTrips(filtered),
                );
              },
              loading: () => const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Erreur de chargement des trajets : $e'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Trip> _applyFilter(List<Trip> trips) {
    switch (_filter) {
      case _TripFilter.all:
        return trips;
      case _TripFilter.business:
        return trips.where((t) => t.isBusiness).toList();
      case _TripFilter.personal:
        return trips.where((t) => !t.isBusiness).toList();
    }
  }

  Widget _buildFilterChip(String label, _TripFilter filter) {
    final isSelected = _filter == filter;
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) {
        setState(() => _filter = filter);
      },
      visualDensity: VisualDensity.compact,
    );
  }

  List<Widget> _buildGroupedTrips(List<Trip> trips) {
    final grouped = <String, List<Trip>>{};
    for (final trip in trips) {
      final date = trip.startedAt.toLocal();
      final key = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      grouped.putIfAbsent(key, () => []).add(trip);
    }

    final widgets = <Widget>[];
    for (final entry in grouped.entries) {
      final date = DateTime.parse(entry.key);
      final dayName = _formatDayHeader(date);
      widgets.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            dayName,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Colors.grey.shade600,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
      );
      for (final trip in entry.value) {
        widgets.add(
          TripCard(
            trip: trip,
            onTap: () => _navigateToTripDetail(context, trip),
            onClassificationToggle: () => _toggleClassification(trip),
          ),
        );
      }
    }
    return widgets;
  }

  String _formatDayHeader(DateTime date) {
    final weekdays = ['Lun', 'Mar', 'Mer', 'Jeu', 'Ven', 'Sam', 'Dim'];
    final months = [
      'Jan', 'Fév', 'Mar', 'Avr', 'Mai', 'Jun',
      'Jul', 'Aoû', 'Sep', 'Oct', 'Nov', 'Déc',
    ];
    return '${weekdays[date.weekday - 1]}, ${months[date.month - 1]} ${date.day}';
  }

  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.all(48),
      child: Column(
        children: [
          Icon(
            Icons.directions_car_outlined,
            size: 64,
            color: Colors.grey.shade300,
          ),
          const SizedBox(height: 16),
          Text(
            'Aucun trajet détecté',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.grey.shade600,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Les trajets sont détectés automatiquement\nà partir des données GPS lors du dépointage.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey.shade500,
                ),
          ),
        ],
      ),
    );
  }

  void _navigateToTripDetail(BuildContext context, Trip trip) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TripDetailScreen(trip: trip),
      ),
    );
  }

  void _navigateToReport(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MileageReportScreen(
          initialStart: _periodStart,
          initialEnd: _periodEnd,
        ),
      ),
    );
  }

  Future<void> _toggleClassification(Trip trip) async {
    final newClassification = trip.isBusiness
        ? TripClassification.personal
        : TripClassification.business;

    final service = ref.read(tripServiceProvider);
    final success =
        await service.updateTripClassification(trip.id, newClassification);

    if (success) {
      ref.invalidate(tripsForPeriodProvider(_periodParams));
      ref.invalidate(mileageSummaryProvider(_periodParams));
    }
  }
}
