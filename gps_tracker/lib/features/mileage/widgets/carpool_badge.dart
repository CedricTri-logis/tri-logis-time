import 'package:flutter/material.dart';
import '../models/carpool_info.dart';

class CarpoolBadge extends StatelessWidget {
  final CarpoolInfo carpoolInfo;

  const CarpoolBadge({super.key, required this.carpoolInfo});

  @override
  Widget build(BuildContext context) {
    final isPassenger = carpoolInfo.isPassenger;
    return Chip(
      avatar: Icon(
        isPassenger ? Icons.person : Icons.drive_eta,
        size: 14,
        color: isPassenger ? Colors.white : Colors.green.shade900,
      ),
      label: Text(
        isPassenger
            ? 'Passager${carpoolInfo.driverName != null ? ' \u00b7 ${carpoolInfo.driverName}' : ''}'
            : 'Conducteur',
        style: TextStyle(
          fontSize: 11,
          color: isPassenger ? Colors.white : Colors.green.shade900,
        ),
      ),
      backgroundColor: isPassenger ? Colors.orange : Colors.green.shade100,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    );
  }
}
