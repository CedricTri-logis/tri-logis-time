'use client';

import { useEffect, useMemo, useCallback, useState } from 'react';
import { MapContainer, TileLayer, Marker, useMap, Popup } from 'react-leaflet';
import L from 'leaflet';
import { useRouter } from 'next/navigation';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import { GeofenceCircle } from './geofence-circle';
import type { Location, LocationType } from '@/types/location';
import { LOCATION_TYPE_COLORS, getLocationTypeColor } from '@/lib/utils/segment-colors';
import { MapPin, ExternalLink, Eye, EyeOff } from 'lucide-react';

// Import Leaflet CSS
import 'leaflet/dist/leaflet.css';

// Fix for default marker icons in webpack/next.js
delete (L.Icon.Default.prototype as unknown as { _getIconUrl?: unknown })._getIconUrl;
L.Icon.Default.mergeOptions({
  iconRetinaUrl: 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/images/marker-icon-2x.png',
  iconUrl: 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/images/marker-icon.png',
  shadowUrl: 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/images/marker-shadow.png',
});

// Default center (Montreal) and zoom
const DEFAULT_CENTER: [number, number] = [45.5017, -73.5673];
const DEFAULT_ZOOM = 11;

interface LocationsOverviewMapProps {
  locations: Location[];
  isLoading?: boolean;
  onLocationClick?: (location: Location) => void;
  selectedLocationId?: string | null;
  showInactive?: boolean;
  className?: string;
}

/**
 * Map component displaying all locations with their geofence circles.
 * Supports filtering, selection, and click-to-view-details functionality.
 */
