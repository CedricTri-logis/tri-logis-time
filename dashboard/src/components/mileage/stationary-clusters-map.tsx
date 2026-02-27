'use client';

import { useEffect, useState } from 'react';
import {
  APIProvider,
  Map,
  useMap,
  AdvancedMarker,
} from '@vis.gl/react-google-maps';
import { X } from 'lucide-react';
import { supabaseClient } from '@/lib/supabase/client';

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

interface GpsPoint {
  latitude: number;
  longitude: number;
  accuracy: number;
  received_at: string;
  speed: number | null;
  speed_accuracy: number | null;
  heading: number | null;
  altitude: number | null;
  altitude_accuracy: number | null;
  activity_type: string | null;
  is_mocked: boolean | null;
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

  const [infoClusterId, setInfoClusterId] = useState<string | null>(null);
  const infoCluster = clusters.find((c) => c.id === infoClusterId) || null;

  const [gpsPoints, setGpsPoints] = useState<GpsPoint[]>([]);
  const [loadingGps, setLoadingGps] = useState(false);
  const [selectedGpsIndex, setSelectedGpsIndex] = useState<number | null>(null);
  const selectedGpsPoint = selectedGpsIndex != null ? gpsPoints[selectedGpsIndex] ?? null : null;

  // Sync external selection with detail card
  useEffect(() => {
    if (selectedClusterId) {
      setInfoClusterId(selectedClusterId);
    }
  }, [selectedClusterId]);

  // Fetch GPS points when a cluster is selected
  useEffect(() => {
    setSelectedGpsIndex(null);
    if (!infoClusterId) {
      setGpsPoints([]);
      return;
    }
    let cancelled = false;
    setLoadingGps(true);
    (async () => {
      try {
        const { data, error } = await supabaseClient.rpc('get_cluster_gps_points', {
          p_cluster_id: infoClusterId,
        });
        if (cancelled) return;
        if (error) {
          console.error('[cluster-gps-points] RPC error:', error);
          setGpsPoints([]);
        } else {
          setGpsPoints((data as GpsPoint[]) || []);
        }
      } catch (err) {
        if (!cancelled) setGpsPoints([]);
      } finally {
        if (!cancelled) setLoadingGps(false);
      }
    })();
    return () => { cancelled = true; };
  }, [infoClusterId]);

  const handleClose = () => {
    setInfoClusterId(null);
    onClusterSelect?.(null);
  };

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
    <div className="relative rounded-xl overflow-hidden border border-slate-200 shadow-sm" style={{ height }}>
      <APIProvider apiKey={apiKey}>
        <Map
          defaultCenter={DEFAULT_CENTER}
          defaultZoom={DEFAULT_ZOOM}
          mapId="stationary_clusters_map"
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

          {/* GPS footprint: blue dots (clickable) */}
          {infoClusterId && gpsPoints.map((pt, i) => {
            const isGpsSelected = i === selectedGpsIndex;
            return (
              <AdvancedMarker
                key={`gps-${i}`}
                position={{ lat: pt.latitude, lng: pt.longitude }}
                zIndex={isGpsSelected ? 900 : 500}
                onClick={() => setSelectedGpsIndex(isGpsSelected ? null : i)}
              >
                <div
                  className="rounded-full cursor-pointer"
                  style={{
                    width: isGpsSelected ? 10 : 6,
                    height: isGpsSelected ? 10 : 6,
                    backgroundColor: isGpsSelected ? '#2563eb' : '#3b82f6',
                    opacity: isGpsSelected ? 1 : 0.6,
                    border: isGpsSelected ? '2px solid white' : '1px solid white',
                    boxShadow: isGpsSelected ? '0 0 6px rgba(37,99,235,0.5)' : 'none',
                  }}
                />
              </AdvancedMarker>
            );
          })}

