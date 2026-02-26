'use client';

import { useMemo, useState, useCallback, useEffect, useRef } from 'react';
import {
  APIProvider,
  Map,
  useMap,
  AdvancedMarker,
  Pin,
  InfoWindow,
} from '@vis.gl/react-google-maps';
import { format } from 'date-fns';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';
import { Play, Square, Navigation, Map as MapIcon, Layers } from 'lucide-react';
import type { GpsTrailPoint } from '@/types/monitoring';
import { filterTrailPoints, formatDuration } from '@/lib/gps-trail-filter';

// Professional "Silver" map style to reduce visual noise
const SILVER_MAP_ID = '8e0a97af9386fefc'; // Note: In production, you'd create this in Google Cloud Console
const SILVER_MAP_STYLE = [
  { elementType: "geometry", stylers: [{ color: "#f5f5f5" }] },
  { elementType: "labels.icon", stylers: [{ visibility: "off" }] },
  { elementType: "labels.text.fill", stylers: [{ color: "#616161" }] },
  { elementType: "labels.text.stroke", stylers: [{ color: "#f5f5f5" }] },
  { featureType: "administrative.land_parcel", elementType: "labels.text.fill", stylers: [{ color: "#bdbdbd" }] },
  { featureType: "poi", elementType: "geometry", stylers: [{ color: "#eeeeee" }] },
  { featureType: "poi", elementType: "labels.text.fill", stylers: [{ color: "#757575" }] },
  { featureType: "poi.park", elementType: "geometry", stylers: [{ color: "#e5e5e5" }] },
  { featureType: "poi.park", elementType: "labels.text.fill", stylers: [{ color: "#9e9e9e" }] },
  { featureType: "road", elementType: "geometry", stylers: [{ color: "#ffffff" }] },
  { featureType: "road.arterial", elementType: "labels.text.fill", stylers: [{ color: "#757575" }] },
  { featureType: "road.highway", elementType: "geometry", stylers: [{ color: "#dadada" }] },
  { featureType: "road.highway", elementType: "labels.text.fill", stylers: [{ color: "#616161" }] },
  { featureType: "road.local", elementType: "labels.text.fill", stylers: [{ color: "#9e9e9e" }] },
  { featureType: "transit.line", elementType: "geometry", stylers: [{ color: "#e5e5e5" }] },
  { featureType: "transit.station", elementType: "geometry", stylers: [{ color: "#eeeeee" }] },
  { featureType: "water", elementType: "geometry", stylers: [{ color: "#c9c9c9" }] },
  { featureType: "water", elementType: "labels.text.fill", stylers: [{ color: "#9e9e9e" }] }
];

interface GoogleGpsTrailMapProps {
  trail: GpsTrailPoint[];
  isLoading?: boolean;
  employeeName?: string;
  mode?: 'realtime' | 'historical';
  apiKey?: string;
  animatedPoint?: GpsTrailPoint | null;
  isPlaybackActive?: boolean;
}

