'use client';

import { useMemo, useState, useCallback, useEffect } from 'react';
import { MapContainer, TileLayer, Polyline, CircleMarker, Popup, useMap } from 'react-leaflet';
import L from 'leaflet';
import { format } from 'date-fns';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';
import type { TimelineSegment, LocationType } from '@/types/location';
import type { GpsTrailPoint } from '@/types/monitoring';
import {
  getSegmentColor,
  getSegmentLabel,
  SEGMENT_TYPE_COLORS,
  LOCATION_TYPE_COLORS,
  formatDuration,
} from '@/lib/utils/segment-colors';
import { MapPin, Navigation, Clock } from 'lucide-react';

import 'leaflet/dist/leaflet.css';

// Marker colors
const START_MARKER_COLOR = '#22c55e'; // green-500
const END_MARKER_COLOR = '#ef4444'; // red-500

/**
 * GPS point with segment information for coloring the trail
 */
export interface SegmentedGpsPoint extends GpsTrailPoint {
  segmentIndex?: number;
  segmentType?: 'matched' | 'travel' | 'unmatched';
  locationType?: LocationType | null;
  locationName?: string | null;
}

interface SegmentedTrailMapProps {
  trail: GpsTrailPoint[];
  segments: TimelineSegment[];
  isLoading?: boolean;
  selectedSegment?: TimelineSegment | null;
  onSegmentClick?: (segment: TimelineSegment) => void;
  mode?: 'realtime' | 'historical';
  className?: string;
}

/**
 * Map component showing GPS trail colored by timeline segments.
 * Each segment of the trail is colored according to its classification
 * (matched location type, travel, or unmatched).
 */
export function SegmentedTrailMap({
  trail,
  segments,
  isLoading = false,
  selectedSegment = null,
  onSegmentClick,
  mode = 'historical',
  className = '',
}: SegmentedTrailMapProps) {
  const isHistorical = mode === 'historical';

  if (isLoading) {
    return <SegmentedTrailMapSkeleton className={className} />;
  }

  if (trail.length === 0) {
    return (
      <Card className={className}>
        <CardHeader className="pb-2">
          <CardTitle className="text-base font-medium">Segmented GPS Trail</CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col items-center justify-center py-12">
          <MapPin className="h-12 w-12 text-slate-300 mb-4" />
          <h3 className="text-lg font-medium text-slate-900 mb-1">No GPS data</h3>
          <p className="text-sm text-slate-500">
            No GPS points available for this shift.
          </p>
        </CardContent>
      </Card>
    );
  }

  // Calculate bounds
  const positions: [number, number][] = trail.map((p) => [p.latitude, p.longitude]);
  const bounds = L.latLngBounds(positions);

  // Get start and end points
  const startPoint = trail[0];
  const endPoint = trail[trail.length - 1];

  // Build colored polyline segments
  const trailSegments = buildTrailSegments(trail, segments);

  return (
    <Card className={className}>
      <CardHeader className="pb-2">
        <CardTitle className="text-base font-medium flex items-center justify-between">
          <span className="flex items-center gap-2">
            <Navigation className="h-4 w-4 text-slate-500" />
            Segmented GPS Trail
          </span>
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

            {/* Render each segment as a colored polyline */}
            {trailSegments.map((seg, index) => (
              <SegmentPolyline
                key={`segment-${index}`}
                positions={seg.positions}
                color={seg.color}
                segment={seg.segment}
                isSelected={selectedSegment?.segmentIndex === seg.segment?.segmentIndex}
                onClick={onSegmentClick}
              />
            ))}

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

            {/* End marker */}
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
                  </div>
                </Popup>
              </CircleMarker>
            )}

            <FitBoundsOnChange positions={positions} />
          </MapContainer>
        </div>

        {/* Segmented trail legend */}
        <TrailLegend segments={segments} isHistorical={isHistorical} />
      </CardContent>
    </Card>
  );
}

/**
 * A single segment polyline with its color and click handler
 */
