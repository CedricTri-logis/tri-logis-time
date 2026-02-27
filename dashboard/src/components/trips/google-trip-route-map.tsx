'use client';

import { useMemo, useEffect, useState, useCallback } from 'react';
import {
  APIProvider,
  Map,
  useMap,
  AdvancedMarker,
  InfoWindow,
} from '@vis.gl/react-google-maps';
import { decodePolyline6 } from '@/lib/polyline';
import type { Trip, TripGpsPoint } from '@/types/mileage';
import type { TripStop, GpsCluster } from '@/lib/utils/detect-trip-stops';
import { Card } from '@/components/ui/card';

interface TripRouteMapProps {
  trips: Trip[];
  gpsPoints?: TripGpsPoint[];
  stops?: TripStop[];
  clusters?: GpsCluster[];
  height?: number;
  showGpsPoints?: boolean;
  apiKey?: string;
}

const TRIP_COLORS = [
  '#3b82f6', '#22c55e', '#8b5cf6', '#f97316',
  '#ec4899', '#14b8a6', '#eab308', '#ef4444',
];

function getSpeedColor(speed: number | null): string {
  if (speed == null || speed < 0.5) return '#eab308';   // stationary — yellow
  if (speed < 2) return '#f97316';                       // walking — orange
  if (speed < 8) return '#3b82f6';                       // city — blue
  return '#6366f1';                                      // highway — indigo
}

