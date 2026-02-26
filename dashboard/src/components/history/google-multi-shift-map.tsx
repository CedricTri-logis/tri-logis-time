'use client';

import { useState, useMemo, useEffect, useRef } from 'react';
import {
  APIProvider,
  Map as GoogleMap,
  useMap,
  AdvancedMarker,
} from '@vis.gl/react-google-maps';
import { format } from 'date-fns';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import { Badge } from '@/components/ui/badge';
import { Layers, Activity } from 'lucide-react';
import type { MultiShiftGpsPoint, ShiftColorMapping } from '@/types/history';
import { getTrailColorFromPalette, getDimmedColor } from '@/lib/utils/trail-colors';
import { autoSimplifyTrail } from '@/lib/utils/trail-simplify';

interface MultiShiftMapProps {
  trailsByShift: Map<string, MultiShiftGpsPoint[]>;
  colorMappings: ShiftColorMapping[];
  isLoading?: boolean;
  highlightedShiftId?: string | null;
  onShiftHighlight?: (shiftId: string | null) => void;
  apiKey?: string;
}

export function GoogleMultiShiftMap({
  trailsByShift,
  colorMappings,
  isLoading,
  highlightedShiftId,
  onShiftHighlight,
  apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY || '',
}: MultiShiftMapProps) {
  const [showSimplified, setShowSimplified] = useState(true);

  const totalPoints = useMemo(() => {
    let count = 0;
    trailsByShift.forEach((trail) => count += trail.length);
    return count;
  }, [trailsByShift]);

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

  if (isLoading) return <MapSkeleton />;

  return (
    <Card className="overflow-hidden border-slate-200 shadow-xl">
      <CardHeader className="bg-white/80 backdrop-blur-md border-b border-slate-100 py-3">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            <div className="bg-orange-50 p-1.5 rounded-lg">
              <Activity className="h-4 w-4 text-orange-600" />
            </div>
            <div>
              <CardTitle className="text-sm font-semibold text-slate-900">
                Analyse Multi-Services
              </CardTitle>
              <p className="text-[10px] text-slate-500 font-medium">
                Comparaison visuelle des trajets historiques
              </p>
            </div>
          </div>
          <div className="flex items-center gap-2">
             <Button
                variant="outline"
                size="sm"
                className="h-7 text-[10px] font-bold uppercase"
                onClick={() => setShowSimplified(!showSimplified)}
              >
                {showSimplified ? 'Détails complets' : 'Simplifier'}
              </Button>
              <Badge variant="secondary" className="text-[10px] h-6">
                {totalPoints.toLocaleString()} pts
              </Badge>
          </div>
        </div>
      </CardHeader>

      <CardContent className="p-0">
        <div className="h-[500px] w-full">
          <APIProvider apiKey={apiKey}>
            <GoogleMap
              defaultCenter={{ lat: 45.5017, lng: -73.5673 }}
              defaultZoom={12}
              mapId="multi_shift_map"
              disableDefaultUI={true}
              zoomControl={true}
            >
              {Array.from(displayTrails.entries()).map(([shiftId, trail], index) => (
                <div key={shiftId}>
                  <ShiftPolyline 
                    shiftId={shiftId}
                    trail={trail}
                    color={highlightedShiftId && highlightedShiftId !== shiftId ? getDimmedColor(index) : getTrailColorFromPalette(index)}
                    isHighlighted={highlightedShiftId === shiftId}
                    isDimmed={!!highlightedShiftId && highlightedShiftId !== shiftId}
                    onClick={() => onShiftHighlight?.(shiftId)}
                  />
                  {trail.length > 0 && (
                    <AdvancedMarker position={{ lat: trail[0].latitude, lng: trail[0].longitude }}>
                       <div 
                         className="w-2.5 h-2.5 rounded-full border border-white shadow-sm"
                         style={{ backgroundColor: getTrailColorFromPalette(index) }}
                       />
                    </AdvancedMarker>
                  )}
                </div>
              ))}
              <AutoFitTrails trails={displayTrails} />
            </GoogleMap>
          </APIProvider>
        </div>
      </CardContent>
    </Card>
  );
}

function ShiftPolyline({ shiftId, trail, color, isHighlighted, isDimmed, onClick }: any) {
  const map = useMap();
  useEffect(() => {
    if (!map) return;
    const poly = new google.maps.Polyline({
      path: trail.map((p: any) => ({ lat: p.latitude, lng: p.longitude })),
      map,
      strokeColor: color,
      strokeOpacity: isDimmed ? 0.3 : 0.8,
      strokeWeight: isHighlighted ? 6 : 3,
      zIndex: isHighlighted ? 100 : 1,
    });
    poly.addListener('click', onClick);
    return () => poly.setMap(null);
  }, [map, trail, color, isHighlighted, isDimmed, onClick]);
  return null;
}

function AutoFitTrails({ trails }: { trails: Map<string, MultiShiftGpsPoint[]> }) {
  const map = useMap();
  useEffect(() => {
    if (!map || trails.size === 0) return;
    const bounds = new google.maps.LatLngBounds();
    trails.forEach(trail => trail.forEach(p => bounds.extend({ lat: p.latitude, lng: p.longitude })));
    if (!bounds.isEmpty()) {
      map.fitBounds(bounds, { top: 50, right: 50, bottom: 50, left: 50 });
    }
  }, [map, trails]);
  return null;
}

function MapSkeleton() {
  return <Skeleton className="h-[500px] w-full rounded-b-lg" />;
}
