'use client';

import { useMemo, useState, useCallback } from 'react';
import { MapContainer, TileLayer, Polyline, CircleMarker, Popup, useMap } from 'react-leaflet';
import L from 'leaflet';
import { format } from 'date-fns';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';
import { NoGpsTrailEmptyState } from './empty-states';
import type { GpsTrailPoint } from '@/types/monitoring';

import 'leaflet/dist/leaflet.css';

interface GpsTrailMapProps {
  trail: GpsTrailPoint[];
  isLoading?: boolean;
  employeeName?: string;
  /** Historical mode: changes end marker label from "Current" to "End" */
  mode?: 'realtime' | 'historical';
  /** For playback animation: the currently animated point */
  animatedPoint?: GpsTrailPoint | null;
  /** Whether playback is currently active */
  isPlaybackActive?: boolean;
}

// Trail line colors
const TRAIL_COLOR = '#3b82f6'; // blue-500
const TRAIL_HIGHLIGHT_COLOR = '#1d4ed8'; // blue-700
const START_MARKER_COLOR = '#22c55e'; // green-500
const END_MARKER_COLOR = '#ef4444'; // red-500
const ANIMATED_MARKER_COLOR = '#f59e0b'; // amber-500

/**
 * Map component showing GPS trail as a connected polyline.
 * Includes start/end markers and interactive point hover.
 */
export function GpsTrailMap({
  trail,
  isLoading,
  employeeName,
  mode = 'realtime',
  animatedPoint,
  isPlaybackActive = false,
}: GpsTrailMapProps) {
  const [selectedPoint, setSelectedPoint] = useState<GpsTrailPoint | null>(null);
  const isHistorical = mode === 'historical';

  if (isLoading) {
    return <GpsTrailMapSkeleton />;
  }

  if (trail.length === 0) {
    return (
      <Card>
        <CardHeader className="pb-2">
          <CardTitle className="text-base font-medium">GPS Trail</CardTitle>
        </CardHeader>
        <CardContent>
          <NoGpsTrailEmptyState />
        </CardContent>
      </Card>
    );
  }

  // Get positions for polyline
  const positions: [number, number][] = trail.map((p) => [p.latitude, p.longitude]);

  // Calculate bounds
  const bounds = L.latLngBounds(positions);

  // Get start and end points
  const startPoint = trail[0];
  const endPoint = trail[trail.length - 1];

  return (
    <Card>
      <CardHeader className="pb-2">
        <CardTitle className="text-base font-medium flex items-center justify-between">
          <span>GPS Trail</span>
          <span className="text-sm font-normal text-slate-500">
            {trail.length} point{trail.length !== 1 ? 's' : ''}
          </span>
        </CardTitle>
      </CardHeader>
      <CardContent className="p-0">
        <div className="h-[400px] rounded-b-lg overflow-hidden">
          <MapContainer
            bounds={bounds}
            boundsOptions={{ padding: [50, 50] }}
            className="h-full w-full"
            scrollWheelZoom={true}
          >
            <TileLayer
              attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
              url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
            />

            {/* Trail polyline */}
            <Polyline
              positions={positions}
              pathOptions={{
                color: TRAIL_COLOR,
                weight: 3,
                opacity: 0.8,
              }}
            />

            {/* Interactive trail points */}
            <TrailPoints
              trail={trail}
              onPointSelect={setSelectedPoint}
              selectedPoint={selectedPoint}
            />

            {/* Start marker */}
            <CircleMarker
              center={[startPoint.latitude, startPoint.longitude]}
              radius={10}
              pathOptions={{
                color: START_MARKER_COLOR,
                fillColor: START_MARKER_COLOR,
                fillOpacity: 1,
                weight: 2,
              }}
            >
              <Popup>
                <div className="text-sm">
                  <p className="font-semibold text-green-700">Start Point</p>
                  <p className="text-slate-600">{format(startPoint.capturedAt, 'h:mm:ss a')}</p>
                  <p className="text-xs text-slate-500 font-mono mt-1">
                    {startPoint.latitude.toFixed(6)}, {startPoint.longitude.toFixed(6)}
                  </p>
                </div>
              </Popup>
            </CircleMarker>

            {/* End marker (only if different from start) */}
            {trail.length > 1 && (
              <CircleMarker
                center={[endPoint.latitude, endPoint.longitude]}
                radius={10}
                pathOptions={{
                  color: END_MARKER_COLOR,
                  fillColor: END_MARKER_COLOR,
                  fillOpacity: 1,
                  weight: 2,
                }}
              >
                <Popup>
                  <div className="text-sm">
                    <p className="font-semibold text-red-700">
                      {isHistorical ? 'End Point' : 'Current Position'}
                    </p>
                    <p className="text-slate-600">{format(endPoint.capturedAt, 'h:mm:ss a')}</p>
                    <p className="text-xs text-slate-500 font-mono mt-1">
                      {endPoint.latitude.toFixed(6)}, {endPoint.longitude.toFixed(6)}
                    </p>
                    {endPoint.accuracy > 100 && (
                      <p className="text-xs text-yellow-600 mt-1">
                        Accuracy: ~{Math.round(endPoint.accuracy)}m
                      </p>
                    )}
                  </div>
                </Popup>
              </CircleMarker>
            )}

            {/* Animated playback marker (for historical mode) */}
            {isPlaybackActive && animatedPoint && (
              <CircleMarker
                center={[animatedPoint.latitude, animatedPoint.longitude]}
                radius={12}
                pathOptions={{
                  color: ANIMATED_MARKER_COLOR,
                  fillColor: ANIMATED_MARKER_COLOR,
                  fillOpacity: 1,
                  weight: 3,
                }}
              >
                <Popup>
                  <div className="text-sm">
                    <p className="font-semibold text-amber-700">Playback Position</p>
                    <p className="text-slate-600">{format(animatedPoint.capturedAt, 'h:mm:ss a')}</p>
                    <p className="text-xs text-slate-500 font-mono mt-1">
                      {animatedPoint.latitude.toFixed(6)}, {animatedPoint.longitude.toFixed(6)}
                    </p>
                  </div>
                </Popup>
              </CircleMarker>
            )}

            <FitBoundsOnUpdate positions={positions} />
          </MapContainer>
        </div>

        {/* Trail legend */}
        <div className="flex items-center justify-center gap-6 py-3 border-t border-slate-100 text-xs text-slate-600">
          <span className="flex items-center gap-1.5">
            <span className="h-3 w-3 rounded-full bg-green-500" />
            Start
          </span>
          <span className="flex items-center gap-1.5">
            <span className="h-3 w-3 rounded-full bg-red-500" />
            {isHistorical ? 'End' : 'Current'}
          </span>
          <span className="flex items-center gap-1.5">
            <span className="h-6 w-0.5 bg-blue-500" />
            Trail
          </span>
          {isPlaybackActive && (
            <span className="flex items-center gap-1.5">
              <span className="h-3 w-3 rounded-full bg-amber-500" />
              Playback
            </span>
          )}
        </div>
      </CardContent>
    </Card>
  );
}

