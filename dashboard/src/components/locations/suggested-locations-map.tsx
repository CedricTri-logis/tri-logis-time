'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  APIProvider,
  Map,
  useMap,
  AdvancedMarker,
  InfoWindow,
} from '@vis.gl/react-google-maps';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Plus, EyeOff, MapPin, ChevronLeft, ChevronRight } from 'lucide-react';
import type { Location } from '@/types/location';
import { getLocationTypeColor, getLocationTypeLabel } from '@/lib/utils/segment-colors';
import { supabaseClient } from '@/lib/supabase/client';

const DEFAULT_CENTER = { lat: 48.2410, lng: -79.0280 };
const DEFAULT_ZOOM = 13;

export interface MapCluster {
  cluster_id: number;
  centroid_latitude: number;
  centroid_longitude: number;
  occurrence_count: number;
  has_start_endpoints: boolean;
  has_end_endpoints: boolean;
  employee_names: string[];
  first_seen: string;
  last_seen: string;
  google_address?: string | null;
  place_name?: string | null;
}

interface ClusterOccurrence {
  trip_id: string;
  employee_name: string;
  endpoint_type: 'start' | 'end';
  latitude: number;
  longitude: number;
  seen_at: string;
  address: string | null;
}

interface SuggestedLocationsMapProps {
  clusters: MapCluster[];
  selectedClusterId: number | null;
  onClusterSelect: (clusterId: number) => void;
  onCreateFromCluster: (cluster: MapCluster) => void;
  onIgnoreCluster?: (cluster: MapCluster) => void;
  locations?: Location[];
}

