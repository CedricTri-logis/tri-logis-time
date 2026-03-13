'use client';

import { useState, useEffect } from 'react';
import { AlertTriangle } from 'lucide-react';
import { supabaseClient } from '@/lib/supabase/client';
import { GoogleTripRouteMap } from '@/components/trips/google-trip-route-map';
import { formatDistance, formatDurationMinutes } from '@/lib/utils/activity-display';
import type { ApprovalActivity } from '@/types/mileage';

export function GapExpandDetail({ activity }: { activity: ApprovalActivity }) {
  const [endCoords, setEndCoords] = useState<{ lat: number; lng: number } | null>(null);
  const [routeGeometry, setRouteGeometry] = useState<string | null>(null);
  const [roadDistanceKm, setRoadDistanceKm] = useState<number | null>(activity.road_distance_km ?? null);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      // Fetch end location coordinates
      let endLat = activity.latitude ?? 0;
      let endLng = activity.longitude ?? 0;

      if (activity.end_location_id) {
        const { data } = await supabaseClient
          .from('locations')
          .select('latitude, longitude')
          .eq('id', activity.end_location_id)
          .single();
        if (!cancelled && data) {
          endLat = data.latitude;
          endLng = data.longitude;
          setEndCoords({ lat: endLat, lng: endLng });
        }
      }

      // Call OSRM route-between-points for the road route
      const startLat = activity.latitude ?? 0;
      const startLng = activity.longitude ?? 0;
      if (startLat !== endLat || startLng !== endLng) {
        try {
          const { data: routeData } = await supabaseClient.functions.invoke('route-between-points', {
            body: { start_lat: startLat, start_lng: startLng, end_lat: endLat, end_lng: endLng },
          });
          if (!cancelled && routeData?.success) {
            setRouteGeometry(routeData.route_geometry);
            if (routeData.road_distance_km) setRoadDistanceKm(routeData.road_distance_km);
          }
        } catch { /* OSRM unavailable — show markers only */ }
      }

      if (!cancelled) setIsLoading(false);
    })();
    return () => { cancelled = true; };
  }, [activity.end_location_id, activity.latitude, activity.longitude]);

  const startLat = activity.latitude ?? 0;
  const startLng = activity.longitude ?? 0;
  const endLat = endCoords?.lat ?? startLat;
  const endLng = endCoords?.lng ?? startLng;

  const tripForMap = {
    id: activity.activity_id,
    start_latitude: startLat,
    start_longitude: startLng,
    end_latitude: endLat,
    end_longitude: endLng,
    match_status: routeGeometry ? 'matched' as const : 'pending' as const,
    route_geometry: routeGeometry,
    distance_km: activity.distance_km ?? 0,
    road_distance_km: roadDistanceKm,
    duration_minutes: activity.duration_minutes,
    classification: 'business' as const,
    gps_point_count: 0,
    transport_mode: 'driving' as 'driving' | 'walking' | 'unknown',
  } as any;

  return (
    <div className="grid grid-cols-1 lg:grid-cols-3 gap-6 p-4 bg-amber-50/30 rounded-lg border border-amber-200">
      <div className="lg:col-span-2">
        <GoogleTripRouteMap
          trips={[tripForMap]}
          gpsPoints={[]}
          stops={[]}
          clusters={[]}
          height={300}
          showGpsPoints={false}
        />
        {isLoading && (
          <p className="text-xs text-muted-foreground mt-1">Chargement...</p>
        )}
      </div>
      <div className="grid grid-cols-2 gap-y-4 text-sm content-start">
        <div className="col-span-2 flex items-center gap-2 p-2 mb-2 bg-amber-50 border border-amber-200 rounded text-xs text-amber-700">
          <AlertTriangle className="h-4 w-4 flex-shrink-0" />
          <span>D&eacute;placement non trac&eacute; &mdash; trajet estim&eacute; entre les deux points connus</span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">D&eacute;part</span>
          <span className="font-medium">{activity.start_location_name || 'Inconnu'}</span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Arriv&eacute;e</span>
          <span className="font-medium">{activity.end_location_name || 'Inconnu'}</span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Distance vol d'oiseau</span>
          <span className="font-medium">{formatDistance(activity.distance_km)}</span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Distance route (OSRM)</span>
          <span className="font-medium">
            {isLoading ? '...' : roadDistanceKm ? formatDistance(roadDistanceKm) : '—'}
          </span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Dur&eacute;e</span>
          <span className="font-medium">{formatDurationMinutes(activity.duration_minutes)}</span>
        </div>
        <div className="col-span-2">
          <span className="text-xs text-muted-foreground block">Classification auto</span>
          <span className="text-xs">{activity.auto_reason}</span>
        </div>
      </div>
    </div>
  );
}
