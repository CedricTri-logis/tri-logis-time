import type { TripGpsPoint } from '@/types/mileage';

export interface TripStop {
  latitude: number;
  longitude: number;
  startTime: string;
  endTime: string;
  durationSeconds: number;
  pointCount: number;
  category: 'brief' | 'moderate' | 'extended';
}

const STOP_SPEED_THRESHOLD = 0.83; // m/s (~3 km/h)
const MIN_STOP_DURATION = 15; // seconds

function categorize(durationSeconds: number): TripStop['category'] {
  if (durationSeconds <= 60) return 'brief';
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
    const isStopped = pt.speed === null || pt.speed < STOP_SPEED_THRESHOLD;

    if (isStopped) {
      cluster.push(pt);
    } else {
      flushCluster();
    }
  }

  // Flush any trailing cluster
  flushCluster();

  return stops;
}
