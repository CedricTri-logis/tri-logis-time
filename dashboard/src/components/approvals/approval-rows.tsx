'use client';

import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import {
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
  WifiOff,
  UtensilsCrossed,
} from 'lucide-react';
import { TripExpandDetail } from './trip-expand-detail';
import { GapExpandDetail } from './gap-expand-detail';
import { StopExpandDetail } from './stop-expand-detail';
import { ClockTimeEditPopover } from './clock-time-edit-popover';
import { ClusterSegmentModal } from './cluster-segment-modal';
import { LOCATION_TYPE_ICON_MAP } from '@/lib/constants/location-icons';
import { LOCATION_TYPE_LABELS } from '@/lib/validations/location';
import type { ProcessedActivity } from '@/lib/utils/merge-clock-events';
import { formatTime, formatDurationMinutes, formatDistance } from '@/lib/utils/activity-display';
import type { LocationType } from '@/types/location';
import type {
  ApprovalActivity,
  DayApprovalDetail as DayApprovalDetailType,
  ProjectSession,
} from '@/types/mileage';
import {
  type ProjectSlice,
  type DisplayItem,
  getProjectSlices,
  type MergedGroup,
} from './approval-utils';
import { Fragment, useState } from 'react';
import { resolveGeocodedName, type GeocodeResult } from '@/lib/hooks/use-reverse-geocode';

// --- Project cell component ---

export function ProjectCell({ slices }: { slices: ProjectSlice[] }) {
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

// --- Icon helper for approval activities ---

export function ApprovalActivityIcon({ activity }: { activity: ApprovalActivity }) {
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

// --- Compact trip connector row ---

export function TripConnectorRow({
  pa,
  isApproved,
  isSaving,
  isExpanded,
  onToggle,
  onOverride,
  projectSessions,
  geocodedAddresses,
}: {
  pa: ProcessedActivity<ApprovalActivity>;
  isApproved: boolean;
  isSaving: boolean;
  isExpanded: boolean;
  onToggle: () => void;
  onOverride: (activity: ApprovalActivity, status: 'approved' | 'rejected') => void;
  projectSessions: ProjectSession[];
  geocodedAddresses?: Map<string, GeocodeResult>;
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
              <TripExpandDetail activity={activity} geocodedAddresses={geocodedAddresses} />
            </div>
          </td>
        </tr>
      )}
    </>
  );
}

// --- GPS gap sub-row inside merged location row ---