export function SuggestedLocationsMap({
  clusters,
  selectedClusterId,
  onClusterSelect,
  onCreateFromCluster,
  onIgnoreCluster,
  locations = [],
}: SuggestedLocationsMapProps) {
  const apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY || '';
  const selectedCluster = clusters.find((c) => c.cluster_id === selectedClusterId) || null;
  const [selectedLocationId, setSelectedLocationId] = useState<string | null>(null);
  const selectedLocation = locations.find((l) => l.id === selectedLocationId) || null;

  const [occurrences, setOccurrences] = useState<ClusterOccurrence[]>([]);
  const [occurrenceIndex, setOccurrenceIndex] = useState(0);
  const [loadingOccurrences, setLoadingOccurrences] = useState(false);

  // Fetch occurrences when a cluster is selected
  useEffect(() => {
    if (!selectedCluster) {
      setOccurrences([]);
      setOccurrenceIndex(0);
      return;
    }

    let cancelled = false;
    async function fetchOccurrences() {
      setLoadingOccurrences(true);
      const { data, error } = await supabaseClient.rpc('get_cluster_occurrences', {
        p_centroid_lat: selectedCluster!.centroid_latitude,
        p_centroid_lng: selectedCluster!.centroid_longitude,
      });
      if (!cancelled) {
        setOccurrences(error ? [] : (data as ClusterOccurrence[]) || []);
        setOccurrenceIndex(0);
        setLoadingOccurrences(false);
      }
    }
    fetchOccurrences();
    return () => { cancelled = true; };
  }, [selectedCluster?.cluster_id]);

  const currentOccurrence = occurrences[occurrenceIndex] || null;

  return (
    <div className="h-[500px] w-full rounded-xl overflow-hidden border border-slate-200 shadow-sm">
      <APIProvider apiKey={apiKey}>
        <Map
          defaultCenter={DEFAULT_CENTER}
          defaultZoom={DEFAULT_ZOOM}
          mapId="suggested_locations_map"
          disableDefaultUI={true}
          zoomControl={true}
        >
          {/* Existing location geofence circles + small markers */}
          {locations.map((loc) => (
            <GeofenceCircle
              key={loc.id}
              center={{ lat: loc.latitude, lng: loc.longitude }}
              radius={loc.radiusMeters}
              locationType={loc.locationType}
            />
          ))}
          {locations.map((loc) => {
            const isLocSelected = loc.id === selectedLocationId;
            return (
              <AdvancedMarker
                key={`loc-${loc.id}`}
                position={{ lat: loc.latitude, lng: loc.longitude }}
                onClick={() => {
                  setSelectedLocationId(isLocSelected ? null : loc.id);
                  if (selectedClusterId) onClusterSelect(-1);
                }}
              >
                <div
                  className="rounded-full flex items-center justify-center shadow-sm cursor-pointer"
                  style={{
                    width: isLocSelected ? 26 : 20,
                    height: isLocSelected ? 26 : 20,
                    backgroundColor: getLocationTypeColor(loc.locationType),
                    border: isLocSelected ? '3px solid white' : '2px solid white',
                  }}
                >
                  <MapPin className="h-2.5 w-2.5 text-white" />
                </div>
              </AdvancedMarker>
            );
          })}

          {/* Cluster markers */}
          {clusters.map((cluster) => {
            const minSize = 24;
            const maxSize = 48;
            const maxOcc = Math.max(...clusters.map((c) => c.occurrence_count), 1);
            const size = Math.round(
              minSize + ((cluster.occurrence_count - 1) / Math.max(maxOcc - 1, 1)) * (maxSize - minSize)
            );
            const isSelected = cluster.cluster_id === selectedClusterId;

            return (
              <AdvancedMarker
                key={cluster.cluster_id}
                position={{
                  lat: cluster.centroid_latitude,
                  lng: cluster.centroid_longitude,
                }}
                onClick={() => {
                  onClusterSelect(cluster.cluster_id);
                  setSelectedLocationId(null);
                }}
              >
                <div
                  className="rounded-full flex items-center justify-center font-bold text-white shadow-md transition-all"
                  style={{
                    width: size,
                    height: size,
                    fontSize: size < 30 ? 10 : 12,
                    backgroundColor: isSelected ? '#d97706' : '#f59e0b',
                    border: isSelected ? '3px solid #92400e' : '2px solid white',
                    transform: isSelected ? 'scale(1.2)' : 'scale(1)',
                  }}
                >
                  {cluster.occurrence_count}
                </div>
              </AdvancedMarker>
            );
          })}

          {/* Individual occurrence GPS marker */}
          {selectedCluster && currentOccurrence && (
            <AdvancedMarker
              position={{
                lat: currentOccurrence.latitude,
                lng: currentOccurrence.longitude,
              }}
            >
              <div
                className="rounded-full shadow-md"
                style={{
                  width: 12,
                  height: 12,
                  backgroundColor: '#ef4444',
                  border: '2px solid white',
                }}
              />
            </AdvancedMarker>
          )}

          {selectedCluster && (
            <InfoWindow
              position={{
                lat: selectedCluster.centroid_latitude,
                lng: selectedCluster.centroid_longitude,
              }}
              onCloseClick={() => onClusterSelect(-1)}
              pixelOffset={[0, -24]}
            >
              <div className="p-1 min-w-[200px] max-w-[280px]">
                {selectedCluster.place_name && (
                  <h4 className="font-bold text-slate-900 text-sm mb-0.5">
                    {selectedCluster.place_name}
                  </h4>
                )}
                <p className="text-xs text-slate-500 mb-1.5">
                  {selectedCluster.google_address || 'Adresse en cours...'}
                </p>
                <div className="flex items-center gap-1.5 mb-1.5 flex-wrap">
                  <Badge variant="secondary" className="text-[10px]">
                    {selectedCluster.occurrence_count} occurrence
                    {selectedCluster.occurrence_count > 1 ? 's' : ''}
                  </Badge>
                  {selectedCluster.has_start_endpoints && (
                    <Badge variant="outline" className="text-[10px]">
                      Départ
                    </Badge>
                  )}
                  {selectedCluster.has_end_endpoints && (
                    <Badge variant="outline" className="text-[10px]">
                      Arrivée
                    </Badge>
                  )}
                </div>

                {/* Occurrence browser */}
                {loadingOccurrences ? (
                  <p className="text-[10px] text-slate-400 mb-2">Chargement...</p>
                ) : occurrences.length > 0 && currentOccurrence ? (
                  <div className="border-t border-slate-200 pt-1.5 mt-1 mb-2">
                    <div className="flex items-center justify-between mb-1">
                      <span className="text-[11px] font-medium text-slate-700">
                        {currentOccurrence.employee_name}
                      </span>
                      <Badge
                        variant={currentOccurrence.endpoint_type === 'start' ? 'default' : 'secondary'}
                        className="text-[9px] h-4"
                      >
                        {currentOccurrence.endpoint_type === 'start' ? 'Départ' : 'Arrivée'}
                      </Badge>
                    </div>
                    <p className="text-[10px] text-slate-500">
                      {new Date(currentOccurrence.seen_at).toLocaleDateString('fr-CA', {
                        day: 'numeric',
                        month: 'short',
                        year: 'numeric',
                      })},{' '}
                      {new Date(currentOccurrence.seen_at).toLocaleTimeString('fr-CA', {
                        hour: '2-digit',
                        minute: '2-digit',
                      })}
                    </p>
                    <p className="text-[9px] text-slate-400 font-mono">
                      ({currentOccurrence.latitude.toFixed(5)}, {currentOccurrence.longitude.toFixed(5)})
                    </p>
                    {occurrences.length > 1 && (
                      <div className="flex items-center justify-center gap-2 mt-1.5">
                        <button
                          className="p-0.5 rounded hover:bg-slate-100 disabled:opacity-30"
                          disabled={occurrenceIndex === 0}
                          onClick={() => setOccurrenceIndex((i) => i - 1)}
                        >
                          <ChevronLeft className="h-3.5 w-3.5 text-slate-600" />
                        </button>
                        <span className="text-[10px] text-slate-500 tabular-nums">
                          {occurrenceIndex + 1} / {occurrences.length}
                        </span>
                        <button
                          className="p-0.5 rounded hover:bg-slate-100 disabled:opacity-30"
                          disabled={occurrenceIndex === occurrences.length - 1}
                          onClick={() => setOccurrenceIndex((i) => i + 1)}
                        >
                          <ChevronRight className="h-3.5 w-3.5 text-slate-600" />
                        </button>
                      </div>
                    )}
                  </div>
                ) : (
                  <>
                    {selectedCluster.employee_names?.length > 0 && (
                      <p className="text-[10px] text-slate-400 mb-1">
                        {selectedCluster.employee_names.join(', ')}
                      </p>
                    )}
                    <p className="text-[10px] text-slate-400 mb-2">
                      {new Date(selectedCluster.first_seen).toLocaleDateString('fr-CA')} —{' '}
                      {new Date(selectedCluster.last_seen).toLocaleDateString('fr-CA')}
                    </p>
                  </>
                )}

                <div className="flex gap-1.5">
                  <Button
                    size="sm"
                    className="flex-1 h-7 text-[11px]"
                    onClick={() => onCreateFromCluster(selectedCluster)}
                  >
                    <Plus className="h-3 w-3 mr-1" />
                    Créer
                  </Button>
                  {onIgnoreCluster && (
                    <Button
                      variant="outline"
                      size="sm"
                      className="h-7 text-[11px]"
                      onClick={() => onIgnoreCluster(selectedCluster)}
                    >
                      <EyeOff className="h-3 w-3 mr-1" />
                      Ignorer
                    </Button>
                  )}
                </div>
              </div>
            </InfoWindow>
          )}

          {selectedLocation && (
            <InfoWindow
              position={{
                lat: selectedLocation.latitude,
                lng: selectedLocation.longitude,
              }}
              onCloseClick={() => setSelectedLocationId(null)}
              pixelOffset={[0, -16]}
            >
              <div className="p-1 min-w-[160px] max-w-[240px]">
                <h4 className="font-bold text-slate-900 text-sm mb-0.5">
                  {selectedLocation.name}
                </h4>
                <div className="flex items-center gap-1.5 mb-1">
                  <span
                    className="px-1.5 py-0.5 rounded text-[10px] font-medium"
                    style={{
                      backgroundColor: `${getLocationTypeColor(selectedLocation.locationType)}20`,
                      color: getLocationTypeColor(selectedLocation.locationType),
                    }}
                  >
                    {getLocationTypeLabel(selectedLocation.locationType)}
                  </span>
                  <span className="text-[10px] text-slate-400">
                    {selectedLocation.radiusMeters}m
                  </span>
                </div>
                {selectedLocation.address && (
                  <p className="text-[10px] text-slate-500">
                    {selectedLocation.address}
                  </p>
                )}
              </div>
            </InfoWindow>
          )}

          <AutoFitClusters clusters={clusters} locations={locations} selectedClusterId={selectedClusterId} />
        </Map>
      </APIProvider>
    </div>
  );
}

