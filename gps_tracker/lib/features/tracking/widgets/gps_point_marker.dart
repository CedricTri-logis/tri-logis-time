import 'package:flutter/material.dart';

import '../models/route_point.dart';

/// Individual GPS point marker for map display.
class GpsPointMarker extends StatelessWidget {
  /// The GPS point to display.
  final RoutePoint point;

  /// Marker size in logical pixels.
  final double size;

  /// Whether this is the start point.
  final bool isStart;

  /// Whether this is the end point.
  final bool isEnd;

  /// Callback when tapped.
  final VoidCallback? onTap;

  const GpsPointMarker({
    required this.point,
    super.key,
    this.size = 12,
    this.isStart = false,
    this.isEnd = false,
    this.onTap,
  });

  Color get markerColor {
    if (isStart) return Colors.green;
    if (isEnd) return Colors.red;
    if (point.isLowAccuracy) return Colors.orange;
    if (point.isHighAccuracy) return Colors.green;
    return Colors.yellow; // Medium accuracy
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: markerColor,
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white,
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(64),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: isStart || isEnd
            ? Icon(
                isStart ? Icons.play_arrow : Icons.stop,
                size: size * 0.6,
                color: Colors.white,
              )
            : null,
      ),
    );
  }
}
