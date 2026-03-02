'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
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
  Car,
  Footprints,
  Clock,
  LogIn,
  LogOut,
  ChevronDown,
  ChevronUp,
  ArrowRight,
} from 'lucide-react';
import { toast } from 'sonner';
import { supabaseClient } from '@/lib/supabase/client';
import { GoogleTripRouteMap } from '@/components/trips/google-trip-route-map';
import { StationaryClustersMap } from '@/components/mileage/stationary-clusters-map';
import type { StationaryCluster } from '@/components/mileage/stationary-clusters-map';
import { detectTripStops, detectGpsClusters } from '@/lib/utils/detect-trip-stops';
import { LOCATION_TYPE_ICON_MAP } from '@/lib/constants/location-icons';
import { mergeClockEvents, type ProcessedActivity } from '@/lib/utils/merge-clock-events';
import { formatTime, formatDuration, formatDurationMinutes, formatDistance } from '@/lib/utils/activity-display';
import type { LocationType } from '@/types/location';
import type {
  DayApprovalDetail as DayApprovalDetailType,
  ApprovalActivity,
  ApprovalAutoStatus,
  TripGpsPoint,
} from '@/types/mileage';

interface DayApprovalDetailProps {
  employeeId: string;
  employeeName: string;
  date: string;
  onClose: () => void;
}

function formatHours(minutes: number): string {
  if (minutes === 0) return '0h';
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m > 0 ? `${h}h${m.toString().padStart(2, '0')}` : `${h}h`;
}

function formatDate(dateStr: string): string {
  return new Date(dateStr + 'T12:00:00').toLocaleDateString('fr-CA', {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    year: 'numeric',
  });
}

const STATUS_BADGE: Record<ApprovalAutoStatus, { className: string; icon: typeof CheckCircle2; label: string }> = {
  approved: {
    className: 'bg-green-100 text-green-700 hover:bg-green-100',
    icon: CheckCircle2,
    label: 'Approuvé',
  },
  rejected: {
    className: 'bg-red-100 text-red-700 hover:bg-red-100',
    icon: XCircle,
    label: 'Rejeté',
  },
  needs_review: {
    className: 'bg-yellow-100 text-yellow-700 hover:bg-yellow-100',
    icon: AlertTriangle,
    label: 'À vérifier',
  },
};

// --- Icon helper for approval activities ---

