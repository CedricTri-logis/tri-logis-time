'use client';

import { useEffect, useRef, useMemo, useState, useCallback } from 'react';
import {
  APIProvider,
  Map,
  useMap,
  AdvancedMarker,
  MapMouseEvent,
} from '@vis.gl/react-google-maps';
import { Card } from '@/components/ui/card';
import type { LocationType } from '@/types/location';
import { getLocationTypeColor } from '@/lib/utils/segment-colors';

interface NearbyLocationCircle {
  id: string;
  name: string;
  latitude: number;
  longitude: number;
  radiusMeters: number;
  isOverlapping: boolean;
}

interface LocationMapProps {
  position: [number, number] | null;
  radius: number;
  locationType: LocationType;
  onPositionChange: (lat: number, lng: number) => void;
  className?: string;
  readOnly?: boolean;
  apiKey?: string;
  nearbyLocations?: NearbyLocationCircle[];
}

export function GoogleLocationMap({
  position,
  radius,
  locationType,
  onPositionChange,
  className = 'h-[400px] w-full rounded-lg overflow-hidden',
  readOnly = false,
  apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY || '',
  nearbyLocations,
}: LocationMapProps) {
  const center = position ? { lat: position[0], lng: position[1] } : { lat: 45.5017, lng: -73.5673 };
  const lastDragEndRef = useRef(0);

  const handleMapClick = (e: MapMouseEvent) => {
    if (!readOnly && e.detail.latLng) {
      // Ignore click events that fire right after a marker drag (ghost click)
      if (Date.now() - lastDragEndRef.current < 300) return;
      onPositionChange(e.detail.latLng.lat, e.detail.latLng.lng);
    }
  };

  return (
    <Card className={className}>
      <APIProvider apiKey={apiKey}>
        <Map
          defaultCenter={center}
          defaultZoom={position ? 15 : 12}
          mapId="location_edit_map"
          onClick={handleMapClick}
          disableDefaultUI={readOnly}
          gestureHandling={readOnly ? 'none' : 'auto'}
        >
          {position && (
            <>
              <AdvancedMarker
                position={{ lat: position[0], lng: position[1] }}
                draggable={!readOnly}
                onDragEnd={(e) => {
                  if (e.latLng) {
                    lastDragEndRef.current = Date.now();
                    onPositionChange(e.latLng.lat(), e.latLng.lng());
                  }
                }}
              />
              <GeofenceCircle 
                center={{ lat: position[0], lng: position[1] }} 
                radius={radius} 
                locationType={locationType} 
              />
              <AutoFitBounds
                center={{ lat: position[0], lng: position[1] }}
                radius={radius}
                nearbyLocations={nearbyLocations}
              />
            </>
          )}
          {/* Nearby location circles */}
          {nearbyLocations?.map((loc) => (
            <NearbyCircle
              key={loc.id}
              center={{ lat: loc.latitude, lng: loc.longitude }}
              radius={loc.radiusMeters}
              name={loc.name}
              isOverlapping={loc.isOverlapping}
            />
          ))}
        </Map>
      </APIProvider>
    </Card>
  );
}

function GeofenceCircle({ center, radius, locationType }: { center: google.maps.LatLngLiteral, radius: number, locationType: LocationType }) {
  const map = useMap();
  const color = getLocationTypeColor(locationType);

  useEffect(() => {
    if (!map) return;

    const circle = new google.maps.Circle({
      map,
      center,
      radius,
      fillColor: color,
      fillOpacity: 0.2,
      strokeColor: color,
      strokeOpacity: 0.8,
      strokeWeight: 2,
    });

    return () => circle.setMap(null);
  }, [map, center, radius, color]);

  return null;
}

/**
 * Fits the map to show the main circle plus any nearby locations.
 * Only re-fits on radius or nearby locations change — NOT on position drag.
 */
function AutoFitBounds({
  center,
  radius,
  nearbyLocations,
}: {
  center: google.maps.LatLngLiteral;
  radius: number;
  nearbyLocations?: NearbyLocationCircle[];
}) {
  const map = useMap();
  const centerRef = useRef(center);
  centerRef.current = center;

  // Stable key for nearby locations to avoid re-fitting on every render
  const nearbyKey = useMemo(
    () => (nearbyLocations ?? []).map((l) => l.id).sort().join(','),
    [nearbyLocations]
  );

  useEffect(() => {
    if (!map) return;

    const bounds = new google.maps.LatLngBounds();

    // Include main circle
    const mainCircle = new google.maps.Circle({ center: centerRef.current, radius });
    const mainBounds = mainCircle.getBounds();
    if (mainBounds) bounds.union(mainBounds);

    // Include nearby location circles
    if (nearbyLocations?.length) {
      for (const loc of nearbyLocations) {
        const c = new google.maps.Circle({
          center: { lat: loc.latitude, lng: loc.longitude },
          radius: loc.radiusMeters,
        });
        const cb = c.getBounds();
        if (cb) bounds.union(cb);
      }
    }

    map.fitBounds(bounds, { top: 40, right: 40, bottom: 40, left: 40 });
  }, [map, radius, nearbyKey, nearbyLocations]);

  return null;
}

function NearbyCircle({
  center,
  radius,
  name,
  isOverlapping,
}: {
  center: google.maps.LatLngLiteral;
  radius: number;
  name: string;
  isOverlapping: boolean;
}) {
  const map = useMap();

  useEffect(() => {
    if (!map) return;

    const color = isOverlapping ? '#ef4444' : '#6b7280';

    const circle = new google.maps.Circle({
      map,
      center,
      radius,
      fillColor: color,
      fillOpacity: isOverlapping ? 0.25 : 0.08,
      strokeColor: color,
      strokeOpacity: isOverlapping ? 0.9 : 0.4,
      strokeWeight: isOverlapping ? 2 : 1,
    });

    // Label
    const label = new google.maps.Marker({
      map,
      position: center,
      icon: {
        path: google.maps.SymbolPath.CIRCLE,
        scale: 0,
      },
      label: {
        text: name,
        fontSize: '10px',
        fontWeight: isOverlapping ? '700' : '500',
        color: isOverlapping ? '#dc2626' : '#6b7280',
        className: 'nearby-location-label',
      },
    });

    return () => {
      circle.setMap(null);
      label.setMap(null);
    };
  }, [map, center, radius, name, isOverlapping]);

  return null;
}
