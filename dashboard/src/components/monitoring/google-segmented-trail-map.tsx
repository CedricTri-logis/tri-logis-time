'use client';

import { useMemo, useState, useEffect, useRef } from 'react';
import {
  APIProvider,
  Map,
  useMap,
  AdvancedMarker,
  InfoWindow,
} from '@vis.gl/react-google-maps';
import { format } from 'date-fns';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';
import { Navigation, Clock, MapPin } from 'lucide-react';
import type { TimelineSegment } from '@/types/location';
import type { GpsTrailPoint } from '@/types/monitoring';
import { filterTrailPoints } from '@/lib/gps-trail-filter';
import {
  getSegmentColor,
  getSegmentLabel,
  formatDuration,
} from '@/lib/utils/segment-colors';

interface GoogleSegmentedTrailMapProps {
  trail: GpsTrailPoint[];
  segments: TimelineSegment[];
  isLoading?: boolean;
  selectedSegment?: TimelineSegment | null;
  onSegmentClick?: (segment: TimelineSegment) => void;
  mode?: 'realtime' | 'historical';
  apiKey?: string;
}

export function GoogleSegmentedTrailMap({
  trail,
  segments,
  isLoading,
  selectedSegment,
  onSegmentClick,
  mode = 'historical',
  apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY || '',
}: GoogleSegmentedTrailMapProps) {
  
  const [selectedPoint, setSelectedPoint] = useState<GpsTrailPoint | null>(null);

  const { points: filteredPoints } = useMemo(
    () => filterTrailPoints(trail),
    [trail],
  );

  if (isLoading) return <MapSkeleton />;
  if (trail.length === 0) return <EmptyState />;

  const startPoint = trail[0];
  const endPoint = trail[trail.length - 1];

  return (
    <Card className="overflow-hidden border-slate-200 shadow-xl">
      <CardHeader className="bg-white/80 backdrop-blur-md border-b border-slate-100 py-3">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            <div className="bg-indigo-50 p-1.5 rounded-lg">
              <Layers className="h-4 w-4 text-indigo-600" />
            </div>
            <div>
              <CardTitle className="text-sm font-semibold text-slate-900">
                Analyse des Segments
              </CardTitle>
              <p className="text-[10px] text-slate-500 font-medium">
                Trajet décomposé par activité
              </p>
            </div>
          </div>
        </div>
      </CardHeader>

      <CardContent className="p-0 relative">
        <div className="h-[500px] w-full">
          <APIProvider apiKey={apiKey}>
            <Map
              defaultCenter={{ lat: endPoint.latitude, lng: endPoint.longitude }}
              defaultZoom={15}
              mapId="segmented_map"
              disableDefaultUI={true}
              zoomControl={true}
            >
              <SegmentedPolylines 
                trail={trail} 
                segments={segments} 
                selectedSegmentId={selectedSegment?.segmentIndex}
                onSegmentClick={onSegmentClick}
              />

              {/* Individual GPS points (filtered: movement + stationary boundaries) */}
              {filteredPoints.map((point) => (
                <AdvancedMarker
                  key={point.id}
                  position={{ lat: point.latitude, lng: point.longitude }}
                  onClick={() => setSelectedPoint(point)}
                  zIndex={1}
                >
                  <div className="w-2 h-2 rounded-full bg-slate-500/70 border border-white/80 shadow-sm hover:scale-150 transition-transform cursor-pointer" />
                </AdvancedMarker>
              ))}

              {/* InfoWindow for selected point */}
              {selectedPoint && (
                <InfoWindow
                  position={{ lat: selectedPoint.latitude, lng: selectedPoint.longitude }}
                  onCloseClick={() => setSelectedPoint(null)}
                  headerDisabled
                >
                  <div className="text-sm p-1 min-w-[140px]">
                    <p className="font-semibold text-slate-800">
                      {format(selectedPoint.capturedAt, 'h:mm:ss a')}
                    </p>
                    <p className="text-xs text-slate-500 font-mono mt-1">
                      {selectedPoint.latitude.toFixed(6)}, {selectedPoint.longitude.toFixed(6)}
                    </p>
                    {selectedPoint.accuracy > 50 && (
                      <p className="text-xs text-amber-600 mt-1">
                        Précision: ~{Math.round(selectedPoint.accuracy)}m
                      </p>
                    )}
                  </div>
                </InfoWindow>
              )}

              {/* Start marker */}
              <AdvancedMarker position={{ lat: startPoint.latitude, lng: startPoint.longitude }} zIndex={10}>
                <div className="bg-green-600 w-3 h-3 rounded-full border-2 border-white shadow-lg" />
              </AdvancedMarker>

              {/* End / Live marker */}
              <AdvancedMarker position={{ lat: endPoint.latitude, lng: endPoint.longitude }} zIndex={10}>
                <div className={`w-4 h-4 rounded-full border-2 border-white shadow-lg ${mode === 'realtime' ? 'bg-blue-600 animate-pulse' : 'bg-red-600'}`} />
              </AdvancedMarker>

              <AutoFitBounds points={trail} />
            </Map>
          </APIProvider>
        </div>
      </CardContent>
    </Card>
  );
}

