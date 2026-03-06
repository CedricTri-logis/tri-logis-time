import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../shared/utils/timezone_formatter.dart';
import '../screens/fullscreen_map_screen.dart';
import '../services/history_service.dart';

/// Widget that displays GPS route on an OpenStreetMap via flutter_map
///
/// Shows clock-in/out locations as markers and GPS points as a route polyline.
class GpsRouteMap extends StatefulWidget {
  /// GPS points for the route
  final List<GpsPointData> gpsPoints;

  /// Clock-in location (if available)
  final LatLng? clockInLocation;

  /// Clock-out location (if available)
  final LatLng? clockOutLocation;

  /// Clock-in timestamp for marker info
  final DateTime? clockedInAt;

  /// Clock-out timestamp for marker info
  final DateTime? clockedOutAt;

  /// Callback when a GPS point marker is tapped
  final void Function(GpsPointData point)? onPointTapped;

  /// Initial camera position (defaults to clock-in location or first point)
  final LatLng? initialPosition;

  /// Whether the map can be interacted with
  final bool interactive;

  /// Height of the map widget
  final double? height;

  /// Whether to show the fullscreen button
  final bool showFullscreenButton;

  /// Title for the fullscreen view
  final String? shiftTitle;

  const GpsRouteMap({
    super.key,
    required this.gpsPoints,
    this.clockInLocation,
    this.clockOutLocation,
    this.clockedInAt,
    this.clockedOutAt,
    this.onPointTapped,
    this.initialPosition,
    this.interactive = true,
    this.height,
    this.showFullscreenButton = true,
    this.shiftTitle,
  });

  @override
  State<GpsRouteMap> createState() => _GpsRouteMapState();
}

class _GpsRouteMapState extends State<GpsRouteMap> {
  late final MapController _controller;
  List<Marker> _markers = [];
  List<Polyline> _polylines = [];
  GpsPointData? _selectedPoint;

  @override
  void initState() {
    super.initState();
    _controller = MapController();
    _buildMapElements();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(GpsRouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gpsPoints != widget.gpsPoints ||
        oldWidget.clockInLocation != widget.clockInLocation ||
        oldWidget.clockOutLocation != widget.clockOutLocation) {
      _buildMapElements();
    }
  }

  void _buildMapElements() {
    final markers = <Marker>[];
    final polylinePoints = <LatLng>[];

    // Add clock-in marker
    if (widget.clockInLocation != null) {
      markers.add(
        Marker(
          point: widget.clockInLocation!,
          width: 40,
          height: 40,
          child: const Icon(Icons.location_on, color: Colors.green, size: 40),
        ),
      );
      polylinePoints.add(widget.clockInLocation!);
    }

    // Add GPS point markers and build polyline
    for (int i = 0; i < widget.gpsPoints.length; i++) {
      final point = widget.gpsPoints[i];
      final position = LatLng(point.latitude, point.longitude);
      polylinePoints.add(position);

      // Only add markers for selected points or at intervals for large datasets
      if (widget.gpsPoints.length <= 20 || i % (widget.gpsPoints.length ~/ 20) == 0) {
        markers.add(
          Marker(
            point: position,
            width: 24,
            height: 24,
            child: GestureDetector(
              onTap: () {
                setState(() => _selectedPoint = point);
                widget.onPointTapped?.call(point);
              },
              child: const Icon(Icons.circle, color: Colors.blue, size: 14),
            ),
          ),
        );
      }
    }

    // Add clock-out marker
    if (widget.clockOutLocation != null) {
      markers.add(
        Marker(
          point: widget.clockOutLocation!,
          width: 40,
          height: 40,
          child: const Icon(Icons.location_on, color: Colors.red, size: 40),
        ),
      );
      polylinePoints.add(widget.clockOutLocation!);
    }

    // Create polyline for the route
    final polylines = <Polyline>[];
    if (polylinePoints.length >= 2) {
      polylines.add(
        Polyline(
          points: polylinePoints,
          color: Colors.blue,
          strokeWidth: 4,
        ),
      );
    }

    setState(() {
      _markers = markers;
      _polylines = polylines;
    });
  }

  LatLng _getInitialPosition() {
    if (widget.initialPosition != null) {
      return widget.initialPosition!;
    }
    if (widget.clockInLocation != null) {
      return widget.clockInLocation!;
    }
    if (widget.gpsPoints.isNotEmpty) {
      return LatLng(widget.gpsPoints.first.latitude, widget.gpsPoints.first.longitude);
    }
    // Default to a central position if no data
    return const LatLng(37.7749, -122.4194);
  }

  LatLngBounds? _getBounds() {
    final points = <LatLng>[];

    if (widget.clockInLocation != null) {
      points.add(widget.clockInLocation!);
    }
    for (final point in widget.gpsPoints) {
      points.add(LatLng(point.latitude, point.longitude));
    }
    if (widget.clockOutLocation != null) {
      points.add(widget.clockOutLocation!);
    }

    if (points.length < 2) return null;

    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;

    for (final point in points) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }

