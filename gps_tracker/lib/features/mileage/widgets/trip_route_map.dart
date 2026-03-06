import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../../shared/utils/polyline_decoder.dart';
import '../models/trip.dart';

class TripRouteMap extends StatelessWidget {
  final Trip trip;
  final List<LatLng>? routePoints;
  final double height;

  const TripRouteMap({
    super.key,
    required this.trip,
    this.routePoints,
    this.height = 200,
  });

  @override
  Widget build(BuildContext context) {
    final startLatLng = LatLng(trip.startLatitude, trip.startLongitude);
    final endLatLng = LatLng(trip.endLatitude, trip.endLongitude);

    // Build polylines
    final polylines = <Polyline>[];
    bool isDotted = false;
    List<LatLng> polylinePoints;

    if (trip.isRouteMatched && trip.routeGeometry != null) {
      final matchedPoints = decodePolyline6(trip.routeGeometry!);
      if (matchedPoints.isNotEmpty) {
        polylinePoints = matchedPoints;
      } else {
        polylinePoints = [startLatLng, endLatLng];
        isDotted = true;
      }
    } else if (routePoints != null && routePoints!.isNotEmpty) {
      polylinePoints = routePoints!;
    } else {
      polylinePoints = [startLatLng, endLatLng];
      isDotted = true;
    }

    polylines.add(Polyline(
      points: polylinePoints,
      color: Theme.of(context).colorScheme.primary,
      strokeWidth: isDotted ? 3 : 4,
      isDotted: isDotted,
    ));

    // Calculate bounds including all polyline points and endpoints
    double minLat = startLatLng.latitude;
    double maxLat = startLatLng.latitude;
    double minLng = startLatLng.longitude;
    double maxLng = startLatLng.longitude;

    for (final polyline in polylines) {
      for (final point in polyline.points) {
        if (point.latitude < minLat) minLat = point.latitude;
        if (point.latitude > maxLat) maxLat = point.latitude;
        if (point.longitude < minLng) minLng = point.longitude;
        if (point.longitude > maxLng) maxLng = point.longitude;
      }
    }

    if (endLatLng.latitude < minLat) minLat = endLatLng.latitude;
    if (endLatLng.latitude > maxLat) maxLat = endLatLng.latitude;
    if (endLatLng.longitude < minLng) minLng = endLatLng.longitude;
    if (endLatLng.longitude > maxLng) maxLng = endLatLng.longitude;

    final bounds = LatLngBounds(
      LatLng(minLat, minLng),
      LatLng(maxLat, maxLng),
    );

    // Build markers
    final markers = <Marker>[
      Marker(
        point: startLatLng,
        width: 32,
        height: 32,
        child: const Icon(Icons.location_on, color: Colors.green, size: 32),
      ),
      Marker(
        point: endLatLng,
        width: 32,
        height: 32,
        child: const Icon(Icons.location_on, color: Colors.red, size: 32),
      ),
    ];

    return SizedBox(
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: FlutterMap(
          options: MapOptions(
            initialCenter: LatLng(
              (minLat + maxLat) / 2,
              (minLng + maxLng) / 2,
            ),
            initialZoom: 12,
            initialCameraFit: CameraFit.bounds(
              bounds: bounds,
              padding: const EdgeInsets.all(50),
            ),
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.none,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'ca.trilogis.gpstracker',
            ),
            PolylineLayer(polylines: polylines),
            MarkerLayer(markers: markers),
          ],
        ),
      ),
    );
  }
}
