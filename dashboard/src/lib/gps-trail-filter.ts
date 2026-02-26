import type { GpsTrailPoint } from '@/types/monitoring';

// ── Configuration ──────────────────────────────────────────────────────────
/** Distance (meters) below which consecutive points are considered stationary */
const STATIONARY_RADIUS_M = 30;
/** Minimum consecutive stationary points to form a zone (avoids false positives) */
const MIN_STATIONARY_POINTS = 3;

// ── Types ──────────────────────────────────────────────────────────────────
export interface StationaryZone {
  center: { latitude: number; longitude: number };
  firstPoint: GpsTrailPoint;
  lastPoint: GpsTrailPoint;
  /** Duration in milliseconds */
  duration: number;
  /** Number of original GPS points collapsed into this zone */
  pointCount: number;
}

export interface FilteredTrail {
  /** Points to render: all movement points + first/last of each stationary zone */
  points: GpsTrailPoint[];
  /** Detected stationary zones */
  stationaryZones: StationaryZone[];
}

// ── Haversine distance ─────────────────────────────────────────────────────
function toRad(deg: number): number {
  return (deg * Math.PI) / 180;
}

/** Returns distance in meters between two lat/lng points */
function haversineM(
  lat1: number,
  lon1: number,
  lat2: number,
  lon2: number,
): number {
  const R = 6_371_000; // Earth radius in meters
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// ── Core filter ────────────────────────────────────────────────────────────
/**
 * Determines if a point should be considered stationary relative to an anchor.
 * Takes accuracy into account: a point 200m away with 250m accuracy is still
 * stationary because its error circle includes the anchor position.
 *
 * Logic: the point is stationary if the distance minus the point's accuracy
 * is within the stationary radius. In other words, if the closest possible
 * true position (distance - accuracy) is within the threshold, the point
 * could still be at the anchor.
 */
function isStationary(
  anchorLat: number,
  anchorLon: number,
  point: GpsTrailPoint,
): boolean {
  const dist = haversineM(anchorLat, anchorLon, point.latitude, point.longitude);
  // Effective distance: subtract accuracy (the true position could be closer)
  const effectiveDist = Math.max(0, dist - point.accuracy);
  return effectiveDist <= STATIONARY_RADIUS_M;
}

/**
 * Filters a GPS trail to reduce visual clutter from stationary periods:
 * - Stationary zones: only the first and last point are kept
 * - Movement periods: 100 % of points are kept
 * - Clock-in (first) and clock-out/current (last) are always included
 * - Accuracy-aware: a far-away point with poor accuracy is still considered
 *   stationary if its error circle overlaps the anchor position
 */
export function filterTrailPoints(trail: GpsTrailPoint[]): FilteredTrail {
  if (trail.length <= 2) {
    return { points: [...trail], stationaryZones: [] };
  }

  // Step 1: label every point as stationary or moving relative to a cluster anchor
  const labels: ('stationary' | 'moving')[] = new Array(trail.length);
  labels[0] = 'moving'; // first point is always kept as-is

  let anchorIdx = 0;
  for (let i = 1; i < trail.length; i++) {
    if (isStationary(trail[anchorIdx].latitude, trail[anchorIdx].longitude, trail[i])) {
      labels[i] = 'stationary';
    } else {
      labels[i] = 'moving';
      anchorIdx = i;
    }
  }

  // Step 2: group consecutive stationary labels into runs
  interface Run {
    type: 'stationary' | 'moving';
    startIdx: number;
    endIdx: number; // inclusive
  }

  const runs: Run[] = [];
  let currentRun: Run = { type: labels[0], startIdx: 0, endIdx: 0 };

  for (let i = 1; i < labels.length; i++) {
    if (labels[i] === currentRun.type) {
      currentRun.endIdx = i;
    } else {
      runs.push(currentRun);
      currentRun = { type: labels[i], startIdx: i, endIdx: i };
    }
  }
  runs.push(currentRun);

  // Step 3: build filtered points + stationary zones
  const filtered: GpsTrailPoint[] = [];
  const zones: StationaryZone[] = [];
  const addedIndices = new Set<number>();

  const addPoint = (idx: number) => {
    if (!addedIndices.has(idx)) {
      addedIndices.add(idx);
      filtered.push(trail[idx]);
    }
  };

  for (const run of runs) {
    const runLength = run.endIdx - run.startIdx + 1;

    if (run.type === 'stationary' && runLength >= MIN_STATIONARY_POINTS) {
      // Stationary zone: keep only first and last
      addPoint(run.startIdx);
      addPoint(run.endIdx);

      // Compute zone center (average of all points in the zone)
      let sumLat = 0;
      let sumLng = 0;
      for (let i = run.startIdx; i <= run.endIdx; i++) {
        sumLat += trail[i].latitude;
        sumLng += trail[i].longitude;
      }
      zones.push({
        center: {
          latitude: sumLat / runLength,
          longitude: sumLng / runLength,
        },
        firstPoint: trail[run.startIdx],
        lastPoint: trail[run.endIdx],
        duration:
          trail[run.endIdx].capturedAt.getTime() -
          trail[run.startIdx].capturedAt.getTime(),
        pointCount: runLength,
      });
    } else {
      // Movement or short stationary run: keep all points
      for (let i = run.startIdx; i <= run.endIdx; i++) {
        addPoint(i);
      }
    }
  }

  // Ensure first and last points of the original trail are always included
  addPoint(0);
  addPoint(trail.length - 1);

  // Sort by original chronological order (addPoint may have inserted out of order for first/last)
  filtered.sort((a, b) => a.capturedAt.getTime() - b.capturedAt.getTime());

  return { points: filtered, stationaryZones: zones };
}

// ── Formatting helper ──────────────────────────────────────────────────────
/** Formats a duration in ms to a human-readable string (e.g. "1h 23min", "45min", "30s") */
export function formatDuration(ms: number): string {
  const totalSeconds = Math.round(ms / 1000);
  if (totalSeconds < 60) return `${totalSeconds}s`;
  const minutes = Math.floor(totalSeconds / 60);
  const hours = Math.floor(minutes / 60);
  const remainingMinutes = minutes % 60;
  if (hours === 0) return `${minutes}min`;
  if (remainingMinutes === 0) return `${hours}h`;
  return `${hours}h ${remainingMinutes}min`;
}