function formatTime(dateStr: string): string {
  return new Date(dateStr).toLocaleTimeString('fr-CA', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

const STOP_COLORS: Record<TripStop['category'], string> = {
  moderate: '#f97316',
  extended: '#ef4444',
};

function formatDuration(seconds: number): string {
  if (seconds < 60) return `${Math.round(seconds)}s`;
  const min = Math.floor(seconds / 60);
  const sec = Math.round(seconds % 60);
  return sec > 0 ? `${min}min ${sec}s` : `${min}min`;
}

function getClusterColor(durationSeconds: number): string {
  if (durationSeconds < 30) return '#eab308';   // yellow — brief
  if (durationSeconds < 180) return '#f97316';   // orange — moderate
  return '#ef4444';                               // red — extended
}

export function GoogleTripRouteMap({
  trips,
  gpsPoints = [],
  stops = [],
  clusters = [],
  height = 400,
  showGpsPoints = true,
  apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY || '',
}: TripRouteMapProps) {
  const [selectedPoint, setSelectedPoint] = useState<TripGpsPoint | null>(null);
  const [selectedStop, setSelectedStop] = useState<TripStop | null>(null);
  const [selectedCluster, setSelectedCluster] = useState<GpsCluster | null>(null);

  const routes = useMemo(() => {
    return trips.map((trip, index) => {
      const isMatched = trip.match_status === 'matched' && !!trip.route_geometry;
      const hasGpsTrail = gpsPoints.length >= 2;

      // OSRM road route (may be partial for low-confidence matches)
      const osrmPoints =
        isMatched && trip.route_geometry
          ? decodePolyline6(trip.route_geometry).map(([lat, lng]) => ({ lat, lng }))
          : null;

      // GPS trail as base layer (always available if we have points)
      const gpsTrailPoints = hasGpsTrail
        ? gpsPoints.map((pt) => ({ lat: pt.latitude, lng: pt.longitude }))
        : null;

      // Primary display: OSRM route > GPS trail > straight line fallback
      const points = osrmPoints ?? gpsTrailPoints ?? [
        { lat: trip.start_latitude, lng: trip.start_longitude },
        { lat: trip.end_latitude, lng: trip.end_longitude },
      ];

      return {
        id: trip.id,
        points,
        color: TRIP_COLORS[index % TRIP_COLORS.length],
        isMatched,
        hasGpsTrail,
        // For matched trips with GPS points: also draw GPS trail underneath
        gpsTrailPoints: isMatched && gpsTrailPoints ? gpsTrailPoints : null,
        start: { lat: trip.start_latitude, lng: trip.start_longitude },
        end: { lat: trip.end_latitude, lng: trip.end_longitude },
      };
    });
  }, [trips, gpsPoints]);

  if (trips.length === 0) {
    return (
      <Card
        className="flex items-center justify-center bg-slate-50 border-dashed border-2"
        style={{ height }}
      >
        <p className="text-slate-400 text-sm">Aucun trajet à afficher</p>
      </Card>
    );
  }

  return (
    <div className="overflow-hidden rounded-lg" style={{ height }}>
      <APIProvider apiKey={apiKey}>
        <Map
          defaultCenter={routes[0]?.start}
          defaultZoom={12}
          mapId="trip_route_map"
          disableDefaultUI={true}
          zoomControl={true}
          style={{ height: '100%', width: '100%' }}
        >
          {/* Route polylines */}
          {routes.map((route) => (
            <div key={route.id}>
              {/* GPS trail underneath (thin orange line showing full path) */}
              {route.gpsTrailPoints && (
                <GpsTrailPolyline points={route.gpsTrailPoints} />
              )}
              {/* Primary route: OSRM road match or GPS trail or straight line */}
              <TripPolyline route={route} />

              <AdvancedMarker position={route.start}>
                <div className="bg-green-600 w-4 h-4 rounded-full border-2 border-white shadow-lg" />
              </AdvancedMarker>

              <AdvancedMarker position={route.end}>
                <div className="bg-red-600 w-4 h-4 rounded-full border-2 border-white shadow-lg" />
              </AdvancedMarker>
            </div>
          ))}

          {/* GPS points */}
          {showGpsPoints && gpsPoints.length > 0 && (
            <GpsPointsLayer
              points={gpsPoints}
              onPointClick={setSelectedPoint}
            />
          )}

          {/* GPS point info window */}
          {selectedPoint && (
            <InfoWindow
              position={{ lat: selectedPoint.latitude, lng: selectedPoint.longitude }}
              onCloseClick={() => setSelectedPoint(null)}
            >
              <div className="text-xs space-y-1 min-w-[140px]">
                <p className="font-semibold text-slate-900">
                  Point #{selectedPoint.sequence_order}
                </p>
                <p className="text-slate-600">
                  {formatTime(selectedPoint.captured_at)}
                </p>
                {selectedPoint.speed != null && (
                  <p className="text-slate-600">
                    Vitesse: {(selectedPoint.speed * 3.6).toFixed(1)} km/h
                  </p>
                )}
                <p className="text-slate-600">
                  Précision: {selectedPoint.accuracy.toFixed(0)}m
                </p>
                {selectedPoint.altitude != null && (
                  <p className="text-slate-600">
                    Altitude: {selectedPoint.altitude.toFixed(0)}m
                  </p>
                )}
              </div>
            </InfoWindow>
          )}

          {/* GPS clusters (brief stops < 60s) */}
          {clusters.length > 0 && (
            <GpsClustersLayer
              clusters={clusters}
              onClusterClick={(c) => { setSelectedPoint(null); setSelectedStop(null); setSelectedCluster(c); }}
            />
          )}

          {/* Cluster info window */}
          {selectedCluster && (
            <InfoWindow
              position={{ lat: selectedCluster.latitude, lng: selectedCluster.longitude }}
              onCloseClick={() => setSelectedCluster(null)}
            >
              <div className="text-xs space-y-1 min-w-[140px]">
                <p className="font-semibold text-slate-900">
                  Pause ({formatDuration(selectedCluster.durationSeconds)})
                </p>
                <p className="text-slate-600">
                  {formatTime(selectedCluster.startTime)} – {formatTime(selectedCluster.endTime)}
                </p>
                <p className="text-slate-600">
                  {selectedCluster.pointCount} points GPS
                </p>
              </div>
            </InfoWindow>
          )}

          {/* Stop markers */}
          {stops.length > 0 && (
            <StopsLayer
              stops={stops}
              onStopClick={(s) => { setSelectedPoint(null); setSelectedCluster(null); setSelectedStop(s); }}
            />
          )}

          {/* Stop info window */}
          {selectedStop && (
            <InfoWindow
              position={{ lat: selectedStop.latitude, lng: selectedStop.longitude }}
              onCloseClick={() => setSelectedStop(null)}
            >
              <div className="text-xs space-y-1 min-w-[140px]">
                <p className="font-semibold text-slate-900">
                  Arrêt ({formatDuration(selectedStop.durationSeconds)})
                </p>
                <p className="text-slate-600">
                  {formatTime(selectedStop.startTime)} – {formatTime(selectedStop.endTime)}
                </p>
                <p className="text-slate-600">
                  {selectedStop.pointCount} points GPS
                </p>
              </div>
            </InfoWindow>
          )}

          <AutoFitBounds routes={routes} gpsPoints={showGpsPoints ? gpsPoints : []} />
        </Map>
      </APIProvider>
    </div>
  );
}

function GpsPointsLayer({
  points,
  onPointClick,
}: {
  points: TripGpsPoint[];
  onPointClick: (p: TripGpsPoint) => void;
}) {
  const map = useMap();

  useEffect(() => {
    if (!map || points.length === 0) return;

    const overlays: google.maps.MVCObject[] = [];

    points.forEach((pt) => {
      const position = { lat: pt.latitude, lng: pt.longitude };
      const color = getSpeedColor(pt.speed);

      // Accuracy halo for imprecise points
      if (pt.accuracy > 15) {
        const halo = new google.maps.Circle({
          map,
          center: position,
          radius: pt.accuracy,
          fillColor: color,
          fillOpacity: 0.08,
          strokeColor: color,
          strokeOpacity: 0.15,
          strokeWeight: 1,
          clickable: false,
        });
        overlays.push(halo);
      }

      // GPS point dot
      const dot = new google.maps.Circle({
        map,
        center: position,
        radius: 4,
        fillColor: color,
        fillOpacity: 0.9,
        strokeColor: '#fff',
        strokeOpacity: 1,
        strokeWeight: 1.5,
        clickable: true,
        zIndex: 10,
      });
      dot.addListener('click', () => onPointClick(pt));
      overlays.push(dot);
    });

    return () => {
      overlays.forEach((o) => (o as any).setMap(null));
    };
  }, [map, points, onPointClick]);

  return null;
}

function GpsTrailPolyline({ points }: { points: google.maps.LatLngLiteral[] }) {
  const map = useMap();
  useEffect(() => {
    if (!map || points.length < 2) return;
    const poly = new google.maps.Polyline({
      path: points,
      map,
      strokeColor: '#f97316',
      strokeOpacity: 0.5,
      strokeWeight: 3,
      zIndex: 1,
    });
    return () => poly.setMap(null);
  }, [map, points]);
  return null;
}

function TripPolyline({ route }: { route: any }) {
  const map = useMap();
  useEffect(() => {
    if (!map) return;

    // Matched = solid thick blue (OSRM road route)
    // GPS trail = solid medium orange (actual GPS path)
    // Straight-line fallback = dashed thin gray
    const isGpsTrail = route.hasGpsTrail;
    const poly = new google.maps.Polyline({
      path: route.points,
      map,
      strokeColor: route.isMatched ? route.color : isGpsTrail ? '#f97316' : route.color,
      strokeOpacity: route.isMatched ? 0.8 : isGpsTrail ? 0.7 : 0.4,
      strokeWeight: route.isMatched ? 5 : isGpsTrail ? 4 : 3,
      icons:
        route.isMatched || isGpsTrail
          ? []
          : [
              {
                icon: { path: 'M 0,-1 0,1', strokeOpacity: 1, scale: 2 },
                offset: '0',
                repeat: '10px',
              },
            ],
    });
    return () => poly.setMap(null);
  }, [map, route]);
  return null;
}

function StopsLayer({
  stops,
  onStopClick,
}: {
  stops: TripStop[];
  onStopClick: (s: TripStop) => void;
}) {
  const map = useMap();

  useEffect(() => {
    if (!map || stops.length === 0) return;

    const overlays: google.maps.Circle[] = [];

    stops.forEach((stop) => {
      const position = { lat: stop.latitude, lng: stop.longitude };
      const color = STOP_COLORS[stop.category];

      // Pulsing outer ring for extended stops
      if (stop.category === 'extended') {
        const ring = new google.maps.Circle({
          map,
          center: position,
          radius: 20,
          fillColor: color,
          fillOpacity: 0.25,
          strokeColor: color,
          strokeOpacity: 0.4,
          strokeWeight: 1,
          clickable: false,
          zIndex: 19,
        });
        overlays.push(ring);
      }

      const circle = new google.maps.Circle({
        map,
        center: position,
        radius: 12,
        fillColor: color,
        fillOpacity: 0.7,
        strokeColor: '#fff',
        strokeOpacity: 1,
        strokeWeight: 2,
        clickable: true,
        zIndex: 20,
      });
      circle.addListener('click', () => onStopClick(stop));
      overlays.push(circle);
    });

    return () => {
      overlays.forEach((o) => o.setMap(null));
    };
  }, [map, stops, onStopClick]);

  return null;
}

function GpsClustersLayer({
  clusters,
  onClusterClick,
}: {
  clusters: GpsCluster[];
  onClusterClick: (c: GpsCluster) => void;
}) {
  const map = useMap();

  useEffect(() => {
    if (!map || clusters.length === 0) return;

    const overlays: google.maps.MVCObject[] = [];

    clusters.forEach((cluster) => {
      const position = { lat: cluster.latitude, lng: cluster.longitude };
      const color = getClusterColor(cluster.durationSeconds);

      // Cluster circle (larger than individual GPS dots)
      const circle = new google.maps.Circle({
        map,
        center: position,
        radius: 18,
        fillColor: color,
        fillOpacity: 0.7,
        strokeColor: '#fff',
        strokeOpacity: 1,
        strokeWeight: 2,
        clickable: true,
        zIndex: 15,
      });
      circle.addListener('click', () => onClusterClick(cluster));
      overlays.push(circle);

      // Label with point count (using AdvancedMarker is not possible here,
      // so we use a Marker with a custom label)
      const marker = new google.maps.Marker({
        map,
        position,
        icon: {
          path: google.maps.SymbolPath.CIRCLE,
          scale: 0,
        },
        label: {
          text: String(cluster.pointCount),
          color: '#fff',
          fontSize: '10px',
          fontWeight: 'bold',
        },
        clickable: true,
        zIndex: 16,
      });
      marker.addListener('click', () => onClusterClick(cluster));
      overlays.push(marker);
    });

    return () => {
      overlays.forEach((o) => (o as any).setMap(null));
    };
  }, [map, clusters, onClusterClick]);

  return null;
}

function AutoFitBounds({ routes, gpsPoints }: { routes: any[]; gpsPoints: TripGpsPoint[] }) {
  const map = useMap();
  useEffect(() => {
    if (!map || (routes.length === 0 && gpsPoints.length === 0)) return;
    const bounds = new google.maps.LatLngBounds();
    routes.forEach((r) => r.points.forEach((p: any) => bounds.extend(p)));
    gpsPoints.forEach((pt) => bounds.extend({ lat: pt.latitude, lng: pt.longitude }));
    map.fitBounds(bounds, { top: 40, right: 40, bottom: 40, left: 40 });
  }, [map, routes, gpsPoints]);
  return null;
}
