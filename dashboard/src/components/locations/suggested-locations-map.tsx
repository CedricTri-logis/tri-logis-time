'use client';

import { useState, useEffect } from 'react';
import {
  APIProvider,
  Map,
  useMap,
  AdvancedMarker,
} from '@vis.gl/react-google-maps';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Plus, MapPin, ChevronLeft, ChevronRight, X, EyeOff, Building2, HardHat, Truck, Home, Coffee, Fuel } from 'lucide-react';
import type { Location } from '@/types/location';
import type { LocationType } from '@/types/location';
import { getLocationTypeColor, getLocationTypeLabel } from '@/lib/utils/segment-colors';
import { supabaseClient } from '@/lib/supabase/client';

const LOCATION_TYPE_ICONS: Record<LocationType, React.ElementType> = {
  office: Building2,
  building: HardHat,
  vendor: Truck,
  home: Home,
  cafe_restaurant: Coffee,
  gaz: Fuel,
  other: MapPin,
};

// Suggested clusters use teal to avoid collision with building (amber) location type
const SUGGESTED_COLOR = '#0d9488';        // teal-600
const SUGGESTED_COLOR_SELECTED = '#0f766e'; // teal-700
const SUGGESTED_BORDER_SELECTED = '#134e4a'; // teal-900

const DEFAULT_CENTER = { lat: 48.2410, lng: -79.0280 };
const DEFAULT_ZOOM = 13;

export interface MapCluster {
  cluster_id: number;
  centroid_latitude: number;
  centroid_longitude: number;
  occurrence_count: number;
  employee_names: string[];
  first_seen: string;
  last_seen: string;
  total_duration_seconds: number;
  avg_accuracy: number;
  google_address?: string | null;
  place_name?: string | null;
}

export interface ClusterOccurrence {
  cluster_id: string;
  employee_name: string;
  centroid_latitude: number;
  centroid_longitude: number;
  centroid_accuracy: number | null;
  started_at: string;
  ended_at: string;
  duration_seconds: number;
  gps_point_count: number;
  shift_id: string;
}

interface GpsPoint {
  latitude: number;
  longitude: number;
  accuracy: number;
  received_at: string;
  speed?: number | null;
  speed_accuracy?: number | null;
  heading?: number | null;
  altitude?: number | null;
  altitude_accuracy?: number | null;
  activity_type?: string | null;
  is_mocked?: boolean | null;
}

interface SuggestedLocationsMapProps {
  clusters: MapCluster[];
  selectedClusterId: number | null;
  onClusterSelect: (clusterId: number) => void;
  onCreateFromCluster: (cluster: MapCluster) => void;
  onIgnoreCluster: (cluster: MapCluster) => void;
  locations?: Location[];
}

