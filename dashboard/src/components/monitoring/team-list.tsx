'use client';

import Link from 'next/link';
import { Briefcase, ChevronRight, Clock, LogIn, MapPin, MonitorSmartphone, Smartphone, SprayCan, User, UtensilsCrossed, Wrench } from 'lucide-react';
import { ACTIVITY_TYPE_CONFIG, type ActivityType } from '@/types/work-session';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Skeleton } from '@/components/ui/skeleton';
import { DurationCounter } from './duration-counter';
import { LastUpdatedBadge } from './staleness-indicator';
import { NoTeamEmptyState, NoResultsEmptyState } from './empty-states';
import { formatDeviceModel } from '@/lib/utils/device-model';
import type { MonitoredEmployee } from '@/types/monitoring';

interface TeamListProps {
  team: MonitoredEmployee[];
  isLoading?: boolean;
  search?: string;
  shiftStatus?: 'all' | 'on-shift' | 'off-shift' | 'never-installed';
  onClearFilters?: () => void;
}

/**
 * List of supervised team members with shift status and current location info.
 * Each row links to the employee's shift detail page.
 */
export function TeamList({
  team,
  isLoading,
  search = '',
  shiftStatus = 'all',
  onClearFilters,
}: TeamListProps) {
  if (isLoading) {
    return <TeamListSkeleton />;
  }

  if (team.length === 0) {
    const hasFilters = search !== '' || shiftStatus !== 'all';

    if (hasFilters && onClearFilters) {
      return (
        <NoResultsEmptyState
          search={search}
          shiftStatus={shiftStatus}
          onClearFilters={onClearFilters}
        />
      );
    }

    return <NoTeamEmptyState />;
  }

  return (
    <Card>
      <CardHeader className="pb-3">
        <CardTitle className="text-base font-medium">
          Membres de l&apos;équipe ({team.length})
        </CardTitle>
      </CardHeader>
      <CardContent className="p-0">
        <ul className="divide-y divide-slate-100">
          {team.map((employee) => (
            <TeamListItem key={employee.id} employee={employee} />
          ))}
        </ul>
      </CardContent>
    </Card>
  );
}

interface TeamListItemProps {
  employee: MonitoredEmployee;
}

