'use client';

import { useState, useEffect, useCallback, useMemo, useRef, Fragment } from 'react';
import { useReverseGeocode, type GeocodeResult } from '@/lib/hooks/use-reverse-geocode';
import { Sheet, SheetContent, SheetTitle } from '@/components/ui/sheet';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Textarea } from '@/components/ui/textarea';
import {
  Loader2,
  CheckCircle2,
  XCircle,
  AlertTriangle,
  Car,
  Clock,
  Calendar,
  User,
  WifiOff,
  UtensilsCrossed,
  MapPin,
  Phone,
} from 'lucide-react';
import { toast } from 'sonner';
import { supabaseClient } from '@/lib/supabase/client';
import { LOCATION_TYPE_ICON_MAP } from '@/lib/constants/location-icons';
import { LOCATION_TYPE_LABELS } from '@/lib/validations/location';
import { mergeClockEvents } from '@/lib/utils/merge-clock-events';
import { formatDuration, formatTime } from '@/lib/utils/activity-display';
import type { LocationType } from '@/types/location';
import type {
  DayApprovalDetail as DayApprovalDetailType,
  ApprovalActivity,
} from '@/types/mileage';
import {
  mergeSameLocationGaps,
  nestLunchActivities,
  groupDisplayItemsByShift,
  formatHours,
  formatDate,
} from './approval-utils';
import {
  ProjectCell,
  ApprovalActivityIcon,
  TripConnectorRow,
  GapSubRow,
  MergedLocationRow,
  ActivityRow,
  LunchGroupRow,
} from './approval-rows';

interface DayApprovalDetailProps {
  employeeId: string;
  employeeName: string;
  date: string;
  onClose: (hasChanges: boolean) => void;
}

// --- Main component ---

