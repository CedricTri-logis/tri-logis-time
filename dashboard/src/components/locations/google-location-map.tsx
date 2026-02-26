'use client';

import { useEffect, useMemo, useState, useCallback } from 'react';
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

interface LocationMapProps {
  position: [number, number] | null;
  radius: number;
  locationType: LocationType;
  onPositionChange: (lat: number, lng: number) => void;
  className?: string;
  readOnly?: boolean;
  apiKey?: string;
}

export function GoogleLocationMap({
  position,
  radius,
  locationType,
  onPositionChange,
  className = 'h-[400px] w-full rounded-lg overflow-hidden',
  readOnly = false,
  apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY || '',
}: LocationMapProps) {
  const center = position ? { lat: position[0], lng: position[1] } : { lat: 45.5017, lng: -73.5673 };

  const handleMapClick = (e: MapMouseEvent) => {
    if (!readOnly && e.detail.latLng) {
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
                  if (e.latLng) onPositionChange(e.latLng.lat(), e.latLng.lng());
                }}
              />
              <GeofenceCircle 
                center={{ lat: position[0], lng: position[1] }} 
                radius={radius} 
                locationType={locationType} 
              />
              <AutoFitCircle center={{ lat: position[0], lng: position[1] }} radius={radius} />
            </>
          )}
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

function AutoFitCircle({ center, radius }: { center: google.maps.LatLngLiteral, radius: number }) {
  const map = useMap();
  useEffect(() => {
    if (!map) return;
    const circle = new google.maps.Circle({ center, radius });
    map.fitBounds(circle.getBounds()!, { top: 40, right: 40, bottom: 40, left: 40 });
  }, [map, center, radius]);
  return null;
}
