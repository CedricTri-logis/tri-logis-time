'use client';

import { useState, useEffect, useCallback } from 'react';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Loader2, MapPin, Plus, Eye } from 'lucide-react';
import { toast } from 'sonner';
import { supabaseClient } from '@/lib/supabase/client';

interface UnmatchedCluster {
  cluster_id: number;
  centroid_latitude: number;
  centroid_longitude: number;
  occurrence_count: number;
  has_start_endpoints: boolean;
  has_end_endpoints: boolean;
  employee_names: string[];
  first_seen: string;
  last_seen: string;
  sample_addresses: string[];
  google_address?: string;
  google_loading?: boolean;
}

interface SuggestedLocationsTabProps {
  onCreateLocation: (prefill: {
    latitude: number;
    longitude: number;
    name: string;
    address: string;
  }) => void;
}

export function SuggestedLocationsTab({ onCreateLocation }: SuggestedLocationsTabProps) {
  const [clusters, setClusters] = useState<UnmatchedCluster[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  const fetchClusters = useCallback(async () => {
    setIsLoading(true);
    const { data, error } = await supabaseClient.rpc('get_unmatched_trip_clusters', {
      p_min_occurrences: 1,
    });
    if (error) {
      toast.error('Erreur lors du chargement des suggestions');
    } else {
      setClusters(data || []);
    }
    setIsLoading(false);
  }, []);

  useEffect(() => {
    fetchClusters();
  }, [fetchClusters]);

  const reverseGeocode = async (cluster: UnmatchedCluster) => {
    const apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY;
    if (!apiKey) {
      toast.error('Clé Google Maps non configurée');
      return;
    }

    setClusters((prev) =>
      prev.map((c) =>
        c.cluster_id === cluster.cluster_id ? { ...c, google_loading: true } : c
      )
    );

    try {
      const response = await fetch(
        `https://maps.googleapis.com/maps/api/geocode/json?latlng=${cluster.centroid_latitude},${cluster.centroid_longitude}&key=${apiKey}&language=fr`
      );
      const data = await response.json();
      const address = data.results?.[0]?.formatted_address || 'Adresse non trouvée';

      setClusters((prev) =>
        prev.map((c) =>
          c.cluster_id === cluster.cluster_id
            ? { ...c, google_address: address, google_loading: false }
            : c
        )
      );
    } catch {
      setClusters((prev) =>
        prev.map((c) =>
          c.cluster_id === cluster.cluster_id ? { ...c, google_loading: false } : c
        )
      );
      toast.error('Erreur de géocodage');
    }
  };

  const handleCreate = (cluster: UnmatchedCluster) => {
    const name = cluster.google_address?.split(',')[0] || `Emplacement ${cluster.cluster_id}`;
    const address = cluster.google_address || cluster.sample_addresses?.[0] || '';
    onCreateLocation({
      latitude: cluster.centroid_latitude,
      longitude: cluster.centroid_longitude,
      name,
      address,
    });
  };

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
          Tous les départs et arrivées de trajets correspondent à des emplacements connus.
        </p>
      </div>
    );
  }

  return (
    <div className="space-y-3">
      <p className="text-sm text-muted-foreground">
        {clusters.length} groupe{clusters.length > 1 ? 's' : ''} d&apos;emplacements non vérifiés.
        Cliquez sur &quot;Voir adresse&quot; pour obtenir une suggestion Google Maps.
      </p>
      {clusters.map((cluster) => (
        <Card key={cluster.cluster_id}>
          <CardContent className="p-4">
            <div className="flex items-start justify-between gap-4">
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2 mb-1">
                  <Badge variant="secondary" className="text-xs">
                    {cluster.occurrence_count} occurrence{cluster.occurrence_count > 1 ? 's' : ''}
                  </Badge>
                  {cluster.has_start_endpoints && (
                    <Badge variant="outline" className="text-xs">Départ</Badge>
                  )}
                  {cluster.has_end_endpoints && (
                    <Badge variant="outline" className="text-xs">Arrivée</Badge>
                  )}
                </div>

                {cluster.google_address ? (
                  <p className="text-sm font-medium">{cluster.google_address}</p>
                ) : cluster.sample_addresses?.length > 0 ? (
                  <p className="text-sm text-muted-foreground">{cluster.sample_addresses[0]}</p>
                ) : (
                  <p className="text-sm text-muted-foreground">
                    {cluster.centroid_latitude.toFixed(5)}, {cluster.centroid_longitude.toFixed(5)}
                  </p>
                )}

                <div className="text-xs text-muted-foreground mt-1 space-y-0.5">
                  {cluster.employee_names?.length > 0 && (
                    <p>Employés: {cluster.employee_names.join(', ')}</p>
                  )}
                  <p>
                    Période: {new Date(cluster.first_seen).toLocaleDateString('fr-CA')} —{' '}
                    {new Date(cluster.last_seen).toLocaleDateString('fr-CA')}
                  </p>
                </div>
              </div>

              <div className="flex flex-col gap-1">
                {!cluster.google_address && (
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => reverseGeocode(cluster)}
                    disabled={cluster.google_loading}
                  >
                    {cluster.google_loading ? (
                      <Loader2 className="h-3 w-3 animate-spin mr-1" />
                    ) : (
                      <Eye className="h-3 w-3 mr-1" />
                    )}
                    Voir adresse
                  </Button>
                )}
                <Button
                  variant="default"
                  size="sm"
                  onClick={() => handleCreate(cluster)}
                >
                  <Plus className="h-3 w-3 mr-1" />
                  Créer
                </Button>
              </div>
            </div>
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