export function DayApprovalDetail({ employeeId, employeeName, date, onClose }: DayApprovalDetailProps) {
  const [detail, setDetail] = useState<DayApprovalDetailType | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isSaving, setIsSaving] = useState(false);
  const [notes, setNotes] = useState('');
  const [showNotes, setShowNotes] = useState(false);
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const hasChanges = useRef(false);

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

  // Merge same-location GPS gaps into grouped rows, then nest lunch sub-activities
  const displayItems = useMemo(() => {
    const merged = mergeSameLocationGaps(processedActivities);
    return nestLunchActivities(merged);
  }, [processedActivities]);

  // Group display items by shift for visual containers
  const shiftGroups = useMemo(() => {
    return groupDisplayItemsByShift(displayItems);
  }, [displayItems]);

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

  // Collect coordinates of activities without a known location name for reverse geocoding
  const unknownLocationPoints = useMemo(() => {
    if (!detail?.activities) return [];
    const points: { latitude: number; longitude: number }[] = [];
    for (const a of detail.activities) {
      // Stops/clocks without a geofence match
      if (!a.location_name && a.latitude != null && a.longitude != null) {
        points.push({ latitude: a.latitude, longitude: a.longitude });
      }
      // Trip/gap start without a name
      if (!a.start_location_name && a.latitude != null && a.longitude != null) {
        points.push({ latitude: a.latitude, longitude: a.longitude });
      }
    }
    return points;
  }, [detail?.activities]);

  const { results: geocodedAddresses } = useReverseGeocode(unknownLocationPoints);

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
        hasChanges.current = true;
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
      hasChanges.current = true;
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
      hasChanges.current = true;
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
      hasChanges.current = true;
      setDetail(data as DayApprovalDetailType);
      toast.success('Journée rouverte');
    } finally {
      setIsSaving(false);
    }
  };

  const handleShiftTypeToggle = async (shiftId: string, newType: 'regular' | 'call') => {
    const { data: { user } } = await supabaseClient.auth.getUser();
    if (!user) return;

    const { error } = await supabaseClient.rpc('update_shift_type', {
      p_shift_id: shiftId,
      p_shift_type: newType,
      p_changed_by: user.id,
    });

    if (error) {
      toast.error(`Erreur: ${error.message}`);
      return;
    }

    toast.success(newType === 'call' ? 'Marqué comme rappel' : 'Rappel retiré');
    hasChanges.current = true;
    fetchDetail();
  };

  const isApproved = detail?.approval_status === 'approved';
  const canApprove = detail && !isApproved && visibleNeedsReviewCount === 0 && !detail.has_active_shift;

  return (
    <Sheet open onOpenChange={() => onClose(hasChanges.current)}>
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
            <div className={`grid grid-cols-2 ${gpsGapTotals.seconds > 0 || (detail.summary.lunch_minutes ?? 0) > 0 ? 'sm:grid-cols-5' : 'sm:grid-cols-4'} gap-4`}>
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
                  <span className="text-2xl font-black text-slate-800 tracking-tight">{formatHours(detail.summary.total_shift_minutes + (detail.summary.call_bonus_minutes ?? 0))}</span>
                </div>
                {(detail.summary.call_bonus_minutes ?? 0) > 0 && (
                  <span className="text-[10px] text-orange-600 font-medium mt-0.5">+{formatHours(detail.summary.call_bonus_minutes)} rappel</span>
                )}
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
                    }`}>{Math.round(gpsGapTotals.seconds / 60)}&nbsp;min</span>
                  </div>
                  <span className="text-[10px] text-muted-foreground/60 font-medium">
                    {gpsGapTotals.count} interruption{gpsGapTotals.count > 1 ? 's' : ''}
                  </span>
                </div>
              )}

              {(detail.summary.lunch_minutes ?? 0) > 0 && (
                <div className="group relative overflow-hidden flex flex-col p-4 bg-slate-50 rounded-2xl border border-slate-200 shadow-sm transition-all hover:shadow-md">
                  <div className="absolute top-0 right-0 p-3 text-slate-200 group-hover:scale-110 transition-transform">
                    <UtensilsCrossed className="h-12 w-12" />
                  </div>
                  <span className="text-[10px] uppercase tracking-[0.1em] text-slate-500 font-bold mb-1">Dîner</span>
                  <div className="flex items-baseline gap-1 mt-auto">
                    <span className="text-2xl font-black text-slate-700 tracking-tight">{formatHours(detail.summary.lunch_minutes)}</span>
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
                {(detail.summary.call_bonus_minutes ?? 0) > 0 && (
                  <span
                    className="inline-flex items-center gap-1 rounded-full bg-orange-50 px-2 py-0.5 text-xs font-medium text-orange-700 border border-orange-200"
                    title="Bonus rappel (min. 3h)"
                  >
                    <Phone className="h-3 w-3" />
                    +{formatHours(detail.summary.call_bonus_minutes)}
                  </span>
                )}
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

            {detail?.has_stale_gps && (
              <div className="flex items-center gap-2 rounded-md bg-orange-50 border border-orange-200 px-3 py-2 text-sm text-orange-700">
                <AlertTriangle className="h-4 w-4" />
                <span>GPS manquant — un ou plusieurs quarts n&apos;ont pas reçu de signal GPS</span>
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
                  {shiftGroups.length === 0 ? (
                    <tr>
                      <td colSpan={9} className="px-3 py-12 text-center text-sm text-muted-foreground italic">
                        Aucune activité détectée pour cette période
                      </td>
                    </tr>
                  ) : (
                    shiftGroups.map((shift) => {
                      const isCall = shift.shiftType === 'call';
                      const ps = detail?.project_sessions ?? [];
                      return (
                        <Fragment key={shift.shiftId}>
                          {/* Shift header row */}
                          <tr className={`border-b-2 ${
                            isCall
                              ? 'bg-orange-100/80 border-b-orange-300'
                              : 'bg-slate-100/80 border-b-slate-200'
                          }`}>
                            <td colSpan={9} className="px-4 py-2.5">
                              <div className="flex items-center justify-between">
                                <div className="flex items-center gap-3">
                                  <span className={`text-xs font-bold uppercase tracking-wider ${
                                    isCall ? 'text-orange-800' : 'text-slate-600'
                                  }`}>
                                    Quart {shift.shiftNumber}
                                  </span>
                                  <span className={`text-xs tabular-nums ${
                                    isCall ? 'text-orange-700' : 'text-slate-500'
                                  }`}>
                                    {formatTime(shift.startedAt)} → {formatTime(shift.endedAt)}
                                  </span>
                                  <span className={`text-xs font-semibold ${
                                    isCall ? 'text-orange-800' : 'text-slate-700'
                                  }`}>
                                    ({formatHours(shift.durationMinutes)})
                                  </span>
                                  {isCall && (
                                    <Badge className="bg-orange-200 text-orange-800 border-orange-300 text-[10px]">
                                      <Phone className="h-3 w-3 mr-0.5" />
                                      Rappel {shift.shiftTypeSource === 'auto' ? '(auto)' : '(manuel)'}
                                    </Badge>
                                  )}
                                </div>
                                <div onClick={(e) => e.stopPropagation()}>
                                  {isCall ? (
                                    <Button
                                      variant="ghost"
                                      size="sm"
                                      className="h-7 text-xs text-orange-600 hover:text-orange-800 hover:bg-orange-200/50"
                                      onClick={() => handleShiftTypeToggle(shift.shiftId, 'regular')}
                                      disabled={isSaving || isApproved}
                                    >
                                      Retirer rappel
                                    </Button>
                                  ) : (
                                    <Button
                                      variant="ghost"
                                      size="sm"
                                      className="h-7 text-xs text-orange-600 hover:text-orange-800 hover:bg-orange-100"
                                      onClick={() => handleShiftTypeToggle(shift.shiftId, 'call')}
                                      disabled={isSaving || isApproved}
                                    >
                                      <Phone className="h-3 w-3 mr-1" />
                                      Marquer comme rappel
                                    </Button>
                                  )}
                                </div>
                              </div>
                            </td>
                          </tr>
                          {/* Shift activities */}
                          {shift.items.map((item) => {
                            if (item.type === 'lunch_group') {
                              const key = `lunch-${item.lunch.item.activity_id}`;
                              return (
                                <LunchGroupRow
                                  key={key}
                                  lunch={item.lunch}
                                  children={item.children}
                                  isApproved={isApproved}
                                  isSaving={isSaving}
                                  onOverride={handleOverride}
                                  onDetailUpdated={(data) => { hasChanges.current = true; setDetail(data); }}
                                  projectSessions={ps}
                                  geocodedAddresses={geocodedAddresses}
                                  employeeId={employeeId}
                                />
                              );
                            }

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
                                  geocodedAddresses={geocodedAddresses}
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
                                onDetailUpdated={(data) => { hasChanges.current = true; setDetail(data); }}
                                projectSessions={ps}
                                geocodedAddresses={geocodedAddresses}
                                employeeId={employeeId}
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
                                onDetailUpdated={(data) => { hasChanges.current = true; setDetail(data); }}
                                projectSessions={ps}
                                geocodedAddresses={geocodedAddresses}
                                employeeId={employeeId}
                              />
                            );
                          })}
                        </Fragment>
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
