'use client';

import { useMemo } from 'react';
import { MapContainer, TileLayer, Polyline, CircleMarker, Popup } from 'react-leaflet';
import L from 'leaflet';
import { decodePolyline6 } from '@/lib/polyline';
import type { Trip } from '@/types/mileage';

import 'leaflet/dist/leaflet.css';

interface TripRouteMapProps {
  trips: Trip[];
  height?: number;
}

const TRIP_COLORS = [
  '#3b82f6', '#22c55e', '#8b5cf6', '#f97316',
  '#ec4899', '#14b8a6', '#eab308', '#ef4444',
];

export function TripRouteMap({ trips, height = 400 }: TripRouteMapProps) {
  const { routes, bounds } = useMemo(() => {
    const routeData: Array<{
      trip: Trip;
      points: [number, number][];
      color: string;
      isMatched: boolean;
    }> = [];

    let minLat = 90;
    let maxLat = -90;
    let minLng = 180;
    let maxLng = -180;

    trips.forEach((trip, index) => {
      const color = TRIP_COLORS[index % TRIP_COLORS.length];
      const isMatched = trip.match_status === 'matched' && !!trip.route_geometry;

      let points: [number, number][];
      if (isMatched && trip.route_geometry) {
        points = decodePolyline6(trip.route_geometry);
      } else {
        points = [
          [trip.start_latitude, trip.start_longitude],
          [trip.end_latitude, trip.end_longitude],
        ];
      }

      for (const [lat, lng] of points) {
        if (lat < minLat) minLat = lat;
        if (lat > maxLat) maxLat = lat;
        if (lng < minLng) minLng = lng;
        if (lng > maxLng) maxLng = lng;
      }

      routeData.push({ trip, points, color, isMatched });
    });

    const mapBounds: L.LatLngBoundsExpression | undefined =
      routeData.length > 0
        ? [
            [minLat - 0.005, minLng - 0.005],
            [maxLat + 0.005, maxLng + 0.005],
          ]
        : undefined;

    return { routes: routeData, bounds: mapBounds };
  }, [trips]);

  if (trips.length === 0) {
    return (
      <div
        className="flex items-center justify-center bg-muted rounded-lg"
        style={{ height }}
      >
        <p className="text-muted-foreground text-sm">Aucun trajet à afficher</p>
      </div>
    );
  }

  return (
    <div style={{ height }} className="rounded-lg overflow-hidden">
      <MapContainer
        bounds={bounds}
        style={{ height: '100%', width: '100%' }}
        scrollWheelZoom={true}
      >
        <TileLayer
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
          url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
        />

        {routes.map(({ trip, points, color, isMatched }, index) => (
          <div key={trip.id}>
            <Polyline
              positions={points}
              pathOptions={{
                color,
                weight: isMatched ? 4 : 3,
                opacity: isMatched ? 0.8 : 0.5,
                dashArray: isMatched ? undefined : '10 6',
              }}
            />

            <CircleMarker
              center={[trip.start_latitude, trip.start_longitude]}
              radius={7}
              pathOptions={{
                fillColor: '#22c55e',
                fillOpacity: 1,
                color: '#fff',
                weight: 2,
              }}
            >
              <Popup>
                <strong>Départ</strong>
                <br />
                {trip.start_address || `${trip.start_latitude.toFixed(4)}, ${trip.start_longitude.toFixed(4)}`}
              </Popup>
            </CircleMarker>

            <CircleMarker
              center={[trip.end_latitude, trip.end_longitude]}
              radius={7}
              pathOptions={{
                fillColor: '#ef4444',
                fillOpacity: 1,
                color: '#fff',
                weight: 2,
              }}
            >
              <Popup>
                <strong>Arrivée</strong>
                <br />
                {trip.end_address || `${trip.end_latitude.toFixed(4)}, ${trip.end_longitude.toFixed(4)}`}
              </Popup>
            </CircleMarker>
          </div>
        ))}
      </MapContainer>
    </div>
  );
}
