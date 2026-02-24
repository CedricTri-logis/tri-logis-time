import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../shared/utils/timezone_formatter.dart';
import '../services/history_service.dart';

/// Fullscreen map view with complete gesture control and enhanced UI
///
/// Best practice for mobile maps: embedded preview + fullscreen for interaction
class FullscreenMapScreen extends StatefulWidget {
  final List<GpsPointData> gpsPoints;
  final LatLng? clockInLocation;
  final LatLng? clockOutLocation;
  final DateTime? clockedInAt;
  final DateTime? clockedOutAt;
  final String? shiftTitle;

  const FullscreenMapScreen({
    super.key,
    required this.gpsPoints,
    this.clockInLocation,
    this.clockOutLocation,
    this.clockedInAt,
    this.clockedOutAt,
    this.shiftTitle,
  });

  @override
  State<FullscreenMapScreen> createState() => _FullscreenMapScreenState();
}

class _FullscreenMapScreenState extends State<FullscreenMapScreen> {
  GoogleMapController? _controller;
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  MapType _mapType = MapType.normal;
  GpsPointData? _selectedPoint;
  bool _showInfo = true;

  @override
  void initState() {
    super.initState();
    // Set to fullscreen immersive mode
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _buildMapElements();
  }

  @override
  void dispose() {
    // Restore system UI
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _buildMapElements() {
    final markers = <Marker>{};
    final polylinePoints = <LatLng>[];

    // Add clock-in marker
    if (widget.clockInLocation != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('clock_in'),
          position: widget.clockInLocation!,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          infoWindow: InfoWindow(
            title: 'Pointage',
            snippet: widget.clockedInAt != null
                ? TimezoneFormatter.formatDateTimeWithTz(widget.clockedInAt!)
                : null,
          ),
        ),
      );
      polylinePoints.add(widget.clockInLocation!);
    }

    // Add GPS point markers and build polyline
    for (int i = 0; i < widget.gpsPoints.length; i++) {
      final point = widget.gpsPoints[i];
      final position = LatLng(point.latitude, point.longitude);
      polylinePoints.add(position);

      // Add markers at intervals for large datasets
      if (widget.gpsPoints.length <= 30 || i % (widget.gpsPoints.length ~/ 30) == 0) {
        markers.add(
          Marker(
            markerId: MarkerId('point_${point.id}'),
            position: position,
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
            infoWindow: InfoWindow(
              title: 'Point GPS ${i + 1}',
              snippet: TimezoneFormatter.formatTimeWithSecondsTz(point.capturedAt),
            ),
            onTap: () {
              setState(() => _selectedPoint = point);
            },
          ),
        );
      }
    }

