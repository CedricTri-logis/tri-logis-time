import type { TripGpsPoint } from '@/types/mileage';

export interface TripStop {
  latitude: number;
  longitude: number;
  startTime: string;
  endTime: string;
  durationSeconds: number;
  pointCount: number;
  category: 'moderate' | 'extended';
}

// Thresholds aligned with detect_trips server-side
const SENSOR_STOP_SPEED = 0.28; // m/s (< 1 km/h)
const NOISE_SPEED_LIMIT = 3.0; // m/s — GPS noise ceiling within radius
const SPATIAL_RADIUS_M = 50; // meters
const MIN_STOP_DURATION = 60; // seconds (1 minute)

function haversineM(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const R = 6371000;
  const dLat = ((lat2 - lat1) * Math.PI) / 180;
  const dLng = ((lng2 - lng1) * Math.PI) / 180;
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos((lat1 * Math.PI) / 180) *
      Math.cos((lat2 * Math.PI) / 180) *
      Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function categorize(durationSeconds: number): TripStop['category'] {
  if (durationSeconds <= 180) return 'moderate';
  return 'extended';
}

export function detectTripStops(points: TripGpsPoint[]): TripStop[] {
  if (points.length < 2) return [];

  const sorted = [...points].sort(
    (a, b) => new Date(a.captured_at).getTime() - new Date(b.captured_at).getTime(),
  );

  const stops: TripStop[] = [];
  let cluster: TripGpsPoint[] = [];
  let centerLat = 0;
  let centerLng = 0;

  function flushCluster() {
    if (cluster.length < 2) {
      cluster = [];
      return;
    }

    const first = cluster[0];
    const last = cluster[cluster.length - 1];
    const duration =
      (new Date(last.captured_at).getTime() - new Date(first.captured_at).getTime()) / 1000;

    if (duration < MIN_STOP_DURATION) {
      cluster = [];
      return;
    }

    const latSum = cluster.reduce((s, p) => s + p.latitude, 0);
    const lngSum = cluster.reduce((s, p) => s + p.longitude, 0);

    stops.push({
      latitude: latSum / cluster.length,
      longitude: lngSum / cluster.length,
      startTime: first.captured_at,
      endTime: last.captured_at,
      durationSeconds: duration,
      pointCount: cluster.length,
      category: categorize(duration),
    });

    cluster = [];
  }

  for (const pt of sorted) {
    const sensorStopped = pt.speed === null || pt.speed < SENSOR_STOP_SPEED;
    const withinRadius =
      cluster.length > 0 &&
      haversineM(centerLat, centerLng, pt.latitude, pt.longitude) < SPATIAL_RADIUS_M;
    const noiseSuppressed =
      withinRadius && pt.speed !== null && pt.speed < NOISE_SPEED_LIMIT;

    if (sensorStopped || noiseSuppressed) {
      if (cluster.length === 0) {
        centerLat = pt.latitude;
        centerLng = pt.longitude;
      }
      cluster.push(pt);
    } else {
      flushCluster();
    }
  }

  flushCluster();
  return stops;
}
