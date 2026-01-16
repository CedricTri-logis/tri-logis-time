'use client';

import { useState, useMemo, useCallback } from 'react';
import { MapContainer, TileLayer, Polyline, CircleMarker, Popup, useMap } from 'react-leaflet';
import L from 'leaflet';
import { format } from 'date-fns';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import { Badge } from '@/components/ui/badge';
import { Layers } from 'lucide-react';
import type { MultiShiftGpsPoint, ShiftColorMapping } from '@/types/history';
import { getTrailColorFromPalette, getDimmedColor } from '@/lib/utils/trail-colors';
import { autoSimplifyTrail } from '@/lib/utils/trail-simplify';

import 'leaflet/dist/leaflet.css';

interface MultiShiftMapProps {
  trailsByShift: Map<string, MultiShiftGpsPoint[]>;
  colorMappings: ShiftColorMapping[];
  isLoading?: boolean;
  highlightedShiftId?: string | null;
  onShiftHighlight?: (shiftId: string | null) => void;
}

/**
 * Map component for displaying multiple shift GPS trails with color coding.
 * Supports highlighting individual trails and trail simplification for performance.
 */
export function MultiShiftMap({
  trailsByShift,
  colorMappings,
  isLoading,
  highlightedShiftId,
  onShiftHighlight,
}: MultiShiftMapProps) {
  const [showSimplified, setShowSimplified] = useState(true);

  // Calculate total point count
  const totalPoints = useMemo(() => {
    let count = 0;
    trailsByShift.forEach((trail) => {
      count += trail.length;
    });
    return count;
  }, [trailsByShift]);

  // Apply simplification if needed
  const displayTrails = useMemo(() => {
    const result = new Map<string, MultiShiftGpsPoint[]>();

    trailsByShift.forEach((trail, shiftId) => {
      if (showSimplified && trail.length > 500) {
        result.set(shiftId, autoSimplifyTrail(trail) as MultiShiftGpsPoint[]);
      } else {
        result.set(shiftId, trail);
      }
    });

    return result;
  }, [trailsByShift, showSimplified]);

  // Get simplified point count for display
  const simplifiedPoints = useMemo(() => {
    let count = 0;
    displayTrails.forEach((trail) => {
      count += trail.length;
    });
    return count;
  }, [displayTrails]);

  // Calculate bounds from all trails
  const bounds = useMemo(() => {
    const allPositions: [number, number][] = [];
    displayTrails.forEach((trail) => {
      trail.forEach((point) => {
        allPositions.push([point.latitude, point.longitude]);
      });
    });
    if (allPositions.length === 0) return null;
    return L.latLngBounds(allPositions);
  }, [displayTrails]);

  // Get color for a shift (with dimming support)
  const getShiftColor = useCallback(
    (shiftId: string, index: number): string => {
      if (highlightedShiftId && highlightedShiftId !== shiftId) {
        return getDimmedColor(index);
      }
      return getTrailColorFromPalette(index);
    },
    [highlightedShiftId]
  );

  if (isLoading) {
    return (
      <Card>
        <CardHeader className="pb-2">
          <Skeleton className="h-5 w-32" />
        </CardHeader>
        <CardContent className="p-0">
          <Skeleton className="h-[500px] w-full rounded-b-lg" />
        </CardContent>
      </Card>
    );
  }

  if (displayTrails.size === 0 || !bounds) {
    return (
      <Card>
        <CardHeader className="pb-2">
          <CardTitle className="text-base font-medium">Multi-Shift GPS Trails</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="h-[200px] flex items-center justify-center text-sm text-slate-500">
            No GPS data available for selected shifts
          </div>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card>
      <CardHeader className="pb-2">
        <div className="flex items-center justify-between">
          <CardTitle className="text-base font-medium">Multi-Shift GPS Trails</CardTitle>
          <div className="flex items-center gap-3">
            {totalPoints > 500 && (
              <Button
                variant="outline"
                size="sm"
                onClick={() => setShowSimplified(!showSimplified)}
              >
                <Layers className="h-4 w-4 mr-2" />
                {showSimplified ? 'Show Full Detail' : 'Simplify'}
              </Button>
            )}
            <Badge variant="secondary" className="font-mono">
              {showSimplified && totalPoints !== simplifiedPoints
                ? `${simplifiedPoints.toLocaleString()} / ${totalPoints.toLocaleString()}`
                : totalPoints.toLocaleString()}{' '}
              points
            </Badge>
          </div>
        </div>
      </CardHeader>
      <CardContent className="p-0">
        <div className="h-[500px] rounded-b-lg overflow-hidden">
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

            {/* Render each shift's trail */}
            {Array.from(displayTrails.entries()).map(([shiftId, trail], index) => {
              const positions: [number, number][] = trail.map((p) => [
                p.latitude,
                p.longitude,
              ]);
              const color = getShiftColor(shiftId, index);
              const isHighlighted = highlightedShiftId === shiftId;
              const mapping = colorMappings.find((m) => m.shiftId === shiftId);
              const shiftDate = mapping?.shiftDate ?? trail[0]?.shiftDate;

              return (
                <Polyline
                  key={shiftId}
                  positions={positions}
                  pathOptions={{
                    color,
                    weight: isHighlighted ? 5 : 3,
                    opacity: highlightedShiftId && !isHighlighted ? 0.4 : 0.8,
                  }}
                  eventHandlers={{
                    click: () => onShiftHighlight?.(shiftId),
                    mouseover: (e) => {
                      e.target.setStyle({ weight: 5 });
                    },
                    mouseout: (e) => {
                      e.target.setStyle({ weight: isHighlighted ? 5 : 3 });
                    },
                  }}
                >
                  <Popup>
                    <div className="text-sm">
                      <p className="font-semibold">{shiftDate}</p>
                      <p className="text-slate-600">
                        {trail.length} GPS points
                      </p>
                      {trail[0] && (
                        <p className="text-xs text-slate-500">
                          {format(trail[0].capturedAt, 'h:mm a')} -{' '}
                          {format(trail[trail.length - 1].capturedAt, 'h:mm a')}
                        </p>
                      )}
                    </div>
                  </Popup>
                </Polyline>
              );
            })}

            {/* Start markers for each trail */}
            {Array.from(displayTrails.entries()).map(([shiftId, trail], index) => {
              if (trail.length === 0) return null;
              const startPoint = trail[0];
              const color = getShiftColor(shiftId, index);

              return (
                <CircleMarker
                  key={`start-${shiftId}`}
                  center={[startPoint.latitude, startPoint.longitude]}
                  radius={6}
                  pathOptions={{
                    color,
                    fillColor: color,
                    fillOpacity: highlightedShiftId && highlightedShiftId !== shiftId ? 0.4 : 1,
                    weight: 2,
                  }}
                >
                  <Popup>
                    <div className="text-sm">
                      <p className="font-semibold">Start - {startPoint.shiftDate}</p>
                      <p className="text-slate-600">
                        {format(startPoint.capturedAt, 'h:mm:ss a')}
                      </p>
                    </div>
                  </Popup>
                </CircleMarker>
              );
            })}

            <FitBoundsOnUpdate bounds={bounds} />
          </MapContainer>
        </div>
      </CardContent>
    </Card>
  );
}

function FitBoundsOnUpdate({ bounds }: { bounds: L.LatLngBounds }) {
  const map = useMap();

  useMemo(() => {
    map.fitBounds(bounds, { padding: [50, 50], maxZoom: 16 });
  }, [map, bounds]);

  return null;
}
