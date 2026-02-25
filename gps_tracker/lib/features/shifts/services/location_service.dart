import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../models/geo_point.dart';

/// Service for GPS location capture with permission handling.
class LocationService {
  static const Duration _locationTimeout = Duration(seconds: 15);

  /// Check if location services are enabled.
  Future<bool> isLocationServiceEnabled() async {
    return await Geolocator.isLocationServiceEnabled();
  }

  /// Check current permission status.
  Future<LocationPermission> checkPermission() async {
    return await Geolocator.checkPermission();
  }

  /// Request location permission.
  Future<LocationPermission> requestPermission() async {
    return await Geolocator.requestPermission();
  }

  /// Ensure location permission is granted.
  /// Returns true if permission is granted (either 'whileInUse' or 'always').
  Future<bool> ensureLocationPermission() async {
    final serviceEnabled = await isLocationServiceEnabled();
    if (!serviceEnabled) {
      return false;
    }

    var permission = await checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await requestPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      return false;
    }

    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  /// Get the current location with high accuracy.
  /// Falls back to last known position on timeout.
  Future<Position?> getCurrentPosition() async {
    try {
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: _locationTimeout,
      );
    } on TimeoutException {
      // Fall back to last known position
      return await getLastKnownPosition();
    } catch (e) {
      // Try last known as fallback
      return await getLastKnownPosition();
    }
  }

  /// Get the last known position.
  Future<Position?> getLastKnownPosition() async {
    try {
      return await Geolocator.getLastKnownPosition();
    } catch (e) {
      return null;
    }
  }

  /// Capture location for clock-in/out event.
  /// Returns null if location cannot be obtained.
  Future<({GeoPoint? location, double? accuracy})> captureClockLocation() async {
    final hasPermission = await ensureLocationPermission();
    if (!hasPermission) {
      return (location: null, accuracy: null);
    }

    final position = await getCurrentPosition();
    if (position == null) {
      return (location: null, accuracy: null);
    }

    return (
      location: GeoPoint(
        latitude: position.latitude,
        longitude: position.longitude,
      ),
      accuracy: position.accuracy,
    );
  }

  /// Strict GPS health check for clock-in validation.
  /// Returns a fresh GPS fix or null if GPS is not working.
  /// Unlike [captureClockLocation], this does NOT fall back to last known position.
  Future<({GeoPoint? location, double? accuracy, String? failureReason})>
      verifyGpsForClockIn() async {
    final hasPermission = await ensureLocationPermission();
    if (!hasPermission) {
      return (
        location: null,
        accuracy: null,
        failureReason: 'permission_denied',
      );
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );

      // Reject positions with very poor accuracy (GPS not locked)
      if (position.accuracy > 100) {
        return (
          location: GeoPoint(
            latitude: position.latitude,
            longitude: position.longitude,
          ),
          accuracy: position.accuracy,
          failureReason: 'poor_accuracy',
        );
      }

      return (
        location: GeoPoint(
          latitude: position.latitude,
          longitude: position.longitude,
        ),
        accuracy: position.accuracy,
        failureReason: null,
      );
    } on TimeoutException {
      return (location: null, accuracy: null, failureReason: 'timeout');
    } catch (e) {
      return (location: null, accuracy: null, failureReason: 'error:$e');
    }
  }

  /// Open device location settings.
  Future<bool> openLocationSettings() async {
    return await Geolocator.openLocationSettings();
  }

  /// Open app settings (for permission denied forever).
  Future<bool> openAppSettings() async {
    return await Geolocator.openAppSettings();
  }

  /// Calculate distance between two points in meters.
  double distanceBetween(GeoPoint start, GeoPoint end) {
    return Geolocator.distanceBetween(
      start.latitude,
      start.longitude,
      end.latitude,
      end.longitude,
    );
  }
}