function ApprovalActivityIcon({ activity }: { activity: ApprovalActivity }) {
  if (activity.activity_type === 'clock_in') return <LogIn className="h-4 w-4 text-emerald-600" />;
  if (activity.activity_type === 'clock_out') return <LogOut className="h-4 w-4 text-red-500" />;
  if (activity.activity_type === 'trip') {
    if (activity.transport_mode === 'walking') return <Footprints className="h-4 w-4 text-orange-500" />;
    if (activity.transport_mode === 'driving') return <Car className="h-4 w-4 text-blue-500" />;
    return <Car className="h-4 w-4 text-gray-300" />;
  }
  // Stop — use location type icon if available
  if (activity.location_name && activity.location_type) {
    const entry = LOCATION_TYPE_ICON_MAP[activity.location_type as LocationType];
    if (entry) {
      const Icon = entry.icon;
      return <Icon className={entry.className} />;
    }
  }
  if (activity.location_name) return <MapPin className="h-4 w-4 text-green-500" />;
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
        {activity.has_gps_gap && (
          <div className="col-span-2 flex items-center gap-2 p-2 mb-2 bg-amber-50 border border-amber-200 rounded text-xs text-amber-700">
            <AlertTriangle className="h-4 w-4 flex-shrink-0" />
            <span>Trajet sans trace GPS &mdash; aucune donn&eacute;e de parcours disponible</span>
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

  const handleOverride = async (activity: ApprovalActivity, newStatus: 'approved' | 'rejected') => {
    // If there's already an override with the same status, remove it (toggle back to auto)
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
  const canApprove = detail && !isApproved && detail.summary.needs_review_count === 0 && !detail.has_active_shift;

  return (
    <Sheet open onOpenChange={() => onClose()}>
      <SheetContent className="w-full sm:max-w-[50vw] overflow-y-auto" side="right">
        <SheetHeader>
          <SheetTitle>{employeeName}</SheetTitle>
          <p className="text-sm text-muted-foreground capitalize">{formatDate(date)}</p>
        </SheetHeader>

        {isLoading ? (
          <div className="flex items-center justify-center py-12">
            <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
          </div>
        ) : detail ? (
          <div className="mt-4 space-y-4">
            {/* Summary bar */}
            <div className="flex flex-wrap gap-2">
              <Badge className="bg-green-100 text-green-700 hover:bg-green-100">
                <CheckCircle2 className="h-3 w-3 mr-1" />
                {formatHours(detail.summary.approved_minutes)} approuvé
              </Badge>
              <Badge className="bg-red-100 text-red-700 hover:bg-red-100">
                <XCircle className="h-3 w-3 mr-1" />
                {formatHours(detail.summary.rejected_minutes)} rejeté
              </Badge>
              {detail.summary.needs_review_count > 0 && (
                <Badge className="bg-yellow-100 text-yellow-700 hover:bg-yellow-100">
                  <AlertTriangle className="h-3 w-3 mr-1" />
                  {detail.summary.needs_review_count} à vérifier
                </Badge>
              )}
              <Badge variant="outline">
                <Clock className="h-3 w-3 mr-1" />
                {formatHours(detail.summary.total_shift_minutes)} total
              </Badge>
            </div>

            {/* Approval status */}
            {isApproved && (
              <div className="rounded-md bg-green-50 p-3 text-sm text-green-700 flex items-center gap-2">
                <CheckCircle2 className="h-4 w-4" />
                <span>
                  Journée approuvée
                  {detail.approved_at && ` le ${new Date(detail.approved_at).toLocaleDateString('fr-CA')}`}
                </span>
              </div>
            )}

            {detail.has_active_shift && (
              <div className="rounded-md bg-gray-50 p-3 text-sm text-gray-600 flex items-center gap-2">
                <Clock className="h-4 w-4" />
                <span>Un quart de travail est encore en cours</span>
              </div>
            )}

            {/* Activity table */}
            <div className="overflow-x-auto border rounded-lg">
              <table className="w-full text-sm">
                <thead className="border-b bg-muted/50">
                  <tr>
                    <th className="px-3 py-2.5 text-center font-medium text-muted-foreground w-10">Type</th>
                    <th className="px-3 py-2.5 text-left font-medium text-muted-foreground">Début</th>
                    <th className="px-3 py-2.5 text-left font-medium text-muted-foreground">Fin</th>
                    <th className="px-3 py-2.5 text-left font-medium text-muted-foreground">Durée</th>
                    <th className="px-3 py-2.5 text-left font-medium text-muted-foreground">Détails</th>
                    <th className="px-3 py-2.5 text-right font-medium text-muted-foreground">Distance</th>
                    <th className="px-3 py-2.5 text-center font-medium text-muted-foreground">Approbation</th>
                    <th className="px-3 py-2.5 w-8"></th>
                  </tr>
                </thead>
                <tbody className="divide-y">
                  {processedActivities.length === 0 ? (
                    <tr>
                      <td colSpan={8} className="px-3 py-8 text-center text-sm text-gray-500">
                        Aucune activité détectée
                      </td>
                    </tr>
                  ) : (
                    processedActivities.map((pa) => (
                      <ActivityRow
                        key={`${pa.item.activity_type}-${pa.item.activity_id}`}
                        pa={pa}
                        isApproved={isApproved}
                        isSaving={isSaving}
                        isExpanded={expandedId === `${pa.item.activity_type}-${pa.item.activity_id}`}
                        onToggle={() => {
                          const key = `${pa.item.activity_type}-${pa.item.activity_id}`;
                          setExpandedId(expandedId === key ? null : key);
                        }}
                        onOverride={handleOverride}
                      />
                    ))
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

                {!canApprove && detail.summary.needs_review_count > 0 && (
                  <p className="text-xs text-yellow-600 text-center">
                    {detail.summary.needs_review_count} activité(s) à vérifier avant approbation
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

// --- Individual activity row ---

function ActivityRow({
  pa,
  isApproved,
  isSaving,
  isExpanded,
  onToggle,
  onOverride,
}: {
  pa: ProcessedActivity<ApprovalActivity>;
  isApproved: boolean;
  isSaving: boolean;
  isExpanded: boolean;
  onToggle: () => void;
  onOverride: (activity: ApprovalActivity, status: 'approved' | 'rejected') => void;
}) {
  const { item: activity, hasClockIn, hasClockOut } = pa;
  const isTrip = activity.activity_type === 'trip';
  const isStop = activity.activity_type === 'stop';
  const isClock = activity.activity_type === 'clock_in' || activity.activity_type === 'clock_out';
  const canExpand = !isClock;
  const hasOverride = activity.override_status !== null;

  const rowBg =
    activity.final_status === 'needs_review'
      ? 'bg-yellow-50'
      : activity.final_status === 'rejected'
      ? 'bg-red-50'
      : '';

  return (
    <>
      <tr
        className={`${rowBg} ${canExpand ? 'cursor-pointer' : ''} hover:bg-muted/50 transition-colors`}
        onClick={canExpand ? onToggle : undefined}
      >
        {/* Type icon */}
        <td className="px-3 py-2.5 text-center">
          <div className="flex items-center justify-center gap-0.5">
            {hasClockIn && <LogIn className="h-3.5 w-3.5 text-emerald-600" />}
            <ApprovalActivityIcon activity={activity} />
            {hasClockOut && <LogOut className="h-3.5 w-3.5 text-red-500" />}
          </div>
        </td>

        {/* Début */}
        <td className="px-3 py-2.5 whitespace-nowrap font-medium">
          {formatTime(activity.started_at)}
        </td>

        {/* Fin */}
        <td className="px-3 py-2.5 whitespace-nowrap text-muted-foreground">
          {isClock ? '\u2014' : formatTime(activity.ended_at)}
        </td>

        {/* Durée */}
        <td className="px-3 py-2.5 whitespace-nowrap tabular-nums">
          <div className="flex items-center gap-1">
            {isClock ? '\u2014' : formatDurationMinutes(activity.duration_minutes)}
            {isStop && (activity.gps_gap_seconds ?? 0) > 0 && (
              <span title={`${Math.round((activity.gps_gap_seconds ?? 0) / 60)} min sans signal GPS`}>
                <AlertTriangle className="h-3.5 w-3.5 text-amber-500" />
              </span>
            )}
            {isTrip && activity.has_gps_gap && (
              <span title="Trajet sans trace GPS">
                <AlertTriangle className="h-3.5 w-3.5 text-amber-500" />
              </span>
            )}
          </div>
        </td>

        {/* Détails */}
        <td className="px-3 py-2.5 max-w-[350px]">
          {isTrip ? (
            <div>
              <div className="flex items-center gap-1 text-xs truncate">
                <span className="truncate">{activity.start_location_name || 'Inconnu'}</span>
                <ArrowRight className="h-3 w-3 flex-shrink-0 text-muted-foreground" />
                <span className="truncate">{activity.end_location_name || 'Inconnu'}</span>
              </div>
              <div className="text-xs text-gray-500 mt-0.5">
                {activity.auto_reason}
                {hasOverride && <span className="ml-1 text-blue-600">(modifié manuellement)</span>}
              </div>
            </div>
          ) : isStop ? (
            <div>
              <span className={`text-xs ${activity.location_name ? 'text-green-600 font-medium' : 'text-amber-600'}`}>
                Arrêt{activity.location_name ? ` \u2014 ${activity.location_name}` : ' \u2014 Non associé'}
              </span>
              <div className="text-xs text-gray-500 mt-0.5">
                {activity.auto_reason}
                {hasOverride && <span className="ml-1 text-blue-600">(modifié manuellement)</span>}
              </div>
            </div>
          ) : (
            <div>
              <span className="text-xs text-muted-foreground">
                {activity.activity_type === 'clock_in' ? 'Clock-in' : 'Clock-out'}
                {activity.location_name ? ` \u2014 ${activity.location_name}` : ''}
              </span>
              <div className="text-xs text-gray-500 mt-0.5">
                {activity.auto_reason}
                {hasOverride && <span className="ml-1 text-blue-600">(modifié manuellement)</span>}
              </div>
            </div>
          )}
        </td>

        {/* Distance */}
        <td className="px-3 py-2.5 text-right tabular-nums whitespace-nowrap">
          {isTrip ? formatDistance(activity.road_distance_km ?? activity.distance_km) : '\u2014'}
        </td>

        {/* Approbation */}
        <td className="px-3 py-2.5 text-center">
          {!isApproved ? (
            <div className="flex items-center justify-center gap-1" onClick={(e) => e.stopPropagation()}>
              <Button
                variant="ghost"
                size="icon"
                className={`h-7 w-7 ${
                  activity.final_status === 'approved'
                    ? 'text-green-600 bg-green-100'
                    : 'text-gray-400 hover:text-green-600'
                }`}
                onClick={() => onOverride(activity, 'approved')}
                disabled={isSaving}
              >
                <CheckCircle2 className="h-4 w-4" />
              </Button>
              <Button
                variant="ghost"
                size="icon"
                className={`h-7 w-7 ${
                  activity.final_status === 'rejected'
                    ? 'text-red-600 bg-red-100'
                    : 'text-gray-400 hover:text-red-600'
                }`}
                onClick={() => onOverride(activity, 'rejected')}
                disabled={isSaving}
              >
                <XCircle className="h-4 w-4" />
              </Button>
            </div>
          ) : (
            <Badge variant="secondary" className={STATUS_BADGE[activity.final_status].className}>
              {(() => { const StatusIcon = STATUS_BADGE[activity.final_status].icon; return <StatusIcon className="h-3 w-3 mr-1" />; })()}
              {STATUS_BADGE[activity.final_status].label}
            </Badge>
          )}
        </td>

        {/* Expand chevron */}
        <td className="px-3 py-2.5 text-center">
          {canExpand && (
            isExpanded
              ? <ChevronUp className="h-4 w-4 text-muted-foreground" />
              : <ChevronDown className="h-4 w-4 text-muted-foreground" />
          )}
        </td>
      </tr>

      {/* Expanded detail row */}
      {isExpanded && canExpand && (
        <tr>
          <td colSpan={8} className="p-0">
            {isTrip ? (
              <TripExpandDetail activity={activity} />
            ) : isStop ? (
              <StopExpandDetail activity={activity} />
            ) : null}
          </td>
        </tr>
      )}
    </>
  );
}
