'use client';

import Link from 'next/link';
import { ChevronRight, Clock, LogIn, MapPin, MonitorSmartphone, Smartphone, User } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Skeleton } from '@/components/ui/skeleton';
import { DurationCounter } from './duration-counter';
import { StalenessIndicator, LastUpdatedBadge } from './staleness-indicator';
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
          Team Members ({team.length})
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
        <div className="flex items-center gap-3 min-w-0">
          {/* Avatar placeholder */}
          <div className="flex h-10 w-10 items-center justify-center rounded-full bg-slate-100 text-slate-500">
            <User className="h-5 w-5" />
          </div>

          {/* Employee info */}
          <div className="min-w-0">
            <div className="flex items-center gap-2">
              <span className="font-medium text-slate-900 truncate">
                {employee.displayName}
              </span>
              <ShiftStatusBadge status={employee.shiftStatus} />
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
            </div>
            {/* Device & last shift info */}
            <div className="flex items-center gap-3 text-xs text-slate-400 mt-0.5">
              {employee.lastSignInAt && (
                <span className="flex items-center gap-1">
                  <LogIn className="h-3 w-3" />
                  {formatLastConnection(employee.lastSignInAt)}
                </span>
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
                </span>
              )}
            </div>
          </div>
        </div>

        {/* Right side: location info + chevron */}
        <div className="flex items-center gap-3">
          {isOnShift && (
            <LocationInfo
              location={employee.currentLocation}
            />
          )}
          <ChevronRight className="h-5 w-5 text-slate-400" />
        </div>
      </Link>
    </li>
  );
}

interface ShiftStatusBadgeProps {
  status: 'on-shift' | 'off-shift' | 'never-installed';
}

function ShiftStatusBadge({ status }: ShiftStatusBadgeProps) {
  if (status === 'on-shift') {
    return (
      <Badge className="bg-green-100 text-green-700 border-green-200">
        <span className="mr-1 h-1.5 w-1.5 rounded-full bg-green-500 animate-pulse" />
        On shift
      </Badge>
    );
  }

  if (status === 'never-installed') {
    return (
      <Badge variant="outline" className="text-orange-500 border-orange-200 bg-orange-50">
        <MonitorSmartphone className="mr-1 h-3 w-3" />
        Never installed
      </Badge>
    );
  }

  return (
    <Badge variant="outline" className="text-slate-500">
      Off shift
    </Badge>
  );
}

interface LocationInfoProps {
  location: MonitoredEmployee['currentLocation'];
}

function LocationInfo({ location }: LocationInfoProps) {
  if (!location) {
    return (
      <div className="flex items-center gap-1.5 text-sm text-slate-400">
        <MapPin className="h-4 w-4" />
        <span>Pending</span>
      </div>
    );
  }

  return (
    <div className="flex items-center gap-2">
      <StalenessIndicator
        capturedAt={location.capturedAt}
        showLabel={false}
        size="sm"
      />
      <LastUpdatedBadge capturedAt={location.capturedAt} />
    </div>
  );
}

function formatLastConnection(date: Date): string {
  const now = new Date();
  const diffMs = now.getTime() - date.getTime();
  const diffMinutes = Math.floor(diffMs / (1000 * 60));
  const diffHours = Math.floor(diffMs / (1000 * 60 * 60));
  const diffDays = Math.floor(diffMs / (1000 * 60 * 60 * 24));

  if (diffMinutes < 5) return 'Just now';
  if (diffMinutes < 60) return `${diffMinutes}m ago`;
  if (diffHours < 24) return `${diffHours}h ago`;
  if (diffDays === 1) return 'Yesterday';
  if (diffDays < 7) return `${diffDays}d ago`;

  return date.toLocaleDateString('en-CA', { month: 'short', day: 'numeric' });
}

function formatLastShift(date: Date): string {
  const now = new Date();
  const diffMs = now.getTime() - date.getTime();
  const diffDays = Math.floor(diffMs / (1000 * 60 * 60 * 24));

  if (diffDays === 0) return 'Today';
  if (diffDays === 1) return 'Yesterday';
  if (diffDays < 7) return `${diffDays}d ago`;

  return date.toLocaleDateString('en-CA', { month: 'short', day: 'numeric' });
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
        No employees currently on shift
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
          +{remaining} more on shift
        </Link>
      )}
    </div>
  );
}
