'use client';

import { useState, useEffect, useMemo } from 'react';
import { AlertTriangle } from 'lucide-react';
import { supabaseClient } from '@/lib/supabase/client';
import { GoogleTripRouteMap } from '@/components/trips/google-trip-route-map';
import { detectTripStops, detectGpsClusters } from '@/lib/utils/detect-trip-stops';
import { formatDurationMinutes, formatDistance } from '@/lib/utils/activity-display';
import type { ApprovalActivity, TripGpsPoint } from '@/types/mileage';
import { resolveGeocodedName, type GeocodeResult } from '@/lib/hooks/use-reverse-geocode';

export function TripExpandDetail({ activity, geocodedAddresses }: { activity: ApprovalActivity; geocodedAddresses?: Map<string, GeocodeResult> }) {
  const [gpsPoints, setGpsPoints] = useState<TripGpsPoint[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  const stops = useMemo(() => detectTripStops(gpsPoints), [gpsPoints]);
  const gpsClusters = useMemo(() => detectGpsClusters(gpsPoints), [gpsPoints]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data } = await supabaseClient
        .from('trip_gps_points')
        .select(`
          sequence_order,
          gps_point:gps_points(latitude, longitude, accuracy, speed, heading, altitude, captured_at)
        `)
        .eq('trip_id', activity.activity_id)
        .order('sequence_order', { ascending: true });

      if (cancelled) return;

      if (data) {
        const points: TripGpsPoint[] = data
          .filter((d: any) => d.gps_point)
          .map((d: any) => ({
            sequence_order: d.sequence_order,
            latitude: d.gps_point.latitude,
            longitude: d.gps_point.longitude,
            accuracy: d.gps_point.accuracy,
            speed: d.gps_point.speed,
            heading: d.gps_point.heading,
            altitude: d.gps_point.altitude,
            captured_at: d.gps_point.captured_at,
          }));
        setGpsPoints(points);
      }
      setIsLoading(false);
    })();
    return () => { cancelled = true; };
  }, [activity.activity_id]);

  const tripForMap = {
    id: activity.activity_id,
    start_latitude: activity.latitude ?? 0,
    start_longitude: activity.longitude ?? 0,
    end_latitude: activity.latitude ?? 0,
    end_longitude: activity.longitude ?? 0,
    match_status: 'pending' as const,
    route_geometry: null,
    distance_km: activity.distance_km ?? 0,
    road_distance_km: activity.road_distance_km,
    duration_minutes: activity.duration_minutes,
    classification: 'business' as const,
    gps_point_count: 0,
    transport_mode: (activity.transport_mode ?? 'driving') as 'driving' | 'walking' | 'unknown',
  } as any;

  // Use GPS points for start/end if available
  if (gpsPoints.length > 0) {
    tripForMap.start_latitude = gpsPoints[0].latitude;
    tripForMap.start_longitude = gpsPoints[0].longitude;
    tripForMap.end_latitude = gpsPoints[gpsPoints.length - 1].latitude;
    tripForMap.end_longitude = gpsPoints[gpsPoints.length - 1].longitude;
    tripForMap.gps_point_count = gpsPoints.length;
  }

  const startLat = gpsPoints.length > 0 ? gpsPoints[0].latitude : activity.latitude;
  const startLng = gpsPoints.length > 0 ? gpsPoints[0].longitude : activity.longitude;
  const endLat = gpsPoints.length > 0 ? gpsPoints[gpsPoints.length - 1].latitude : activity.latitude;
  const endLng = gpsPoints.length > 0 ? gpsPoints[gpsPoints.length - 1].longitude : activity.longitude;

  const from = activity.start_location_name || resolveGeocodedName(startLat, startLng, geocodedAddresses, 'Inconnu');
  const to = activity.end_location_name || resolveGeocodedName(endLat, endLng, geocodedAddresses, 'Inconnu');

  return (
    <div className="grid grid-cols-1 lg:grid-cols-3 gap-6 p-4 bg-muted/30 rounded-lg">
      <div className="lg:col-span-2">
        <GoogleTripRouteMap
          trips={[tripForMap]}
          gpsPoints={gpsPoints}
          stops={stops}
          clusters={gpsClusters}
          height={300}
          showGpsPoints={gpsPoints.length > 0}
        />
        {isLoading && (
          <p className="text-xs text-muted-foreground mt-1">Chargement des points GPS...</p>
        )}
      </div>
      <div className="grid grid-cols-2 gap-y-4 text-sm content-start">
        {(activity.has_gps_gap || (activity.gps_gap_seconds ?? 0) > 0) && (
          <div className="col-span-2 flex items-center gap-2 p-2 mb-2 bg-amber-50 border border-amber-200 rounded text-xs text-amber-700">
            <AlertTriangle className="h-4 w-4 flex-shrink-0" />
            <span>
              {activity.has_gps_gap && (activity.gps_gap_seconds ?? 0) === 0
                ? 'Trajet sans trace GPS — aucune donnée de parcours disponible'
                : `Signal GPS perdu — ${Math.round((activity.gps_gap_seconds ?? 0) / 60)} min (${activity.gps_gap_count ?? 0})`
              }
            </span>
          </div>
        )}
        <div>
          <span className="text-xs text-muted-foreground block">D&eacute;part</span>
          <span className="font-medium">{from}</span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Arriv&eacute;e</span>
          <span className="font-medium">{to}</span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Distance GPS</span>
          <span className="font-medium">{formatDistance(activity.distance_km)}</span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Distance route</span>
          <span className="font-medium">{formatDistance(activity.road_distance_km)}</span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Dur&eacute;e</span>
          <span className="font-medium">{formatDurationMinutes(activity.duration_minutes)}</span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Mode</span>
          <span className="font-medium">
            {activity.transport_mode === 'walking' ? 'À pied' : activity.transport_mode === 'driving' ? 'Auto' : 'Inconnu'}
          </span>
        </div>
        <div className="col-span-2">
          <span className="text-xs text-muted-foreground block">Classification auto</span>
          <span className="text-xs">{activity.auto_reason}</span>
          {activity.override_status && (
            <span className="text-xs text-blue-600 ml-1">(modifié manuellement)</span>
          )}
        </div>
      </div>
    </div>
  );
}
