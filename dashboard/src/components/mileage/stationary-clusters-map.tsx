'use client';

import { useEffect, useState } from 'react';
import {
  APIProvider,
  Map,
  useMap,
  AdvancedMarker,
  InfoWindow,
} from '@vis.gl/react-google-maps';

export interface StationaryCluster {
  id: string;
  shift_id: string;
  employee_id: string;
  employee_name: string;
  centroid_latitude: number;
  centroid_longitude: number;
  centroid_accuracy: number | null;
  started_at: string;
  ended_at: string;
  duration_seconds: number;
  gps_point_count: number;
  matched_location_id: string | null;
  matched_location_name: string | null;
  created_at: string;
}

interface StationaryClustersMapProps {
  clusters: StationaryCluster[];
  height?: number;
  selectedClusterId?: string | null;
  onClusterSelect?: (id: string | null) => void;
}

function formatDuration(seconds: number): string {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (hours > 0) return `${hours}h ${minutes}min`;
  return `${minutes}min`;
}

function formatDateTime(dateStr: string): string {
  const d = new Date(dateStr);
  return `${d.toLocaleDateString('fr-CA', { day: 'numeric', month: 'short' })} ${d.toLocaleTimeString('fr-CA', { hour: '2-digit', minute: '2-digit' })}`;
}

const DEFAULT_CENTER = { lat: 48.241, lng: -79.028 };
const DEFAULT_ZOOM = 11;

export function StationaryClustersMap({
  clusters,
  height = 400,
  selectedClusterId,
  onClusterSelect,
}: StationaryClustersMapProps) {
  const apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY || '';
  const mapId = process.env.NEXT_PUBLIC_GOOGLE_MAPS_MAP_ID || '';

  const [infoClusterId, setInfoClusterId] = useState<string | null>(null);
  const infoCluster = clusters.find((c) => c.id === infoClusterId) || null;

  // Sync external selection with InfoWindow
  useEffect(() => {
    if (selectedClusterId) {
      setInfoClusterId(selectedClusterId);
    }
  }, [selectedClusterId]);

  if (clusters.length === 0) {
    return (
      <div
        className="flex items-center justify-center rounded-xl border border-slate-200 bg-slate-50 text-sm text-muted-foreground"
        style={{ height }}
      >
        Aucun arr&ecirc;t &agrave; afficher.
      </div>
    );
  }

  return (
    <div className="rounded-xl overflow-hidden border border-slate-200 shadow-sm" style={{ height }}>
      <APIProvider apiKey={apiKey}>
        <Map
          defaultCenter={DEFAULT_CENTER}
          defaultZoom={DEFAULT_ZOOM}
          mapId={mapId}
          disableDefaultUI
          zoomControl
        >
          {clusters.map((cluster) => {
            const isMatched = !!cluster.matched_location_id;
            const isSelected = cluster.id === selectedClusterId;
            return (
              <AdvancedMarker
                key={cluster.id}
                position={{
                  lat: cluster.centroid_latitude,
                  lng: cluster.centroid_longitude,
                }}
                onClick={() => {
                  setInfoClusterId(cluster.id);
                  onClusterSelect?.(cluster.id);
                }}
              >
                <div
                  className="rounded-full shadow-md transition-transform"
                  style={{
                    width: isSelected ? 16 : 12,
                    height: isSelected ? 16 : 12,
                    backgroundColor: isMatched ? '#22c55e' : '#f59e0b',
                    border: isSelected ? '3px solid white' : '2px solid white',
                    transform: isSelected ? 'scale(1.3)' : 'scale(1)',
                  }}
                />
              </AdvancedMarker>
            );
          })}

          {infoCluster && (
            <InfoWindow
              position={{
                lat: infoCluster.centroid_latitude,
                lng: infoCluster.centroid_longitude,
              }}
              onCloseClick={() => {
                setInfoClusterId(null);
                onClusterSelect?.(null);
              }}
              pixelOffset={[0, -10]}
            >
              <div className="p-1 min-w-[180px] max-w-[260px]">
                <h4 className="font-bold text-slate-900 text-sm mb-0.5">
                  {infoCluster.employee_name}
                </h4>
                <p className="text-xs mb-1" style={{ color: infoCluster.matched_location_id ? '#16a34a' : '#d97706' }}>
                  {infoCluster.matched_location_name || 'Non associ\u00e9'}
                </p>
                <p className="text-[11px] text-slate-600 mb-0.5">
                  Dur\u00e9e: <strong>{formatDuration(infoCluster.duration_seconds)}</strong>
                </p>
                <p className="text-[11px] text-slate-600 mb-0.5">
                  Points GPS: <strong>{infoCluster.gps_point_count}</strong>
                </p>
                <p className="text-[10px] text-slate-400">
                  {formatDateTime(infoCluster.started_at)} &mdash; {formatDateTime(infoCluster.ended_at)}
                </p>
              </div>
            </InfoWindow>
          )}

          <FitBoundsHelper clusters={clusters} />
        </Map>
      </APIProvider>
    </div>
  );
}

function FitBoundsHelper({ clusters }: { clusters: StationaryCluster[] }) {
  const map = useMap();

  useEffect(() => {
    if (!map || clusters.length === 0) return;

    const bounds = new google.maps.LatLngBounds();
    for (const c of clusters) {
      bounds.extend({ lat: c.centroid_latitude, lng: c.centroid_longitude });
    }

    // Only fit if we have multiple points spread across the map
    if (clusters.length === 1) {
      map.setCenter({ lat: clusters[0].centroid_latitude, lng: clusters[0].centroid_longitude });
      map.setZoom(15);
    } else {
      map.fitBounds(bounds, { top: 40, right: 40, bottom: 40, left: 40 });
    }
  }, [map, clusters]);

  return null;
}
