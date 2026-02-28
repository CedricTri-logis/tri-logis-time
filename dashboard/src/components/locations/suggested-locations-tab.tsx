'use client';

import { useState, useEffect, useCallback } from 'react';
import dynamic from 'next/dynamic';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Skeleton } from '@/components/ui/skeleton';
import { EyeOff, Loader2, MapPin, Plus } from 'lucide-react';
import { toast } from 'sonner';
import { supabaseClient } from '@/lib/supabase/client';
import type { MapCluster } from './suggested-locations-map';
import type { Location } from '@/types/location';

const SuggestedLocationsMap = dynamic(
  () =>
    import('./suggested-locations-map').then((m) => ({
      default: m.SuggestedLocationsMap,
    })),
  {
    ssr: false,
    loading: () => <Skeleton className="h-[500px] w-full rounded-xl" />,
  }
);

type UnmatchedCluster = MapCluster;

interface SuggestedLocationsTabProps {
  onCreateLocation: (prefill: {
    latitude: number;
    longitude: number;
    name: string;
    address: string;
  }) => void;
  locations?: Location[];
  refreshKey?: number;
}

async function enrichClusters(rawClusters: UnmatchedCluster[]): Promise<UnmatchedCluster[]> {
  const apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY;
  if (!apiKey || rawClusters.length === 0) return rawClusters;

  const enriched = await Promise.all(
    rawClusters.map(async (cluster) => {
      let address: string | null = null;
      let placeName: string | null = null;

      // 1. Reverse geocode for address
      try {
        const geoRes = await fetch(
          `https://maps.googleapis.com/maps/api/geocode/json?latlng=${cluster.centroid_latitude},${cluster.centroid_longitude}&key=${apiKey}&language=fr`
        );
        const geoData = await geoRes.json();
        address = geoData.results?.[0]?.formatted_address || address;
      } catch {
        /* keep fallback */
      }

      // 2. Places Nearby Search (New API) for business name
      try {
        const placesRes = await fetch(
          'https://places.googleapis.com/v1/places:searchNearby',
          {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              'X-Goog-Api-Key': apiKey,
              'X-Goog-FieldMask':
                'places.displayName,places.formattedAddress,places.types',
            },
            body: JSON.stringify({
              locationRestriction: {
                circle: {
                  center: {
                    latitude: cluster.centroid_latitude,
                    longitude: cluster.centroid_longitude,
                  },
                  radius: 50.0,
                },
              },
              maxResultCount: 1,
              languageCode: 'fr',
            }),
          }
        );
        const placesData = await placesRes.json();
        placeName = placesData.places?.[0]?.displayName?.text || null;
        if (!address && placesData.places?.[0]?.formattedAddress) {
          address = placesData.places[0].formattedAddress;
        }
      } catch {
        /* no business name found */
      }

      return { ...cluster, google_address: address, place_name: placeName };
    })
  );

  return enriched;
}

function formatDuration(seconds: number): string {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (hours > 0) return `${hours}h ${minutes}min`;
  return `${minutes}min`;
}