export function GapSubRow({
  gap,
  isApproved,
  isSaving,
  onOverride,
  geocodedAddresses,
}: {
  gap: ApprovalActivity;
  isApproved: boolean;
  isSaving: boolean;
  onOverride: (activity: ApprovalActivity, status: 'approved' | 'rejected') => void;
  geocodedAddresses?: Map<string, GeocodeResult>;
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

export function MergedLocationRow({
  group,
  isApproved,
  isSaving,
  isExpanded,
  onToggle,
  onOverride,
  projectSessions,
  geocodedAddresses,
}: {
  group: MergedGroup;
  isApproved: boolean;
  isSaving: boolean;
  isExpanded: boolean;
  onToggle: () => void;
  onOverride: (activity: ApprovalActivity, status: 'approved' | 'rejected') => void;
  projectSessions: ProjectSession[];
  geocodedAddresses?: Map<string, GeocodeResult>;
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
                {activity.location_name || resolveGeocodedName(activity.latitude, activity.longitude, geocodedAddresses, 'Arrêt non associé')}
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
                    geocodedAddresses={geocodedAddresses}
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

export function ActivityRow({
  pa,
  isApproved,
  isSaving,
  isExpanded,
  onToggle,
  onOverride,
  onDetailUpdated,
  projectSessions,
  geocodedAddresses,
}: {
  pa: ProcessedActivity<ApprovalActivity>;
  isApproved: boolean;
  isSaving: boolean;
  isExpanded: boolean;
  onToggle: () => void;
  onOverride: (activity: ApprovalActivity, status: 'approved' | 'rejected') => void;
  onDetailUpdated?: (data: DayApprovalDetailType) => void;
  projectSessions: ProjectSession[];
  geocodedAddresses?: Map<string, GeocodeResult>;
}) {
  const { item: activity, hasClockIn, hasClockOut, clockInActivity, clockOutActivity } = pa;
  const isStop = activity.activity_type === 'stop';
  const isSegment = activity.activity_type === 'stop_segment';
  const isStopLike = isStop || isSegment;
  const isClock = activity.activity_type === 'clock_in' || activity.activity_type === 'clock_out';
  const isGap = activity.activity_type === 'gap';
  const isLunch = activity.activity_type === 'lunch';
  const canExpand = isStopLike || isGap;
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
            {isStop && !isApproved && onDetailUpdated && (
              <span onClick={(e) => e.stopPropagation()}>
                <ClusterSegmentModal
                  clusterId={activity.activity_id}
                  startedAt={activity.started_at}
                  endedAt={activity.ended_at}
                  isSegmented={false}
                  onUpdated={onDetailUpdated}
                />
              </span>
            )}
            {isSegment && (
              <Badge variant="outline" className="text-[10px] px-1 py-0 ml-1">Segment</Badge>
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
                  <span>{activity.start_location_name || resolveGeocodedName(activity.latitude, activity.longitude, geocodedAddresses, 'Inconnu')}</span>
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
          ) : isStopLike ? (
            <div className="space-y-1">
              <div className={`text-xs flex items-center gap-1.5 ${statusConfig.text}`}>
                <span className={activity.location_name ? 'font-bold underline decoration-current/20' : ''}>
                  {activity.location_name || resolveGeocodedName(activity.latitude, activity.longitude, geocodedAddresses, 'Arrêt non associé')}
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
                {activity.location_name || resolveGeocodedName(activity.latitude, activity.longitude, geocodedAddresses, 'Lieu inconnu')}
              </div>
            </div>
          )}
        </td>

        {/* Horaire */}
        <td className="px-3 py-3 whitespace-nowrap">
          <div className="flex flex-col gap-0.5">
            {/* Start time — with clock-in edit if merged */}
            <span className="flex items-center gap-1">
              {hasClockIn && clockInActivity && (clockInActivity as ApprovalActivity).is_edited && (clockInActivity as ApprovalActivity).original_value && (
                <span className="line-through text-muted-foreground text-[10px]">
                  {formatTime((clockInActivity as ApprovalActivity).original_value!)}
                </span>
              )}
              <span className={`text-xs font-black ${statusConfig.text}`}>{formatTime(activity.started_at)}</span>
              {hasClockIn && clockInActivity && (clockInActivity as ApprovalActivity).is_edited && (
                <Badge variant="outline" className="text-[10px] px-1 py-0">Modifié</Badge>
              )}
              {hasClockIn && !isApproved && onDetailUpdated && (
                <span onClick={(e) => e.stopPropagation()}>
                  <ClockTimeEditPopover
                    shiftId={activity.shift_id}
                    field="clocked_in_at"
                    currentTime={clockInActivity ? clockInActivity.started_at : activity.started_at}
                    originalTime={clockInActivity ? (clockInActivity as ApprovalActivity).original_value : undefined}
                    isEdited={!!(clockInActivity && (clockInActivity as ApprovalActivity).is_edited)}
                    onUpdated={onDetailUpdated}
                  />
                </span>
              )}
              {isClock && activity.activity_type === 'clock_in' && !isApproved && onDetailUpdated && (
                <span onClick={(e) => e.stopPropagation()}>
                  <ClockTimeEditPopover
                    shiftId={activity.shift_id}
                    field="clocked_in_at"
                    currentTime={activity.started_at}
                    originalTime={activity.original_value}
                    isEdited={!!activity.is_edited}
                    onUpdated={onDetailUpdated}
                  />
                </span>
              )}
            </span>

            {/* End time — with clock-out edit if merged */}
            {!isClock && (
              <span className="flex items-center gap-1">
                {hasClockOut && clockOutActivity && (clockOutActivity as ApprovalActivity).is_edited && (clockOutActivity as ApprovalActivity).original_value && (
                  <span className="line-through text-muted-foreground text-[10px]">
                    {formatTime((clockOutActivity as ApprovalActivity).original_value!)}
                  </span>
                )}
                <span className={`text-[10px] font-medium ${statusConfig.subtext}`}>{formatTime(activity.ended_at)}</span>
                {hasClockOut && clockOutActivity && (clockOutActivity as ApprovalActivity).is_edited && (
                  <Badge variant="outline" className="text-[10px] px-1 py-0">Modifié</Badge>
                )}
                {hasClockOut && !isApproved && onDetailUpdated && (
                  <span onClick={(e) => e.stopPropagation()}>
                    <ClockTimeEditPopover
                      shiftId={activity.shift_id}
                      field="clocked_out_at"
                      currentTime={clockOutActivity ? clockOutActivity.started_at : activity.ended_at}
                      originalTime={clockOutActivity ? (clockOutActivity as ApprovalActivity).original_value : undefined}
                      isEdited={!!(clockOutActivity && (clockOutActivity as ApprovalActivity).is_edited)}
                      onUpdated={onDetailUpdated}
                    />
                  </span>
                )}
              </span>
            )}

            {/* Standalone clock-out */}
            {isClock && activity.activity_type === 'clock_out' && !isApproved && onDetailUpdated && (
              <span className="flex items-center gap-1">
                {activity.is_edited && activity.original_value && (
                  <span className="line-through text-muted-foreground text-[10px]">
                    {formatTime(activity.original_value)}
                  </span>
                )}
                <span className={`text-xs font-black ${statusConfig.text}`}>{formatTime(activity.started_at)}</span>
                {activity.is_edited && (
                  <Badge variant="outline" className="text-[10px] px-1 py-0">Modifié</Badge>
                )}
                <span onClick={(e) => e.stopPropagation()}>
                  <ClockTimeEditPopover
                    shiftId={activity.shift_id}
                    field="clocked_out_at"
                    currentTime={activity.started_at}
                    originalTime={activity.original_value}
                    isEdited={!!activity.is_edited}
                    onUpdated={onDetailUpdated}
                  />
                </span>
              </span>
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

      {/* Expanded detail row (stops/segments + gaps — trips use TripConnectorRow) */}
      {isExpanded && canExpand && (
        <tr>
          <td colSpan={9} className="p-0 border-b">
            <div className="px-4 py-6 bg-muted/10 border-t border-b">
              {isGap ? (
                <GapExpandDetail activity={activity} geocodedAddresses={geocodedAddresses} />
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

// --- Collapsible lunch group row ---

export function LunchGroupRow({
  lunch,
  children: childItems,
  isApproved,
  isSaving,
  onOverride,
  onDetailUpdated,
  projectSessions,
  geocodedAddresses,
}: {
  lunch: ProcessedActivity<ApprovalActivity>;
  children: DisplayItem[];
  isApproved: boolean;
  isSaving: boolean;
  isExpanded?: boolean;
  onToggle?: () => void;
  onOverride: (activity: ApprovalActivity, status: 'approved' | 'rejected') => void;
  onDetailUpdated?: (data: DayApprovalDetailType) => void;
  projectSessions: ProjectSession[];
  expandedChildId?: string | null;
  onChildToggle?: (key: string) => void;
  geocodedAddresses?: Map<string, GeocodeResult>;
}) {
  const activity = lunch.item;
  const [open, setOpen] = useState(false);
  const [expandedChild, setExpandedChild] = useState<string | null>(null);

  return (
    <>
      {/* Lunch summary row — always visible */}
      <tr
        className="bg-slate-50/80 border-l-4 border-l-slate-300 hover:bg-slate-100/80 cursor-pointer transition-all duration-200 group border-b border-white/50"
        onClick={() => setOpen(!open)}
      >
        {/* Action */}
        <td className="px-3 py-3 text-center">
          <div className="flex justify-center">
            <Badge variant="outline" className="font-bold text-[10px] px-2.5 py-0.5 rounded-full bg-slate-100 text-slate-600 border-slate-200">
              <UtensilsCrossed className="h-3 w-3 mr-1" />
              Pause
            </Badge>
          </div>
        </td>

        {/* Clock icon */}
        <td className="px-2 py-3 text-center">
          <div className="flex items-center justify-center">
            <UtensilsCrossed className="h-3.5 w-3.5 text-orange-500" />
          </div>
        </td>

        {/* Type icon */}
        <td className="px-2 py-3 text-center">
          <div className="flex justify-center bg-white/80 rounded-lg p-1.5 shadow-sm border border-black/5 group-hover:scale-110 transition-transform">
            <UtensilsCrossed className="h-4 w-4 text-orange-500" />
          </div>
        </td>

        {/* Durée */}
        <td className="px-3 py-3 whitespace-nowrap">
          <div className="flex items-center gap-1.5 tabular-nums text-xs text-slate-700 font-medium">
            {formatDurationMinutes(activity.duration_minutes)}
          </div>
        </td>

        {/* Détails */}
        <td className="px-3 py-3 max-w-[300px]">
          <div className="space-y-1">
            <div className="text-xs flex items-center gap-1.5 text-orange-700 font-medium">
              <UtensilsCrossed className="h-3 w-3" />
              <span className="font-bold">Pause dîner</span>
            </div>
            <div className="flex items-center gap-1.5">
              <span className="text-[10px] leading-tight text-orange-600/70">
                {formatTime(activity.started_at)} — {formatTime(activity.ended_at)}
              </span>
              {childItems.length > 0 && (
                <span className="text-[10px] text-slate-400">
                  · {childItems.length} activité{childItems.length > 1 ? 's' : ''}
                </span>
              )}
            </div>
          </div>
        </td>

        {/* Horaire */}
        <td className="px-3 py-3 whitespace-nowrap">
          <div className="flex flex-col">
            <span className="text-xs font-black text-slate-700">{formatTime(activity.started_at)}</span>
            <span className="text-[10px] font-medium text-slate-500">{formatTime(activity.ended_at)}</span>
          </div>
        </td>

        {/* Distance */}
        <td className="px-3 py-3 text-right">
          <span className="opacity-20 text-xs font-bold">—</span>
        </td>

        {/* Projet */}
        <td className="px-3 py-3">
          <span className="text-[10px] text-muted-foreground/40">—</span>
        </td>

        {/* Expand chevron */}
        <td className="px-3 py-3 text-center">
          {childItems.length > 0 && (
            <div className={`rounded-full p-1 transition-colors ${open ? 'bg-muted' : 'group-hover:bg-muted'}`}>
              {open
                ? <ChevronUp className="h-4 w-4 text-primary" />
                : <ChevronDown className="h-4 w-4 text-muted-foreground" />
              }
            </div>
          )}
        </td>
      </tr>

      {/* Expanded: nested child activities */}
      {open && childItems.map((child) => {
        if (child.type === 'merged') {
          const group = child.group;
          const key = `merged-${group.primaryStop.item.activity_id}`;
          return (
            <MergedLocationRow
              key={key}
              group={group}
              isApproved={isApproved}
              isSaving={isSaving}
              isExpanded={expandedChild === key}
              onToggle={() => setExpandedChild(expandedChild === key ? null : key)}
              onOverride={onOverride}
              projectSessions={projectSessions}
              geocodedAddresses={geocodedAddresses}
            />
          );
        }

        if (child.type === 'activity') {
          const pa = child.pa;
          const key = `${pa.item.activity_type}-${pa.item.activity_id}`;
          const isTrip = pa.item.activity_type === 'trip';

          return isTrip ? (
            <TripConnectorRow
              key={key}
              pa={pa}
              isApproved={isApproved}
              isSaving={isSaving}
              isExpanded={expandedChild === key}
              onToggle={() => setExpandedChild(expandedChild === key ? null : key)}
              onOverride={onOverride}
              projectSessions={projectSessions}
              geocodedAddresses={geocodedAddresses}
            />
          ) : (
            <ActivityRow
              key={key}
              pa={pa}
              isApproved={isApproved}
              isSaving={isSaving}
              isExpanded={expandedChild === key}
              onToggle={() => setExpandedChild(expandedChild === key ? null : key)}
              onOverride={onOverride}
              onDetailUpdated={onDetailUpdated}
              projectSessions={projectSessions}
              geocodedAddresses={geocodedAddresses}
            />
          );
        }

        return null;
      })}
    </>
  );
}
