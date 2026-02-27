import 'package:flutter/material.dart';
import '../models/carpool_info.dart';
import '../models/trip.dart';
import 'carpool_badge.dart';
import 'company_vehicle_badge.dart';
import 'match_status_badge.dart';
import 'trip_classification_chip.dart';

class TripCard extends StatelessWidget {
  final Trip trip;
  final CarpoolInfo? carpoolInfo;
  final bool hasCompanyVehicle;
  final VoidCallback? onTap;
  final VoidCallback? onClassificationToggle;

  const TripCard({
    super.key,
    required this.trip,
    this.carpoolInfo,
    this.hasCompanyVehicle = false,
    this.onTap,
    this.onClassificationToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    trip.isWalking ? Icons.directions_walk : Icons.directions_car,
                    size: 18,
                    color: trip.isWalking
                        ? Colors.orange
                        : trip.isBusiness
                            ? theme.colorScheme.primary
                            : Colors.grey,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      trip.startDisplayName,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (trip.isLowConfidence)
                    Tooltip(
                      message: 'Faible précision GPS sur certains segments',
                      child: Icon(
                        Icons.warning_amber_rounded,
                        size: 18,
                        color: Colors.amber.shade700,
                      ),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 26),
                child: Row(
                  children: [
                    const Icon(Icons.arrow_downward, size: 14, color: Colors.grey),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        trip.endDisplayName,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.grey.shade600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _MetricChip(
                    icon: Icons.straighten,
                    label: '${trip.effectiveDistanceKm.toStringAsFixed(1)} km',
                  ),
                  const SizedBox(width: 8),
                  _MetricChip(
                    icon: Icons.timer_outlined,
                    label: '${trip.durationMinutes} min',
                  ),
                  const Spacer(),
                  MatchStatusBadge(trip: trip, compact: true),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                alignment: WrapAlignment.end,
                children: [
                  if (carpoolInfo != null)
                    CarpoolBadge(carpoolInfo: carpoolInfo!),
                  if (hasCompanyVehicle)
                    const CompanyVehicleBadge(),
                  TripClassificationChip(
                    classification: trip.classification,
                    onTap: onClassificationToggle,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MetricChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: Colors.grey),
        const SizedBox(width: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
