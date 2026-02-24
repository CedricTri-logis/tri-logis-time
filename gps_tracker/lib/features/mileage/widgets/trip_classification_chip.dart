import 'package:flutter/material.dart';

import '../models/trip.dart';

/// Tappable chip showing trip classification (Business/Personal).
class TripClassificationChip extends StatelessWidget {
  final TripClassification classification;
  final VoidCallback? onTap;

  const TripClassificationChip({
    super.key,
    required this.classification,
    this.onTap,
  });

  bool get _isBusiness => classification == TripClassification.business;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Chip(
        label: Text(
          _isBusiness ? 'Affaires' : 'Personnel',
          style: TextStyle(
            fontSize: 11,
            color: _isBusiness ? Colors.white : Colors.grey.shade700,
          ),
        ),
        backgroundColor:
            _isBusiness ? theme.colorScheme.primary : Colors.grey.shade200,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
      ),
    );
  }
}
