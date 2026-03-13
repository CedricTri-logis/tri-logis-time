import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../mileage/models/trip.dart';

/// Decode polyline6 to latlong2 LatLng.
List<LatLng> _decodePolyline6(String encoded) {
  final List<LatLng> points = [];
  int index = 0;
  int lat = 0;
  int lng = 0;
  while (index < encoded.length) {
    int shift = 0;
    int result = 0;
    int byte;
    do {
      byte = encoded.codeUnitAt(index++) - 63;
      result |= (byte & 0x1F) << shift;
      shift += 5;
    } while (byte >= 0x20);
    lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
    shift = 0;
    result = 0;
    do {
      byte = encoded.codeUnitAt(index++) - 63;
      result |= (byte & 0x1F) << shift;
      shift += 5;
    } while (byte >= 0x20);
    lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
    points.add(LatLng(lat / 1e6, lng / 1e6));
  }
  return points;
}

const _tripColors = [
  Color(0xFF8b5cf6),
  Color(0xFF22c55e),
  Color(0xFFf97316),
  Color(0xFFec4899),
  Color(0xFF14b8a6),
  Color(0xFFeab308),
];

/// Interactive map showing OSRM-matched trip routes with tap-to-popup.
class TripRoutesMap extends StatefulWidget {
  final List<Trip> trips;
  const TripRoutesMap({super.key, required this.trips});

  @override
  State<TripRoutesMap> createState() => _TripRoutesMapState();
}

class _TripRoutesMapState extends State<TripRoutesMap> {
  late final MapController _mapController;
  Trip? _selectedTrip;

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

  LatLngBounds? get _bounds {
    final allPoints = <LatLng>[];
    for (final trip in widget.trips) {
      allPoints.add(LatLng(trip.startLatitude, trip.startLongitude));
      allPoints.add(LatLng(trip.endLatitude, trip.endLongitude));
      if (trip.isRouteMatched && trip.routeGeometry != null) {
        allPoints.addAll(_decodePolyline6(trip.routeGeometry!));
      }
    }
    if (allPoints.isEmpty) return null;
    double minLat = allPoints.first.latitude,
        maxLat = allPoints.first.latitude;
    double minLng = allPoints.first.longitude,
        maxLng = allPoints.first.longitude;
    for (final pt in allPoints) {
      if (pt.latitude < minLat) minLat = pt.latitude;
      if (pt.latitude > maxLat) maxLat = pt.latitude;
      if (pt.longitude < minLng) minLng = pt.longitude;
      if (pt.longitude > maxLng) maxLng = pt.longitude;
    }
    const pad = 0.002;
    return LatLngBounds(
        LatLng(minLat - pad, minLng - pad), LatLng(maxLat + pad, maxLng + pad));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.trips.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Trajets',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 250,
                child: Stack(
                  children: [
                    FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter: const LatLng(45.5, -73.6),
                        initialZoom: 12,
                        initialCameraFit: _bounds != null
                            ? CameraFit.bounds(
                                bounds: _bounds!,
                                padding: const EdgeInsets.all(40))
                            : null,
                        onTap: (_, __) =>
                            setState(() => _selectedTrip = null),
                      ),
                      children: [
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.gps_tracker.app',
                        ),
                        PolylineLayer(polylines: _buildPolylines()),
                        MarkerLayer(markers: _buildMarkers()),
                      ],
                    ),
                    // Popup for selected trip
                    if (_selectedTrip != null)
                      Positioned(
                        bottom: 8,
                        left: 8,
                        right: 8,
                        child: _TripPopup(
                          trip: _selectedTrip!,
                          color: _tripColors[widget.trips
                                  .indexOf(_selectedTrip!) %
                              _tripColors.length],
                          onClose: () =>
                              setState(() => _selectedTrip = null),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Polyline> _buildPolylines() {
    return widget.trips.asMap().entries.map((entry) {
      final trip = entry.value;
      final color = _tripColors[entry.key % _tripColors.length];
      final isMatched = trip.isRouteMatched && trip.routeGeometry != null;
      final points = isMatched
          ? _decodePolyline6(trip.routeGeometry!)
          : [
              LatLng(trip.startLatitude, trip.startLongitude),
              LatLng(trip.endLatitude, trip.endLongitude)
            ];
      return Polyline(
        points: points,
        color: color,
        strokeWidth: _selectedTrip == trip ? 6 : 4,
        isDotted: !isMatched,
      );
    }).toList();
  }

  List<Marker> _buildMarkers() {
    final markers = <Marker>[];
    for (int i = 0; i < widget.trips.length; i++) {
      final trip = widget.trips[i];
      final color = _tripColors[i % _tripColors.length];
      // Start marker
      markers.add(Marker(
        point: LatLng(trip.startLatitude, trip.startLongitude),
        width: 20,
        height: 20,
        child: GestureDetector(
          onTap: () => setState(() => _selectedTrip = trip),
          child: Container(
            decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2)),
          ),
        ),
      ));
      // End marker
      markers.add(Marker(
        point: LatLng(trip.endLatitude, trip.endLongitude),
        width: 20,
        height: 20,
        child: GestureDetector(
          onTap: () => setState(() => _selectedTrip = trip),
          child: Container(
            decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2)),
            child: const Icon(Icons.flag, size: 12, color: Colors.white),
          ),
        ),
      ));
    }
    return markers;
  }
}

class _TripPopup extends StatelessWidget {
  final Trip trip;
  final Color color;
  final VoidCallback onClose;
  const _TripPopup(
      {required this.trip, required this.color, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dist = trip.effectiveDistanceKm.toStringAsFixed(1);
    final dur = trip.durationMinutes;
    final h = dur ~/ 60;
    final m = dur % 60;
    final durStr =
        h == 0 ? '$m min' : '${h}h${m.toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
      ),
      child: Row(
        children: [
          Container(
              width: 4,
              height: 40,
              decoration: BoxDecoration(
                  color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${trip.startDisplayName} \u2192 ${trip.endDisplayName}',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  '$dist km \u00b7 $durStr${trip.isRouteMatched ? '' : ' (estim\u00e9)'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: onClose,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints()),
        ],
      ),
    );
  }
}
