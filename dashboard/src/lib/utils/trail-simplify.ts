/**
 * Douglas-Peucker trail simplification algorithm
 * Reduces the number of points in a polyline while preserving the overall shape
 */

/**
 * GPS point interface for simplification
 */
export interface SimplifiablePoint {
  latitude: number;
  longitude: number;
}

/**
 * Calculate perpendicular distance from a point to a line segment
 * Uses a simple Cartesian approximation suitable for small GPS areas
 */
function perpendicularDistance<T extends SimplifiablePoint>(
  point: T,
  lineStart: T,
  lineEnd: T
): number {
  const dx = lineEnd.longitude - lineStart.longitude;
  const dy = lineEnd.latitude - lineStart.latitude;

  // Line segment has zero length
  if (dx === 0 && dy === 0) {
    const pdx = point.longitude - lineStart.longitude;
    const pdy = point.latitude - lineStart.latitude;
    return Math.sqrt(pdx * pdx + pdy * pdy);
  }

  // Calculate perpendicular distance
  const mag = Math.sqrt(dx * dx + dy * dy);
  const u =
    ((point.longitude - lineStart.longitude) * dx +
      (point.latitude - lineStart.latitude) * dy) /
    (mag * mag);

  let closestLon: number;
  let closestLat: number;

  if (u < 0) {
    closestLon = lineStart.longitude;
    closestLat = lineStart.latitude;
  } else if (u > 1) {
    closestLon = lineEnd.longitude;
    closestLat = lineEnd.latitude;
  } else {
    closestLon = lineStart.longitude + u * dx;
    closestLat = lineStart.latitude + u * dy;
  }

  const distLon = point.longitude - closestLon;
  const distLat = point.latitude - closestLat;

  return Math.sqrt(distLon * distLon + distLat * distLat);
}

/**
 * Simplify a GPS trail using the Douglas-Peucker algorithm
 * @param points Array of GPS points to simplify
 * @param epsilon Tolerance value (in degrees, ~0.00001 = ~1 meter)
 * @returns Simplified array of points (subset of original)
 */
export function simplifyTrail<T extends SimplifiablePoint>(
  points: T[],
  epsilon: number
): T[] {
  if (points.length <= 2) {
    return points;
  }

  // Find the point with the maximum distance from the line
  let maxDistance = 0;
  let maxIndex = 0;

  const start = points[0];
  const end = points[points.length - 1];

  for (let i = 1; i < points.length - 1; i++) {
    const distance = perpendicularDistance(points[i], start, end);
    if (distance > maxDistance) {
      maxDistance = distance;
      maxIndex = i;
    }
  }

  // If max distance is greater than epsilon, recursively simplify
  if (maxDistance > epsilon) {
    // Recursive call for left and right segments
    const leftSimplified = simplifyTrail(points.slice(0, maxIndex + 1), epsilon);
    const rightSimplified = simplifyTrail(points.slice(maxIndex), epsilon);

    // Combine results (avoid duplicating the split point)
    return [...leftSimplified.slice(0, -1), ...rightSimplified];
  }

  // All points within epsilon, return just the endpoints
  return [start, end];
}

/**
 * Simplification thresholds based on point count
 */
export const SIMPLIFICATION_THRESHOLDS = {
  /** Below this count, no simplification needed */
  MIN_POINTS: 500,
  /** Epsilon for 501-2000 points */
  LOW_EPSILON: 0.00001, // ~1m
  /** Epsilon for 2001-5000 points */
  MEDIUM_EPSILON: 0.00005, // ~5m
  /** Epsilon for >5000 points */
  HIGH_EPSILON: 0.0001, // ~10m
} as const;

/**
 * Get the appropriate epsilon value based on point count
 */
export function getSimplificationEpsilon(pointCount: number): number | null {
  if (pointCount <= SIMPLIFICATION_THRESHOLDS.MIN_POINTS) {
    return null; // No simplification needed
  }
  if (pointCount <= 2000) {
    return SIMPLIFICATION_THRESHOLDS.LOW_EPSILON;
  }
  if (pointCount <= 5000) {
    return SIMPLIFICATION_THRESHOLDS.MEDIUM_EPSILON;
  }
  return SIMPLIFICATION_THRESHOLDS.HIGH_EPSILON;
}

/**
 * Auto-simplify a trail based on point count thresholds
 * @param points Array of GPS points
 * @returns Simplified array (or original if below threshold)
 */
export function autoSimplifyTrail<T extends SimplifiablePoint>(points: T[]): T[] {
  const epsilon = getSimplificationEpsilon(points.length);

  if (epsilon === null) {
    return points;
  }

  return simplifyTrail(points, epsilon);
}
