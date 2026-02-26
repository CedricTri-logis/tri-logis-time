import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
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

    final markers = <Marker>{
      Marker(
        markerId: const MarkerId('start'),
        position: startLatLng,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        infoWindow: InfoWindow(title: 'Start', snippet: trip.startDisplayName),
      ),
      Marker(
        markerId: const MarkerId('end'),
        position: endLatLng,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        infoWindow: InfoWindow(title: 'End', snippet: trip.endDisplayName),
      ),
    };

    final polylines = <Polyline>{};

    // Use matched route geometry if available
    if (trip.isRouteMatched && trip.routeGeometry != null) {
      final matchedPoints = decodePolyline6(trip.routeGeometry!);
      if (matchedPoints.isNotEmpty) {
        polylines.add(Polyline(
          polylineId: const PolylineId('route'),
          points: matchedPoints,
          color: Theme.of(context).colorScheme.primary,
          width: 4,
        ));
      }
    } else if (routePoints != null && routePoints!.isNotEmpty) {
      // Use provided route points (GPS points as straight lines)
      polylines.add(Polyline(
        polylineId: const PolylineId('route'),
        points: routePoints!,
        color: Theme.of(context).colorScheme.primary,
        width: 4,
      ));
    } else {
      // Dashed line between start and end if no route points
      polylines.add(Polyline(
        polylineId: const PolylineId('route'),
        points: [startLatLng, endLatLng],
        color: Theme.of(context).colorScheme.primary,
        width: 3,
        patterns: [PatternItem.dash(10), PatternItem.gap(5)],
      ));
    }

    // Calculate bounds including all polyline points
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

    // Include end point in bounds
    if (endLatLng.latitude < minLat) minLat = endLatLng.latitude;
    if (endLatLng.latitude > maxLat) maxLat = endLatLng.latitude;
    if (endLatLng.longitude < minLng) minLng = endLatLng.longitude;
    if (endLatLng.longitude > maxLng) maxLng = endLatLng.longitude;

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );

    return SizedBox(
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: GoogleMap(
          initialCameraPosition: CameraPosition(
            target: LatLng(
              (minLat + maxLat) / 2,
              (minLng + maxLng) / 2,
            ),
            zoom: 12,
          ),
          markers: markers,
          polylines: polylines,
          myLocationEnabled: false,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          mapToolbarEnabled: false,
          liteModeEnabled: true,
          onMapCreated: (controller) {
            Future.delayed(const Duration(milliseconds: 200), () {
              controller.animateCamera(
                CameraUpdate.newLatLngBounds(bounds, 50),
              );
            });
          },
        ),
      ),
    );
  }
}
