'use client';

import { useEffect, useCallback } from 'react';
import {
  APIProvider,
  Map,
  useMap,
  AdvancedMarker,
  InfoWindow,
} from '@vis.gl/react-google-maps';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Plus } from 'lucide-react';

const DEFAULT_CENTER = { lat: 45.5017, lng: -73.5673 };
const DEFAULT_ZOOM = 11;

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

interface SuggestedLocationsMapProps {
  clusters: MapCluster[];
  selectedClusterId: number | null;
  onClusterSelect: (clusterId: number) => void;
  onCreateFromCluster: (cluster: MapCluster) => void;
}

export function SuggestedLocationsMap({
  clusters,
  selectedClusterId,
  onClusterSelect,
  onCreateFromCluster,
}: SuggestedLocationsMapProps) {
  const apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY || '';
  const selectedCluster = clusters.find((c) => c.cluster_id === selectedClusterId) || null;

  return (
    <div className="h-[350px] w-full rounded-xl overflow-hidden border border-slate-200 shadow-sm">
      <APIProvider apiKey={apiKey}>
        <Map
          defaultCenter={DEFAULT_CENTER}
          defaultZoom={DEFAULT_ZOOM}
          mapId="suggested_locations_map"
          disableDefaultUI={true}
          zoomControl={true}
        >
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
                onClick={() => onClusterSelect(cluster.cluster_id)}
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
                {selectedCluster.employee_names?.length > 0 && (
                  <p className="text-[10px] text-slate-400 mb-1">
                    {selectedCluster.employee_names.join(', ')}
                  </p>
                )}
                <p className="text-[10px] text-slate-400 mb-2">
                  {new Date(selectedCluster.first_seen).toLocaleDateString('fr-CA')} —{' '}
                  {new Date(selectedCluster.last_seen).toLocaleDateString('fr-CA')}
                </p>
                <Button
                  size="sm"
                  className="w-full h-7 text-[11px]"
                  onClick={() => onCreateFromCluster(selectedCluster)}
                >
                  <Plus className="h-3 w-3 mr-1" />
                  Créer
                </Button>
              </div>
            </InfoWindow>
          )}

          <AutoFitClusters clusters={clusters} selectedClusterId={selectedClusterId} />
        </Map>
      </APIProvider>
    </div>
  );
}

function AutoFitClusters({
  clusters,
  selectedClusterId,
}: {
  clusters: MapCluster[];
  selectedClusterId: number | null;
}) {
  const map = useMap();

  // Fit bounds on initial load
  useEffect(() => {
    if (!map || clusters.length === 0) return;
    const bounds = new google.maps.LatLngBounds();
    clusters.forEach((c) =>
      bounds.extend({ lat: c.centroid_latitude, lng: c.centroid_longitude })
    );
    map.fitBounds(bounds, { top: 50, right: 50, bottom: 50, left: 50 });
  }, [map, clusters]);

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