function SegmentedPolylines({ 
  trail, 
  segments, 
  selectedSegmentId,
  onSegmentClick 
}: { 
  trail: GpsTrailPoint[], 
  segments: TimelineSegment[],
  selectedSegmentId?: number,
  onSegmentClick?: (segment: TimelineSegment) => void
}) {
  const map = useMap();
  const polylinesRef = useRef<google.maps.Polyline[]>([]);

  useEffect(() => {
    if (!map || trail.length === 0 || segments.length === 0) return;

    // Clear old polylines
    polylinesRef.current.forEach(p => p.setMap(null));
    polylinesRef.current = [];

    // Group trail into segments
    let currentSegmentIndex = 0;
    let currentPath: google.maps.LatLngLiteral[] = [];
    
    trail.forEach((point, idx) => {
      const pointTime = point.capturedAt.getTime();
      
      // Check if we need to switch segment
      while (
        currentSegmentIndex < segments.length - 1 &&
        pointTime >= segments[currentSegmentIndex + 1].startTime.getTime()
      ) {
        if (currentPath.length >= 2) {
          createPolyline(currentPath, segments[currentSegmentIndex]);
        }
        currentPath = currentPath.length > 0 ? [currentPath[currentPath.length - 1]] : [];
        currentSegmentIndex++;
      }
      
      currentPath.push({ lat: point.latitude, lng: point.longitude });
    });

    if (currentPath.length >= 2) {
      createPolyline(currentPath, segments[currentSegmentIndex]);
    }

    function createPolyline(path: google.maps.LatLngLiteral[], segment: TimelineSegment) {
      const isSelected = selectedSegmentId === segment.segmentIndex;
      const color = getSegmentColor(segment.segmentType, segment.locationType);
      
      const poly = new google.maps.Polyline({
        path,
        map,
        strokeColor: color,
        strokeOpacity: isSelected ? 1 : 0.7,
        strokeWeight: isSelected ? 8 : 5,
        zIndex: isSelected ? 100 : 1,
      });

      poly.addListener('click', () => {
        if (onSegmentClick) onSegmentClick(segment);
      });

      polylinesRef.current.push(poly);
    }

    return () => {
      polylinesRef.current.forEach(p => p.setMap(null));
    };
  }, [map, trail, segments, selectedSegmentId]);

  return null;
}

import { Layers } from 'lucide-react';

function AutoFitBounds({ points }: { points: GpsTrailPoint[] }) {
  const map = useMap();
  const lastCountRef = useRef(0);

  useEffect(() => {
    if (!map || points.length === 0) return;

    // Only auto-fit on initial load or when new points are added
    if (lastCountRef.current === 0 || points.length > lastCountRef.current) {
      const bounds = new google.maps.LatLngBounds();
      points.forEach(p => bounds.extend({ lat: p.latitude, lng: p.longitude }));
      map.fitBounds(bounds, { top: 50, right: 50, bottom: 50, left: 50 });
    }
    lastCountRef.current = points.length;
  }, [map, points]);

  return null;
}

function MapSkeleton() {
  return <Skeleton className="h-[500px] w-full rounded-xl" />;
}

function EmptyState() {
  return (
    <div className="h-[500px] flex items-center justify-center bg-slate-50 border-2 border-dashed rounded-xl">
      <p className="text-slate-400">Aucune donnée à segmenter</p>
    </div>
  );
}