function TeamListItem({ employee }: TeamListItemProps) {
  const isOnShift = employee.shiftStatus === 'on-shift';

  return (
    <li>
      <Link
        href={`/dashboard/monitoring/${employee.id}`}
        className="flex items-center justify-between px-4 py-3 hover:bg-slate-50 transition-colors"
      >
        <div className="flex items-center gap-3 min-w-0 flex-1">
          {/* Avatar placeholder */}
          <div className="flex h-10 w-10 items-center justify-center rounded-full bg-slate-100 text-slate-500 flex-shrink-0">
            <User className="h-5 w-5" />
          </div>

          {/* Employee info */}
          <div className="min-w-0 flex-1">
            <div className="flex items-center gap-2">
              <span className="font-medium text-slate-900 truncate">
                {employee.displayName}
              </span>
              <ShiftStatusBadge status={employee.shiftStatus} isOnLunch={employee.isOnLunch} />
            </div>
            <div className="flex items-center gap-3 text-sm text-slate-500">
              {employee.employeeId && (
                <span className="truncate">ID: {employee.employeeId}</span>
              )}
              {isOnShift && employee.currentShift && (
                <DurationCounter
                  startTime={employee.currentShift.clockedInAt}
                  format="hm"
                  className="text-slate-600"
                />
              )}
              {isOnShift && employee.isOnLunch && employee.lunchStartedAt && (
                <span className="flex items-center gap-1 text-orange-600">
                  <UtensilsCrossed className="h-3 w-3" />
                  <DurationCounter
                    startTime={employee.lunchStartedAt}
                    format="hm"
                    className="text-orange-600"
                  />
                </span>
              )}
            </div>
            {/* Clock-in location */}
            {isOnShift && employee.currentShift?.clockInLocation && (
              <div className="flex items-center gap-1 text-xs text-blue-600 mt-0.5">
                <MapPin className="h-3 w-3 flex-shrink-0" />
                <span className="font-mono text-[10px]">
                  Pointé à {employee.currentShift.clockInLocation.latitude.toFixed(4)}, {employee.currentShift.clockInLocation.longitude.toFixed(4)}
                </span>
              </div>
            )}
            {/* Active session info (cleaning or maintenance) */}
            {isOnShift && employee.activeSessionLocation && (
              <SessionBadge
                sessionType={employee.activeSessionType}
                location={employee.activeSessionLocation}
                startedAt={employee.activeSessionStartedAt}
              />
            )}
            {/* Device & last shift info */}
            <div className="flex items-center gap-3 text-xs text-slate-400 mt-0.5">
              {employee.lastSignInAt && (
                <span className="flex items-center gap-1">
                  <LogIn className="h-3 w-3" />
                  {formatLastConnection(employee.lastSignInAt)}
                </span>
              )}
              {employee.currentLocation?.capturedAt && (
                <LastUpdatedBadge capturedAt={employee.currentLocation.capturedAt} />
              )}
              {employee.lastShiftAt && (
                <span className="flex items-center gap-1">
                  <Clock className="h-3 w-3" />
                  {formatLastShift(employee.lastShiftAt)}
                </span>
              )}
              {employee.deviceAppVersion && (
                <span>v{employee.deviceAppVersion}</span>
              )}
              {(employee.deviceModel || employee.devicePlatform) && (
                <span className="flex items-center gap-1">
                  <Smartphone className="h-3 w-3" />
                  {formatDeviceModel(employee.deviceModel) || employee.devicePlatform}
                  {employee.deviceOsVersion && (
                    <span className="text-slate-300">· {formatOsVersion(employee.deviceOsVersion)}</span>
                  )}
                </span>
              )}
            </div>
          </div>
        </div>

        {/* Right side: chevron */}
        <div className="flex items-center flex-shrink-0">
          <ChevronRight className="h-5 w-5 text-slate-400" />
        </div>
      </Link>
    </li>
  );
}

const ACTIVITY_TYPE_ICONS: Record<ActivityType, typeof SprayCan> = {
  cleaning: SprayCan,
  maintenance: Wrench,
  admin: Briefcase,
};

interface SessionBadgeProps {
  sessionType: 'cleaning' | 'maintenance' | 'admin' | null;
  location: string;
  startedAt: Date | null;
}

function SessionBadge({ sessionType, location, startedAt }: SessionBadgeProps) {
  const activityType: ActivityType = sessionType ?? 'cleaning';
  const config = ACTIVITY_TYPE_CONFIG[activityType];
  const Icon = ACTIVITY_TYPE_ICONS[activityType];

  return (
    <div
      className="flex items-center gap-1.5 text-xs mt-0.5"
      style={{ color: config.color }}
    >
      <Icon className="h-3 w-3 flex-shrink-0" />
      <span className="truncate">{location}</span>
      {startedAt && (
        <DurationCounter
          startTime={startedAt}
          format="hm"
          className="ml-1 flex-shrink-0 opacity-60"
        />
      )}
    </div>
  );
}

interface ShiftStatusBadgeProps {
  status: 'on-shift' | 'off-shift' | 'never-installed';
  isOnLunch?: boolean;
}

function ShiftStatusBadge({ status, isOnLunch }: ShiftStatusBadgeProps) {
  if (status === 'on-shift' && isOnLunch) {
    return (
      <Badge className="bg-orange-100 text-orange-700 border-orange-200">
        <UtensilsCrossed className="mr-1 h-3 w-3" />
        Pause dîner
      </Badge>
    );
  }

  if (status === 'on-shift') {
    return (
      <Badge className="bg-green-100 text-green-700 border-green-200">
        <span className="mr-1 h-1.5 w-1.5 rounded-full bg-green-500 animate-pulse" />
        En quart
      </Badge>
    );
  }

  if (status === 'never-installed') {
    return (
      <Badge variant="outline" className="text-orange-500 border-orange-200 bg-orange-50">
        <MonitorSmartphone className="mr-1 h-3 w-3" />
        Jamais installé
      </Badge>
    );
  }

  return (
    <Badge variant="outline" className="text-slate-500">
      Hors quart
    </Badge>
  );
}


