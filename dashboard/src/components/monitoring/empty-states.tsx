'use client';

import { Users, MapPin, Clock, Wifi } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';

interface EmptyStateBaseProps {
  icon: React.ElementType;
  title: string;
  description: string;
  action?: {
    label: string;
    onClick: () => void;
  };
}

function EmptyStateBase({ icon: Icon, title, description, action }: EmptyStateBaseProps) {
  return (
    <div className="flex flex-col items-center justify-center py-12 text-center">
      <div className="rounded-full bg-slate-100 p-4">
        <Icon className="h-8 w-8 text-slate-400" />
      </div>
      <h3 className="mt-4 text-lg font-semibold text-slate-900">{title}</h3>
      <p className="mt-2 max-w-md text-sm text-slate-500">{description}</p>
      {action && (
        <Button variant="outline" onClick={action.onClick} className="mt-4">
          {action.label}
        </Button>
      )}
    </div>
  );
}

/**
 * Empty state when user has no supervised employees
 */
export function NoTeamEmptyState() {
  return (
    <EmptyStateBase
      icon={Users}
      title="No team members assigned"
      description="You don't have any employees assigned to supervise. Contact an administrator to set up your team."
    />
  );
}

/**
 * Empty state when all team members are off-shift
 */
export function NoActiveShiftsEmptyState() {
  return (
    <EmptyStateBase
      icon={Clock}
      title="All team members are off-shift"
      description="None of your supervised employees are currently clocked in. Active shifts will appear here when employees start their work."
    />
  );
}

/**
 * Empty state for search/filter with no results
 */
interface NoResultsEmptyStateProps {
  search: string;
  shiftStatus: string;
  onClearFilters: () => void;
}

export function NoResultsEmptyState({
  search,
  shiftStatus,
  onClearFilters,
}: NoResultsEmptyStateProps) {
  const hasFilters = search !== '' || shiftStatus !== 'all';

  if (!hasFilters) {
    return <NoTeamEmptyState />;
  }

  const filterParts: string[] = [];
  if (search) filterParts.push(`"${search}"`);
  if (shiftStatus !== 'all') {
    const statusLabels: Record<string, string> = {
      'on-shift': 'on-shift only',
      'off-shift': 'off-shift only',
      'never-installed': 'never installed only',
    };
    filterParts.push(statusLabels[shiftStatus] ?? shiftStatus);
  }

  return (
    <EmptyStateBase
      icon={Users}
      title="No employees found"
      description={`No employees match your filters: ${filterParts.join(', ')}`}
      action={{
        label: 'Clear filters',
        onClick: onClearFilters,
      }}
    />
  );
}

/**
 * Empty state when GPS data is not yet available for an active shift
 */
export function LocationPendingState() {
  return (
    <Card className="border-dashed">
      <CardContent className="flex items-center gap-3 py-4">
        <div className="rounded-full bg-slate-100 p-2">
          <MapPin className="h-4 w-4 text-slate-400" />
        </div>
        <div>
          <p className="text-sm font-medium text-slate-700">Location pending</p>
          <p className="text-xs text-slate-500">Waiting for first GPS update</p>
        </div>
      </CardContent>
    </Card>
  );
}

/**
 * Empty state for GPS trail with no points
 */
export function NoGpsTrailEmptyState() {
  return (
    <EmptyStateBase
      icon={MapPin}
      title="No GPS trail available"
      description="GPS tracking data has not been recorded for this shift yet. The trail will appear as the employee moves with GPS enabled."
    />
  );
}

/**
 * Empty state when offline/disconnected
 */
interface OfflineEmptyStateProps {
  lastUpdated?: Date | null;
  onRetry?: () => void;
}

export function OfflineEmptyState({ lastUpdated, onRetry }: OfflineEmptyStateProps) {
  return (
    <EmptyStateBase
      icon={Wifi}
      title="Connection lost"
      description={
        lastUpdated
          ? `Unable to connect to real-time updates. Last updated ${formatTimeAgo(lastUpdated)}.`
          : 'Unable to connect to real-time updates. Please check your internet connection.'
      }
      action={
        onRetry
          ? {
              label: 'Retry connection',
              onClick: onRetry,
            }
          : undefined
      }
    />
  );
}

/**
 * Compact inline empty state for cards/map
 */
interface InlineEmptyStateProps {
  message: string;
}

export function InlineEmptyState({ message }: InlineEmptyStateProps) {
  return (
    <div className="flex items-center justify-center py-8 text-sm text-slate-500">
      {message}
    </div>
  );
}

// Helper function
function formatTimeAgo(date: Date): string {
  const seconds = Math.floor((Date.now() - date.getTime()) / 1000);

  if (seconds < 5) return 'just now';
  if (seconds < 60) return `${seconds}s ago`;

  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;

  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;

  return date.toLocaleString();
}