function formatDuration(seconds: number): string {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (hours > 0) return `${hours}h ${minutes}min`;
  return `${minutes}min`;
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
  const [gpsPoints, setGpsPoints] = useState<GpsPoint[]>([]);
  const [selectedGpsIndex, setSelectedGpsIndex] = useState<number | null>(null);
  const selectedGpsPoint = selectedGpsIndex != null ? gpsPoints[selectedGpsIndex] ?? null : null;

  // Fetch occurrences when a cluster is selected
  useEffect(() => {
    if (!selectedCluster) {
      setOccurrences([]);
      setOccurrenceIndex(0);
      return;
    }

    let cancelled = false;
    setLoadingOccurrences(true);
    (async () => {
      try {
        const { data, error } = await supabaseClient.rpc('get_cluster_occurrences', {
          p_centroid_lat: selectedCluster!.centroid_latitude,
          p_centroid_lng: selectedCluster!.centroid_longitude,
        });
        if (cancelled) return;
        if (error) {
          console.error('[cluster-occurrences] RPC error:', error);
          setOccurrences([]);
        } else {
          setOccurrences((data as ClusterOccurrence[]) || []);
        }
      } catch (err) {
        if (cancelled) return;
        console.error('[cluster-occurrences] fetch failed:', err);
        setOccurrences([]);
      } finally {
        if (!cancelled) {
          setOccurrenceIndex(0);
          setLoadingOccurrences(false);
        }
      }
    })();
    return () => { cancelled = true; };
  }, [selectedCluster?.cluster_id]);

  const currentOccurrence = occurrences[occurrenceIndex] || null;

  // Fetch GPS points when the current occurrence changes
  useEffect(() => {
    setSelectedGpsIndex(null);
    if (!currentOccurrence) {
      setGpsPoints([]);
      return;
    }
    let cancelled = false;
    (async () => {
      try {
        const { data, error } = await supabaseClient.rpc('get_cluster_gps_points', {
          p_cluster_id: currentOccurrence.cluster_id,
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
      }
    })();
    return () => { cancelled = true; };
  }, [currentOccurrence?.cluster_id]);

  const handleCloseCluster = () => {
    onClusterSelect(-1);
    setSelectedGpsIndex(null);
  };

  const handleCloseLocation = () => {
    setSelectedLocationId(null);
  };

  return (
    <div className="relative h-[500px] w-full rounded-xl overflow-hidden border border-slate-200 shadow-sm">
      <APIProvider apiKey={apiKey}>
        <Map
          defaultCenter={DEFAULT_CENTER}
          defaultZoom={DEFAULT_ZOOM}
          mapId="suggested_locations_map"
          disableDefaultUI={true}
          zoomControl={true}
        >
          {/* Existing location geofence circles */}
          {locations.map((loc) => (
            <GeofenceCircle
              key={loc.id}
              center={{ lat: loc.latitude, lng: loc.longitude }}
              radius={loc.radiusMeters}
              locationType={loc.locationType}
            />
          ))}

          {/* Existing location markers — white circle with colored type icon */}
          {locations.map((loc) => {
            const isLocSelected = loc.id === selectedLocationId;
            const color = getLocationTypeColor(loc.locationType);
            const Icon = LOCATION_TYPE_ICONS[loc.locationType as LocationType] || MapPin;
            return (
              <AdvancedMarker
                key={`loc-${loc.id}`}
                position={{ lat: loc.latitude, lng: loc.longitude }}
                onClick={() => {
                  setSelectedLocationId(isLocSelected ? null : loc.id);
                  if (selectedClusterId) onClusterSelect(-1);
                  setSelectedGpsIndex(null);
                }}
                zIndex={isLocSelected ? 800 : 100}
              >
                <div
                  className="rounded-full flex items-center justify-center shadow-md cursor-pointer transition-transform"
                  style={{
                    width: isLocSelected ? 32 : 26,
                    height: isLocSelected ? 32 : 26,
                    backgroundColor: 'white',
                    border: `${isLocSelected ? 3 : 2}px solid ${color}`,
                    transform: isLocSelected ? 'scale(1.15)' : 'scale(1)',
                  }}
                >
                  <Icon style={{ width: isLocSelected ? 16 : 13, height: isLocSelected ? 16 : 13, color }} />
                </div>
              </AdvancedMarker>
            );
          })}

          {/* Suggested cluster markers — teal circles with count */}
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
                  setSelectedGpsIndex(null);
                }}
                zIndex={isSelected ? 700 : 200}
              >
                <div
                  className="rounded-full flex items-center justify-center font-bold text-white shadow-md transition-all"
                  style={{
                    width: size,
                    height: size,
                    fontSize: size < 30 ? 10 : 12,
                    backgroundColor: isSelected ? SUGGESTED_COLOR_SELECTED : SUGGESTED_COLOR,
                    border: isSelected
                      ? `3px solid ${SUGGESTED_BORDER_SELECTED}`
                      : '2px solid white',
                    transform: isSelected ? 'scale(1.2)' : 'scale(1)',
                  }}
                >
                  {cluster.occurrence_count}
                </div>
              </AdvancedMarker>
            );
          })}

          {/* Individual GPS points for current occurrence — clickable */}
          {selectedCluster && currentOccurrence && gpsPoints.map((pt, i) => {
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

          {/* Occurrence centroid: accuracy circle + center dot */}
          {selectedCluster && currentOccurrence && (
            <>
              <AccuracyCircle
                center={{ lat: currentOccurrence.centroid_latitude, lng: currentOccurrence.centroid_longitude }}
                radius={currentOccurrence.centroid_accuracy ?? 0}
              />
              <AdvancedMarker
                position={{
                  lat: currentOccurrence.centroid_latitude,
                  lng: currentOccurrence.centroid_longitude,
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
              <PanToOccurrence
                position={{ lat: currentOccurrence.centroid_latitude, lng: currentOccurrence.centroid_longitude }}
                occurrenceIndex={occurrenceIndex}
              />
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

          <AutoFitClusters clusters={clusters} locations={locations} selectedClusterId={selectedClusterId} />
        </Map>
      </APIProvider>

      {/* Floating cluster detail card (bottom-left) */}
      {selectedCluster && (
        <div className="absolute bottom-3 left-3 z-[10] bg-white rounded-lg shadow-lg border border-teal-200 p-3 min-w-[220px] max-w-[300px]">
          <button
            onClick={handleCloseCluster}
            className="absolute top-1.5 right-1.5 p-0.5 rounded hover:bg-slate-100 text-slate-400 hover:text-slate-600"
          >
            <X className="h-3.5 w-3.5" />
          </button>

          {selectedCluster.place_name && (
            <h4 className="font-bold text-slate-900 text-sm mb-0.5 pr-5">
              {selectedCluster.place_name}
            </h4>
          )}
          <p className="text-xs text-slate-500 mb-1.5 pr-5">
            {selectedCluster.google_address || 'Adresse en cours...'}
          </p>
          <div className="flex items-center gap-1.5 mb-1.5 flex-wrap">
            <Badge variant="secondary" className="text-[10px]">
              {selectedCluster.occurrence_count} arrêt
              {selectedCluster.occurrence_count > 1 ? 's' : ''}
            </Badge>
            <Badge variant="outline" className="text-[10px]">
              {formatDuration(selectedCluster.total_duration_seconds)}
            </Badge>
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
                <span className="text-[10px] text-slate-400">
                  {currentOccurrence.gps_point_count} pts GPS
                </span>
              </div>
              <p className="text-[10px] text-slate-500">
                {new Date(currentOccurrence.started_at).toLocaleDateString('fr-CA', {
                  day: 'numeric',
                  month: 'short',
                })},{' '}
                {new Date(currentOccurrence.started_at).toLocaleTimeString('fr-CA', {
                  hour: '2-digit',
                  minute: '2-digit',
                })}
                {' — '}
                {new Date(currentOccurrence.ended_at).toLocaleTimeString('fr-CA', {
                  hour: '2-digit',
                  minute: '2-digit',
                })}
                <span className="text-slate-400">
                  {' · '}{formatDuration(currentOccurrence.duration_seconds)}
                </span>
              </p>
              <p className="text-[9px] text-slate-400 font-mono">
                ({currentOccurrence.centroid_latitude.toFixed(5)}, {currentOccurrence.centroid_longitude.toFixed(5)})
                {currentOccurrence.centroid_accuracy != null && (
                  <span className="text-slate-300">
                    {' '}± {Math.round(currentOccurrence.centroid_accuracy)}m
                  </span>
                )}
              </p>
              {occurrences.length > 1 && (
                <div className="flex items-center justify-center gap-2 mt-1.5">
                  <button
                    className="p-0.5 rounded hover:bg-slate-100 disabled:opacity-30"
                    disabled={occurrenceIndex === 0}
                    onClick={() => { setOccurrenceIndex((i) => i - 1); setSelectedGpsIndex(null); }}
                  >
                    <ChevronLeft className="h-3.5 w-3.5 text-slate-600" />
                  </button>
                  <span className="text-[10px] text-slate-500 tabular-nums">
                    {occurrenceIndex + 1} / {occurrences.length}
                  </span>
                  <button
                    className="p-0.5 rounded hover:bg-slate-100 disabled:opacity-30"
                    disabled={occurrenceIndex === occurrences.length - 1}
                    onClick={() => { setOccurrenceIndex((i) => i + 1); setSelectedGpsIndex(null); }}
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
            <Button
              variant="ghost"
              size="sm"
              className="h-7 text-[11px] text-muted-foreground"
              onClick={() => onIgnoreCluster(selectedCluster)}
            >
              <EyeOff className="h-3 w-3 mr-1" />
              Ignorer
            </Button>
          </div>
        </div>
      )}

      {/* Floating existing location detail card (bottom-left, when no cluster selected) */}
      {selectedLocation && !selectedCluster && (
        <div className="absolute bottom-3 left-3 z-[10] bg-white rounded-lg shadow-lg border border-slate-200 p-3 min-w-[180px] max-w-[260px]">
          <button
            onClick={handleCloseLocation}
            className="absolute top-1.5 right-1.5 p-0.5 rounded hover:bg-slate-100 text-slate-400 hover:text-slate-600"
          >
            <X className="h-3.5 w-3.5" />
          </button>
          <h4 className="font-bold text-slate-900 text-sm mb-0.5 pr-5">
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
              Précision: <strong>±{Math.round(selectedGpsPoint.accuracy)}m</strong>
            </p>
            {selectedGpsPoint.speed != null && (
              <p>
                Vitesse: <strong>{(selectedGpsPoint.speed * 3.6).toFixed(1)} km/h</strong>
                {selectedGpsPoint.speed_accuracy != null && (
                  <span className="text-slate-400"> (±{(selectedGpsPoint.speed_accuracy * 3.6).toFixed(1)})</span>
                )}
              </p>
            )}
            {selectedGpsPoint.altitude != null && (
              <p>
                Altitude: <strong>{Math.round(selectedGpsPoint.altitude)}m</strong>
                {selectedGpsPoint.altitude_accuracy != null && (
                  <span className="text-slate-400"> (±{Math.round(selectedGpsPoint.altitude_accuracy)}m)</span>
                )}
              </p>
            )}
            {selectedGpsPoint.heading != null && (
              <p>
                Cap: <strong>{Math.round(selectedGpsPoint.heading)}°</strong>
              </p>
            )}
            {selectedGpsPoint.activity_type && (
              <p>
                Activité: <strong>{selectedGpsPoint.activity_type}</strong>
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

function PanToOccurrence({ position, occurrenceIndex }: { position: google.maps.LatLngLiteral; occurrenceIndex: number }) {
  const map = useMap();
  useEffect(() => {
    if (!map) return;
    map.panTo(position);
  }, [map, position.lat, position.lng, occurrenceIndex]);
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