function formatOsVersion(osVersion: string): string {
  // "Android 14 (SDK 34)" → "Android 14"
  return osVersion.replace(/\s*\(SDK \d+\)/, '');
}

function formatLastConnection(date: Date): string {
  const now = new Date();
  const diffMs = now.getTime() - date.getTime();
  const diffMinutes = Math.floor(diffMs / (1000 * 60));
  const diffHours = Math.floor(diffMs / (1000 * 60 * 60));
  const diffDays = Math.floor(diffMs / (1000 * 60 * 60 * 24));

  if (diffMinutes < 5) return 'À l\'instant';
  if (diffMinutes < 60) return `il y a ${diffMinutes}min`;
  if (diffHours < 24) return `il y a ${diffHours}h`;
  if (diffDays === 1) return 'Hier';
  if (diffDays < 7) return `il y a ${diffDays}j`;

  return date.toLocaleDateString('fr-CA', { month: 'short', day: 'numeric' });
}

function formatLastShift(date: Date): string {
  const now = new Date();
  const diffMs = now.getTime() - date.getTime();
  const diffDays = Math.floor(diffMs / (1000 * 60 * 60 * 24));

  if (diffDays === 0) return 'Aujourd\'hui';
  if (diffDays === 1) return 'Hier';
  if (diffDays < 7) return `il y a ${diffDays}j`;

  return date.toLocaleDateString('fr-CA', { month: 'short', day: 'numeric' });
}

function TeamListSkeleton() {
  return (
    <Card>
      <CardHeader className="pb-3">
        <Skeleton className="h-5 w-32" />
      </CardHeader>
      <CardContent className="p-0">
        <ul className="divide-y divide-slate-100">
          {Array.from({ length: 5 }).map((_, i) => (
            <li key={i} className="flex items-center justify-between px-4 py-3">
              <div className="flex items-center gap-3">
                <Skeleton className="h-10 w-10 rounded-full" />
                <div className="space-y-2">
                  <Skeleton className="h-4 w-32" />
                  <Skeleton className="h-3 w-20" />
                </div>
              </div>
              <Skeleton className="h-4 w-16" />
            </li>
          ))}
        </ul>
      </CardContent>
    </Card>
  );
}

/**
 * Compact version of team list for sidebar or small spaces
 */
interface CompactTeamListProps {
  team: MonitoredEmployee[];
  maxItems?: number;
}

export function CompactTeamList({ team, maxItems = 5 }: CompactTeamListProps) {
  const activeTeam = team.filter((e) => e.shiftStatus === 'on-shift');
  const displayTeam = activeTeam.slice(0, maxItems);
  const remaining = activeTeam.length - maxItems;

  if (activeTeam.length === 0) {
    return (
      <p className="text-sm text-slate-500 py-2">
        Aucun employé actuellement en quart
      </p>
    );
  }

  return (
    <div className="space-y-2">
      {displayTeam.map((employee) => (
        <Link
          key={employee.id}
          href={`/dashboard/monitoring/${employee.id}`}
          className="flex items-center gap-2 text-sm hover:bg-slate-50 rounded px-2 py-1 -mx-2"
        >
          <span className="h-1.5 w-1.5 rounded-full bg-green-500" />
          <span className="truncate">{employee.displayName}</span>
          {employee.currentShift && (
            <DurationCounter
              startTime={employee.currentShift.clockedInAt}
              format="hm"
              className="text-slate-500 ml-auto"
            />
          )}
        </Link>
      ))}
      {remaining > 0 && (
        <Link
          href="/dashboard/monitoring"
          className="text-sm text-blue-600 hover:underline"
        >
          +{remaining} autres en quart
        </Link>
      )}
    </div>
  );
}
