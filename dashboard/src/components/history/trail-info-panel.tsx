'use client';

import { useMemo } from 'react';
import { format, differenceInMinutes } from 'date-fns';
import { MapPin, Clock, Navigation, Timer, Route } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';
import type { HistoricalGpsPoint } from '@/types/history';
import { calculateTotalDistance, formatDistance } from '@/lib/utils/distance';

interface TrailInfoPanelProps {
  trail: HistoricalGpsPoint[];
  employeeName?: string;
  shiftDate?: Date;
  isLoading?: boolean;
}

/**
 * Information panel showing trail statistics:
 * - Total distance
 * - Duration
 * - Point count
 * - First/last timestamps
 */
export function TrailInfoPanel({
  trail,
  employeeName,
  shiftDate,
  isLoading,
}: TrailInfoPanelProps) {
  // Calculate trail statistics
  const stats = useMemo(() => {
    if (trail.length === 0) {
      return {
        totalDistance: 0,
        durationMinutes: 0,
        pointCount: 0,
        firstTimestamp: null,
        lastTimestamp: null,
        avgAccuracy: null,
      };
    }

    const totalDistance = calculateTotalDistance(trail);
    const firstTimestamp = trail[0].capturedAt;
    const lastTimestamp = trail[trail.length - 1].capturedAt;
    const durationMinutes = differenceInMinutes(lastTimestamp, firstTimestamp);

    // Calculate average accuracy (excluding null values)
    const accuracies = trail
      .map((p) => p.accuracy)
      .filter((a): a is number => a !== null);
    const avgAccuracy =
      accuracies.length > 0
        ? accuracies.reduce((sum, a) => sum + a, 0) / accuracies.length
        : null;

    return {
      totalDistance,
      durationMinutes,
      pointCount: trail.length,
      firstTimestamp,
      lastTimestamp,
      avgAccuracy,
    };
  }, [trail]);

  // Format duration
  const formatDuration = (minutes: number): string => {
    const hours = Math.floor(minutes / 60);
    const mins = minutes % 60;
    if (hours === 0) return `${mins} min`;
    return `${hours}h ${mins}m`;
  };

  if (isLoading) {
    return (
      <Card>
        <CardHeader className="pb-3">
          <Skeleton className="h-5 w-32" />
        </CardHeader>
        <CardContent>
          <div className="grid gap-4 md:grid-cols-4">
            {[...Array(4)].map((_, i) => (
              <div key={i} className="space-y-2">
                <Skeleton className="h-4 w-20" />
                <Skeleton className="h-6 w-16" />
              </div>
            ))}
          </div>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card>
      <CardHeader className="pb-3">
        <CardTitle className="text-base font-medium flex items-center justify-between">
          <span>Trail Summary</span>
          {employeeName && (
            <span className="text-sm font-normal text-slate-500">{employeeName}</span>
          )}
        </CardTitle>
        {shiftDate && (
          <p className="text-sm text-slate-500">{format(shiftDate, 'MMMM d, yyyy')}</p>
        )}
      </CardHeader>
      <CardContent>
        <div className="grid gap-4 md:grid-cols-4">
          {/* Total Distance */}
          <div className="flex items-start gap-3">
            <div className="p-2 rounded-lg bg-blue-50">
              <Route className="h-5 w-5 text-blue-600" />
            </div>
            <div>
              <p className="text-sm font-medium text-slate-500">Distance</p>
              <p className="text-lg font-semibold text-slate-900">
                {formatDistance(stats.totalDistance)}
              </p>
            </div>
          </div>

          {/* Duration */}
          <div className="flex items-start gap-3">
            <div className="p-2 rounded-lg bg-green-50">
              <Timer className="h-5 w-5 text-green-600" />
            </div>
            <div>
              <p className="text-sm font-medium text-slate-500">Duration</p>
              <p className="text-lg font-semibold text-slate-900">
                {formatDuration(stats.durationMinutes)}
              </p>
            </div>
          </div>

          {/* Point Count */}
          <div className="flex items-start gap-3">
            <div className="p-2 rounded-lg bg-purple-50">
              <MapPin className="h-5 w-5 text-purple-600" />
            </div>
            <div>
              <p className="text-sm font-medium text-slate-500">GPS Points</p>
              <p className="text-lg font-semibold text-slate-900">
                {stats.pointCount.toLocaleString()}
              </p>
            </div>
          </div>

          {/* Time Range */}
          <div className="flex items-start gap-3">
            <div className="p-2 rounded-lg bg-amber-50">
              <Clock className="h-5 w-5 text-amber-600" />
            </div>
            <div>
              <p className="text-sm font-medium text-slate-500">Time Range</p>
              {stats.firstTimestamp && stats.lastTimestamp ? (
                <p className="text-sm font-semibold text-slate-900">
                  {format(stats.firstTimestamp, 'h:mm a')} -{' '}
                  {format(stats.lastTimestamp, 'h:mm a')}
                </p>
              ) : (
                <p className="text-lg font-semibold text-slate-400">—</p>
              )}
            </div>
          </div>
        </div>

        {/* Average Accuracy (if available) */}
        {stats.avgAccuracy !== null && (
          <div className="mt-4 pt-4 border-t border-slate-100">
            <p className="text-xs text-slate-500">
              Average GPS accuracy: ±{Math.round(stats.avgAccuracy)}m
            </p>
          </div>
        )}
      </CardContent>
    </Card>
  );
}