    // Add clock-out marker
    if (widget.clockOutLocation != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('clock_out'),
          position: widget.clockOutLocation!,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          infoWindow: InfoWindow(
            title: 'Dépointage',
            snippet: widget.clockedOutAt != null
                ? TimezoneFormatter.formatDateTimeWithTz(widget.clockedOutAt!)
                : null,
          ),
        ),
      );
      polylinePoints.add(widget.clockOutLocation!);
    }

    // Create polyline for the route
    final polylines = <Polyline>{};
    if (polylinePoints.length >= 2) {
      polylines.add(
        Polyline(
          polylineId: const PolylineId('route'),
          points: polylinePoints,
          color: Colors.blue,
          width: 4,
        ),
      );
    }

    setState(() {
      _markers = markers;
      _polylines = polylines;
    });
  }

  LatLng _getInitialPosition() {
    if (widget.clockInLocation != null) {
      return widget.clockInLocation!;
    }
    if (widget.gpsPoints.isNotEmpty) {
      return LatLng(widget.gpsPoints.first.latitude, widget.gpsPoints.first.longitude);
    }
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
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
  }

  void _fitBounds() {
    final bounds = _getBounds();
    if (bounds != null && _controller != null) {
      _controller!.animateCamera(
        CameraUpdate.newLatLngBounds(bounds, 80),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(widget.shiftTitle ?? 'Carte du trajet'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: Icon(_showInfo ? Icons.info : Icons.info_outline),
            tooltip: _showInfo ? 'Masquer les infos' : 'Afficher les infos',
            onPressed: () => setState(() => _showInfo = !_showInfo),
          ),
        ],
      ),
      body: Stack(
        children: [
          // Full screen map
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: _getInitialPosition(),
              zoom: 15,
            ),
            markers: _markers,
            polylines: _polylines,
            mapType: _mapType,
            onMapCreated: (controller) {
              _controller = controller;
              Future.delayed(const Duration(milliseconds: 500), _fitBounds);
            },
            myLocationEnabled: false,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            compassEnabled: true,
            mapToolbarEnabled: false,
            // Full gesture support
            scrollGesturesEnabled: true,
            zoomGesturesEnabled: true,
            rotateGesturesEnabled: true,
            tiltGesturesEnabled: true,
          ),

          // Map controls - right side
          Positioned(
            right: 16,
            bottom: 140,
            child: Column(
              children: [
                _buildControlButton(
                  icon: _mapType == MapType.satellite ? Icons.map : Icons.satellite_alt,
                  label: _mapType == MapType.satellite ? 'Carte' : 'Satellite',
                  onPressed: () {
                    setState(() {
                      _mapType = _mapType == MapType.satellite
                          ? MapType.normal
                          : MapType.satellite;
                    });
                  },
                ),
                const SizedBox(height: 12),
                _buildControlButton(
                  icon: Icons.add,
                  label: 'Agrandir',
                  onPressed: () => _controller?.animateCamera(CameraUpdate.zoomIn()),
                ),
                const SizedBox(height: 8),
                _buildControlButton(
                  icon: Icons.remove,
                  label: 'Réduire',
                  onPressed: () => _controller?.animateCamera(CameraUpdate.zoomOut()),
                ),
                const SizedBox(height: 12),
                _buildControlButton(
                  icon: Icons.fit_screen,
                  label: 'Adapter la route',
                  onPressed: _fitBounds,
                ),
              ],
            ),
          ),

          // Info panel - bottom
          if (_showInfo)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildInfoPanel(),
            ),

          // Selected point info
          if (_selectedPoint != null)
            Positioned(
              left: 16,
              right: 80,
              bottom: _showInfo ? 140 : 16,
              child: _buildSelectedPointCard(),
            ),

          // Gesture hint (shown briefly)
          Positioned(
            left: 16,
            top: 100,
            child: _buildGestureHint(),
          ),
        ],
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(8),
      color: Colors.white,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          child: Icon(icon, size: 24, color: Colors.grey[800]),
        ),
      ),
    );
  }

  Widget _buildInfoPanel() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Legend
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildLegendItem(Colors.green, 'Pointage'),
                _buildLegendItem(Colors.red, 'Dépointage'),
                _buildLegendItem(Colors.blue, 'Trajet'),
                _buildLegendItem(Colors.lightBlue, 'Points GPS'),
              ],
            ),
            const SizedBox(height: 12),
            // Stats row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatItem(
                  Icons.location_on,
                  '${widget.gpsPoints.length}',
                  'Points',
                ),
                if (widget.clockedInAt != null)
                  _buildStatItem(
                    Icons.login,
                    TimezoneFormatter.formatTimeWithTz(widget.clockedInAt!),
                    'Pointage',
                  ),
                if (widget.clockedOutAt != null)
                  _buildStatItem(
                    Icons.logout,
                    TimezoneFormatter.formatTimeWithTz(widget.clockedOutAt!),
                    'Dépointage',
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLegendItem(Color color, String label) {
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
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey[700],
          ),
        ),
      ],
    );
  }

  Widget _buildStatItem(IconData icon, String value, String label) {
    return Column(
      children: [
        Icon(icon, size: 20, color: Colors.grey[600]),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Colors.grey[600],
          ),
        ),
      ],
    );
  }

  Widget _buildSelectedPointCard() {
    final point = _selectedPoint!;
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.location_on, color: Colors.blue),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    TimezoneFormatter.formatTimeWithSecondsTz(point.capturedAt),
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    '${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[600],
                    ),
                  ),
                  if (point.accuracy != null)
                    Text(
                      'Précision : ±${point.accuracy!.toStringAsFixed(0)}m',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[500],
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => setState(() => _selectedPoint = null),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGestureHint() {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1.0, end: 0.0),
      duration: const Duration(seconds: 5),
      builder: (context, value, child) {
        if (value == 0) return const SizedBox.shrink();
        return Opacity(
          opacity: value,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.touch_app, color: Colors.white, size: 16),
                SizedBox(width: 8),
                Text(
                  'Glisser pour déplacer • Pincer pour zoomer',
                  style: TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
