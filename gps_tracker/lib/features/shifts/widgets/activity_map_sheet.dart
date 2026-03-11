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

/// Bottom sheet showing a map for a stop location or a trip route.
class ActivityMapSheet extends StatelessWidget {
  final String title;
  final String? subtitle;
  final LatLng? stopLocation;
  final Trip? trip;

  const ActivityMapSheet._({
    required this.title,
    this.subtitle,
    this.stopLocation,
    this.trip,
  });

  /// Show a stop location on the map.
  static void showStop(
    BuildContext context, {
    required String locationName,
    required double latitude,
    required double longitude,
    String? locationType,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => ActivityMapSheet._(
        title: locationName,
        subtitle: locationType,
        stopLocation: LatLng(latitude, longitude),
      ),
    );
  }

  /// Show a trip route on the map.
  static void showTrip(
    BuildContext context, {
    required Trip trip,
    String? startName,
    String? endName,
  }) {
    final from = startName ?? trip.startDisplayName;
    final to = endName ?? trip.endDisplayName;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => ActivityMapSheet._(
        title: '$from \u2192 $to',
        subtitle:
            '${trip.effectiveDistanceKm.toStringAsFixed(1)} km \u00b7 ${trip.durationMinutes} min',
        trip: trip,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.55,
      child: Column(
        children: [
          // Handle
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Map
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _buildMap(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMap() {
    if (stopLocation != null) {
      return _StopMap(location: stopLocation!);
    }
    if (trip != null) {
      return _TripMap(trip: trip!);
    }
    return const SizedBox.shrink();
  }
}

class _StopMap extends StatelessWidget {
  final LatLng location;
  const _StopMap({required this.location});

  @override
  Widget build(BuildContext context) {
    return FlutterMap(
      options: MapOptions(
        initialCenter: location,
        initialZoom: 16,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.gps_tracker.app',
        ),
        MarkerLayer(
          markers: [
            Marker(
              point: location,
              width: 40,
              height: 40,
              child: const Icon(
                Icons.location_on,
                color: Colors.red,
                size: 40,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _TripMap extends StatelessWidget {
  final Trip trip;
  const _TripMap({required this.trip});

  @override
  Widget build(BuildContext context) {
    final start = LatLng(trip.startLatitude, trip.startLongitude);
    final end = LatLng(trip.endLatitude, trip.endLongitude);
    final hasRoute = trip.isRouteMatched && trip.routeGeometry != null;
    final decodedPoints =
        hasRoute ? _decodePolyline6(trip.routeGeometry!) : <LatLng>[];

    // Connect GPS start/end to OSRM route (which snaps to roads)
    final routePoints = <LatLng>[
      start,
      ...decodedPoints,
      end,
    ];

    // Calculate bounds
    double minLat = start.latitude, maxLat = start.latitude;
    double minLng = start.longitude, maxLng = start.longitude;
    for (final pt in [...routePoints, end]) {
      if (pt.latitude < minLat) minLat = pt.latitude;
      if (pt.latitude > maxLat) maxLat = pt.latitude;
      if (pt.longitude < minLng) minLng = pt.longitude;
      if (pt.longitude > maxLng) maxLng = pt.longitude;
    }
    const pad = 0.003;
    final bounds = LatLngBounds(
      LatLng(minLat - pad, minLng - pad),
      LatLng(maxLat + pad, maxLng + pad),
    );

    return FlutterMap(
      options: MapOptions(
        initialCenter: LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2),
        initialZoom: 14,
        initialCameraFit:
            CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(40)),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.gps_tracker.app',
        ),
        PolylineLayer(
          polylines: [
            Polyline(
              points: routePoints,
              color: const Color(0xFF8b5cf6),
              strokeWidth: 5,
              isDotted: !hasRoute && decodedPoints.isEmpty,
            ),
          ],
        ),
        MarkerLayer(
          markers: [
            Marker(
              point: start,
              width: 24,
              height: 24,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
            Marker(
              point: end,
              width: 24,
              height: 24,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: const Icon(Icons.flag, size: 14, color: Colors.white),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
