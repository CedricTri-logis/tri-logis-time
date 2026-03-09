import 'package:flutter/material.dart';

class CompanyVehicleBadge extends StatelessWidget {
  const CompanyVehicleBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: const Icon(Icons.business, size: 14, color: Colors.white),
      label: const Text(
        'Véh. entreprise',
        style: TextStyle(fontSize: 11, color: Colors.white),
      ),
      backgroundColor: Colors.purple,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    );
  }
}