export function LocationsOverviewMap({
  locations,
  isLoading = false,
  onLocationClick,
  selectedLocationId = null,
  showInactive = true,
  className = '',
}: LocationsOverviewMapProps) {
  const router = useRouter();

  // Filter locations based on active status
  const filteredLocations = useMemo(() => {
    if (showInactive) return locations;
    return locations.filter((loc) => loc.isActive);
  }, [locations, showInactive]);

  // Calculate center and bounds from locations
  const { center, bounds } = useMemo(() => {
    if (filteredLocations.length === 0) {
      return { center: DEFAULT_CENTER, bounds: null };
    }

    const lats = filteredLocations.map((l) => l.latitude);
    const lngs = filteredLocations.map((l) => l.longitude);

    const minLat = Math.min(...lats);
    const maxLat = Math.max(...lats);
    const minLng = Math.min(...lngs);
    const maxLng = Math.max(...lngs);

    const centerLat = (minLat + maxLat) / 2;
    const centerLng = (minLng + maxLng) / 2;

    return {
      center: [centerLat, centerLng] as [number, number],
      bounds: L.latLngBounds(
        [minLat, minLng],
        [maxLat, maxLng]
      ),
    };
  }, [filteredLocations]);

  const handleLocationClick = useCallback(
    (location: Location) => {
      if (onLocationClick) {
        onLocationClick(location);
      } else {
        // Default: navigate to location detail page
        router.push(`/dashboard/locations/${location.id}`);
      }
    },
    [onLocationClick, router]
  );

  if (isLoading) {
    return <MapSkeleton className={className} />;
  }

  if (locations.length === 0) {
    return (
      <Card className={className}>
        <CardContent className="flex flex-col items-center justify-center py-12">
          <MapPin className="h-12 w-12 text-slate-300 mb-4" />
          <h3 className="text-lg font-medium text-slate-900 mb-1">
            No locations to display
          </h3>
          <p className="text-sm text-slate-500">
            Create locations to see them on the map.
          </p>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card className={className}>
      <CardHeader className="pb-2">
        <div className="flex items-center justify-between">
          <CardTitle className="text-base font-medium flex items-center gap-2">
            <MapPin className="h-4 w-4 text-slate-500" />
            Locations Map
          </CardTitle>
          <div className="text-sm text-slate-500">
            {filteredLocations.length} location{filteredLocations.length !== 1 ? 's' : ''}
          </div>
        </div>
      </CardHeader>
      <CardContent className="p-0">
        <div className="h-[500px] w-full">
          <MapContainer
            center={center}
            zoom={DEFAULT_ZOOM}
            className="h-full w-full rounded-b-lg"
            scrollWheelZoom={true}
          >
            <TileLayer
              attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
              url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
            />

            {/* Auto-fit bounds when locations change */}
            {bounds && <FitToBounds bounds={bounds} />}

            {/* Render geofence circles for all locations */}
            {filteredLocations.map((location) => (
              <GeofenceCircle
                key={location.id}
                location={location}
                isSelected={location.id === selectedLocationId}
                onClick={handleLocationClick}
                showPopup={true}
              />
            ))}

            {/* Render center markers for each location */}
            {filteredLocations.map((location) => (
              <LocationMarker
                key={`marker-${location.id}`}
                location={location}
                isSelected={location.id === selectedLocationId}
                onClick={handleLocationClick}
              />
            ))}
          </MapContainer>
        </div>

        {/* Legend */}
        <div className="p-3 border-t border-slate-100">
          <LocationTypeLegend />
        </div>
      </CardContent>
    </Card>
  );
}

/**
 * Fit map bounds to show all locations
 */
interface FitToBoundsProps {
  bounds: L.LatLngBounds;
}

function FitToBounds({ bounds }: FitToBoundsProps) {
  const map = useMap();

  useEffect(() => {
    // Add padding to bounds for geofence circles
    map.fitBounds(bounds, { padding: [60, 60], maxZoom: 15 });
  }, [map, bounds]);

  return null;
}

/**
 * Custom marker for location center point
 */
interface LocationMarkerProps {
  location: Location;
  isSelected: boolean;
  onClick: (location: Location) => void;
}

function LocationMarker({ location, isSelected, onClick }: LocationMarkerProps) {
  const color = getLocationTypeColor(location.locationType);
  const typeConfig = LOCATION_TYPE_COLORS[location.locationType];

  // Create a custom colored icon
  const icon = useMemo(() => {
    return L.divIcon({
      className: 'custom-marker',
      html: `
        <div style="
          background-color: ${color};
          width: ${isSelected ? '28px' : '24px'};
          height: ${isSelected ? '28px' : '24px'};
          border-radius: 50%;
          border: 3px solid white;
          box-shadow: 0 2px 6px rgba(0,0,0,0.3);
          display: flex;
          align-items: center;
          justify-content: center;
          ${!location.isActive ? 'opacity: 0.5;' : ''}
        ">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="white">
            <path d="M21 10c0 7-9 13-9 13s-9-6-9-13a9 9 0 0 1 18 0z"/>
            <circle cx="12" cy="10" r="3"/>
          </svg>
        </div>
      `,
      iconSize: [isSelected ? 28 : 24, isSelected ? 28 : 24],
      iconAnchor: [isSelected ? 14 : 12, isSelected ? 14 : 12],
    });
  }, [color, isSelected, location.isActive]);

  return (
    <Marker
      position={[location.latitude, location.longitude]}
      icon={icon}
      eventHandlers={{
        click: () => onClick(location),
      }}
    >
      <Popup>
        <LocationPopupContent location={location} typeConfig={typeConfig} />
      </Popup>
    </Marker>
  );
}

/**
 * Popup content when clicking a location marker
 */
interface LocationPopupContentProps {
  location: Location;
  typeConfig: { label: string; color: string };
}

function LocationPopupContent({ location, typeConfig }: LocationPopupContentProps) {
  const router = useRouter();

  return (
    <div className="min-w-[200px] p-1">
      <div className="font-medium text-sm mb-1">{location.name}</div>
      <div className="flex items-center gap-2 mb-2">
        <span
          className="text-xs px-2 py-0.5 rounded"
          style={{
            backgroundColor: `${typeConfig.color}20`,
            color: typeConfig.color,
          }}
        >
          {typeConfig.label}
        </span>
        {!location.isActive && (
          <span className="text-xs px-2 py-0.5 rounded bg-slate-100 text-slate-500">
            Inactive
          </span>
        )}
      </div>
      {location.address && (
        <div className="text-xs text-slate-500 mb-2">{location.address}</div>
      )}
      <div className="text-xs text-slate-400 mb-3">
        Radius: {location.radiusMeters}m
      </div>
      <Button
        size="sm"
        variant="outline"
        className="w-full text-xs h-7"
        onClick={() => router.push(`/dashboard/locations/${location.id}`)}
      >
        <ExternalLink className="h-3 w-3 mr-1" />
        View Details
      </Button>
    </div>
  );
}

/**
 * Legend showing location type colors
 */
function LocationTypeLegend() {
  return (
    <div className="flex flex-wrap items-center gap-4 text-xs">
      <span className="text-slate-500 font-medium">Legend:</span>
      {Object.entries(LOCATION_TYPE_COLORS).map(([type, config]) => (
        <div key={type} className="flex items-center gap-1.5">
          <div
            className="h-3 w-3 rounded-full"
            style={{ backgroundColor: config.color }}
          />
          <span className="text-slate-600">{config.label}</span>
        </div>
      ))}
    </div>
  );
}

/**
 * Loading skeleton for the map
 */
function MapSkeleton({ className = '' }: { className?: string }) {
  return (
    <Card className={className}>
      <CardHeader className="pb-2">
        <div className="flex items-center justify-between">
          <Skeleton className="h-5 w-32" />
          <Skeleton className="h-4 w-20" />
        </div>
      </CardHeader>
      <CardContent className="p-0">
        <Skeleton className="h-[500px] w-full rounded-b-lg" />
      </CardContent>
    </Card>
  );
}

/**
 * Compact map view for smaller displays
 */
interface CompactLocationsMapProps {
  locations: Location[];
  isLoading?: boolean;
  onLocationClick?: (location: Location) => void;
  className?: string;
}

export function CompactLocationsMap({
  locations,
  isLoading = false,
  onLocationClick,
  className = 'h-[300px]',
}: CompactLocationsMapProps) {
  const router = useRouter();

  // Calculate bounds
  const bounds = useMemo(() => {
    if (locations.length === 0) return null;

    const lats = locations.map((l) => l.latitude);
    const lngs = locations.map((l) => l.longitude);

    return L.latLngBounds(
      [Math.min(...lats), Math.min(...lngs)],
      [Math.max(...lats), Math.max(...lngs)]
    );
  }, [locations]);

  const center = useMemo(() => {
    if (locations.length === 0) return DEFAULT_CENTER;
    const lats = locations.map((l) => l.latitude);
    const lngs = locations.map((l) => l.longitude);
    return [
      (Math.min(...lats) + Math.max(...lats)) / 2,
      (Math.min(...lngs) + Math.max(...lngs)) / 2,
    ] as [number, number];
  }, [locations]);

  const handleClick = useCallback(
    (location: Location) => {
      if (onLocationClick) {
        onLocationClick(location);
      } else {
        router.push(`/dashboard/locations/${location.id}`);
      }
    },
    [onLocationClick, router]
  );

  if (isLoading) {
    return <Skeleton className={`w-full ${className}`} />;
  }

  if (locations.length === 0) {
    return (
      <div className={`flex items-center justify-center bg-slate-100 rounded-lg ${className}`}>
        <p className="text-sm text-slate-500">No locations</p>
      </div>
    );
  }

  return (
    <div className={className}>
      <MapContainer
        center={center}
        zoom={DEFAULT_ZOOM}
        className="h-full w-full rounded-lg"
        scrollWheelZoom={true}
      >
        <TileLayer
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
          url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
        />
        {bounds && <FitToBounds bounds={bounds} />}
        {locations.map((location) => (
          <GeofenceCircle
            key={location.id}
            location={location}
            onClick={handleClick}
            showPopup={true}
          />
        ))}
      </MapContainer>
    </div>
  );
}
