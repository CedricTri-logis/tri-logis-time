import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Decodes a Google encoded polyline string with precision 6 (polyline6).
/// Returns a list of LatLng points representing the decoded route.
List<LatLng> decodePolyline6(String encoded) {
  final List<LatLng> points = [];
  int index = 0;
  int lat = 0;
  int lng = 0;

  while (index < encoded.length) {
    // Decode latitude
    int shift = 0;
    int result = 0;
    int byte;
    do {
      byte = encoded.codeUnitAt(index++) - 63;
      result |= (byte & 0x1F) << shift;
      shift += 5;
    } while (byte >= 0x20);
    lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

    // Decode longitude
    shift = 0;
    result = 0;
    do {
      byte = encoded.codeUnitAt(index++) - 63;
      result |= (byte & 0x1F) << shift;
      shift += 5;
    } while (byte >= 0x20);
    lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

    // Precision 6: divide by 1e6
    points.add(LatLng(lat / 1e6, lng / 1e6));
  }

  return points;
}

/// Decodes and combines multiple encoded polyline6 strings into a single
/// list of LatLng points. Used when OSRM gaps=split produces multiple matchings.
List<LatLng> combinePolylines(List<String> encodedList) {
  final List<LatLng> combined = [];
  for (final encoded in encodedList) {
    combined.addAll(decodePolyline6(encoded));
  }
  return combined;
}