interface SegmentPolylineProps {
  positions: [number, number][];
  color: string;
  segment: TimelineSegment | null;
  isSelected: boolean;
  onClick?: (segment: TimelineSegment) => void;
}

function SegmentPolyline({
  positions,
  color,
  segment,
  isSelected,
  onClick,
}: SegmentPolylineProps) {
  if (positions.length < 2) return null;

  const handleClick = useCallback(() => {
    if (segment && onClick) {
      onClick(segment);
    }
  }, [segment, onClick]);

  return (
    <Polyline
      positions={positions}
      pathOptions={{
        color: color,
        weight: isSelected ? 6 : 4,
        opacity: isSelected ? 1 : 0.8,
        lineCap: 'round',
        lineJoin: 'round',
      }}
      eventHandlers={{
        click: handleClick,
      }}
    >
      {segment && (
        <Popup>
          <SegmentPopupContent segment={segment} />
        </Popup>
      )}
    </Polyline>
  );
}

/**
 * Popup content when clicking a segment on the map
 */
function SegmentPopupContent({ segment }: { segment: TimelineSegment }) {
  const color = getSegmentColor(segment.segmentType, segment.locationType);
  const label = getSegmentLabel(
    segment.segmentType,
    segment.locationName,
    segment.locationType
  );

  return (
    <div className="min-w-[180px]">
      <div className="flex items-center gap-2 mb-2">
        <div
          className="h-3 w-3 rounded-full"
          style={{ backgroundColor: color }}
        />
        <span className="font-medium text-sm">{label}</span>
      </div>
      <div className="space-y-1 text-xs text-slate-600">
        <div className="flex items-center gap-1.5">
          <Clock className="h-3 w-3" />
          <span>{formatDuration(segment.durationSeconds)}</span>
        </div>
        <div>
          {format(segment.startTime, 'h:mm a')} - {format(segment.endTime, 'h:mm a')}
        </div>
        <div className="text-slate-400">
          {segment.pointCount} GPS point{segment.pointCount !== 1 ? 's' : ''}
        </div>
      </div>
    </div>
  );
}

/**
 * Legend showing segment colors used in the trail
 */
interface TrailLegendProps {
  segments: TimelineSegment[];
  isHistorical: boolean;
}

function TrailLegend({ segments, isHistorical }: TrailLegendProps) {
  // Get unique segment types and location types used
  const legendItems = useMemo(() => {
    const items: Array<{ color: string; label: string }> = [];
    const seen = new Set<string>();

    for (const segment of segments) {
      const color = getSegmentColor(segment.segmentType, segment.locationType);
      let label: string;

      if (segment.segmentType === 'matched' && segment.locationType) {
        label = LOCATION_TYPE_COLORS[segment.locationType].label;
      } else {
        label = SEGMENT_TYPE_COLORS[segment.segmentType].label;
      }

      const key = `${color}-${label}`;
      if (!seen.has(key)) {
        seen.add(key);
        items.push({ color, label });
      }
    }

    return items;
  }, [segments]);

  return (
    <div className="flex flex-wrap items-center gap-4 py-3 px-4 border-t border-slate-100 text-xs text-slate-600">
      <span className="flex items-center gap-1.5">
        <span className="h-3 w-3 rounded-full bg-green-500" />
        Start
      </span>
      <span className="flex items-center gap-1.5">
        <span className="h-3 w-3 rounded-full bg-red-500" />
        {isHistorical ? 'End' : 'Current'}
      </span>
      <span className="text-slate-300">|</span>
      {legendItems.map((item, index) => (
        <span key={index} className="flex items-center gap-1.5">
          <span
            className="h-4 w-1 rounded"
            style={{ backgroundColor: item.color }}
          />
          {item.label}
        </span>
      ))}
    </div>
  );
}

/**
 * Auto-fit map bounds when positions change
 */
function FitBoundsOnChange({ positions }: { positions: [number, number][] }) {
  const map = useMap();

  useEffect(() => {
    if (positions.length > 0) {
      const bounds = L.latLngBounds(positions);
      map.fitBounds(bounds, { padding: [50, 50], maxZoom: 16 });
    }
  }, [map, positions]);

  return null;
}