interface TrailPointsProps {
  trail: GpsTrailPoint[];
  onPointSelect: (point: GpsTrailPoint | null) => void;
  selectedPoint: GpsTrailPoint | null;
}

/**
 * Interactive trail points that show details on hover/click.
 * Only show every Nth point for performance with large trails.
 */
function TrailPoints({ trail, onPointSelect, selectedPoint }: TrailPointsProps) {
  // For large trails, only show every Nth point
  const step = trail.length > 100 ? Math.ceil(trail.length / 50) : 1;

  const visiblePoints = useMemo(() => {
    if (step === 1) return trail;
    return trail.filter((_, i) => i % step === 0 || i === trail.length - 1);
  }, [trail, step]);

  return (
    <>
      {visiblePoints.map((point, index) => (
        <CircleMarker
          key={point.id}
          center={[point.latitude, point.longitude]}
          radius={4}
          pathOptions={{
            color: selectedPoint?.id === point.id ? TRAIL_HIGHLIGHT_COLOR : TRAIL_COLOR,
            fillColor: 'white',
            fillOpacity: 1,
            weight: selectedPoint?.id === point.id ? 3 : 2,
          }}
          eventHandlers={{
            click: () => onPointSelect(point),
            mouseover: (e) => {
              e.target.setStyle({ fillColor: TRAIL_HIGHLIGHT_COLOR });
            },
            mouseout: (e) => {
              e.target.setStyle({ fillColor: 'white' });
            },
          }}
        >
          <Popup>
            <div className="text-sm">
              <p className="font-medium text-slate-700">
                {format(point.capturedAt, 'h:mm:ss a')}
              </p>
              <p className="text-xs text-slate-500 font-mono">
                {point.latitude.toFixed(6)}, {point.longitude.toFixed(6)}
              </p>
              {point.accuracy > 50 && (
                <p className="text-xs text-slate-400 mt-1">
                  Accuracy: ~{Math.round(point.accuracy)}m
                </p>
              )}
            </div>
          </Popup>
        </CircleMarker>
      ))}
    </>
  );
}

interface FitBoundsOnUpdateProps {
  positions: [number, number][];
}

function FitBoundsOnUpdate({ positions }: FitBoundsOnUpdateProps) {
  const map = useMap();

  useMemo(() => {
    if (positions.length > 0) {
      const bounds = L.latLngBounds(positions);
      map.fitBounds(bounds, { padding: [50, 50], maxZoom: 16 });
    }
  }, [map, positions]);

  return null;
}

function GpsTrailMapSkeleton() {
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