          {/* Red accuracy circle + centroid dot */}
          {infoCluster && (
            <>
              <AccuracyCircle
                center={{ lat: infoCluster.centroid_latitude, lng: infoCluster.centroid_longitude }}
                radius={infoCluster.centroid_accuracy ?? 0}
              />
              <AdvancedMarker
                position={{
                  lat: infoCluster.centroid_latitude,
                  lng: infoCluster.centroid_longitude,
                }}
                zIndex={1000}
              >
                <div
                  className="rounded-full shadow-md"
                  style={{
                    width: 10,
                    height: 10,
                    backgroundColor: '#ef4444',
                    border: '2px solid white',
                  }}
                />
              </AdvancedMarker>
            </>
          )}

          {/* Selected GPS point accuracy circle */}
          {selectedGpsPoint && (
            <AccuracyCircle
              center={{ lat: selectedGpsPoint.latitude, lng: selectedGpsPoint.longitude }}
              radius={selectedGpsPoint.accuracy}
              color="#3b82f6"
            />
          )}

          <FitBoundsHelper
            clusters={clusters}
            selectedClusterId={infoClusterId}
            gpsPoints={gpsPoints}
            selectedCluster={infoCluster}
          />
        </Map>
      </APIProvider>

      {/* Floating detail card (bottom-left) */}
      {infoCluster && (
        <div className="absolute bottom-3 left-3 z-[10] bg-white rounded-lg shadow-lg border border-slate-200 p-3 min-w-[200px] max-w-[280px]">
          <button
            onClick={handleClose}
            className="absolute top-1.5 right-1.5 p-0.5 rounded hover:bg-slate-100 text-slate-400 hover:text-slate-600"
          >
            <X className="h-3.5 w-3.5" />
          </button>
          <h4 className="font-bold text-slate-900 text-sm mb-0.5 pr-5">
            {infoCluster.employee_name}
          </h4>
          <p className="text-xs mb-1" style={{ color: infoCluster.matched_location_id ? '#16a34a' : '#d97706' }}>
            {infoCluster.matched_location_name || 'Non associ\u00e9'}
          </p>
          <p className="text-[11px] text-slate-600 mb-0.5">
            Dur&eacute;e: <strong>{formatDuration(infoCluster.duration_seconds)}</strong>
          </p>
          <p className="text-[11px] text-slate-600 mb-0.5">
            Points GPS: <strong>{infoCluster.gps_point_count}</strong>
          </p>
          <p className="text-[10px] text-slate-400">
            {formatDateTime(infoCluster.started_at)} &mdash; {formatDateTime(infoCluster.ended_at)}
          </p>
          {loadingGps && (
            <p className="text-[10px] text-blue-400 mt-1">Chargement GPS...</p>
          )}
        </div>
      )}

