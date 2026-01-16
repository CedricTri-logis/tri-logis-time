'use client';

import { cn } from '@/lib/utils';
import type { StalenessLevel } from '@/types/monitoring';
import { getStalenessLevel, STALENESS_THRESHOLDS } from '@/types/monitoring';

interface StalenessIndicatorProps {
  capturedAt: Date | null;
  className?: string;
  showLabel?: boolean;
  size?: 'sm' | 'md';
}

const stalenessConfig: Record<
  StalenessLevel,
  { dotColor: string; bgColor: string; textColor: string; label: string }
> = {
  fresh: {
    dotColor: 'bg-green-500',
    bgColor: 'bg-green-50',
    textColor: 'text-green-700',
    label: 'Live',
  },
  stale: {
    dotColor: 'bg-yellow-500',
    bgColor: 'bg-yellow-50',
    textColor: 'text-yellow-700',
    label: 'Stale',
  },
  'very-stale': {
    dotColor: 'bg-red-500',
    bgColor: 'bg-red-50',
    textColor: 'text-red-700',
    label: 'Very stale',
  },
  unknown: {
    dotColor: 'bg-slate-400',
    bgColor: 'bg-slate-50',
    textColor: 'text-slate-600',
    label: 'Unknown',
  },
};

/**
 * Visual indicator for GPS data freshness.
 * Shows different colors based on how recently the location was updated.
 */
export function StalenessIndicator({
  capturedAt,
  className,
  showLabel = true,
  size = 'md',
}: StalenessIndicatorProps) {
  const level = getStalenessLevel(capturedAt);
  const config = stalenessConfig[level];

  const dotSizeClass = size === 'sm' ? 'h-1.5 w-1.5' : 'h-2 w-2';
  const textSizeClass = size === 'sm' ? 'text-xs' : 'text-sm';

  if (!showLabel) {
    // Just the dot indicator
    return (
      <span
        className={cn(
          'inline-flex rounded-full',
          dotSizeClass,
          config.dotColor,
          className
        )}
        title={`${config.label}${capturedAt ? ` - ${formatAgeDescription(capturedAt)}` : ''}`}
      />
    );
  }

  return (
    <span
      className={cn(
        'inline-flex items-center gap-1.5 rounded-full px-2 py-0.5',
        config.bgColor,
        config.textColor,
        textSizeClass,
        className
      )}
    >
      <span className={cn('rounded-full', dotSizeClass, config.dotColor)} />
      {config.label}
    </span>
  );
}

/**
 * Compact badge showing just the time since last update
 */
interface LastUpdatedBadgeProps {
  capturedAt: Date | null;
  className?: string;
}

export function LastUpdatedBadge({ capturedAt, className }: LastUpdatedBadgeProps) {
  const level = getStalenessLevel(capturedAt);
  const config = stalenessConfig[level];

  if (!capturedAt) {
    return (
      <span className={cn('text-xs text-slate-400', className)}>No data</span>
    );
  }

  return (
    <span className={cn('flex items-center gap-1 text-xs', config.textColor, className)}>
      <span className={cn('h-1.5 w-1.5 rounded-full', config.dotColor)} />
      {formatAgeDescription(capturedAt)}
    </span>
  );
}

/**
 * Staleness legend for map or dashboard
 */
export function StalenessLegend() {
  return (
    <div className="flex flex-wrap items-center gap-4 text-xs text-slate-600">
      <span className="flex items-center gap-1.5">
        <span className="h-2 w-2 rounded-full bg-green-500" />
        Live (&lt;{STALENESS_THRESHOLDS.FRESH_MAX_MINUTES}min)
      </span>
      <span className="flex items-center gap-1.5">
        <span className="h-2 w-2 rounded-full bg-yellow-500" />
        Stale ({STALENESS_THRESHOLDS.FRESH_MAX_MINUTES}-{STALENESS_THRESHOLDS.STALE_MAX_MINUTES}min)
      </span>
      <span className="flex items-center gap-1.5">
        <span className="h-2 w-2 rounded-full bg-red-500" />
        Very stale (&gt;{STALENESS_THRESHOLDS.STALE_MAX_MINUTES}min)
      </span>
    </div>
  );
}

// Helper to format age description
function formatAgeDescription(date: Date): string {
  const seconds = Math.floor((Date.now() - date.getTime()) / 1000);

  if (seconds < 5) return 'just now';
  if (seconds < 60) return `${seconds}s ago`;

  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;

  const hours = Math.floor(minutes / 60);
  return `${hours}h ago`;
}
