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
import { Card } from '@/components/ui/card';

interface TripRouteMapProps {
  trips: Trip[];
  gpsPoints?: TripGpsPoint[];
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

export function GoogleTripRouteMap({
  trips,
  gpsPoints = [],
  height = 400,
  showGpsPoints = true,
  apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY || '',
}: TripRouteMapProps) {
  const [selectedPoint, setSelectedPoint] = useState<TripGpsPoint | null>(null);

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
