import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/location_service.dart';

/// Provider for the LocationService.
final locationServiceProvider = Provider<LocationService>((ref) {
  return LocationService();
});
