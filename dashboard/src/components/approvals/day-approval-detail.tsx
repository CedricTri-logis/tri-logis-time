'use client';

import { useState, useEffect, useCallback, useMemo, useRef } from 'react';
import { Sheet, SheetContent, SheetHeader, SheetTitle } from '@/components/ui/sheet';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Textarea } from '@/components/ui/textarea';
import {
  Loader2,
  CheckCircle2,
  XCircle,
  AlertTriangle,
  MapPin,
  MapPinOff,
  Car,
  Footprints,
  MoveRight,
  Clock,
  LogIn,
  LogOut,
  ChevronDown,
  ChevronUp,
  ArrowRight,
  Calendar,
  User,
  WifiOff,
  UtensilsCrossed,
} from 'lucide-react';
import { toast } from 'sonner';
import { supabaseClient } from '@/lib/supabase/client';
import { GoogleTripRouteMap } from '@/components/trips/google-trip-route-map';
import { StationaryClustersMap } from '@/components/mileage/stationary-clusters-map';
import type { StationaryCluster } from '@/components/mileage/stationary-clusters-map';
import { detectTripStops, detectGpsClusters } from '@/lib/utils/detect-trip-stops';
import { LOCATION_TYPE_ICON_MAP } from '@/lib/constants/location-icons';
import { LOCATION_TYPE_LABELS } from '@/lib/validations/location';
import { mergeClockEvents, type ProcessedActivity } from '@/lib/utils/merge-clock-events';
import { formatTime, formatDuration, formatDurationMinutes, formatDistance } from '@/lib/utils/activity-display';
import type { LocationType } from '@/types/location';
import type {
  DayApprovalDetail as DayApprovalDetailType,
  ApprovalActivity,
  TripGpsPoint,
  ProjectSession,
} from '@/types/mileage';
import {
  type ProjectSlice,
  getProjectSlices,
  type MergedGroup,
  type DisplayItem,
  mergeSameLocationGaps,
  formatHours,
  formatDate,
  STATUS_BADGE,
} from './approval-utils';

// --- Project cell component ---

function ProjectCell({ slices }: { slices: ProjectSlice[] }) {
  if (slices.length === 0) return <td className="px-3 py-3"><span className="text-[10px] text-muted-foreground/40">—</span></td>;

  return (
    <td className="px-3 py-3">
      <div className="flex flex-col gap-0.5">
        {slices.map((slice, i) => {
          if (slice.type === 'gap') {
            return (
              <div key={`gap-${i}`} className="flex items-center gap-1.5 text-[11px] text-amber-600">
                <span className="flex-shrink-0">⚠️</span>
                <span className="truncate">Aucun projet</span>
                <span className="text-[10px] tabular-nums text-amber-500 ml-auto whitespace-nowrap">
                  {formatDurationMinutes(slice.duration_minutes)}
                </span>
              </div>
            );
          }

          const ps = slice.session!;
          const icon = ps.session_type === 'cleaning' ? '🧹' : '🔧';
          const label = ps.unit_label
            ? `${ps.building_name} #${ps.unit_label}`
            : ps.building_name;

          return (
            <div key={ps.session_id} className="flex items-center gap-1.5 text-[11px] text-foreground">
              <span className="flex-shrink-0">{icon}</span>
              <span className="truncate" title={label}>{label}</span>
              <span className="text-[10px] tabular-nums text-muted-foreground ml-auto whitespace-nowrap">
                {formatDurationMinutes(slice.duration_minutes)}
              </span>
            </div>
          );
        })}
      </div>
    </td>
  );
}

interface DayApprovalDetailProps {
  employeeId: string;
  employeeName: string;
  date: string;
  onClose: () => void;
}

// --- Icon helper for approval activities ---

function ApprovalActivityIcon({ activity }: { activity: ApprovalActivity }) {
  if (activity.activity_type === 'lunch') {
    return <UtensilsCrossed className="h-4 w-4 text-orange-500" />;
  }
  if (activity.activity_type === 'gap') {
    // Clock gaps have start/end location names from the SQL function
    if (activity.start_location_name || activity.end_location_name) {
      // Clock-in gap: starts from clock location (no start_location_id), ends at first cluster
      if (!activity.start_location_id && activity.end_location_id) return <LogIn className="h-4 w-4 text-amber-500" />;
      // Clock-out gap: starts from last cluster, ends at clock location (no end_location_id)
      if (activity.start_location_id && !activity.end_location_id) return <LogOut className="h-4 w-4 text-amber-500" />;
    }
    return <WifiOff className="h-4 w-4 text-purple-500" />;
  }
  if (activity.activity_type === 'trip') {
    if (activity.transport_mode === 'walking') return <Footprints className="h-4 w-4 text-orange-500" />;
    if (activity.transport_mode === 'driving') return <Car className="h-4 w-4 text-blue-500" />;
    return <MoveRight className="h-4 w-4 text-gray-400" />;
  }
  // Stop or standalone clock — use location type icon if available
  if (activity.location_name && activity.location_type) {
    const entry = LOCATION_TYPE_ICON_MAP[activity.location_type as LocationType];
    if (entry) {
      const Icon = entry.icon;
      return <Icon className={entry.className} />;
    }
  }
  if (activity.location_name) return <MapPin className="h-4 w-4 text-green-500" />;
  // Unknown location — MapPinOff for clocks, amber MapPin for stops
  if (activity.activity_type === 'clock_in' || activity.activity_type === 'clock_out') {
    return <MapPinOff className="h-4 w-4 text-amber-500" />;
  }
  return <MapPin className="h-4 w-4 text-amber-500" />;
}

// --- Trip expand detail (fetch GPS points, show map) ---

