/**
 * Haversine distance calculation utilities for GPS coordinates
 * Uses the Haversine formula to calculate great-circle distance between two points
 */

const EARTH_RADIUS_KM = 6371;

/**
 * Convert degrees to radians
 */
function toRadians(degrees: number): number {
  return degrees * (Math.PI / 180);
}

/**
 * Calculate the Haversine distance between two GPS coordinates
 * @param lat1 Latitude of first point in degrees
 * @param lon1 Longitude of first point in degrees
 * @param lat2 Latitude of second point in degrees
 * @param lon2 Longitude of second point in degrees
 * @returns Distance in kilometers
 */
export function haversineDistance(
  lat1: number,
  lon1: number,
  lat2: number,
  lon2: number
): number {
  const dLat = toRadians(lat2 - lat1);
  const dLon = toRadians(lon2 - lon1);

  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(toRadians(lat1)) *
      Math.cos(toRadians(lat2)) *
      Math.sin(dLon / 2) *
      Math.sin(dLon / 2);

  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));

  return EARTH_RADIUS_KM * c;
}

/**
 * GPS point interface for distance calculations
 */
export interface GpsCoordinate {
  latitude: number;
  longitude: number;
}

/**
 * Calculate the total distance traveled along a path of GPS points
 * @param points Array of GPS coordinates in order
 * @returns Total distance in kilometers
 */
export function calculateTotalDistance(points: GpsCoordinate[]): number {
  if (points.length < 2) {
    return 0;
  }

  let totalDistance = 0;

  for (let i = 1; i < points.length; i++) {
    const prev = points[i - 1];
    const curr = points[i];
    totalDistance += haversineDistance(
      prev.latitude,
      prev.longitude,
      curr.latitude,
      curr.longitude
    );
  }

  return totalDistance;
}

/**
 * Calculate distance between two GPS points
 * @param point1 First GPS coordinate
 * @param point2 Second GPS coordinate
 * @returns Distance in kilometers
 */
export function distanceBetweenPoints(
  point1: GpsCoordinate,
  point2: GpsCoordinate
): number {
  return haversineDistance(
    point1.latitude,
    point1.longitude,
    point2.latitude,
    point2.longitude
  );
}

/**
 * Format a distance value for display
 * @param distanceKm Distance in kilometers
 * @returns Formatted string (e.g., "1.5 km" or "500 m")
 */
export function formatDistance(distanceKm: number): string {
  if (distanceKm < 1) {
    const meters = Math.round(distanceKm * 1000);
    return `${meters} m`;
  }
  return `${distanceKm.toFixed(2)} km`;
}