export function GoogleGpsTrailMap({
  trail,
  isLoading,
  employeeName,
  mode = 'realtime',
  apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY || '',
  animatedPoint,
  isPlaybackActive,
}: GoogleGpsTrailMapProps) {
  const [selectedPoint, setSelectedPoint] = useState<GpsTrailPoint | null>(null);
  const [mapType, setMapType] = useState<'roadmap' | 'satellite' | 'hybrid'>('roadmap');

  const { points: filteredPoints, stationaryZones } = useMemo(
    () => filterTrailPoints(trail),
    [trail]
  );

  if (isLoading) return <MapSkeleton />;
  if (trail.length === 0) return <EmptyState />;

  const startPoint = trail[0];
  const endPoint = trail[trail.length - 1];

  return (
    <Card className="overflow-hidden border-slate-200 shadow-lg">
      <CardHeader className="bg-white/80 backdrop-blur-md border-b border-slate-100 py-3">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            <div className="bg-blue-50 p-1.5 rounded-lg">
              <Navigation className="h-4 w-4 text-blue-600" />
            </div>
            <div>
              <CardTitle className="text-sm font-semibold text-slate-900">
                Suivi GPS Premium
              </CardTitle>
              <p className="text-[10px] text-slate-500 font-medium">
                {filteredPoints.length} points optimisés • {stationaryZones.length} arrêts détectés
              </p>
            </div>
          </div>
          
          <div className="flex items-center gap-1 bg-slate-50 p-1 rounded-md border border-slate-100">
             <button 
               onClick={() => setMapType('roadmap')}
               className={`p-1.5 rounded transition-all ${mapType === 'roadmap' ? 'bg-white shadow-sm text-blue-600' : 'text-slate-400 hover:text-slate-600'}`}
             >
               <MapIcon className="h-3.5 w-3.5" />
             </button>
             <button 
               onClick={() => setMapType('hybrid')}
               className={`p-1.5 rounded transition-all ${mapType === 'hybrid' ? 'bg-white shadow-sm text-blue-600' : 'text-slate-400 hover:text-slate-600'}`}
             >
               <Layers className="h-3.5 w-3.5" />
             </button>
          </div>
        </div>
      </CardHeader>

      <CardContent className="p-0 relative">
        <div className="h-[500px] w-full">
          <APIProvider apiKey={apiKey}>
            <Map
              defaultCenter={{ lat: endPoint.latitude, lng: endPoint.longitude }}
              defaultZoom={15}
              mapId={SILVER_MAP_ID}
              styles={mapType === 'roadmap' ? SILVER_MAP_STYLE : []}
              mapTypeId={mapType}
              disableDefaultUI={true}
              zoomControl={true}
              mapTypeControl={false}
              streetViewControl={true}
              fullscreenControl={false}
            >
              {/* The actual tracé (Polyline) */}
              <TrailPolyline points={filteredPoints} />

              {/* Start Marker */}
              <AdvancedMarker position={{ lat: startPoint.latitude, lng: startPoint.longitude }}>
                <div className="relative group">
                  <div className="absolute -inset-2 bg-green-500/20 rounded-full blur-sm group-hover:bg-green-500/40 transition-all" />
                  <div className="relative bg-green-600 text-white p-1.5 rounded-full border-2 border-white shadow-xl">
                    <Play className="h-3 w-3 fill-current ml-0.5" />
                  </div>
                </div>
              </AdvancedMarker>

              {/* End / Live Marker */}
              <AdvancedMarker position={{ lat: endPoint.latitude, lng: endPoint.longitude }}>
                <div className="relative">
                  {mode === 'realtime' && (
                    <div className="absolute -inset-4 bg-blue-500/30 rounded-full animate-ping pointer-events-none" />
                  )}
                  <div className={`relative ${mode === 'realtime' ? 'bg-blue-600' : 'bg-red-600'} text-white p-2 rounded-full border-2 border-white shadow-2xl`}>
                    <Navigation className="h-4 w-4 fill-current rotate-45" />
                  </div>
                </div>
              </AdvancedMarker>

              {/* Playback Marker */}
              {isPlaybackActive && animatedPoint && (
                <AdvancedMarker position={{ lat: animatedPoint.latitude, lng: animatedPoint.longitude }}>
                  <div className="relative">
                    <div className="absolute -inset-3 bg-amber-500/40 rounded-full blur-sm" />
                    <div className="relative bg-amber-500 text-white p-2 rounded-full border-2 border-white shadow-2xl z-50">
                      <Navigation className="h-4 w-4 fill-current rotate-45" />
                    </div>
                  </div>
                </AdvancedMarker>
              )}

              {/* Individual GPS points */}
              {filteredPoints.map((point, i) => (
                <AdvancedMarker
                  key={point.id}
                  position={{ lat: point.latitude, lng: point.longitude }}
                  onClick={() => setSelectedPoint(point)}
                  zIndex={1}
                >
                  <div className="w-2.5 h-2.5 rounded-full bg-blue-500 border border-white shadow-sm hover:scale-150 transition-transform cursor-pointer" />
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

              {/* Stationary Zones */}
              {stationaryZones.map((zone, i) => (
                <AdvancedMarker 
                  key={`zone-${i}`} 
                  position={{ lat: zone.center.latitude, lng: zone.center.longitude }}
                >
                  <div className="bg-slate-800/80 backdrop-blur-sm text-[10px] text-white px-2 py-0.5 rounded-full border border-white/20 shadow-md flex items-center gap-1">
                    <Square className="h-2 w-2 fill-current" />
                    Arrêt {formatDuration(zone.duration)}
                  </div>
                </AdvancedMarker>
              ))}

              <AutoFitBounds points={trail} />
            </Map>
          </APIProvider>
        </div>

        {/* Legend Overlay */}
        <div className="absolute bottom-4 left-4 right-4 flex justify-center pointer-events-none">
          <div className="bg-white/90 backdrop-blur-md px-4 py-2 rounded-full border border-slate-200 shadow-lg flex items-center gap-6 text-[10px] font-bold text-slate-600 uppercase tracking-wider pointer-events-auto">
             <div className="flex items-center gap-2">
                <span className="h-2 w-2 rounded-full bg-green-600" />
                Départ
             </div>
             <div className="flex items-center gap-2">
                <span className="h-2 w-2 rounded-full bg-blue-600" />
                En direct
             </div>
             <div className="flex items-center gap-2">
                <div className="h-0.5 w-4 bg-blue-400 rounded-full" />
                Trajet
             </div>
             <div className="flex items-center gap-2">
                <span className="h-2 w-2 rounded-sm bg-slate-800" />
                Arrêt
             </div>
          </div>
        </div>
      </CardContent>
    </Card>
  );
}

/**
 * Custom hook/component to draw the polyline using the Google Maps instance
 */
function TrailPolyline({ points }: { points: GpsTrailPoint[] }) {
  const map = useMap();
  const polylineRef = useRef<google.maps.Polyline | null>(null);

  useEffect(() => {
    if (!map) return;

    const path = points.map(p => ({ lat: p.latitude, lng: p.longitude }));
    
    if (polylineRef.current) {
      polylineRef.current.setPath(path);
    } else {
      polylineRef.current = new google.maps.Polyline({
        path,
        map,
        strokeColor: '#3b82f6',
        strokeOpacity: 0.8,
        strokeWeight: 4,
        icons: [{
          icon: {
            path: google.maps.SymbolPath.FORWARD_CLOSED_ARROW,
            scale: 2,
            strokeWeight: 2,
            fillColor: '#ffffff',
            fillOpacity: 1,
            strokeColor: '#3b82f6',
          },
          offset: '50%',
          repeat: '100px'
        }]
      });
    }

    return () => {
      if (polylineRef.current) {
        polylineRef.current.setMap(null);
        polylineRef.current = null;
      }
    };
  }, [map, points]);

  return null;
}

/**
 * Auto-adjust map bounds to show the entire trail.
 * Only fits on initial load or when new points are added (not on every re-render).
 */
function AutoFitBounds({ points }: { points: GpsTrailPoint[] }) {
  const map = useMap();
  const lastCountRef = useRef(0);

  useEffect(() => {
    if (!map || points.length === 0) return;

    // Only auto-fit on initial load or when new points are added
    if (lastCountRef.current === 0 || points.length > lastCountRef.current) {
      const bounds = new google.maps.LatLngBounds();
      points.forEach(p => bounds.extend({ lat: p.latitude, lng: p.longitude }));
      map.fitBounds(bounds, { top: 60, right: 60, bottom: 60, left: 60 });
    }
    lastCountRef.current = points.length;
  }, [map, points]);

  return null;
}

function MapSkeleton() {
  return (
    <Card className="overflow-hidden">
      <Skeleton className="h-[500px] w-full" />
    </Card>
  );
}

function EmptyState() {
  return (
    <Card className="flex flex-col items-center justify-center p-12 text-center bg-slate-50 border-dashed border-2 border-slate-200">
      <div className="bg-slate-200 p-4 rounded-full mb-4">
        <MapIcon className="h-8 w-8 text-slate-400" />
      </div>
      <h3 className="text-lg font-semibold text-slate-900">Pas encore de données GPS</h3>
      <p className="text-sm text-slate-500 max-w-xs">Le trajet apparaîtra ici dès que l'employé commencera son service.</p>
    </Card>
  );
}