      {/* GPS point detail card (bottom-right) */}
      {selectedGpsPoint && (
        <div className="absolute bottom-3 right-3 z-[10] bg-white rounded-lg shadow-lg border border-blue-200 p-3 min-w-[200px] max-w-[260px]">
          <button
            onClick={() => setSelectedGpsIndex(null)}
            className="absolute top-1.5 right-1.5 p-0.5 rounded hover:bg-slate-100 text-slate-400 hover:text-slate-600"
          >
            <X className="h-3.5 w-3.5" />
          </button>
          <h4 className="font-bold text-blue-600 text-xs mb-1.5 pr-5">
            Point GPS #{(selectedGpsIndex ?? 0) + 1}/{gpsPoints.length}
          </h4>
          <div className="space-y-0.5 text-[11px] text-slate-600">
            <p>
              Heure: <strong>
                {new Date(selectedGpsPoint.received_at).toLocaleTimeString('fr-CA', { hour: '2-digit', minute: '2-digit', second: '2-digit' })}
              </strong>
            </p>
            <p className="font-mono text-[10px] text-slate-500">
              {selectedGpsPoint.latitude.toFixed(6)}, {selectedGpsPoint.longitude.toFixed(6)}
            </p>
            <p>
              Pr&eacute;cision: <strong>&plusmn;{Math.round(selectedGpsPoint.accuracy)}m</strong>
            </p>
            {selectedGpsPoint.speed != null && (
              <p>
                Vitesse: <strong>{(selectedGpsPoint.speed * 3.6).toFixed(1)} km/h</strong>
                {selectedGpsPoint.speed_accuracy != null && (
                  <span className="text-slate-400"> (&plusmn;{(selectedGpsPoint.speed_accuracy * 3.6).toFixed(1)})</span>
                )}
              </p>
            )}
            {selectedGpsPoint.altitude != null && (
              <p>
                Altitude: <strong>{Math.round(selectedGpsPoint.altitude)}m</strong>
                {selectedGpsPoint.altitude_accuracy != null && (
                  <span className="text-slate-400"> (&plusmn;{Math.round(selectedGpsPoint.altitude_accuracy)}m)</span>
                )}
              </p>
            )}
            {selectedGpsPoint.heading != null && (
              <p>
                Cap: <strong>{Math.round(selectedGpsPoint.heading)}&deg;</strong>
              </p>
            )}
            {selectedGpsPoint.activity_type && (
              <p>
                Activit&eacute;: <strong>{selectedGpsPoint.activity_type}</strong>
              </p>
            )}
            {selectedGpsPoint.is_mocked && (
              <p className="text-red-500 font-medium">Mocked</p>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function AccuracyCircle({ center, radius, color = '#ef4444' }: { center: google.maps.LatLngLiteral; radius: number; color?: string }) {
  const map = useMap();
  useEffect(() => {
    if (!map || radius <= 0) return;
    const circle = new google.maps.Circle({
      map, center, radius,
      fillColor: color,
      fillOpacity: 0.12,
      strokeColor: color,
      strokeOpacity: 0.5,
      strokeWeight: 1.5,
      clickable: false,
    });
    return () => circle.setMap(null);
  }, [map, center.lat, center.lng, radius, color]);
  return null;
}

function FitBoundsHelper({
  clusters,
  selectedClusterId,
  gpsPoints,
  selectedCluster,
}: {
  clusters: StationaryCluster[];
  selectedClusterId: string | null;
  gpsPoints: GpsPoint[];
  selectedCluster: StationaryCluster | null;
}) {
  const map = useMap();

  // Fit all clusters on initial load
  useEffect(() => {
    if (!map || clusters.length === 0 || selectedClusterId) return;

    const bounds = new google.maps.LatLngBounds();
    for (const c of clusters) {
      bounds.extend({ lat: c.centroid_latitude, lng: c.centroid_longitude });
    }

    if (clusters.length === 1) {
      map.setCenter({ lat: clusters[0].centroid_latitude, lng: clusters[0].centroid_longitude });
      map.setZoom(15);
    } else {
      map.fitBounds(bounds, { top: 40, right: 40, bottom: 40, left: 40 });
    }
  }, [map, clusters, selectedClusterId]);

  // Pan to selected cluster
  useEffect(() => {
    if (!map || !selectedClusterId || !selectedCluster) return;
    map.panTo({ lat: selectedCluster.centroid_latitude, lng: selectedCluster.centroid_longitude });
    const currentZoom = map.getZoom();
    if (currentZoom != null && currentZoom < 16) {
      map.setZoom(17);
    }
  }, [map, selectedClusterId, selectedCluster]);

  // Fit GPS points when they load
  useEffect(() => {
    if (!map || !selectedCluster || gpsPoints.length === 0) return;

    const bounds = new google.maps.LatLngBounds();
    bounds.extend({ lat: selectedCluster.centroid_latitude, lng: selectedCluster.centroid_longitude });
    for (const pt of gpsPoints) {
      bounds.extend({ lat: pt.latitude, lng: pt.longitude });
    }
    map.fitBounds(bounds, { top: 40, right: 40, bottom: 40, left: 60 });

    // Cap max zoom at 19
    const listener = google.maps.event.addListenerOnce(map, 'idle', () => {
      const z = map.getZoom();
      if (z != null && z > 19) map.setZoom(19);
    });
    return () => google.maps.event.removeListener(listener);
  }, [map, gpsPoints, selectedCluster]);

  return null;
}
