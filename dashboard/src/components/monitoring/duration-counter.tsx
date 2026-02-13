'use client';

import { useState, useEffect } from 'react';
import { differenceInSeconds } from 'date-fns';
import { formatDurationHMS, formatDurationHM } from '@/types/monitoring';
import { cn } from '@/lib/utils';

interface DurationCounterProps {
  /** The start time of the shift */
  startTime: Date | null;
  /** Display format: 'hms' for HH:MM:SS, 'hm' for Xh Ym */
  format?: 'hms' | 'hm';
  /** Additional CSS classes */
  className?: string;
  /** Show pulsing animation to indicate live updates */
  showPulse?: boolean;
}

/**
 * Live duration counter that updates every second.
 * Displays the time elapsed since a given start time.
 */
export function DurationCounter({
  startTime,
  format = 'hms',
  className,
  showPulse = false,
}: DurationCounterProps) {
  // Get stable timestamp value (number) to avoid re-running effect on Date reference changes
  const startTimestamp = startTime ? startTime.getTime() : null;

  const [duration, setDuration] = useState(0);

  useEffect(() => {
    if (startTimestamp === null) {
      setDuration(0);
      return;
    }

    const startDate = new Date(startTimestamp);

    // Initial calculation
    setDuration(differenceInSeconds(new Date(), startDate));

    // Update every second
    const interval = setInterval(() => {
      setDuration(differenceInSeconds(new Date(), startDate));
    }, 1000);

    return () => clearInterval(interval);
  }, [startTimestamp]);

  if (!startTime) {
    return <span className={cn('text-slate-400', className)}>--:--:--</span>;
  }

  const formattedDuration = format === 'hms' ? formatDurationHMS(duration) : formatDurationHM(duration);

  return (
    <span className={cn('tabular-nums', className)}>
      {showPulse && (
        <span className="mr-1.5 inline-flex h-2 w-2 animate-pulse rounded-full bg-green-500" />
      )}
      {formattedDuration}
    </span>
  );
}

/**
 * Compact duration display without live updates (static).
 * Use for historical/completed shifts.
 */
interface StaticDurationProps {
  seconds: number;
  format?: 'hms' | 'hm';
  className?: string;
}

export function StaticDuration({ seconds, format = 'hm', className }: StaticDurationProps) {
  const formattedDuration = format === 'hms' ? formatDurationHMS(seconds) : formatDurationHM(seconds);

  return <span className={cn('tabular-nums', className)}>{formattedDuration}</span>;
}

/**
 * Duration display with label
 */
interface LabeledDurationProps {
  label: string;
  startTime: Date | null;
  format?: 'hms' | 'hm';
  className?: string;
}

export function LabeledDuration({
  label,
  startTime,
  format = 'hms',
  className,
}: LabeledDurationProps) {
  return (
    <div className={cn('flex flex-col', className)}>
      <span className="text-xs text-slate-500">{label}</span>
      <DurationCounter
        startTime={startTime}
        format={format}
        className="text-lg font-semibold"
        showPulse
      />
    </div>
  );
}
