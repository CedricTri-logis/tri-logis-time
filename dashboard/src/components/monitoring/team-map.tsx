'use client';

import { useMemo, useState, useEffect } from 'react';
import { MapContainer, TileLayer, useMap } from 'react-leaflet';
import L from 'leaflet';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';
import { LocationMarker } from './location-marker';
import { InlineEmptyState } from './empty-states';
import type { MonitoredEmployee } from '@/types/monitoring';

// Import Leaflet CSS
import 'leaflet/dist/leaflet.css';

// Fix for default marker icons in webpack/next.js
// Leaflet expects the marker icons to be in a specific location
delete (L.Icon.Default.prototype as unknown as { _getIconUrl?: unknown })._getIconUrl;
L.Icon.Default.mergeOptions({
  iconRetinaUrl: 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/images/marker-icon-2x.png',
  iconUrl: 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/images/marker-icon.png',
  shadowUrl: 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/images/marker-shadow.png',
});

interface TeamMapProps {
  team: MonitoredEmployee[];
  isLoading?: boolean;
}

// Default center (will be overridden when we have employee locations)
const DEFAULT_CENTER: [number, number] = [45.5017, -73.5673]; // Montreal
const DEFAULT_ZOOM = 12;

/**
 * Interactive map showing employee locations.
 * Only displays employees who are on-shift and have GPS data.
 */
export function TeamMap({ team, isLoading }: TeamMapProps) {
  const [mapError, setMapError] = useState(false);

  // Filter to employees with active shifts and valid locations
  const employeesWithLocation = useMemo(
    () =>
      team.filter(
        (e) =>
          e.shiftStatus === 'on-shift' &&
          e.currentLocation !== null &&
          e.currentLocation.latitude !== null &&
          e.currentLocation.longitude !== null
      ),
    [team]
  );

  // Calculate map bounds to fit all markers
  const bounds = useMemo(() => {
    if (employeesWithLocation.length === 0) return null;

    const lats = employeesWithLocation.map((e) => e.currentLocation!.latitude);
    const lngs = employeesWithLocation.map((e) => e.currentLocation!.longitude);

    return L.latLngBounds(
      [Math.min(...lats), Math.min(...lngs)],
      [Math.max(...lats), Math.max(...lngs)]
    );
  }, [employeesWithLocation]);

  // Get center point for the map
  const center = useMemo(() => {
    if (employeesWithLocation.length === 0) return DEFAULT_CENTER;

    const lats = employeesWithLocation.map((e) => e.currentLocation!.latitude);
    const lngs = employeesWithLocation.map((e) => e.currentLocation!.longitude);

    return [
      lats.reduce((a, b) => a + b, 0) / lats.length,
      lngs.reduce((a, b) => a + b, 0) / lngs.length,
    ] as [number, number];
  }, [employeesWithLocation]);

  if (isLoading) {
    return <MapSkeleton />;
  }

  if (mapError) {
    return <MapErrorState onRetry={() => setMapError(false)} />;
  }

  const activeOnShift = team.filter((e) => e.shiftStatus === 'on-shift');
  const hasActiveWithoutLocation = activeOnShift.length > 0 && employeesWithLocation.length === 0;

  return (
    <Card>
      <CardHeader className="pb-2">
        <CardTitle className="text-base font-medium flex items-center justify-between">
          <span>Live Map</span>
          <span className="text-sm font-normal text-slate-500">
            {employeesWithLocation.length} location{employeesWithLocation.length !== 1 ? 's' : ''}
          </span>
        </CardTitle>
      </CardHeader>
      <CardContent className="p-0">
        {employeesWithLocation.length === 0 ? (
          <div className="h-[400px] flex items-center justify-center bg-slate-50 rounded-b-lg">
            {hasActiveWithoutLocation ? (
              <InlineEmptyState message="Waiting for GPS data from active employees..." />
            ) : (
              <InlineEmptyState message="No employees currently on shift with GPS data" />
            )}
          </div>
        ) : (
          <div className="h-[400px] rounded-b-lg overflow-hidden">
            <MapContainer
              center={center}
              zoom={DEFAULT_ZOOM}
              className="h-full w-full"
              scrollWheelZoom={true}
            >
              <TileLayer
                attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
                url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
              />
              <MapBoundsUpdater bounds={bounds} employeeCount={employeesWithLocation.length} />
              {employeesWithLocation.map((employee) => (
                <LocationMarker
                  key={employee.id}
                  employee={employee}
                />
              ))}
            </MapContainer>
          </div>
        )}
      </CardContent>
    </Card>
  );
}

/**
 * Component to update map bounds when employees change
 */
interface MapBoundsUpdaterProps {
  bounds: L.LatLngBounds | null;
  employeeCount: number;
}

function MapBoundsUpdater({ bounds, employeeCount }: MapBoundsUpdaterProps) {
  const map = useMap();

  useEffect(() => {
    if (bounds && employeeCount > 0) {
      // Add some padding around the bounds
      map.fitBounds(bounds, { padding: [50, 50], maxZoom: 15 });
    }
  }, [map, bounds, employeeCount]);

  return null;
}

function MapSkeleton() {
  return (
    <Card>
      <CardHeader className="pb-2">
        <div className="flex items-center justify-between">
          <Skeleton className="h-5 w-24" />
          <Skeleton className="h-4 w-16" />
        </div>
      </CardHeader>
      <CardContent className="p-0">
        <Skeleton className="h-[400px] w-full rounded-b-lg" />
      </CardContent>
    </Card>
  );
}

interface MapErrorStateProps {
  onRetry: () => void;
}

function MapErrorState({ onRetry }: MapErrorStateProps) {
  return (
    <Card>
      <CardHeader className="pb-2">
        <CardTitle className="text-base font-medium">Live Map</CardTitle>
      </CardHeader>
      <CardContent>
        <div className="h-[400px] flex flex-col items-center justify-center bg-slate-50 rounded-lg">
          <p className="text-sm text-slate-500 mb-4">
            Unable to load map. Please check your internet connection.
          </p>
          <button
            onClick={onRetry}
            className="text-sm text-blue-600 hover:underline"
          >
            Try again
          </button>
        </div>
      </CardContent>
    </Card>
  );
}