function GeofenceCircle({ center, radius, locationType }: { center: google.maps.LatLngLiteral; radius: number; locationType: string }) {
  const map = useMap();
  const color = getLocationTypeColor(locationType as any);
  useEffect(() => {
    if (!map) return;
    const circle = new google.maps.Circle({
      map, center, radius,
      fillColor: color,
      fillOpacity: 0.15,
      strokeColor: color,
      strokeOpacity: 0.6,
      strokeWeight: 1,
      clickable: false,
    });
    return () => circle.setMap(null);
  }, [map, center, radius, color]);
  return null;
}

function AutoFitClusters({
  clusters,
  locations = [],
  selectedClusterId,
}: {
  clusters: MapCluster[];
  locations?: Location[];
  selectedClusterId: number | null;
}) {
  const map = useMap();

  // No auto-fit — default center/zoom is Rouyn-Noranda
  // User can pan/zoom manually; clicking a cluster pans to it

  // Pan to selected cluster
  useEffect(() => {
    if (!map || !selectedClusterId || selectedClusterId < 0) return;
    const cluster = clusters.find((c) => c.cluster_id === selectedClusterId);
    if (cluster) {
      map.panTo({ lat: cluster.centroid_latitude, lng: cluster.centroid_longitude });
    }
  }, [map, selectedClusterId, clusters]);

  return null;
}