function TripExpandDetail({ activity }: { activity: ApprovalActivity }) {
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

  const from = activity.start_location_name || 'Inconnu';
  const to = activity.end_location_name || 'Inconnu';

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

// --- Gap expand detail (show route map between start/end) ---

function GapExpandDetail({ activity }: { activity: ApprovalActivity }) {
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

// --- Stop expand detail (show cluster map) ---

function StopExpandDetail({ activity }: { activity: ApprovalActivity }) {
  const cluster: StationaryCluster = {
    id: activity.activity_id,
    shift_id: activity.shift_id,
    employee_id: '',
    employee_name: '',
    centroid_latitude: activity.latitude ?? 0,
    centroid_longitude: activity.longitude ?? 0,
    centroid_accuracy: null,
    started_at: activity.started_at,
    ended_at: activity.ended_at,
    duration_seconds: activity.duration_minutes * 60,
    gps_point_count: 0,
    matched_location_id: activity.matched_location_id,
    matched_location_name: activity.location_name,
    created_at: activity.started_at,
  };

  return (
    <div className="grid grid-cols-1 lg:grid-cols-3 gap-6 p-4 bg-muted/30 rounded-lg">
      <div className="lg:col-span-2">
        <StationaryClustersMap
          clusters={[cluster]}
          height={300}
          selectedClusterId={activity.activity_id}
        />
      </div>
      <div className="grid grid-cols-2 gap-y-4 text-sm content-start">
        {(activity.gps_gap_seconds ?? 0) > 0 && (
          <div className="col-span-2 flex items-center gap-2 p-2 mb-2 bg-amber-50 border border-amber-200 rounded text-xs text-amber-700">
            <AlertTriangle className="h-4 w-4 flex-shrink-0" />
            <span>
              Signal GPS perdu pendant {Math.round((activity.gps_gap_seconds ?? 0) / 60)} min
              ({activity.gps_gap_count ?? 0} interruption{(activity.gps_gap_count ?? 0) > 1 ? 's' : ''})
            </span>
          </div>
        )}
        <div className="col-span-2">
          <span className="text-xs text-muted-foreground block">Emplacement</span>
          <span className={`font-medium ${activity.location_name ? 'text-green-600' : 'text-amber-600'}`}>
            {activity.location_name || 'Non associé'}
          </span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Durée</span>
          <span className="font-medium">{formatDurationMinutes(activity.duration_minutes)}</span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Coordonnées</span>
          <span className="font-mono text-xs">
            {activity.latitude?.toFixed(6)}, {activity.longitude?.toFixed(6)}
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

// --- Main component ---

export function DayApprovalDetail({ employeeId, employeeName, date, onClose }: DayApprovalDetailProps) {
  const [detail, setDetail] = useState<DayApprovalDetailType | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isSaving, setIsSaving] = useState(false);
  const [notes, setNotes] = useState('');
  const [showNotes, setShowNotes] = useState(false);
  const [expandedId, setExpandedId] = useState<string | null>(null);

  // Resizable panel
  const [panelWidth, setPanelWidth] = useState(50); // vw
  const isDragging = useRef(false);
  const startX = useRef(0);
  const startWidth = useRef(50);

  useEffect(() => {
    const onMouseMove = (e: MouseEvent) => {
      if (!isDragging.current) return;
      const deltaVw = ((startX.current - e.clientX) / window.innerWidth) * 100;
      const newWidth = Math.min(90, Math.max(25, startWidth.current + deltaVw));
      setPanelWidth(newWidth);
    };
    const onMouseUp = () => {
      if (isDragging.current) {
        isDragging.current = false;
        document.body.style.cursor = '';
        document.body.style.userSelect = '';
      }
    };
    window.addEventListener('mousemove', onMouseMove);
    window.addEventListener('mouseup', onMouseUp);
    return () => {
      window.removeEventListener('mousemove', onMouseMove);
      window.removeEventListener('mouseup', onMouseUp);
    };
  }, []);

  const onDragStart = useCallback((e: React.MouseEvent) => {
    e.preventDefault();
    isDragging.current = true;
    startX.current = e.clientX;
    startWidth.current = panelWidth;
    document.body.style.cursor = 'col-resize';
    document.body.style.userSelect = 'none';
  }, [panelWidth]);

  const fetchDetail = useCallback(async () => {
    setIsLoading(true);
    try {
      const { data, error } = await supabaseClient.rpc('get_day_approval_detail', {
        p_employee_id: employeeId,
        p_date: date,
      });
      if (error) {
        toast.error('Erreur lors du chargement: ' + error.message);
        return;
      }
      setDetail(data as DayApprovalDetailType);
    } catch {
      toast.error('Erreur lors du chargement');
    } finally {
      setIsLoading(false);
    }
  }, [employeeId, date]);

  useEffect(() => {
    fetchDetail();
  }, [fetchDetail]);

  // Merge clock events into stops
  const processedActivities = useMemo(() => {
    if (!detail) return [];
    return mergeClockEvents(detail.activities);
  }, [detail]);

  // Merge same-location GPS gaps into grouped rows
  const displayItems = useMemo(() => {
    return mergeSameLocationGaps(processedActivities);
  }, [processedActivities]);

  // Client-side visible needs_review count (excludes trips — they derive from stops)
  const visibleNeedsReviewCount = useMemo(() =>
    processedActivities.filter(pa =>
      pa.item.final_status === 'needs_review' &&
      pa.item.activity_type !== 'trip'
    ).length
  , [processedActivities]);

  // Duration by location type (for summary badges)
  const durationStats = useMemo(() => {
    if (!detail) return { totalTravelSeconds: 0, stopByType: {} as Record<string, number>, totalGapSeconds: 0 };
    const trips = detail.activities.filter(a => a.activity_type === 'trip');
    const stops = detail.activities.filter(a => a.activity_type === 'stop');
    const gaps = detail.activities.filter(a => a.activity_type === 'gap');
    const totalTravelSeconds = trips.reduce((sum, t) => sum + (t.duration_minutes || 0) * 60, 0);
    const totalGapSeconds = gaps.reduce((sum, g) => sum + (g.duration_minutes || 0) * 60, 0);
    const stopByType: Record<string, number> = {};
    for (const stop of stops) {
      const key = stop.location_type || '_unmatched';
      stopByType[key] = (stopByType[key] || 0) + (stop.duration_minutes || 0) * 60;
    }
    return { totalTravelSeconds, stopByType, totalGapSeconds };
  }, [detail]);

  const gpsGapTotals = useMemo(() => {
    if (!detail?.activities) return { seconds: 0, count: 0 };
    return detail.activities.reduce(
      (acc, a) => ({
        seconds: acc.seconds + (a.gps_gap_seconds ?? 0),
        count: acc.count + (a.gps_gap_count ?? 0),
      }),
      { seconds: 0, count: 0 }
    );
  }, [detail?.activities]);

  const handleOverride = async (activity: ApprovalActivity, newStatus: 'approved' | 'rejected') => {
    if (activity.override_status === newStatus) {
      setIsSaving(true);
      try {
        const { data, error } = await supabaseClient.rpc('remove_activity_override', {
          p_employee_id: employeeId,
          p_date: date,
          p_activity_type: activity.activity_type,
          p_activity_id: activity.activity_id,
        });
        if (error) {
          toast.error('Erreur: ' + error.message);
          return;
        }
        setDetail(data as DayApprovalDetailType);
      } finally {
        setIsSaving(false);
      }
      return;
    }

    setIsSaving(true);
    try {
      const { data, error } = await supabaseClient.rpc('save_activity_override', {
        p_employee_id: employeeId,
        p_date: date,
        p_activity_type: activity.activity_type,
        p_activity_id: activity.activity_id,
        p_status: newStatus,
      });
      if (error) {
        toast.error('Erreur: ' + error.message);
        return;
      }
      setDetail(data as DayApprovalDetailType);
    } finally {
      setIsSaving(false);
    }
  };

  const handleApproveDay = async () => {
    setIsSaving(true);
    try {
      const { data, error } = await supabaseClient.rpc('approve_day', {
        p_employee_id: employeeId,
        p_date: date,
        p_notes: notes || null,
      });
      if (error) {
        toast.error('Erreur: ' + error.message);
        return;
      }
      setDetail(data as DayApprovalDetailType);
      toast.success('Journée approuvée');
    } finally {
      setIsSaving(false);
    }
  };

  const handleReopenDay = async () => {
    setIsSaving(true);
    try {
      const { data, error } = await supabaseClient.rpc('reopen_day', {
        p_employee_id: employeeId,
        p_date: date,
      });
      if (error) {
        toast.error('Erreur: ' + error.message);
        return;
      }
      setDetail(data as DayApprovalDetailType);
      toast.success('Journée rouverte');
    } finally {
      setIsSaving(false);
    }
  };

  const isApproved = detail?.approval_status === 'approved';
  const canApprove = detail && !isApproved && visibleNeedsReviewCount === 0 && !detail.has_active_shift;

  return (
    <Sheet open onOpenChange={() => onClose()}>
      <SheetContent
        className="overflow-y-auto !max-w-none"
        style={{ width: `${panelWidth}vw` }}
        side="right"
      >
        {/* Resize drag handle */}
        <div
          onMouseDown={onDragStart}
          className="absolute inset-y-0 left-0 w-1.5 cursor-col-resize hover:bg-primary/20 active:bg-primary/30 transition-colors z-10"
        />
        
        <div className="flex flex-col gap-6 pb-6 mb-2 border-b">
          <div className="flex items-start justify-between">
            <div className="space-y-1.5">
              <div className="flex items-center gap-2.5">
                <div className="h-10 w-10 rounded-full bg-primary/10 flex items-center justify-center text-primary border border-primary/20">
                  <User className="h-5 w-5" />
                </div>
                <SheetTitle className="text-2xl font-bold tracking-tight">{employeeName}</SheetTitle>
              </div>
              <div className="flex items-center gap-4 text-sm text-muted-foreground ml-1.5">
                <p className="flex items-center gap-1.5 capitalize font-medium">
                  <Calendar className="h-4 w-4 text-primary" />
                  {formatDate(date)}
                </p>
                {detail?.summary.total_shift_minutes ? (
                  <p className="flex items-center gap-1.5">
                    <Clock className="h-4 w-4 text-primary" />
                    <span>{formatHours(detail.summary.total_shift_minutes)} enregistrés</span>
                  </p>
                ) : null}
              </div>
            </div>
            
            {isApproved && (
              <Badge variant="outline" className="bg-green-50 text-green-700 border-green-200 px-3 py-1 text-xs font-semibold rounded-full shadow-sm animate-in fade-in zoom-in duration-300">
                <CheckCircle2 className="h-3.5 w-3.5 mr-1.5" />
                Approuvée
              </Badge>
            )}
          </div>
        </div>

        {isLoading ? (
          <div className="flex items-center justify-center py-24">
            <Loader2 className="h-10 w-10 animate-spin text-primary/40" />
          </div>
        ) : detail ? (
          <div className="mt-6 space-y-8 animate-in fade-in slide-in-from-bottom-2 duration-500">
            {/* Summary Grid - Modern Analytics Style */}
            <div className={`grid grid-cols-2 ${gpsGapTotals.seconds > 0 ? 'sm:grid-cols-5' : 'sm:grid-cols-4'} gap-4`}>
              <div className="group relative overflow-hidden flex flex-col p-4 bg-green-50/50 rounded-2xl border border-green-100 shadow-sm transition-all hover:shadow-md">
                <div className="absolute top-0 right-0 p-3 text-green-200/50 group-hover:scale-110 transition-transform">
                  <CheckCircle2 className="h-12 w-12" />
                </div>
                <span className="text-[10px] uppercase tracking-[0.1em] text-green-700/60 font-bold mb-1">Approuvé</span>
                <div className="flex items-baseline gap-1 mt-auto">
                  <span className="text-2xl font-black text-green-700 tracking-tight">{formatHours(detail.summary.approved_minutes)}</span>
                </div>
              </div>

              <div className="group relative overflow-hidden flex flex-col p-4 bg-red-50/50 rounded-2xl border border-red-100 shadow-sm transition-all hover:shadow-md">
                <div className="absolute top-0 right-0 p-3 text-red-200/50 group-hover:scale-110 transition-transform">
                  <XCircle className="h-12 w-12" />
                </div>
                <span className="text-[10px] uppercase tracking-[0.1em] text-red-700/60 font-bold mb-1">Rejeté</span>
                <div className="flex items-baseline gap-1 mt-auto">
                  <span className="text-2xl font-black text-red-700 tracking-tight">{formatHours(detail.summary.rejected_minutes)}</span>
                </div>
              </div>

              <div className={`group relative overflow-hidden flex flex-col p-4 rounded-2xl border shadow-sm transition-all hover:shadow-md ${visibleNeedsReviewCount > 0 ? 'bg-amber-50/50 border-amber-100' : 'bg-muted/30 border-muted-foreground/10'}`}>
                <div className={`absolute top-0 right-0 p-3 transition-transform group-hover:scale-110 ${visibleNeedsReviewCount > 0 ? 'text-amber-200/50' : 'text-muted-foreground/10'}`}>
                  <AlertTriangle className="h-12 w-12" />
                </div>
                <span className={`text-[10px] uppercase tracking-[0.1em] font-bold mb-1 ${visibleNeedsReviewCount > 0 ? 'text-amber-700/60' : 'text-muted-foreground/60'}`}>À vérifier</span>
                <div className="flex items-baseline gap-1 mt-auto">
                  <span className={`text-2xl font-black tracking-tight ${visibleNeedsReviewCount > 0 ? 'text-amber-700' : 'text-muted-foreground/40'}`}>
                    {visibleNeedsReviewCount}
                  </span>
                  <span className="text-[10px] text-muted-foreground/60 font-medium lowercase">activité{visibleNeedsReviewCount > 1 ? 's' : ''}</span>
                </div>
              </div>

              <div className="group relative overflow-hidden flex flex-col p-4 bg-slate-50 rounded-2xl border border-slate-200 shadow-sm transition-all hover:shadow-md">
                <div className="absolute top-0 right-0 p-3 text-slate-200 group-hover:scale-110 transition-transform">
                  <Clock className="h-12 w-12" />
                </div>
                <span className="text-[10px] uppercase tracking-[0.1em] text-slate-500 font-bold mb-1">Total</span>
                <div className="flex items-baseline gap-1 mt-auto">
                  <span className="text-2xl font-black text-slate-800 tracking-tight">{formatHours(detail.summary.total_shift_minutes)}</span>
                </div>
              </div>

              {gpsGapTotals.seconds > 0 && (
                <div className={`group relative overflow-hidden flex flex-col p-4 bg-amber-50/50 rounded-2xl border shadow-sm transition-all hover:shadow-md ${
                  gpsGapTotals.seconds >= 300 ? 'border-amber-200' : 'border-amber-100'
                }`}>
                  <div className="absolute top-0 right-0 p-3 text-amber-200/50 group-hover:scale-110 transition-transform">
                    <AlertTriangle className="h-12 w-12" />
                  </div>
                  <span className={`text-[10px] uppercase tracking-[0.1em] font-bold mb-1 ${
                    gpsGapTotals.seconds >= 300 ? 'text-amber-700/60' : 'text-amber-600/60'
                  }`}>GPS perdu</span>
                  <div className="flex items-baseline gap-1 mt-auto">
                    <span className={`text-2xl font-black tracking-tight ${
                      gpsGapTotals.seconds >= 300 ? 'text-amber-700' : 'text-amber-600'
                    }`}>{Math.round(gpsGapTotals.seconds / 60)} min</span>
                  </div>
                  <span className="text-[10px] text-muted-foreground/60 font-medium">
                    {gpsGapTotals.count} interruption{gpsGapTotals.count > 1 ? 's' : ''}
                  </span>
                </div>
              )}

              {(detail.summary.lunch_minutes ?? 0) > 0 && (
                <div className="group relative overflow-hidden flex flex-col p-4 bg-orange-50/50 rounded-2xl border border-orange-100 shadow-sm transition-all hover:shadow-md">
                  <div className="absolute top-0 right-0 p-3 text-orange-200/50 group-hover:scale-110 transition-transform">
                    <UtensilsCrossed className="h-12 w-12" />
                  </div>
                  <span className="text-[10px] uppercase tracking-[0.1em] text-orange-700/60 font-bold mb-1">Dîner</span>
                  <div className="flex items-baseline gap-1 mt-auto">
                    <span className="text-2xl font-black text-orange-700 tracking-tight">{formatHours(detail.summary.lunch_minutes)}</span>
                  </div>
                </div>
              )}
            </div>

            {/* Duration by type badges */}
            {(durationStats.totalTravelSeconds > 0 || Object.keys(durationStats.stopByType).length > 0 || durationStats.totalGapSeconds > 0) && (
              <div className="flex flex-wrap items-center gap-1.5 px-1">
                <span className="text-[10px] font-semibold text-muted-foreground uppercase mr-1">Répartition:</span>
                {durationStats.totalTravelSeconds > 0 && (
                  <span
                    className="inline-flex items-center gap-1 rounded-full bg-blue-50 px-2 py-0.5 text-xs font-medium text-blue-700 border border-blue-100"
                    title="Déplacement"
                  >
                    <Car className="h-3 w-3" />
                    {formatDuration(durationStats.totalTravelSeconds)}
                  </span>
                )}
                {durationStats.totalGapSeconds > 0 && (
                  <span
                    className="inline-flex items-center gap-1 rounded-full bg-purple-50 px-2 py-0.5 text-xs font-medium text-purple-700 border border-purple-100"
                    title="Temps non suivi"
                  >
                    <WifiOff className="h-3 w-3" />
                    {formatDuration(durationStats.totalGapSeconds)}
                  </span>
                )}
                {Object.entries(durationStats.stopByType)
                  .filter(([, secs]) => secs > 0)
                  .sort(([a], [b]) => {
                    if (a === '_unmatched') return 1;
                    if (b === '_unmatched') return -1;
                    return (durationStats.stopByType[b] || 0) - (durationStats.stopByType[a] || 0);
                  })
                  .map(([type, secs]) => {
                    const isUnmatched = type === '_unmatched';
                    const iconEntry = isUnmatched ? null : LOCATION_TYPE_ICON_MAP[type as LocationType];
                    const Icon = iconEntry ? iconEntry.icon : MapPin;
                    const colorClass = iconEntry ? iconEntry.className : 'h-3 w-3 text-gray-400';
                    const label = isUnmatched ? 'Autre' : (LOCATION_TYPE_LABELS[type as LocationType] || type);
                    return (
                      <span
                        key={type}
                        className="inline-flex items-center gap-1 rounded-full bg-slate-50 px-2 py-0.5 text-xs font-medium text-slate-700 border border-slate-200"
                        title={label}
                      >
                        <Icon className={colorClass.replace('h-4 w-4', 'h-3 w-3')} />
                        {formatDuration(secs)}
                      </span>
                    );
                  })}
              </div>
            )}

            {/* Approval status badge if approved */}
            {isApproved && (
              <div className="rounded-lg bg-green-50/50 border border-green-200 p-3 text-sm text-green-700 flex items-center gap-3">
                <div className="bg-green-100 rounded-full p-1.5">
                  <CheckCircle2 className="h-4 w-4" />
                </div>
                <div>
                  <p className="font-semibold">Journée approuvée</p>
                  <p className="text-xs opacity-80">
                    {detail.approved_at && `Le ${new Date(detail.approved_at).toLocaleDateString('fr-CA', { day: 'numeric', month: 'long', year: 'numeric', hour: '2-digit', minute: '2-digit' })}`}
                  </p>
                </div>
              </div>
            )}

            {detail.has_active_shift && (
              <div className="rounded-lg bg-amber-50/50 border border-amber-200 p-3 text-sm text-amber-700 flex items-center gap-3">
                <div className="bg-amber-100 rounded-full p-1.5 animate-pulse">
                  <Clock className="h-4 w-4" />
                </div>
                <div>
                  <p className="font-semibold text-xs uppercase tracking-tight">En cours</p>
                  <p className="text-xs">Un quart de travail est encore actif pour cet employé.</p>
                </div>
              </div>
            )}

            {/* Activity table */}
            <div className="overflow-hidden border rounded-xl shadow-sm bg-background">
              <table className="w-full text-sm">
                <thead className="bg-muted/30">
                  <tr>
                    <th className="px-3 py-3 text-center font-semibold text-muted-foreground uppercase text-[10px] tracking-wider border-b">Action</th>
                    <th className="px-2 py-3 text-center font-semibold text-muted-foreground uppercase text-[10px] tracking-wider border-b w-8">
                      <Clock className="h-3.5 w-3.5 mx-auto" />
                    </th>
                    <th className="px-2 py-3 text-center font-semibold text-muted-foreground uppercase text-[10px] tracking-wider border-b w-8">Type</th>
                    <th className="px-3 py-3 text-left font-semibold text-muted-foreground uppercase text-[10px] tracking-wider border-b">Durée</th>
                    <th className="px-3 py-3 text-left font-semibold text-muted-foreground uppercase text-[10px] tracking-wider border-b">Détails de l'activité</th>
                    <th className="px-3 py-3 text-left font-semibold text-muted-foreground uppercase text-[10px] tracking-wider border-b">Horaire</th>
                    <th className="px-3 py-3 text-right font-semibold text-muted-foreground uppercase text-[10px] tracking-wider border-b">Distance</th>
                    <th className="px-3 py-3 text-left font-semibold text-muted-foreground uppercase text-[10px] tracking-wider border-b min-w-[180px]">Projet(s)</th>
                    <th className="px-3 py-3 w-8 border-b"></th>
                  </tr>
                </thead>
                <tbody className="divide-y">
                  {displayItems.length === 0 ? (
                    <tr>
                      <td colSpan={9} className="px-3 py-12 text-center text-sm text-muted-foreground italic">
                        Aucune activité détectée pour cette période
                      </td>
                    </tr>
                  ) : (
                    displayItems.map((item, idx) => {
                      const ps = detail?.project_sessions ?? [];
                      if (item.type === 'merged') {
                        const group = item.group;
                        const key = `merged-${group.primaryStop.item.activity_id}`;
                        return (
                          <MergedLocationRow
                            key={key}
                            group={group}
                            isApproved={isApproved}
                            isSaving={isSaving}
                            isExpanded={expandedId === key}
                            onToggle={() => setExpandedId(expandedId === key ? null : key)}
                            onOverride={handleOverride}
                            projectSessions={ps}
                          />
                        );
                      }

                      const pa = item.pa;
                      const key = `${pa.item.activity_type}-${pa.item.activity_id}`;
                      const isTrip = pa.item.activity_type === 'trip';

                      return isTrip ? (
                        <TripConnectorRow
                          key={key}
                          pa={pa}
                          isApproved={isApproved}
                          isSaving={isSaving}
                          isExpanded={expandedId === key}
                          onToggle={() => setExpandedId(expandedId === key ? null : key)}
                          onOverride={handleOverride}
                          projectSessions={ps}
                        />
                      ) : (
                        <ActivityRow
                          key={key}
                          pa={pa}
                          isApproved={isApproved}
                          isSaving={isSaving}
                          isExpanded={expandedId === key}
                          onToggle={() => setExpandedId(expandedId === key ? null : key)}
                          onOverride={handleOverride}
                          projectSessions={ps}
                        />
                      );
                    })
                  )}
                </tbody>
              </table>
            </div>

            {/* Notes + Approve */}
            {!isApproved && !detail.has_active_shift && (
              <div className="border-t pt-4 space-y-3">
                {showNotes ? (
                  <Textarea
                    placeholder="Notes (optionnel)..."
                    value={notes}
                    onChange={(e) => setNotes(e.target.value)}
                    rows={2}
                  />
                ) : (
                  <Button variant="link" size="sm" className="text-xs p-0 h-auto" onClick={() => setShowNotes(true)}>
                    + Ajouter une note
                  </Button>
                )}

                <Button
                  className="w-full"
                  disabled={!canApprove || isSaving}
                  onClick={handleApproveDay}
                >
                  {isSaving ? (
                    <Loader2 className="h-4 w-4 animate-spin mr-2" />
                  ) : (
                    <CheckCircle2 className="h-4 w-4 mr-2" />
                  )}
                  Approuver la journée
                </Button>

                {!canApprove && visibleNeedsReviewCount > 0 && (
                  <p className="text-xs text-yellow-600 text-center">
                    {visibleNeedsReviewCount} activité(s) à vérifier avant approbation
                  </p>
                )}
              </div>
            )}

            {/* Reopen approved day */}
            {isApproved && (
              <div className="border-t pt-4">
                <Button
                  variant="outline"
                  className="w-full"
                  onClick={handleReopenDay}
                  disabled={isSaving}
                >
                  Rouvrir la journée
                </Button>
              </div>
            )}

            {/* Approved notes */}
            {isApproved && detail.notes && (
              <div className="text-sm text-gray-600 bg-gray-50 rounded-md p-3">
                <span className="font-medium">Notes:</span> {detail.notes}
              </div>
            )}
          </div>
        ) : null}
      </SheetContent>
    </Sheet>
  );
}

// --- Compact trip connector row ---

function TripConnectorRow({
  pa,
  isApproved,
  isSaving,
  isExpanded,
  onToggle,
  onOverride,
  projectSessions,
}: {
  pa: ProcessedActivity<ApprovalActivity>;
  isApproved: boolean;
  isSaving: boolean;
  isExpanded: boolean;
  onToggle: () => void;
  onOverride: (activity: ApprovalActivity, status: 'approved' | 'rejected') => void;
  projectSessions: ProjectSession[];
}) {
  const { item: activity } = pa;
  const hasOverride = activity.override_status !== null;

  const statusColor = {
    approved: {
      bg: hasOverride ? 'bg-green-100/70' : 'bg-green-50/80',
      text: 'text-green-700',
      subtext: 'text-green-600/70',
      border: hasOverride ? 'border-l-green-600' : 'border-l-green-400',
    },
    rejected: {
      bg: hasOverride ? 'bg-red-100/70' : 'bg-red-50/80',
      text: 'text-red-700',
      subtext: 'text-red-600/70',
      border: hasOverride ? 'border-l-red-600' : 'border-l-red-400',
    },
    needs_review: {
      bg: 'bg-amber-50/80',
      text: 'text-amber-700',
      subtext: 'text-amber-600/70',
      border: 'border-l-amber-500',
    },
  }[activity.final_status];

  return (
    <>
      <tr
        className={`${statusColor.bg} border-l-[3px] ${statusColor.border} cursor-pointer transition-all hover:brightness-95 group`}
        style={activity.has_gps_gap ? { borderLeftStyle: 'dashed', borderLeftColor: 'rgb(245 158 11)' } : undefined}
        onClick={onToggle}
      >
        {/* Empty action column — no buttons */}
        <td className="px-3 py-1.5">
          {hasOverride && (
            <div className="flex justify-center">
              <div className="h-2 w-2 rounded-full bg-blue-500" title="Override manuel" />
            </div>
          )}
        </td>

        {/* Empty clock column */}
        <td className="py-1.5" />

        {/* Arrow connector icon */}
        <td className="px-2 py-1.5 text-center">
          <div className="flex justify-center">
            {activity.transport_mode === 'walking'
              ? <Footprints className="h-3 w-3 text-orange-400" />
              : activity.transport_mode === 'driving'
                ? <Car className="h-3 w-3 text-blue-400" />
                : <MoveRight className="h-3 w-3 text-gray-400" />
            }
          </div>
        </td>

        {/* Duration + distance inline */}
        <td colSpan={3} className="px-3 py-1.5">
          <div className="flex items-center gap-2 ml-2">
            <ArrowRight className="h-3 w-3 text-muted-foreground/40 flex-shrink-0" />
            <span className={`text-[11px] font-medium tabular-nums ${statusColor.text}`}>
              {formatDurationMinutes(activity.duration_minutes)}
            </span>
            {(activity.road_distance_km ?? activity.distance_km) ? (
              <span className={`text-[11px] tabular-nums ${statusColor.subtext}`}>
                {formatDistance(activity.road_distance_km ?? activity.distance_km)}
              </span>
            ) : null}
            {activity.has_gps_gap && (
              <span aria-label="Données GPS incomplètes"><AlertTriangle className="h-3 w-3 text-amber-500 flex-shrink-0" /></span>
            )}
            {activity.duration_minutes > 60 && (
              <span aria-label={`Trajet long: ${activity.duration_minutes} min`}><Clock className="h-3 w-3 text-amber-500 flex-shrink-0" /></span>
            )}
          </div>
        </td>

        {/* Distance column */}
        <td className="py-1.5" />

        {/* Projet(s) — show sessions overlapping this trip */}
        {(() => {
          const slices = getProjectSlices(activity.started_at, activity.ended_at, projectSessions);
          return slices.length > 0 ? (
            <td className="px-3 py-1.5">
              <div className="flex flex-col gap-0.5">
                {slices.map((slice, i) => {
                  if (slice.type === 'gap') return null; // Don't show gaps for short trips
                  const ps = slice.session!;
                  const icon = ps.session_type === 'cleaning' ? '🧹' : '🔧';
                  return (
                    <span key={ps.session_id} className="text-[10px] text-muted-foreground truncate">
                      {icon} {ps.building_name}{ps.unit_label ? ` #${ps.unit_label}` : ''}
                    </span>
                  );
                })}
              </div>
            </td>
          ) : <td className="py-1.5" />;
        })()}

        {/* Expand chevron */}
        <td className="px-3 py-1.5 text-center">
          <div className={`rounded-full p-0.5 transition-colors ${isExpanded ? 'bg-muted' : 'group-hover:bg-muted'}`}>
            {isExpanded
              ? <ChevronUp className="h-3 w-3 text-primary" />
              : <ChevronDown className="h-3 w-3 text-muted-foreground" />
            }
          </div>
        </td>
      </tr>

      {/* Expanded: route map + override toggle */}
      {isExpanded && (
        <tr>
          <td colSpan={9} className="p-0 border-b">
            <div className="px-4 py-4 bg-muted/10 border-t border-b space-y-4">
              {/* Override controls (only when day not approved) */}
              {!isApproved && (
                <div className="flex items-center gap-3 px-2 py-2 bg-background rounded-lg border">
                  <span className="text-xs font-medium text-muted-foreground">Forcer le statut:</span>
                  <div className="flex items-center gap-2" onClick={(e) => e.stopPropagation()}>
                    <Button
                      variant="outline"
                      size="sm"
                      className={`h-7 text-xs rounded-full ${
                        activity.override_status === 'approved'
                          ? 'border-green-500 bg-green-50 text-green-700'
                          : 'text-muted-foreground hover:text-green-600 hover:bg-green-50'
                      }`}
                      onClick={() => onOverride(activity, 'approved')}
                      disabled={isSaving}
                    >
                      <CheckCircle2 className="h-3 w-3 mr-1" />
                      Approuver
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      className={`h-7 text-xs rounded-full ${
                        activity.override_status === 'rejected'
                          ? 'border-red-500 bg-red-50 text-red-700'
                          : 'text-muted-foreground hover:text-red-600 hover:bg-red-50'
                      }`}
                      onClick={() => onOverride(activity, 'rejected')}
                      disabled={isSaving}
                    >
                      <XCircle className="h-3 w-3 mr-1" />
                      Rejeter
                    </Button>
                  </div>
                  {hasOverride && (
                    <Badge variant="outline" className="text-[10px] border-blue-300 text-blue-600">
                      Override actif
                    </Badge>
                  )}
                </div>
              )}

              {/* Route map */}
              <TripExpandDetail activity={activity} />
            </div>
          </td>
        </tr>
      )}
    </>
  );
}

// --- GPS gap sub-row inside merged location row ---

function GapSubRow({
  gap,
  isApproved,
  isSaving,
  onOverride,
}: {
  gap: ApprovalActivity;
  isApproved: boolean;
  isSaving: boolean;
  onOverride: (activity: ApprovalActivity, status: 'approved' | 'rejected') => void;
}) {
  const finalStatus = gap.override_status ?? gap.auto_status;
  const hasOverride = gap.override_status !== null;

  const config = {
    approved: {
      bg: 'bg-green-50 border-green-200',
      text: 'text-green-800',
      sub: 'text-green-600/70',
    },
    rejected: {
      bg: 'bg-red-50 border-red-200',
      text: 'text-red-800',
      sub: 'text-red-600/70',
    },
    needs_review: {
      bg: 'bg-amber-50 border-amber-300',
      text: 'text-amber-900',
      sub: 'text-amber-700/80',
    },
  }[finalStatus];

  return (
    <div className={`flex items-center gap-3 px-3 py-2 rounded-lg border ${config.bg} ${hasOverride ? 'ring-1 ring-blue-400/30' : ''}`}>
      <WifiOff className="h-3.5 w-3.5 text-purple-500 flex-shrink-0" />

      <div className="flex-1 min-w-0">
        <div className={`text-xs font-medium ${config.text}`}>
          Signal GPS perdu
        </div>
        <div className={`text-[10px] ${config.sub}`}>
          {formatTime(gap.started_at)} — {formatTime(gap.ended_at)} · {formatDurationMinutes(gap.duration_minutes)}
        </div>
      </div>

      {/* Approve / Reject */}
      {!isApproved ? (
        <div className="flex items-center gap-1.5" onClick={(e) => e.stopPropagation()}>
          <div className="relative">
            {gap.override_status === 'approved' && (
              <div className="absolute -inset-0.5 rounded-full border border-blue-500/40 shadow-[0_0_8px_rgba(59,130,246,0.2)]" />
            )}
            <Button
              variant="outline"
              size="icon"
              className={`h-7 w-7 rounded-full transition-all relative z-0 border ${
                gap.override_status === 'approved'
                  ? 'border-blue-500 bg-white text-green-600'
                  : finalStatus === 'approved'
                    ? 'text-green-600 bg-green-50 border-green-300'
                    : 'text-gray-400 hover:text-green-600 hover:bg-green-50 border-gray-200'
              }`}
              onClick={() => onOverride(gap, 'approved')}
              disabled={isSaving}
            >
              <CheckCircle2 className="h-3.5 w-3.5" />
            </Button>
          </div>
          <div className="relative">
            {gap.override_status === 'rejected' && (
              <div className="absolute -inset-0.5 rounded-full border border-blue-500/40 shadow-[0_0_8px_rgba(59,130,246,0.2)]" />
            )}
            <Button
              variant="outline"
              size="icon"
              className={`h-7 w-7 rounded-full transition-all relative z-0 border ${
                gap.override_status === 'rejected'
                  ? 'border-blue-500 bg-white text-red-600'
                  : finalStatus === 'rejected'
                    ? 'text-red-600 bg-red-50 border-red-300'
                    : 'text-gray-400 hover:text-red-600 hover:bg-red-50 border-gray-200'
              }`}
              onClick={() => onOverride(gap, 'rejected')}
              disabled={isSaving}
            >
              <XCircle className="h-3.5 w-3.5" />
            </Button>
          </div>
        </div>
      ) : (
        <Badge
          variant="outline"
          className={`text-[10px] px-2 py-0.5 rounded-full ${
            finalStatus === 'approved' ? 'bg-green-100 text-green-700 border-green-200' :
            finalStatus === 'rejected' ? 'bg-red-100 text-red-700 border-red-200' :
            'bg-amber-100 text-amber-700 border-amber-200'
          }`}
        >
          {finalStatus === 'approved' ? 'Approuve' : finalStatus === 'rejected' ? 'Rejete' : 'A verifier'}
        </Badge>
      )}
    </div>
  );
}

// --- Merged same-location row (stops + nested GPS gaps) ---

function MergedLocationRow({
  group,
  isApproved,
  isSaving,
  isExpanded,
  onToggle,
  onOverride,
  projectSessions,
}: {
  group: MergedGroup;
  isApproved: boolean;
  isSaving: boolean;
  isExpanded: boolean;
  onToggle: () => void;
  onOverride: (activity: ApprovalActivity, status: 'approved' | 'rejected') => void;
  projectSessions: ProjectSession[];
}) {
  const activity = group.primaryStop.item;
  const { hasClockIn } = group.primaryStop;
  // Also check if last stop has clock-out merged
  const lastStopHasClockOut = group.stops[group.stops.length - 1].hasClockOut;
  const hasOverride = activity.override_status !== null;
  const hasUnreviewedGaps = group.gaps.some(g => {
    const final = g.override_status ?? g.auto_status;
    return final === 'needs_review';
  });

  const statusConfig = {
    approved: {
      row: hasOverride
        ? 'bg-green-100 border-l-[6px] border-l-green-600 hover:bg-green-200/70'
        : 'bg-green-50 border-l-4 border-l-green-500 hover:bg-green-100/80',
      badge: 'bg-green-100 text-green-700 border-green-200 ring-1 ring-green-600/10',
      icon: CheckCircle2,
      label: 'Approuve',
      btnApprove: 'text-green-700 bg-green-100 border-green-300 shadow-sm',
      btnReject: 'text-gray-400 hover:text-red-600 hover:bg-red-50 border-transparent',
      text: hasOverride ? 'text-green-950 font-bold' : 'text-green-900 font-medium',
      subtext: 'text-green-700/70',
    },
    rejected: {
      row: hasOverride
        ? 'bg-red-100 border-l-[6px] border-l-red-600 hover:bg-red-200/70'
        : 'bg-red-50 border-l-4 border-l-red-500 hover:bg-red-100/80',
      badge: 'bg-red-100 text-red-700 border-red-200 ring-1 ring-red-600/10',
      icon: XCircle,
      label: 'Rejete',
      btnApprove: 'text-gray-400 hover:text-green-600 hover:bg-green-50 border-transparent',
      btnReject: 'text-red-700 bg-red-100 border-red-300 shadow-sm',
      text: hasOverride ? 'text-red-950 font-bold' : 'text-red-900 font-medium',
      subtext: 'text-red-700/70',
    },
    needs_review: {
      row: 'bg-amber-50 border-l-4 border-l-amber-500 hover:bg-amber-100/80 shadow-[inset_0_0_0_1px_rgba(251,191,36,0.1)]',
      badge: 'bg-amber-100 text-amber-800 border-amber-200 ring-2 ring-amber-500/20',
      icon: AlertTriangle,
      label: 'A verifier',
      btnApprove: 'text-gray-500 hover:text-green-600 hover:bg-green-50 border-gray-200',
      btnReject: 'text-gray-500 hover:text-red-600 hover:bg-red-50 border-gray-200',
      text: 'text-amber-950 font-bold',
      subtext: 'text-amber-800/80',
    }
  }[activity.final_status];

  // Yellow tint override when unreviewed gaps exist
  const rowClassName = hasUnreviewedGaps
    ? `${statusConfig.row} ring-2 ring-amber-400/40 bg-gradient-to-r from-amber-50/80 to-transparent`
    : statusConfig.row;

  return (
    <>
      <tr
        className={`${rowClassName} cursor-pointer transition-all duration-200 group border-b border-white/50`}
        onClick={onToggle}
      >
        {/* Action / Approbation — applies to stop only */}
        <td className="px-3 py-3 text-center">
          {!isApproved ? (
            <div className="flex items-center justify-center gap-2" onClick={(e) => e.stopPropagation()}>
              <div className="relative group/btn">
                {activity.override_status === 'approved' && (
                  <>
                    <div className="absolute -inset-1 rounded-full border border-blue-500/40 shadow-[0_0_12px_rgba(59,130,246,0.3)]" />
                    <div className="absolute -inset-[3px] rounded-full border border-blue-500/10" />
                  </>
                )}
                <Button
                  variant="outline"
                  size="icon"
                  className={`h-9 w-9 rounded-full transition-all relative z-0 hover:scale-105 active:scale-95 border-2 ${
                    activity.override_status === 'approved'
                      ? 'border-blue-600 bg-white text-green-600 shadow-sm'
                      : statusConfig.btnApprove + ' border-transparent shadow-none'
                  }`}
                  onClick={() => onOverride(activity, 'approved')}
                  disabled={isSaving}
                >
                  <CheckCircle2 className={`h-4.5 w-4.5 ${activity.override_status === 'approved' ? 'stroke-[2.5px]' : ''}`} />
                </Button>
              </div>
              <div className="relative group/btn">
                {activity.override_status === 'rejected' && (
                  <>
                    <div className="absolute -inset-1 rounded-full border border-blue-500/40 shadow-[0_0_12px_rgba(59,130,246,0.3)]" />
                    <div className="absolute -inset-[3px] rounded-full border border-blue-500/10" />
                  </>
                )}
                <Button
                  variant="outline"
                  size="icon"
                  className={`h-9 w-9 rounded-full transition-all relative z-0 hover:scale-105 active:scale-95 border-2 ${
                    activity.override_status === 'rejected'
                      ? 'border-blue-600 bg-white text-red-600 shadow-sm'
                      : statusConfig.btnReject + ' border-transparent shadow-none'
                  }`}
                  onClick={() => onOverride(activity, 'rejected')}
                  disabled={isSaving}
                >
                  <XCircle className={`h-4.5 w-4.5 ${activity.override_status === 'rejected' ? 'stroke-[2.5px]' : ''}`} />
                </Button>
              </div>
            </div>
          ) : (
            <div className="flex justify-center">
              <Badge variant="outline" className={`font-bold text-[10px] px-2.5 py-0.5 rounded-full shadow-sm ${statusConfig.badge}`}>
                {(() => { const StatusIcon = statusConfig.icon; return <StatusIcon className="h-3 w-3 mr-1" />; })()}
                {statusConfig.label}
              </Badge>
            </div>
          )}
        </td>

        {/* Clock-in/out indicator */}
        <td className="px-2 py-3 text-center">
          <div className="flex items-center justify-center gap-0.5">
            {hasClockIn && <span title="Debut de quart"><LogIn className="h-3.5 w-3.5 text-emerald-600" /></span>}
            {lastStopHasClockOut && <span title="Fin de quart"><LogOut className="h-3.5 w-3.5 text-red-600" /></span>}
          </div>
        </td>

        {/* Type icon */}
        <td className="px-2 py-3 text-center">
          <div className="flex justify-center bg-white/80 rounded-lg p-1.5 shadow-sm border border-black/5 group-hover:scale-110 transition-transform">
            <ApprovalActivityIcon activity={activity} />
          </div>
        </td>

        {/* Duree — full span */}
        <td className="px-3 py-3 whitespace-nowrap">
          <div className={`flex items-center gap-1.5 tabular-nums text-xs ${statusConfig.text}`}>
            {formatDurationMinutes(group.spanMinutes)}
          </div>
          {/* GPS gap badge */}
          {group.totalGapMinutes > 0 && (
            <div className={`text-[10px] mt-0.5 flex items-center gap-1 ${hasUnreviewedGaps ? 'text-amber-600 font-semibold' : 'text-amber-600/70'}`}>
              <WifiOff className="h-3 w-3" />
              <span>
                {group.gaps.length > 1 ? `${group.gaps.length} gaps · ` : ''}
                {formatDurationMinutes(group.totalGapMinutes)} GPS perdu
              </span>
            </div>
          )}
        </td>

        {/* Details */}
        <td className="px-3 py-3 max-w-[300px]">
          <div className="space-y-1">
            <div className={`text-xs flex items-center gap-1.5 ${statusConfig.text}`}>
              <span className={activity.location_name ? 'font-bold underline decoration-current/20' : ''}>
                {activity.location_name || 'Arret non associe'}
              </span>
            </div>
            <div className="flex items-center gap-1.5">
              <span className={`text-[10px] leading-tight italic ${statusConfig.subtext}`}>
                {activity.auto_reason}
              </span>
            </div>
          </div>
        </td>

        {/* Horaire — full span */}
        <td className="px-3 py-3 whitespace-nowrap">
          <div className="flex flex-col">
            <span className={`text-xs font-black ${statusConfig.text}`}>{formatTime(group.startedAt)}</span>
            <span className={`text-[10px] font-medium ${statusConfig.subtext}`}>{formatTime(group.endedAt)}</span>
          </div>
        </td>

        {/* Distance — dash for merged location rows */}
        <td className="px-3 py-3 text-right tabular-nums whitespace-nowrap">
          <span className="opacity-20 text-xs font-bold">&mdash;</span>
        </td>

        {/* Projet(s) */}
        <ProjectCell slices={getProjectSlices(group.startedAt, group.endedAt, projectSessions)} />

        {/* Expand chevron */}
        <td className="px-3 py-3 text-center">
          <div className={`rounded-full p-1 transition-colors ${isExpanded ? 'bg-muted' : 'group-hover:bg-muted'}`}>
            {isExpanded
              ? <ChevronUp className="h-4 w-4 text-primary" />
              : <ChevronDown className="h-4 w-4 text-muted-foreground" />
            }
          </div>
        </td>
      </tr>

      {/* Expanded: nested GPS gap sub-rows */}
      {isExpanded && (
        <tr>
          <td colSpan={9} className="p-0 border-b">
            <div className="px-6 py-4 bg-amber-50/30 border-t border-amber-200/50">
              {/* Bulk approve button */}
              {!isApproved && hasUnreviewedGaps && (
                <div className="flex items-center gap-2 mb-3">
                  <Button
                    variant="outline"
                    size="sm"
                    className="text-xs h-7 bg-green-50 text-green-700 border-green-300 hover:bg-green-100"
                    disabled={isSaving}
                    onClick={async () => {
                      for (const gap of group.gaps) {
                        const final = gap.override_status ?? gap.auto_status;
                        if (final === 'needs_review') {
                          await onOverride(gap, 'approved');
                        }
                      }
                    }}
                  >
                    <CheckCircle2 className="h-3 w-3 mr-1" />
                    Tout approuver ({group.gaps.filter(g => (g.override_status ?? g.auto_status) === 'needs_review').length})
                  </Button>
                </div>
              )}

              {/* Individual gap rows */}
              <div className="space-y-2">
                {group.gaps.map((gap) => (
                  <GapSubRow
                    key={gap.activity_id}
                    gap={gap}
                    isApproved={isApproved}
                    isSaving={isSaving}
                    onOverride={onOverride}
                  />
                ))}
              </div>
            </div>
          </td>
        </tr>
      )}
    </>
  );
}

// --- Individual activity row (stops, clocks, gaps) ---

function ActivityRow({
  pa,
  isApproved,
  isSaving,
  isExpanded,
  onToggle,
  onOverride,
  projectSessions,
}: {
  pa: ProcessedActivity<ApprovalActivity>;
  isApproved: boolean;
  isSaving: boolean;
  isExpanded: boolean;
  onToggle: () => void;
  onOverride: (activity: ApprovalActivity, status: 'approved' | 'rejected') => void;
  projectSessions: ProjectSession[];
}) {
  const { item: activity, hasClockIn, hasClockOut } = pa;
  const isStop = activity.activity_type === 'stop';
  const isClock = activity.activity_type === 'clock_in' || activity.activity_type === 'clock_out';
  const isGap = activity.activity_type === 'gap';
  const isLunch = activity.activity_type === 'lunch';
  const canExpand = isStop || isGap;
  const hasOverride = activity.override_status !== null;

  const statusConfig = {
    approved: {
      row: hasOverride 
        ? 'bg-green-100 border-l-[6px] border-l-green-600 hover:bg-green-200/70' 
        : 'bg-green-50 border-l-4 border-l-green-500 hover:bg-green-100/80',
      badge: 'bg-green-100 text-green-700 border-green-200 ring-1 ring-green-600/10',
      icon: CheckCircle2,
      label: 'Approuvé',
      btnApprove: 'text-green-700 bg-green-100 border-green-300 shadow-sm',
      btnReject: 'text-gray-400 hover:text-red-600 hover:bg-red-50 border-transparent',
      text: hasOverride ? 'text-green-950 font-bold' : 'text-green-900 font-medium',
      subtext: 'text-green-700/70',
    },
    rejected: {
      row: hasOverride 
        ? 'bg-red-100 border-l-[6px] border-l-red-600 hover:bg-red-200/70' 
        : 'bg-red-50 border-l-4 border-l-red-500 hover:bg-red-100/80',
      badge: 'bg-red-100 text-red-700 border-red-200 ring-1 ring-red-600/10',
      icon: XCircle,
      label: 'Rejeté',
      btnApprove: 'text-gray-400 hover:text-green-600 hover:bg-green-50 border-transparent',
      btnReject: 'text-red-700 bg-red-100 border-red-300 shadow-sm',
      text: hasOverride ? 'text-red-950 font-bold' : 'text-red-900 font-medium',
      subtext: 'text-red-700/70',
    },
    needs_review: {
      row: 'bg-amber-50 border-l-4 border-l-amber-500 hover:bg-amber-100/80 shadow-[inset_0_0_0_1px_rgba(251,191,36,0.1)]',
      badge: 'bg-amber-100 text-amber-800 border-amber-200 ring-2 ring-amber-500/20',
      icon: AlertTriangle,
      label: 'À vérifier',
      btnApprove: 'text-gray-500 hover:text-green-600 hover:bg-green-50 border-gray-200',
      btnReject: 'text-gray-500 hover:text-red-600 hover:bg-red-50 border-gray-200',
      text: 'text-amber-950 font-bold',
      subtext: 'text-amber-800/80',
    }
  }[activity.final_status];

  return (
    <>
      <tr
        className={`${isLunch ? 'bg-slate-50/80 border-l-4 border-l-slate-300 hover:bg-slate-100/80' : statusConfig.row} ${canExpand ? 'cursor-pointer' : ''} transition-all duration-200 group border-b border-white/50`}
        style={isGap ? { borderLeftStyle: 'dashed' } : undefined}
        onClick={canExpand ? onToggle : undefined}
      >
        {/* Action / Approbation */}
        <td className="px-3 py-3 text-center">
          {isLunch ? (
            <div className="flex justify-center">
              <Badge variant="outline" className="font-bold text-[10px] px-2.5 py-0.5 rounded-full bg-slate-100 text-slate-600 border-slate-200">
                <UtensilsCrossed className="h-3 w-3 mr-1" />
                Pause
              </Badge>
            </div>
          ) : !isApproved ? (
            <div className="flex items-center justify-center gap-2" onClick={(e) => e.stopPropagation()}>
              {/* Approve Button */}
              <div className="relative group/btn">
                {activity.override_status === 'approved' && (
                  <>
                    {/* Double Electric Border - Static */}
                    <div className="absolute -inset-1 rounded-full border border-blue-500/40 shadow-[0_0_12px_rgba(59,130,246,0.3)]" />
                    <div className="absolute -inset-[3px] rounded-full border border-blue-500/10" />
                  </>
                )}
                <Button
                  variant="outline"
                  size="icon"
                  className={`h-9 w-9 rounded-full transition-all relative z-0 hover:scale-105 active:scale-95 border-2 ${
                    activity.override_status === 'approved' 
                      ? 'border-blue-600 bg-white text-green-600 shadow-sm' 
                      : statusConfig.btnApprove + ' border-transparent shadow-none'
                  }`}
                  onClick={() => onOverride(activity, 'approved')}
                  disabled={isSaving}
                >
                  <CheckCircle2 className={`h-4.5 w-4.5 ${activity.override_status === 'approved' ? 'stroke-[2.5px]' : ''}`} />
                </Button>
              </div>

              {/* Reject Button */}
              <div className="relative group/btn">
                {activity.override_status === 'rejected' && (
                  <>
                    {/* Double Electric Border - Static */}
                    <div className="absolute -inset-1 rounded-full border border-blue-500/40 shadow-[0_0_12px_rgba(59,130,246,0.3)]" />
                    <div className="absolute -inset-[3px] rounded-full border border-blue-500/10" />
                  </>
                )}
                <Button
                  variant="outline"
                  size="icon"
                  className={`h-9 w-9 rounded-full transition-all relative z-0 hover:scale-105 active:scale-95 border-2 ${
                    activity.override_status === 'rejected' 
                      ? 'border-blue-600 bg-white text-red-600 shadow-sm' 
                      : statusConfig.btnReject + ' border-transparent shadow-none'
                  }`}
                  onClick={() => onOverride(activity, 'rejected')}
                  disabled={isSaving}
                >
                  <XCircle className={`h-4.5 w-4.5 ${activity.override_status === 'rejected' ? 'stroke-[2.5px]' : ''}`} />
                </Button>
              </div>
            </div>
          ) : (
            <div className="flex justify-center">
              <Badge variant="outline" className={`font-bold text-[10px] px-2.5 py-0.5 rounded-full shadow-sm ${statusConfig.badge}`}>
                {(() => { const StatusIcon = statusConfig.icon; return <StatusIcon className="h-3 w-3 mr-1" />; })()}
                {statusConfig.label}
              </Badge>
            </div>
          )}
        </td>

        {/* Clock-in/out indicator */}
        <td className="px-2 py-3 text-center">
          <div className="flex items-center justify-center gap-0.5">
            {hasClockIn && <span title="Début de quart"><LogIn className="h-3.5 w-3.5 text-emerald-600" /></span>}
            {hasClockOut && <span title="Fin de quart"><LogOut className="h-3.5 w-3.5 text-red-600" /></span>}
            {isClock && activity.activity_type === 'clock_in' && <LogIn className="h-3.5 w-3.5 text-emerald-600" />}
            {isClock && activity.activity_type === 'clock_out' && <LogOut className="h-3.5 w-3.5 text-red-600" />}
            {isLunch && <UtensilsCrossed className="h-3.5 w-3.5 text-orange-500" />}
          </div>
        </td>

        {/* Type icon */}
        <td className="px-2 py-3 text-center">
          <div className="flex justify-center bg-white/80 rounded-lg p-1.5 shadow-sm border border-black/5 group-hover:scale-110 transition-transform">
            <ApprovalActivityIcon activity={activity} />
          </div>
        </td>

        {/* Durée */}
        <td className="px-3 py-3 whitespace-nowrap">
          <div className={`flex items-center gap-1.5 tabular-nums text-xs ${statusConfig.text}`}>
            {isClock ? '—' : formatDurationMinutes(activity.duration_minutes)}
            {(activity.gps_gap_seconds ?? 0) > 0 && (
              <AlertTriangle className="h-3.5 w-3.5 text-amber-600 animate-pulse" />
            )}
          </div>
          {(activity.gps_gap_seconds ?? 0) > 0 && (
            <div className={`text-[10px] mt-0.5 ${
              (activity.gps_gap_seconds ?? 0) >= 300
                ? 'text-amber-600 font-medium'
                : 'text-muted-foreground'
            }`}>
              −{Math.round((activity.gps_gap_seconds ?? 0) / 60)} min GPS{(activity.gps_gap_count ?? 0) > 1 ? ` (${activity.gps_gap_count})` : ''}
            </div>
          )}
        </td>

        {/* Détails */}
        <td className="px-3 py-3 max-w-[300px]">
          {isGap ? (
            <div className="space-y-1">
              <div className={`text-xs flex items-center gap-1.5 ${statusConfig.text}`}>
                {(activity.start_location_name || activity.end_location_name) ? (
                  <>
                    <AlertTriangle className="h-3 w-3 text-amber-500" />
                    <span className="font-bold">D&eacute;placement non trac&eacute;</span>
                  </>
                ) : (
                  <>
                    <WifiOff className="h-3 w-3" />
                    <span className="font-bold">Temps non suivi</span>
                  </>
                )}
              </div>
              {(activity.start_location_name || activity.end_location_name) ? (
                <div className={`text-[10px] flex items-center gap-1 ${statusConfig.subtext}`}>
                  <span>{activity.start_location_name || 'Inconnu'}</span>
                  <ArrowRight className="h-2.5 w-2.5 flex-shrink-0" />
                  <span>{activity.end_location_name || 'Inconnu'}</span>
                </div>
              ) : (
                <span className={`text-[10px] leading-tight italic ${statusConfig.subtext}`}>
                  Aucune donnee GPS durant cette periode
                </span>
              )}
            </div>
          ) : isLunch ? (
            <div className="space-y-1">
              <div className="text-xs flex items-center gap-1.5 text-orange-700 font-medium">
                <UtensilsCrossed className="h-3 w-3" />
                <span className="font-bold">Pause dîner</span>
              </div>
              <span className="text-[10px] leading-tight text-orange-600/70">
                {formatTime(activity.started_at)} — {formatTime(activity.ended_at)}
              </span>
            </div>
          ) : isStop ? (
            <div className="space-y-1">
              <div className={`text-xs flex items-center gap-1.5 ${statusConfig.text}`}>
                <span className={activity.location_name ? 'font-bold underline decoration-current/20' : ''}>
                  {activity.location_name || 'Arrêt non associé'}
                </span>
              </div>
              <div className="flex items-center gap-1.5">
                <span className={`text-[10px] leading-tight italic ${statusConfig.subtext}`}>
                  {activity.auto_reason}
                </span>
              </div>
            </div>
          ) : (
            <div className="space-y-1">
              <span className={`text-xs font-bold ${statusConfig.text}`}>
                {activity.activity_type === 'clock_in' ? 'POINTAGE ENTRÉE' : 'POINTAGE SORTIE'}
              </span>
              <div className={`text-[10px] italic ${statusConfig.subtext}`}>
                {activity.location_name || 'Lieu inconnu'}
              </div>
            </div>
          )}
        </td>

        {/* Horaire */}
        <td className="px-3 py-3 whitespace-nowrap">
          <div className="flex flex-col">
            <span className={`text-xs font-black ${statusConfig.text}`}>{formatTime(activity.started_at)}</span>
            {!isClock && (
              <span className={`text-[10px] font-medium ${statusConfig.subtext}`}>{formatTime(activity.ended_at)}</span>
            )}
          </div>
        </td>

        {/* Distance */}
        <td className="px-3 py-3 text-right tabular-nums whitespace-nowrap">
          {isGap && activity.distance_km ? (
            <span className="text-xs text-amber-600">{formatDistance(activity.distance_km)}</span>
          ) : (
            <span className="opacity-20 text-xs font-bold">—</span>
          )}
        </td>

        {/* Projet(s) */}
        {(isClock || isLunch) ? (
          <td className="px-3 py-3"><span className="text-[10px] text-muted-foreground/40">—</span></td>
        ) : (
          <ProjectCell slices={getProjectSlices(activity.started_at, activity.ended_at, projectSessions)} />
        )}

        {/* Expand chevron */}
        <td className="px-3 py-3 text-center">
          {canExpand && (
            <div className={`rounded-full p-1 transition-colors ${isExpanded ? 'bg-muted' : 'group-hover:bg-muted'}`}>
              {isExpanded
                ? <ChevronUp className="h-4 w-4 text-primary" />
                : <ChevronDown className="h-4 w-4 text-muted-foreground" />
              }
            </div>
          )}
        </td>
      </tr>

      {/* Expanded detail row (stops + gaps — trips use TripConnectorRow) */}
      {isExpanded && canExpand && (
        <tr>
          <td colSpan={9} className="p-0 border-b">
            <div className="px-4 py-6 bg-muted/10 border-t border-b">
              {isGap ? (
                <GapExpandDetail activity={activity} />
              ) : (
                <StopExpandDetail activity={activity} />
              )}
            </div>
          </td>
        </tr>
      )}
    </>
  );
}

