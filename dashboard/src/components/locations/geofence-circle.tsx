'use client';

import { Circle, Popup } from 'react-leaflet';
import type { Location, LocationType } from '@/types/location';
import { getLocationTypeColor, LOCATION_TYPE_COLORS } from '@/lib/utils/segment-colors';

interface GeofenceCircleProps {
  location: Location;
  isSelected?: boolean;
  isHighlighted?: boolean;
  onClick?: (location: Location) => void;
  showPopup?: boolean;
}

/**
 * Leaflet circle component representing a location geofence.
 * The circle's radius represents the actual geofence boundary in meters.
 */
export function GeofenceCircle({
  location,
  isSelected = false,
  isHighlighted = false,
  onClick,
  showPopup = true,
}: GeofenceCircleProps) {
  const color = getLocationTypeColor(location.locationType);
  const typeConfig = LOCATION_TYPE_COLORS[location.locationType];

  // Calculate opacity based on state
  const fillOpacity = isSelected ? 0.4 : isHighlighted ? 0.3 : 0.2;
  const weight = isSelected ? 3 : 2;

  return (
    <Circle
      center={[location.latitude, location.longitude]}
      radius={location.radiusMeters}
      pathOptions={{
        color: color,
        fillColor: color,
        fillOpacity,
        weight,
        dashArray: isSelected ? undefined : isHighlighted ? '5, 5' : undefined,
      }}
      eventHandlers={{
        click: () => onClick?.(location),
      }}
    >
      {showPopup && (
        <Popup>
          <div className="min-w-[180px]">
            <div className="font-medium text-sm mb-1">{location.name}</div>
            <div
              className="text-xs px-2 py-0.5 rounded inline-block mb-2"
              style={{
                backgroundColor: `${color}20`,
                color: color,
              }}
            >
              {typeConfig.label}
            </div>
            {location.address && (
              <div className="text-xs text-slate-500 mb-1">{location.address}</div>
            )}
            <div className="text-xs text-slate-400">
              Radius: {location.radiusMeters}m
            </div>
            {!location.isActive && (
              <div className="text-xs text-red-500 mt-1">Inactive</div>
            )}
          </div>
        </Popup>
      )}
    </Circle>
  );
}

interface GeofenceCirclePreviewProps {
  center: [number, number];
  radius: number;
  locationType: LocationType;
}

/**
 * Preview circle for location form (before saving).
 * Displays a dashed circle at the specified position.
 */
export function GeofenceCirclePreview({
  center,
  radius,
  locationType,
}: GeofenceCirclePreviewProps) {
  const color = getLocationTypeColor(locationType);

  return (
    <Circle
      center={center}
      radius={radius}
      pathOptions={{
        color: color,
        fillColor: color,
        fillOpacity: 0.15,
        weight: 2,
        dashArray: '8, 8',
      }}
    />
  );
}
