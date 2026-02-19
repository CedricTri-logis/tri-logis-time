'use client';

import { useMemo } from 'react';
import Link from 'next/link';
import { Marker, Popup, Circle } from 'react-leaflet';
import L from 'leaflet';
import { DurationCounter } from './duration-counter';
import { getStalenessLevel, formatDurationHM } from '@/types/monitoring';
import type { MonitoredEmployee, StalenessLevel } from '@/types/monitoring';

// Threshold for showing accuracy circle (meters)
const ACCURACY_CIRCLE_THRESHOLD = 100;

// Custom marker icon colors based on staleness
const markerColors: Record<StalenessLevel, string> = {
  fresh: '#22c55e', // green-500
  stale: '#eab308', // yellow-500
  'very-stale': '#ef4444', // red-500
  unknown: '#94a3b8', // slate-400
};

interface LocationMarkerProps {
  employee: MonitoredEmployee;
}

/**
 * Map marker for an employee's current location.
 * Shows different colors based on location freshness.
 */
export function LocationMarker({ employee }: LocationMarkerProps) {
  const location = employee.currentLocation;

  if (!location) return null;

  const staleness = getStalenessLevel(location.capturedAt);
  const color = markerColors[staleness];

  // Create custom colored marker icon
  const icon = useMemo(() => {
    return L.divIcon({
      className: 'custom-marker',
      html: `
        <div style="
          width: 32px;
          height: 32px;
          display: flex;
          align-items: center;
          justify-content: center;
        ">
          <svg width="28" height="41" viewBox="0 0 28 41" fill="none" xmlns="http://www.w3.org/2000/svg">
            <path d="M14 0C6.268 0 0 6.268 0 14C0 24.5 14 41 14 41C14 41 28 24.5 28 14C28 6.268 21.732 0 14 0Z" fill="${color}"/>
            <circle cx="14" cy="14" r="7" fill="white"/>
            <circle cx="14" cy="14" r="4" fill="${color}"/>
          </svg>
        </div>
      `,
      iconSize: [32, 41],
      iconAnchor: [16, 41],
      popupAnchor: [0, -41],
    });
  }, [color]);

  const showAccuracyCircle = location.accuracy > ACCURACY_CIRCLE_THRESHOLD;

  return (
    <>
      <Marker
        position={[location.latitude, location.longitude]}
        icon={icon}
      >
        <Popup>
          <MarkerPopupContent employee={employee} staleness={staleness} />
        </Popup>
      </Marker>

      {/* Accuracy circle for poor GPS accuracy */}
      {showAccuracyCircle && (
        <Circle
          center={[location.latitude, location.longitude]}
          radius={location.accuracy}
          pathOptions={{
            color: color,
            fillColor: color,
            fillOpacity: 0.1,
            weight: 1,
            dashArray: '4 4',
          }}
        />
      )}
    </>
  );
}

interface MarkerPopupContentProps {
  employee: MonitoredEmployee;
  staleness: StalenessLevel;
}

function MarkerPopupContent({ employee, staleness }: MarkerPopupContentProps) {
  const location = employee.currentLocation;

  return (
    <div className="min-w-[180px]">
      {/* Employee name */}
      <div className="font-semibold text-slate-900 mb-1">
        {employee.displayName}
      </div>

      {/* Employee ID */}
      {employee.employeeId && (
        <div className="text-xs text-slate-500 mb-2">
          ID: {employee.employeeId}
        </div>
      )}

      {/* Shift duration */}
      {employee.currentShift && (
        <div className="flex items-center gap-2 text-sm text-slate-700 mb-2">
          <span className="text-slate-500">Shift:</span>
          <DurationCounter
            startTime={employee.currentShift.clockedInAt}
            format="hm"
          />
        </div>
      )}

      {/* Location freshness */}
      {location && (
        <div className="flex items-center gap-2 text-xs mb-3">
          <StalenessBadge level={staleness} />
          <span className="text-slate-500">
            {formatTimeAgo(location.capturedAt)}
          </span>
        </div>
      )}

      {/* GPS accuracy warning */}
      {location && location.accuracy > ACCURACY_CIRCLE_THRESHOLD && (
        <div className="text-xs text-yellow-600 mb-3">
          Low accuracy: ~{Math.round(location.accuracy)}m
        </div>
      )}

      {/* Link to detail page */}
      <Link
        href={`/dashboard/monitoring/${employee.id}`}
        className="text-xs text-blue-600 hover:underline"
      >
        View shift details &rarr;
      </Link>
    </div>
  );
}

interface StalenessBadgeProps {
  level: StalenessLevel;
}

function StalenessBadge({ level }: StalenessBadgeProps) {
  const config: Record<StalenessLevel, { bg: string; text: string; label: string }> = {
    fresh: { bg: 'bg-green-100', text: 'text-green-700', label: 'Live' },
    stale: { bg: 'bg-yellow-100', text: 'text-yellow-700', label: 'Stale' },
    'very-stale': { bg: 'bg-red-100', text: 'text-red-700', label: 'Very stale' },
    unknown: { bg: 'bg-slate-100', text: 'text-slate-600', label: 'Unknown' },
  };

  const { bg, text, label } = config[level];

  return (
    <span className={`inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium ${bg} ${text}`}>
      {label}
    </span>
  );
}

function formatTimeAgo(date: Date): string {
  const seconds = Math.floor((Date.now() - date.getTime()) / 1000);

  if (seconds < 5) return 'just now';
  if (seconds < 60) return `${seconds}s ago`;

  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;

  const hours = Math.floor(minutes / 60);
  return `${hours}h ago`;
}
