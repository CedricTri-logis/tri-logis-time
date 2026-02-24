import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/trip.dart';
import '../providers/reimbursement_rate_provider.dart';
import '../providers/trip_provider.dart';
import '../services/mileage_report_service.dart';
import '../widgets/report_share_sheet.dart';

/// Screen for generating a PDF mileage reimbursement report.
class MileageReportScreen extends ConsumerStatefulWidget {
  final DateTime initialStart;
  final DateTime initialEnd;

  const MileageReportScreen({
    super.key,
    required this.initialStart,
    required this.initialEnd,
  });

  @override
  ConsumerState<MileageReportScreen> createState() =>
      _MileageReportScreenState();
}

class _MileageReportScreenState extends ConsumerState<MileageReportScreen> {
  late DateTime _periodStart;
  late DateTime _periodEnd;
  bool _isGenerating = false;

  @override
  void initState() {
    super.initState();
    _periodStart = widget.initialStart;
    _periodEnd = widget.initialEnd;
  }

  String? get _currentUserId =>
      Supabase.instance.client.auth.currentUser?.id;

  TripPeriodParams get _periodParams => TripPeriodParams(
        employeeId: _currentUserId ?? '',
        start: _periodStart,
        end: _periodEnd,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_currentUserId == null) {
      return const Scaffold(
        body: Center(child: Text('Non authentifié')),
      );
    }

    final tripsAsync = ref.watch(tripsForPeriodProvider(_periodParams));
    final rateAsync = ref.watch(reimbursementRateProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Générer un rapport'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Date Range Card
            _buildDateRangeCard(theme),
            const SizedBox(height: 16),

            // Trip Preview Section
            tripsAsync.when(
              data: (trips) => _buildTripPreview(theme, trips),
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'Erreur de chargement des trajets : $e',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Rate Info
            rateAsync.when(
              data: (rate) {
                if (rate == null) return const SizedBox.shrink();
                return _buildRateInfo(theme, rate);
              },
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
            const SizedBox(height: 24),

            // Generate Button
            tripsAsync.when(
              data: (trips) {
                final businessTrips =
                    trips.where((t) => t.isBusiness).toList();
                return _buildGenerateButton(
                  theme,
                  businessTrips: businessTrips,
                  allTrips: trips,
                );
              },
              loading: () => _buildGenerateButton(
                theme,
                businessTrips: [],
                allTrips: [],
                forceDisabled: true,
              ),
              error: (_, __) => _buildGenerateButton(
                theme,
                businessTrips: [],
                allTrips: [],
                forceDisabled: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDateRangeCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              Icons.date_range,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Période',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _formatPeriod(_periodStart, _periodEnd),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: _pickDateRange,
              child: const Text('Modifier'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTripPreview(ThemeData theme, List<Trip> trips) {
    final businessTrips = trips.where((t) => t.isBusiness).toList();
    final totalBusinessKm = businessTrips.fold<double>(
      0,
      (sum, t) => sum + t.distanceKm,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Résumé des trajets',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            if (businessTrips.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Column(
                    children: [
                      Icon(
                        Icons.directions_car_outlined,
                        size: 48,
                        color: Colors.grey.shade300,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "Aucun trajet d'affaires pour cette période",
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else ...[
              Row(
                children: [
                  _buildStatChip(
                    theme,
                    icon: Icons.business_center_outlined,
                    label: "${businessTrips.length} trajet${businessTrips.length == 1 ? '' : 's'} d'affaires",
                  ),
                  const SizedBox(width: 12),
                  _buildStatChip(
                    theme,
                    icon: Icons.straighten,
                    label: '${totalBusinessKm.toStringAsFixed(1)} km',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 8),
              ...businessTrips.take(5).map(
                    (trip) => _buildTripRow(theme, trip),
                  ),
              if (businessTrips.length > 5)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '+ ${businessTrips.length - 5} trajet${businessTrips.length - 5 == 1 ? '' : 's'} de plus',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatChip(
    ThemeData theme, {
    required IconData icon,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTripRow(ThemeData theme, Trip trip) {
    final date = trip.startedAt.toLocal();
    final months = [
      'Jan', 'Fév', 'Mar', 'Avr', 'Mai', 'Jun',
      'Jul', 'Aoû', 'Sep', 'Oct', 'Nov', 'Déc',
    ];
    final dateStr = '${months[date.month - 1]} ${date.day}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Text(
              dateStr,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${trip.startDisplayName} \u2192 ${trip.endDisplayName}',
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${trip.distanceKm.toStringAsFixed(1)} km',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRateInfo(ThemeData theme, dynamic rate) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              Icons.attach_money,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Taux de remboursement',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Rate: ${rate.displayRate} (${rate.displaySource})',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
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

  Widget _buildGenerateButton(
    ThemeData theme, {
    required List<Trip> businessTrips,
    required List<Trip> allTrips,
    bool forceDisabled = false,
  }) {
    final isDisabled =
        forceDisabled || _isGenerating || businessTrips.isEmpty;

    return FilledButton(
      onPressed: isDisabled ? null : () => _generateReport(businessTrips),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: _isGenerating
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Text('Générer le rapport PDF'),
      ),
    );
  }

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(
        start: _periodStart,
        end: _periodEnd.subtract(const Duration(days: 1)),
      ),
    );
    if (picked != null) {
      setState(() {
        _periodStart = picked.start;
        _periodEnd = picked.end.add(const Duration(days: 1));
      });
    }
  }

  Future<void> _generateReport(List<Trip> businessTrips) async {
    setState(() => _isGenerating = true);

    try {
      final userName = Supabase.instance.client.auth.currentUser
              ?.userMetadata?['full_name'] as String? ??
          'Employé';

      final rateValue = ref.read(reimbursementRateProvider).valueOrNull;
      if (rateValue == null) {
        throw Exception('Reimbursement rate not available');
      }

      final filePath = await MileageReportService().generateReport(
        trips: businessTrips,
        rate: rateValue,
        employeeName: userName,
        periodStart: _periodStart,
        periodEnd: _periodEnd,
        ytdKm: 0,
      );

      if (mounted) {
        await ReportShareSheet.show(context, filePath);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erreur de génération du rapport : $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isGenerating = false);
      }
    }
  }

  String _formatPeriod(DateTime start, DateTime end) {
    final months = [
      'Jan', 'Fév', 'Mar', 'Avr', 'Mai', 'Jun',
      'Jul', 'Aoû', 'Sep', 'Oct', 'Nov', 'Déc',
    ];
    final displayEnd = end.subtract(const Duration(days: 1));
    if (start.year == displayEnd.year) {
      if (start.month == displayEnd.month) {
        return '${months[start.month - 1]} ${start.day} - ${displayEnd.day}, ${start.year}';
      }
      return '${months[start.month - 1]} ${start.day} - ${months[displayEnd.month - 1]} ${displayEnd.day}, ${start.year}';
    }
    return '${months[start.month - 1]} ${start.day}, ${start.year} - ${months[displayEnd.month - 1]} ${displayEnd.day}, ${displayEnd.year}';
  }
}
