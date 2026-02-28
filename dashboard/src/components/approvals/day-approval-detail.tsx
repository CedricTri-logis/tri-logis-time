'use client';

import { useState, useEffect, useCallback } from 'react';
import { Sheet, SheetContent, SheetHeader, SheetTitle } from '@/components/ui/sheet';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Textarea } from '@/components/ui/textarea';
import { Loader2, CheckCircle2, XCircle, AlertTriangle, MapPin, Car, Footprints, Clock, LogIn, LogOut } from 'lucide-react';
import { toast } from 'sonner';
import { supabaseClient } from '@/lib/supabase/client';
import type { DayApprovalDetail as DayApprovalDetailType, ApprovalActivity, ApprovalAutoStatus } from '@/types/mileage';

interface DayApprovalDetailProps {
  employeeId: string;
  employeeName: string;
  date: string;
  onClose: () => void;
}

function formatTime(dateStr: string): string {
  return new Date(dateStr).toLocaleTimeString('fr-CA', { hour: '2-digit', minute: '2-digit' });
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

function ActivityIcon({ type }: { type: string }) {
  switch (type) {
    case 'trip':
      return <Car className="h-4 w-4 text-blue-500" />;
    case 'stop':
      return <MapPin className="h-4 w-4 text-purple-500" />;
    case 'clock_in':
      return <LogIn className="h-4 w-4 text-green-500" />;
    case 'clock_out':
      return <LogOut className="h-4 w-4 text-red-500" />;
    default:
      return <Clock className="h-4 w-4 text-gray-500" />;
  }
}

function ActivityLabel({ activity }: { activity: ApprovalActivity }) {
  switch (activity.activity_type) {
    case 'stop':
      return (
        <span>
          Arrêt{activity.location_name ? ` — ${activity.location_name}` : ''}
          {activity.duration_minutes > 0 && (
            <span className="text-gray-500 ml-1">({formatHours(activity.duration_minutes)})</span>
          )}
        </span>
      );
    case 'trip': {
      const from = activity.start_location_name || 'Inconnu';
      const to = activity.end_location_name || 'Inconnu';
      return (
        <span>
          {from} → {to}
          {activity.distance_km && (
            <span className="text-gray-500 ml-1">({activity.distance_km.toFixed(1)} km)</span>
          )}
          {activity.duration_minutes > 0 && (
            <span className="text-gray-500 ml-1">{formatHours(activity.duration_minutes)}</span>
          )}
          {activity.transport_mode === 'walking' && (
            <Footprints className="inline h-3 w-3 text-orange-500 ml-1" />
          )}
        </span>
      );
    }
    case 'clock_in':
      return (
        <span>
          Clock-in{activity.location_name ? ` — ${activity.location_name}` : ''}
        </span>
      );
    case 'clock_out':
      return (
        <span>
          Clock-out{activity.location_name ? ` — ${activity.location_name}` : ''}
        </span>
      );
    default:
      return <span>{activity.activity_type}</span>;
  }
}

export function DayApprovalDetail({ employeeId, employeeName, date, onClose }: DayApprovalDetailProps) {
  const [detail, setDetail] = useState<DayApprovalDetailType | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isSaving, setIsSaving] = useState(false);
  const [notes, setNotes] = useState('');
  const [showNotes, setShowNotes] = useState(false);

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
    } catch (err) {
      toast.error('Erreur lors du chargement');
    } finally {
      setIsLoading(false);
    }
  }, [employeeId, date]);

  useEffect(() => {
    fetchDetail();
  }, [fetchDetail]);

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
      <SheetContent className="w-full sm:max-w-[520px] overflow-y-auto">
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

            {/* Activity timeline */}
            <div className="space-y-1">
              <h3 className="text-sm font-medium text-gray-700 mb-2">Activités</h3>
              {detail.activities.length === 0 ? (
                <p className="text-sm text-gray-500">Aucune activité détectée</p>
              ) : (
                detail.activities.map((activity) => {
                  const statusConfig = STATUS_BADGE[activity.final_status];
                  const StatusIcon = statusConfig.icon;
                  const hasOverride = activity.override_status !== null;

                  return (
                    <div
                      key={`${activity.activity_type}-${activity.activity_id}`}
                      className={`flex items-start gap-3 rounded-lg p-2 text-sm ${
                        activity.final_status === 'needs_review'
                          ? 'bg-yellow-50'
                          : activity.final_status === 'rejected'
                          ? 'bg-red-50'
                          : 'bg-white'
                      }`}
                    >
                      {/* Time */}
                      <span className="text-xs text-gray-500 min-w-[40px] pt-0.5">
                        {formatTime(activity.started_at)}
                      </span>

                      {/* Icon */}
                      <ActivityIcon type={activity.activity_type} />

                      {/* Label */}
                      <div className="flex-1 min-w-0">
                        <div className="truncate">
                          <ActivityLabel activity={activity} />
                        </div>
                        <div className="text-xs text-gray-500 mt-0.5">
                          {activity.auto_reason}
                          {hasOverride && (
                            <span className="ml-1 text-blue-600">(modifié manuellement)</span>
                          )}
                        </div>
                      </div>

                      {/* Status + actions */}
                      <div className="flex items-center gap-1 shrink-0">
                        {!isApproved ? (
                          <>
                            <Button
                              variant="ghost"
                              size="icon"
                              className={`h-7 w-7 ${
                                activity.final_status === 'approved'
                                  ? 'text-green-600 bg-green-100'
                                  : 'text-gray-400 hover:text-green-600'
                              }`}
                              onClick={() => handleOverride(activity, 'approved')}
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
                              onClick={() => handleOverride(activity, 'rejected')}
                              disabled={isSaving}
                            >
                              <XCircle className="h-4 w-4" />
                            </Button>
                          </>
                        ) : (
                          <Badge variant="secondary" className={statusConfig.className}>
                            <StatusIcon className="h-3 w-3 mr-1" />
                            {statusConfig.label}
                          </Badge>
                        )}
                      </div>
                    </div>
                  );
                })
              )}
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