/**
 * Loading skeleton for the map
 */
function SegmentedTrailMapSkeleton({ className = '' }: { className?: string }) {
  return (
    <Card className={className}>
      <CardHeader className="pb-2">
        <div className="flex items-center justify-between">
          <Skeleton className="h-5 w-36" />
          <Skeleton className="h-4 w-16" />
        </div>
      </CardHeader>
      <CardContent className="p-0">
        <Skeleton className="h-[400px] w-full rounded-b-lg" />
      </CardContent>
    </Card>
  );
}

// =============================================================================
// Helper Functions
// =============================================================================

interface TrailSegmentData {
  positions: [number, number][];
  color: string;
  segment: TimelineSegment | null;
}

/**
 * Build colored trail segments by matching GPS points to timeline segments.
 * Each GPS point is assigned to a segment based on its capture time.
 */
function buildTrailSegments(
  trail: GpsTrailPoint[],
  segments: TimelineSegment[]
): TrailSegmentData[] {
  if (trail.length === 0 || segments.length === 0) {
    // No segments, return single gray trail
    return [
      {
        positions: trail.map((p) => [p.latitude, p.longitude]),
        color: '#6b7280', // gray-500
        segment: null,
      },
    ];
  }

  const result: TrailSegmentData[] = [];
  let currentSegmentIndex = 0;
  let currentPositions: [number, number][] = [];
  let currentSegment = segments[0];

  for (const point of trail) {
    const pointTime = point.capturedAt.getTime();

    // Find the matching segment for this point
    while (
      currentSegmentIndex < segments.length - 1 &&
      pointTime >= segments[currentSegmentIndex + 1].startTime.getTime()
    ) {
      // Save current segment before moving to next
      if (currentPositions.length > 0) {
        result.push({
          positions: [...currentPositions],
          color: getSegmentColor(currentSegment.segmentType, currentSegment.locationType),
          segment: currentSegment,
        });
        // Keep last position for continuity
        currentPositions = [currentPositions[currentPositions.length - 1]];
      }
      currentSegmentIndex++;
      currentSegment = segments[currentSegmentIndex];
    }

    currentPositions.push([point.latitude, point.longitude]);
  }

  // Don't forget the last segment
  if (currentPositions.length > 0) {
    result.push({
      positions: currentPositions,
      color: getSegmentColor(currentSegment.segmentType, currentSegment.locationType),
      segment: currentSegment,
    });
  }

  return result;
}

/**
 * Compact version of segmented trail map for smaller displays
 */
interface CompactSegmentedTrailMapProps {
  trail: GpsTrailPoint[];
  segments: TimelineSegment[];
  isLoading?: boolean;
  className?: string;
}

export function CompactSegmentedTrailMap({
  trail,
  segments,
  isLoading = false,
  className = 'h-[250px]',
}: CompactSegmentedTrailMapProps) {
  if (isLoading) {
    return <Skeleton className={`w-full ${className}`} />;
  }

  if (trail.length === 0) {
    return (
      <div className={`flex items-center justify-center bg-slate-100 rounded-lg ${className}`}>
        <p className="text-sm text-slate-500">No GPS data</p>
      </div>
    );
  }

  const positions: [number, number][] = trail.map((p) => [p.latitude, p.longitude]);
  const bounds = L.latLngBounds(positions);
  const trailSegments = buildTrailSegments(trail, segments);

  return (
    <div className={className}>
      <MapContainer
        bounds={bounds}
        boundsOptions={{ padding: [30, 30] }}
        className="h-full w-full rounded-lg"
        scrollWheelZoom={true}
        zoomControl={false}
      >
        <TileLayer
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
          url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
        />
        {trailSegments.map((seg, index) => (
          <Polyline
            key={`segment-${index}`}
            positions={seg.positions}
            pathOptions={{
              color: seg.color,
              weight: 3,
              opacity: 0.8,
            }}
          />
        ))}
      </MapContainer>
    </div>
  );
}
