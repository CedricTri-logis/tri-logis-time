'use client';

import { RefreshCw, CheckCircle, AlertCircle, XCircle } from 'lucide-react';
import { Button } from '@/components/ui/button';
import type { FreshnessState } from '@/types/dashboard';

interface DataFreshnessProps {
  lastUpdated?: Date | null;
  isRefreshing?: boolean;
  onRefresh?: () => void;
  error?: Error | null;
}

export function DataFreshness({
  lastUpdated,
  isRefreshing,
  onRefresh,
  error,
}: DataFreshnessProps) {
  const state = getFreshnessState(lastUpdated, error);

  return (
    <div className="flex items-center gap-3">
      <FreshnessIndicator state={state} lastUpdated={lastUpdated} error={error} />
      <Button
        variant="outline"
        size="sm"
        onClick={onRefresh}
        disabled={isRefreshing}
        className="gap-2"
      >
        <RefreshCw className={`h-4 w-4 ${isRefreshing ? 'animate-spin' : ''}`} />
        {isRefreshing ? 'Refreshing...' : 'Refresh'}
      </Button>
    </div>
  );
}

function getFreshnessState(
  lastUpdated?: Date | null,
  error?: Error | null
): FreshnessState {
  if (error) return 'error';
  if (!lastUpdated) return 'fresh';

  const ageMs = Date.now() - lastUpdated.getTime();
  const ageSeconds = ageMs / 1000;

  if (ageSeconds < 30) return 'fresh';
  if (ageSeconds < 300) return 'stale';
  return 'very_stale';
}

function FreshnessIndicator({
  state,
  lastUpdated,
  error,
}: {
  state: FreshnessState;
  lastUpdated?: Date | null;
  error?: Error | null;
}) {
  const config = {
    fresh: {
      icon: CheckCircle,
      color: 'text-green-500',
      bgColor: 'bg-green-500',
      label: 'Data is fresh',
    },
    stale: {
      icon: AlertCircle,
      color: 'text-yellow-500',
      bgColor: 'bg-yellow-500',
      label: 'Data may be outdated',
    },
    very_stale: {
      icon: AlertCircle,
      color: 'text-red-500',
      bgColor: 'bg-red-500',
      label: 'Data is stale',
    },
    error: {
      icon: XCircle,
      color: 'text-red-500',
      bgColor: 'bg-red-500',
      label: 'Error loading data',
    },
  };

  const { color, bgColor, label } = config[state];

  const timeAgo = lastUpdated ? formatTimeAgo(lastUpdated) : '';

  return (
    <div className="flex items-center gap-2 text-sm">
      <span className={`flex h-2.5 w-2.5 rounded-full ${bgColor}`} />
      <span className="text-slate-600">
        {error ? (
          <span className={color}>{error.message || label}</span>
        ) : (
          <>
            {label}
            {timeAgo && (
              <span className="text-slate-400 ml-1">({timeAgo})</span>
            )}
          </>
        )}
      </span>
    </div>
  );
}

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
