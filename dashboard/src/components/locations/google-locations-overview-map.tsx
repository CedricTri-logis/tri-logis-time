'use client';

import { useEffect, useMemo, useState, useCallback } from 'react';
import {
  APIProvider,
  Map,
  useMap,
  AdvancedMarker,
  InfoWindow,
} from '@vis.gl/react-google-maps';
import { useRouter } from 'next/navigation';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import type { Location } from '@/types/location';
import { LOCATION_TYPE_COLORS, getLocationTypeColor } from '@/lib/utils/segment-colors';
import { MapPin, ExternalLink, Layers } from 'lucide-react';

const DEFAULT_CENTER = { lat: 45.5017, lng: -73.5673 };
const DEFAULT_ZOOM = 11;

interface LocationsOverviewMapProps {
  locations: Location[];
  isLoading?: boolean;
  onLocationClick?: (location: Location) => void;
  selectedLocationId?: string | null;
  showInactive?: boolean;
  className?: string;
  apiKey?: string;
}

export function GoogleLocationsOverviewMap({
  locations,
  isLoading = false,
  onLocationClick,
  selectedLocationId = null,
  showInactive = true,
  className = '',
  apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY || '',
}: LocationsOverviewMapProps) {
  const router = useRouter();
  const [infoWindowLocation, setInfoWindowLocation] = useState<Location | null>(null);

  const filteredLocations = useMemo(() => {
    if (showInactive) return locations;
    return locations.filter((loc) => loc.isActive);
  }, [locations, showInactive]);

  const handleLocationClick = useCallback(
    (location: Location) => {
      setInfoWindowLocation(location);
      if (onLocationClick) {
        onLocationClick(location);
      }
    },
    [onLocationClick]
  );

  if (isLoading) return <MapSkeleton className={className} />;

  return (
    <Card className={`overflow-hidden border-slate-200 shadow-xl ${className}`}>
      <CardHeader className="bg-white/80 backdrop-blur-md border-b border-slate-100 py-3">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            <div className="bg-indigo-50 p-1.5 rounded-lg">
              <MapPin className="h-4 w-4 text-indigo-600" />
            </div>
            <div>
              <CardTitle className="text-sm font-semibold text-slate-900">
                Carte des Sites
              </CardTitle>
              <p className="text-[10px] text-slate-500 font-medium">
                {filteredLocations.length} emplacements répertoriés
              </p>
            </div>
          </div>
        </div>
      </CardHeader>

      <CardContent className="p-0 relative">
        <div className="h-[500px] w-full">
          <APIProvider apiKey={apiKey}>
            <Map
              defaultCenter={DEFAULT_CENTER}
              defaultZoom={DEFAULT_ZOOM}
              mapId="locations_overview_map"
              disableDefaultUI={true}
              zoomControl={true}
            >
              {filteredLocations.map((location) => (
                <div key={location.id}>
                  <AdvancedMarker
                    position={{ lat: location.latitude, lng: location.longitude }}
                    onClick={() => handleLocationClick(location)}
                  >
                    <div 
                      className="w-6 h-6 rounded-full border-2 border-white shadow-md flex items-center justify-center"
                      style={{ 
                        backgroundColor: getLocationTypeColor(location.locationType),
                        opacity: location.isActive ? 1 : 0.5 
                      }}
                    >
                      <MapPin className="h-3 w-3 text-white" />
                    </div>
                  </AdvancedMarker>
                  <GeofenceCircle 
                    center={{ lat: location.latitude, lng: location.longitude }}
                    radius={location.radiusMeters}
                    locationType={location.locationType}
                    isSelected={location.id === selectedLocationId}
                  />
                </div>
              ))}

              {infoWindowLocation && (
                <InfoWindow
                  position={{ lat: infoWindowLocation.latitude, lng: infoWindowLocation.longitude }}
                  onCloseClick={() => setInfoWindowLocation(null)}
                >
                  <div className="p-2 min-w-[200px]">
                    <h4 className="font-bold text-slate-900 text-sm mb-1">{infoWindowLocation.name}</h4>
                    <p className="text-[10px] text-slate-500 mb-2">{infoWindowLocation.address || 'Pas d\'adresse'}</p>
                    <div className="flex items-center gap-2 mb-3">
                       <span className="text-[9px] font-bold uppercase tracking-wider px-1.5 py-0.5 rounded bg-slate-100 text-slate-600">
                          {infoWindowLocation.locationType}
                       </span>
                       <span className="text-[9px] font-bold text-slate-400">Rayon: {infoWindowLocation.radiusMeters}m</span>
                    </div>
                    <Button 
                      size="sm" 
                      className="w-full h-8 text-[11px]"
                      onClick={() => router.push(`/dashboard/locations/${infoWindowLocation.id}`)}
                    >
                      Voir les détails
                    </Button>
                  </div>
                </InfoWindow>
              )}

              <AutoFitLocations locations={filteredLocations} />
            </Map>
          </APIProvider>
        </div>
        
        <div className="p-3 border-t border-slate-100 flex gap-4 overflow-x-auto">
           {Object.entries(LOCATION_TYPE_COLORS).map(([type, config]) => (
             <div key={type} className="flex items-center gap-1.5 whitespace-nowrap">
                <div className="h-2 w-2 rounded-full" style={{ backgroundColor: config.color }} />
                <span className="text-[10px] font-bold text-slate-500 uppercase tracking-tighter">{config.label}</span>
             </div>
           ))}
        </div>
      </CardContent>
    </Card>
  );
}

function GeofenceCircle({ center, radius, locationType, isSelected }: any) {
  const map = useMap();
  const color = getLocationTypeColor(locationType);
  useEffect(() => {
    if (!map) return;
    const circle = new google.maps.Circle({
      map, center, radius,
      fillColor: color,
      fillOpacity: isSelected ? 0.3 : 0.1,
      strokeColor: color,
      strokeOpacity: 0.8,
      strokeWeight: isSelected ? 3 : 1
    });
    return () => circle.setMap(null);
  }, [map, center, radius, color, isSelected]);
  return null;
}

function AutoFitLocations({ locations }: { locations: Location[] }) {
  const map = useMap();
  useEffect(() => {
    if (!map || locations.length === 0) return;
    const bounds = new google.maps.LatLngBounds();
    locations.forEach(l => bounds.extend({ lat: l.latitude, lng: l.longitude }));
    map.fitBounds(bounds, { top: 60, right: 60, bottom: 60, left: 60 });
  }, [map, locations]);
  return null;
}

function MapSkeleton({ className }: { className: string }) {
  return <Skeleton className={`h-[500px] w-full rounded-xl ${className}`} />;
}
