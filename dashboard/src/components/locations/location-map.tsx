'use client';

import { useEffect, useMemo, useState, useCallback } from 'react';
import { MapContainer, TileLayer, Marker, useMap, useMapEvents } from 'react-leaflet';
import L from 'leaflet';
import { GeofenceCirclePreview } from './geofence-circle';
import type { LocationType } from '@/types/location';

// Import Leaflet CSS
import 'leaflet/dist/leaflet.css';

// Fix for default marker icons in webpack/next.js
delete (L.Icon.Default.prototype as unknown as { _getIconUrl?: unknown })._getIconUrl;
L.Icon.Default.mergeOptions({
  iconRetinaUrl: 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/images/marker-icon-2x.png',
  iconUrl: 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/images/marker-icon.png',
  shadowUrl: 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/images/marker-shadow.png',
});

// Default center (Montreal)
const DEFAULT_CENTER: [number, number] = [45.5017, -73.5673];
const DEFAULT_ZOOM = 14;

interface LocationMapProps {
  position: [number, number] | null;
  radius: number;
  locationType: LocationType;
  onPositionChange: (lat: number, lng: number) => void;
  className?: string;
  readOnly?: boolean;
}

/**
 * Interactive map for selecting/viewing a location with geofence radius.
 * Click on the map to set the location marker.
 * The geofence circle updates in real-time with the radius slider.
 */
export function LocationMap({
  position,
  radius,
  locationType,
  onPositionChange,
  className = 'h-[400px] w-full rounded-lg',
  readOnly = false,
}: LocationMapProps) {
  const center = position ?? DEFAULT_CENTER;

  return (
    <div className={className}>
      <MapContainer
        center={center}
        zoom={position ? 15 : DEFAULT_ZOOM}
        className="h-full w-full rounded-lg"
        scrollWheelZoom={true}
      >
        <TileLayer
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
          url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
        />
        <MapClickHandler
          onPositionChange={onPositionChange}
          readOnly={readOnly}
        />
        {position && (
          <>
            <DraggableMarker
              position={position}
              onPositionChange={onPositionChange}
              readOnly={readOnly}
            />
            <GeofenceCirclePreview
              center={position}
              radius={radius}
              locationType={locationType}
            />
          </>
        )}
        {position && <FitToPosition position={position} radius={radius} />}
      </MapContainer>
    </div>
  );
}

/**
 * Click handler for placing marker
 */
interface MapClickHandlerProps {
  onPositionChange: (lat: number, lng: number) => void;
  readOnly: boolean;
}

function MapClickHandler({ onPositionChange, readOnly }: MapClickHandlerProps) {
  useMapEvents({
    click(e) {
      if (!readOnly) {
        onPositionChange(e.latlng.lat, e.latlng.lng);
      }
    },
  });
  return null;
}

/**
 * Draggable marker for fine-tuning position
 */
interface DraggableMarkerProps {
  position: [number, number];
  onPositionChange: (lat: number, lng: number) => void;
  readOnly: boolean;
}

function DraggableMarker({ position, onPositionChange, readOnly }: DraggableMarkerProps) {
  const eventHandlers = useMemo(
    () => ({
      dragend(e: L.DragEndEvent) {
        const marker = e.target;
        const pos = marker.getLatLng();
        onPositionChange(pos.lat, pos.lng);
      },
    }),
    [onPositionChange]
  );

  return (
    <Marker
      position={position}
      draggable={!readOnly}
      eventHandlers={eventHandlers}
    />
  );
}

/**
 * Auto-fit map to show the entire geofence circle
 */
interface FitToPositionProps {
  position: [number, number];
  radius: number;
}

function FitToPosition({ position, radius }: FitToPositionProps) {
  const map = useMap();
  const [isMapReady, setIsMapReady] = useState(false);

  // Wait for the map to be fully initialized
  useEffect(() => {
    const checkMapReady = () => {
      try {
        const size = map.getSize();
        if (size.x > 0 && size.y > 0) {
          setIsMapReady(true);
          return true;
        }
      } catch {
        // Map not ready yet
      }
      return false;
    };

    if (checkMapReady()) return;

    // If not ready, wait for the 'load' event
    const onLoad = () => setIsMapReady(true);
    map.on('load', onLoad);

    // Also try after a short delay as fallback
    const timeout = setTimeout(() => setIsMapReady(true), 100);

    return () => {
      map.off('load', onLoad);
      clearTimeout(timeout);
    };
  }, [map]);

  useEffect(() => {
    if (!isMapReady) return;

    try {
      // Use L.latLng.toBounds() which doesn't require map projection
      const latLng = L.latLng(position[0], position[1]);
      const bounds = latLng.toBounds(radius * 2);
      map.fitBounds(bounds, { padding: [50, 50], maxZoom: 17 });
    } catch (error) {
      // Fallback: just set view to position
      console.warn('Could not fit bounds, using setView fallback:', error);
      map.setView(position, 15);
    }
  }, [map, position, radius, isMapReady]);

  return null;
}

/**
 * Static map for read-only display (e.g., in list view)
 */
interface StaticLocationMapProps {
  position: [number, number];
  radius: number;
  locationType: LocationType;
  className?: string;
}

export function StaticLocationMap({
  position,
  radius,
  locationType,
  className = 'h-[200px] w-full rounded-lg',
}: StaticLocationMapProps) {
  return (
    <LocationMap
      position={position}
      radius={radius}
      locationType={locationType}
      onPositionChange={() => {}}
      className={className}
      readOnly={true}
    />
  );
}

/**
 * Map component for geocoding result preview
 */
interface GeocodingPreviewMapProps {
  results: Array<{
    lat: number;
    lng: number;
    address: string;
  }>;
  selectedIndex: number;
  onSelect: (index: number) => void;
  className?: string;
}

export function GeocodingPreviewMap({
  results,
  selectedIndex,
  onSelect,
  className = 'h-[300px] w-full rounded-lg',
}: GeocodingPreviewMapProps) {
  if (results.length === 0) return null;

  const selectedResult = results[selectedIndex];
  const center: [number, number] = [selectedResult.lat, selectedResult.lng];

  return (
    <div className={className}>
      <MapContainer
        center={center}
        zoom={15}
        className="h-full w-full rounded-lg"
        scrollWheelZoom={true}
      >
        <TileLayer
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
          url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
        />
        {results.map((result, index) => (
          <Marker
            key={index}
            position={[result.lat, result.lng]}
            opacity={index === selectedIndex ? 1 : 0.5}
            eventHandlers={{
              click: () => onSelect(index),
            }}
          />
        ))}
      </MapContainer>
    </div>
  );
}
