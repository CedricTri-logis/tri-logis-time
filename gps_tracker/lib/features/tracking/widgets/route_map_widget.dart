import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/route_point.dart';
import 'gps_point_marker.dart';

/// Display GPS points as a route on an interactive map.
class RouteMapWidget extends StatefulWidget {
  /// GPS points to display.
  final List<RoutePoint> points;

  /// Whether to show individual point markers.
  final bool showMarkers;

  /// Whether to show accuracy indicators on markers.
  final bool showAccuracy;

  /// Callback when a point is tapped.
  final void Function(RoutePoint point)? onPointTap;

  /// Initial zoom level (default: auto-fit to bounds).
  final double? initialZoom;

  const RouteMapWidget({
    required this.points,
    super.key,
    this.showMarkers = true,
    this.showAccuracy = true,
    this.onPointTap,
    this.initialZoom,
  });

  @override
  State<RouteMapWidget> createState() => _RouteMapWidgetState();
}

class _RouteMapWidgetState extends State<RouteMapWidget> {
  late final MapController _mapController;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  LatLng? get _center {
    if (widget.points.isEmpty) return null;

    double sumLat = 0;
    double sumLng = 0;
    for (final point in widget.points) {
      sumLat += point.latitude;
      sumLng += point.longitude;
    }
    return LatLng(
      sumLat / widget.points.length,
      sumLng / widget.points.length,
    );
  }

  LatLngBounds? get _bounds {
    if (widget.points.isEmpty) return null;

    double minLat = widget.points.first.latitude;
    double maxLat = widget.points.first.latitude;
    double minLng = widget.points.first.longitude;
    double maxLng = widget.points.first.longitude;

    for (final point in widget.points) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }

    // Add padding
    const padding = 0.001;
    return LatLngBounds(
      LatLng(minLat - padding, minLng - padding),
      LatLng(maxLat + padding, maxLng + padding),
    );
  }

  List<LatLng> get _routeCoordinates {
    return widget.points
        .map((p) => LatLng(p.latitude, p.longitude))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.points.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.location_off, size: 48, color: Colors.grey),
            SizedBox(height: 8),
            Text(
              'No location data',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _center ?? const LatLng(0, 0),
        initialZoom: widget.initialZoom ?? 14,
        initialCameraFit: _bounds != null
            ? CameraFit.bounds(
                bounds: _bounds!,
                padding: const EdgeInsets.all(50),
              )
            : null,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all,
        ),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.gps_tracker.app',
        ),
        if (_routeCoordinates.length >= 2)
          PolylineLayer(
            polylines: [
              Polyline(
                points: _routeCoordinates,
                color: Colors.blue,
                strokeWidth: 3,
              ),
            ],
          ),
        if (widget.showMarkers)
          MarkerLayer(
            markers: _buildMarkers(),
          ),
      ],
    );
  }

  List<Marker> _buildMarkers() {
    return widget.points.asMap().entries.map((entry) {
      final index = entry.key;
      final point = entry.value;
      final isStart = index == 0;
      final isEnd = index == widget.points.length - 1;

      return Marker(
        point: LatLng(point.latitude, point.longitude),
        width: isStart || isEnd ? 24 : 16,
        height: isStart || isEnd ? 24 : 16,
        child: GpsPointMarker(
          point: point,
          size: isStart || isEnd ? 24 : 16,
          isStart: isStart,
          isEnd: isEnd,
          onTap: widget.onPointTap != null ? () => widget.onPointTap!(point) : null,
        ),
      );
    }).toList();
  }
}
