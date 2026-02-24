import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
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
    if (routePoints != null && routePoints!.isNotEmpty) {
      polylines.add(Polyline(
        polylineId: const PolylineId('route'),
        points: routePoints!,
        color: Theme.of(context).colorScheme.primary,
        width: 4,
      ));
    } else {
      // Straight line between start and end if no route points
      polylines.add(Polyline(
        polylineId: const PolylineId('route'),
        points: [startLatLng, endLatLng],
        color: Theme.of(context).colorScheme.primary,
        width: 3,
        patterns: [PatternItem.dash(10), PatternItem.gap(5)],
      ));
    }

    // Calculate bounds
    final bounds = LatLngBounds(
      southwest: LatLng(
        startLatLng.latitude < endLatLng.latitude ? startLatLng.latitude : endLatLng.latitude,
        startLatLng.longitude < endLatLng.longitude ? startLatLng.longitude : endLatLng.longitude,
      ),
      northeast: LatLng(
        startLatLng.latitude > endLatLng.latitude ? startLatLng.latitude : endLatLng.latitude,
        startLatLng.longitude > endLatLng.longitude ? startLatLng.longitude : endLatLng.longitude,
      ),
    );

    return SizedBox(
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: GoogleMap(
          initialCameraPosition: CameraPosition(
            target: LatLng(
              (startLatLng.latitude + endLatLng.latitude) / 2,
              (startLatLng.longitude + endLatLng.longitude) / 2,
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