export function SuggestedLocationsTab({ onCreateLocation, locations = [], refreshKey }: SuggestedLocationsTabProps) {
  const [clusters, setClusters] = useState<UnmatchedCluster[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [isEnriching, setIsEnriching] = useState(false);
  const [selectedClusterId, setSelectedClusterId] = useState<number | null>(null);

  const fetchClusters = useCallback(async () => {
    setIsLoading(true);
    const { data, error } = await supabaseClient.rpc('get_unmatched_trip_clusters', {
      p_min_occurrences: 1,
    });
    if (error) {
      toast.error('Erreur lors du chargement des suggestions');
      setIsLoading(false);
      return;
    }

    const raw = (data || []) as UnmatchedCluster[];
    setClusters(raw);
    setIsLoading(false);

    // Auto-enrich in background
    if (raw.length > 0) {
      setIsEnriching(true);
      const enriched = await enrichClusters(raw);
      setClusters(enriched);
      setIsEnriching(false);
    }
  }, []);

  useEffect(() => {
    fetchClusters();
  }, [fetchClusters, refreshKey]);

  const handleCreate = (cluster: UnmatchedCluster) => {
    const name =
      cluster.place_name ||
      cluster.google_address?.split(',')[0] ||
      `Emplacement ${cluster.cluster_id}`;
    const address = cluster.google_address || '';
    onCreateLocation({
      latitude: cluster.centroid_latitude,
      longitude: cluster.centroid_longitude,
      name,
      address,
    });
  };

  const handleIgnoreCluster = useCallback(async (cluster: UnmatchedCluster) => {
    const { error } = await supabaseClient.rpc('ignore_location_cluster', {
      p_latitude: cluster.centroid_latitude,
      p_longitude: cluster.centroid_longitude,
      p_occurrence_count: cluster.occurrence_count,
    });
    if (error) {
      toast.error('Erreur lors de l\'ignorance du groupe');
      return;
    }
    // Remove the cluster from the list
    setClusters((prev) => prev.filter((c) => c.cluster_id !== cluster.cluster_id));
    setSelectedClusterId(null);
    toast.success('Groupe ignoré');
  }, []);

  const handleClusterSelect = useCallback((clusterId: number) => {
    if (clusterId < 0) {
      setSelectedClusterId(null);
      return;
    }
    setSelectedClusterId(clusterId);
  }, []);

  const handleCardClick = useCallback((clusterId: number) => {
    setSelectedClusterId((prev) => (prev === clusterId ? null : clusterId));
  }, []);

  // Highlight card when selected from map (no scroll — details visible in map InfoWindow)
  // Card highlight is handled via the ring-2 class in the render below

  if (isLoading) {
    return (
      <div className="flex items-center justify-center py-12">
        <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
      </div>
    );
  }

  if (clusters.length === 0) {
    return (
      <div className="text-center py-12 text-muted-foreground">
        <MapPin className="h-8 w-8 mx-auto mb-2 opacity-50" />
        <p>Aucun emplacement non vérifié</p>
        <p className="text-xs mt-1">
          Tous les arrêts détectés correspondent à des emplacements connus.
        </p>
      </div>
    );
  }

  return (
    <div className="space-y-3">
      <SuggestedLocationsMap
        clusters={clusters}
        selectedClusterId={selectedClusterId}
        onClusterSelect={handleClusterSelect}
        onCreateFromCluster={(mapCluster) => {
          const cluster = clusters.find((c) => c.cluster_id === mapCluster.cluster_id);
          if (cluster) handleCreate(cluster);
        }}
        onIgnoreCluster={(mapCluster) => {
          const cluster = clusters.find((c) => c.cluster_id === mapCluster.cluster_id);
          if (cluster) handleIgnoreCluster(cluster);
        }}
        locations={locations}
      />

      <p className="text-sm text-muted-foreground">
        {clusters.length} groupe{clusters.length > 1 ? 's' : ''} d&apos;emplacements non
        vérifiés.
        {isEnriching && (
          <span className="inline-flex items-center gap-1 ml-1">
            <Loader2 className="h-3 w-3 animate-spin" />
            Chargement des adresses...
          </span>
        )}
      </p>

      {clusters.map((cluster) => {
        const isSelected = cluster.cluster_id === selectedClusterId;
        return (
          <Card
            key={cluster.cluster_id}
            className={`cursor-pointer transition-all ${
              isSelected
                ? 'ring-2 ring-teal-500 shadow-md'
                : 'hover:shadow-sm'
            }`}
            onClick={() => handleCardClick(cluster.cluster_id)}
          >
            <CardContent className="p-4">
              <div className="flex items-start justify-between gap-4">
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2 mb-1">
                    <Badge variant="secondary" className="text-xs">
                      {cluster.occurrence_count} occurrence
                      {cluster.occurrence_count > 1 ? 's' : ''}
                    </Badge>
                  </div>

                  {cluster.place_name && (
                    <p className="text-sm font-semibold text-slate-900">
                      {cluster.place_name}
                    </p>
                  )}

                  {cluster.google_address ? (
                    <p className={`text-sm ${cluster.place_name ? 'text-muted-foreground' : 'font-medium'}`}>
                      {cluster.google_address}
                    </p>
                  ) : (
                    <p className="text-sm text-muted-foreground">
                      {cluster.centroid_latitude.toFixed(5)},{' '}
                      {cluster.centroid_longitude.toFixed(5)}
                    </p>
                  )}

                  <div className="text-xs text-muted-foreground mt-1 space-y-0.5">
                    {cluster.employee_names?.length > 0 && (
                      <p>Employés: {cluster.employee_names.join(', ')}</p>
                    )}
                    <p>
                      Période:{' '}
                      {new Date(cluster.first_seen).toLocaleDateString('fr-CA')} —{' '}
                      {new Date(cluster.last_seen).toLocaleDateString('fr-CA')}
                    </p>
                  </div>
                </div>

                <div className="flex flex-col gap-1">
                  <Button
                    variant="default"
                    size="sm"
                    onClick={(e) => {
                      e.stopPropagation();
                      handleCreate(cluster);
                    }}
                  >
                    <Plus className="h-3 w-3 mr-1" />
                    Créer
                  </Button>
                  <Button
                    variant="ghost"
                    size="sm"
                    className="text-muted-foreground"
                    onClick={(e) => {
                      e.stopPropagation();
                      handleIgnoreCluster(cluster);
                    }}
                  >
                    <EyeOff className="h-3 w-3 mr-1" />
                    Ignorer
                  </Button>
                </div>
              </div>
            </CardContent>
          </Card>
        );
      })}
    </div>
  );
}
