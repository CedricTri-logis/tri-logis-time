import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Lazy reverse geocoding service using Nominatim (OpenStreetMap).
/// Rate-limited to 1 request per second per Nominatim usage policy.
class ReverseGeocodeService {
  static const String _baseUrl = 'https://nominatim.openstreetmap.org/reverse';
  static const Duration _rateLimitDelay = Duration(seconds: 1);
  DateTime _lastRequestTime = DateTime(2000);

  /// Reverse geocode a lat/lng to a human-readable address.
  /// Returns null if geocoding fails or is unavailable.
  Future<String?> reverseGeocode(double latitude, double longitude) async {
    // Rate limiting
    final now = DateTime.now();
    final elapsed = now.difference(_lastRequestTime);
    if (elapsed < _rateLimitDelay) {
      await Future.delayed(_rateLimitDelay - elapsed);
    }
    _lastRequestTime = DateTime.now();

    try {
      final uri = Uri.parse(
        '$_baseUrl?lat=$latitude&lon=$longitude&format=json&addressdetails=1&zoom=18',
      );

      final response = await http.get(
        uri,
        headers: {'User-Agent': 'TriLogisTime/1.0'},
      );

      if (response.statusCode != 200) return null;

      final data = json.decode(response.body) as Map<String, dynamic>;
      final address = data['address'] as Map<String, dynamic>?;
      if (address == null) return data['display_name'] as String?;

      // Build a concise address
      final parts = <String>[];
      final houseNumber = address['house_number'] as String?;
      final road = address['road'] as String?;
      final city = address['city'] ?? address['town'] ?? address['village'];

      if (houseNumber != null && road != null) {
        parts.add('$houseNumber $road');
      } else if (road != null) {
        parts.add(road);
      }
      if (city != null) parts.add(city as String);

      return parts.isNotEmpty ? parts.join(', ') : data['display_name'] as String?;
    } catch (e) {
      debugPrint('Reverse geocoding failed: $e');
      return null;
    }
  }
}