    return LatLngBounds(
      LatLng(minLat, minLng),
      LatLng(maxLat, maxLng),
    );
  }

  void _fitBounds() {
    final bounds = _getBounds();
    if (bounds != null) {
      _controller.fitCamera(
        CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(50)),
      );
    }
  }

  void _openFullscreen(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => FullscreenMapScreen(
          gpsPoints: widget.gpsPoints,
          clockInLocation: widget.clockInLocation,
          clockOutLocation: widget.clockOutLocation,
          clockedInAt: widget.clockedInAt,
          clockedOutAt: widget.clockedOutAt,
          shiftTitle: widget.shiftTitle,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasData = widget.gpsPoints.isNotEmpty ||
        widget.clockInLocation != null ||
        widget.clockOutLocation != null;

    if (!hasData) {
      return Container(
        height: widget.height ?? 300,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.location_off,
                size: 48,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(
                'Aucune donnee GPS disponible',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final bounds = _getBounds();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: widget.height ?? 300,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _controller,
                  options: MapOptions(
                    initialCenter: _getInitialPosition(),
                    initialZoom: 15,
                    initialCameraFit: bounds != null
                        ? CameraFit.bounds(
                            bounds: bounds,
                            padding: const EdgeInsets.all(50),
                          )
                        : null,
                    interactionOptions: InteractionOptions(
                      flags: widget.interactive
                          ? InteractiveFlag.all
                          : InteractiveFlag.none,
                    ),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'ca.trilogis.gpstracker',
                    ),
                    if (_polylines.isNotEmpty)
                      PolylineLayer(polylines: _polylines),
                    if (_markers.isNotEmpty)
                      MarkerLayer(markers: _markers),
                  ],
                ),
                // Custom map controls
                if (widget.interactive)
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Column(
                      children: [
                        // Zoom in
                        _MapControlButton(
                          icon: Icons.add,
                          tooltip: 'Zoom avant',
                          onPressed: () {
                            _controller.move(
                              _controller.camera.center,
                              _controller.camera.zoom + 1,
                            );
                          },
                        ),
                        const SizedBox(height: 4),
                        // Zoom out
                        _MapControlButton(
                          icon: Icons.remove,
                          tooltip: 'Zoom arriere',
                          onPressed: () {
                            _controller.move(
                              _controller.camera.center,
                              _controller.camera.zoom - 1,
                            );
                          },
                        ),
                        const SizedBox(height: 8),
                        // Fit bounds
                        _MapControlButton(
                          icon: Icons.fit_screen,
                          tooltip: 'Ajuster le trace',
                          onPressed: _fitBounds,
                        ),
                        if (widget.showFullscreenButton) ...[
                          const SizedBox(height: 8),
                          // Fullscreen
                          _MapControlButton(
                            icon: Icons.fullscreen,
                            tooltip: 'Plein ecran',
                            onPressed: () => _openFullscreen(context),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (_selectedPoint != null) ...[
          const SizedBox(height: 8),
          _buildSelectedPointInfo(theme),
        ],
        const SizedBox(height: 8),
        _buildLegend(theme),
      ],
    );
  }

  Widget _buildSelectedPointInfo(ThemeData theme) {
    final point = _selectedPoint!;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.location_on,
            color: theme.colorScheme.onPrimaryContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  TimezoneFormatter.formatTimeWithSecondsTz(point.capturedAt),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                if (point.accuracy != null)
                  Text(
                    'Precision : \u00b1${point.accuracy!.toStringAsFixed(0)}m',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => setState(() => _selectedPoint = null),
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ],
      ),
    );
  }

  Widget _buildLegend(ThemeData theme) {
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: [
        _buildLegendItem(theme, Colors.green, 'Pointage'),
        _buildLegendItem(theme, Colors.red, 'Depointage'),
        _buildLegendItem(theme, Colors.blue, 'Trace GPS'),
      ],
    );
  }

  Widget _buildLegendItem(ThemeData theme, Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Custom map control button widget
class _MapControlButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _MapControlButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(4),
      color: Colors.white,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(4),
        child: Tooltip(
          message: tooltip,
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 20,
              color: Colors.grey[700],
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact map preview for use in cards/lists
class GpsRouteMapPreview extends StatelessWidget {
  final List<GpsPointData> gpsPoints;
  final LatLng? clockInLocation;
  final LatLng? clockOutLocation;
  final VoidCallback? onTap;

  const GpsRouteMapPreview({
    super.key,
    required this.gpsPoints,
    this.clockInLocation,
    this.clockOutLocation,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: GpsRouteMap(
        gpsPoints: gpsPoints,
        clockInLocation: clockInLocation,
        clockOutLocation: clockOutLocation,
        interactive: false,
        height: 150,
      ),
    );
  }
}
