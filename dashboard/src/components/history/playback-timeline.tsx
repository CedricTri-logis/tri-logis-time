'use client';

import { useMemo } from 'react';
import { format } from 'date-fns';
import { AlertTriangle } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import type { HistoricalGpsPoint } from '@/types/history';

interface PlaybackTimelineProps {
  trail: HistoricalGpsPoint[];
  currentIndex: number;
  progress: number;
  hasLargeGap: boolean;
  onSeek: (index: number) => void;
}

// Gap threshold for visual indicator (5 minutes)
const LARGE_GAP_THRESHOLD_MS = 5 * 60 * 1000;

/**
 * Timeline scrubber for playback navigation.
 * Shows progress bar with clickable seek functionality.
 * Highlights large time gaps in the trail.
 */
export function PlaybackTimeline({
  trail,
  currentIndex,
  progress,
  hasLargeGap,
  onSeek,
}: PlaybackTimelineProps) {
  // Calculate gap positions for visual indicators
  const gapPositions = useMemo(() => {
    if (trail.length < 2) return [];
    const gaps: { position: number; durationMs: number }[] = [];
    const totalDuration =
      trail[trail.length - 1].capturedAt.getTime() - trail[0].capturedAt.getTime();

    if (totalDuration === 0) return [];

    let cumulativeTime = 0;
    for (let i = 1; i < trail.length; i++) {
      const interval = trail[i].capturedAt.getTime() - trail[i - 1].capturedAt.getTime();
      if (interval > LARGE_GAP_THRESHOLD_MS) {
        gaps.push({
          position: cumulativeTime / totalDuration,
          durationMs: interval,
        });
      }
      cumulativeTime += interval;
    }

    return gaps;
  }, [trail]);

  // Handle click on timeline
  const handleTimelineClick = (e: React.MouseEvent<HTMLDivElement>) => {
    const rect = e.currentTarget.getBoundingClientRect();
    const clickX = e.clientX - rect.left;
    const clickProgress = clickX / rect.width;

    // Find the closest index to this progress
    if (trail.length < 2) return;

    const totalDuration =
      trail[trail.length - 1].capturedAt.getTime() - trail[0].capturedAt.getTime();
    const targetTime = trail[0].capturedAt.getTime() + totalDuration * clickProgress;

    // Binary search for closest point
    let closestIndex = 0;
    let minDiff = Infinity;

    for (let i = 0; i < trail.length; i++) {
      const diff = Math.abs(trail[i].capturedAt.getTime() - targetTime);
      if (diff < minDiff) {
        minDiff = diff;
        closestIndex = i;
      }
    }

    onSeek(closestIndex);
  };

  // Format time display
  const currentTime = trail[currentIndex]?.capturedAt;
  const startTime = trail[0]?.capturedAt;
  const endTime = trail[trail.length - 1]?.capturedAt;

  if (trail.length === 0) {
    return null;
  }

  return (
    <Card>
      <CardHeader className="pb-2">
        <CardTitle className="text-base font-medium flex items-center justify-between">
          <span>Timeline</span>
          <span className="text-sm font-normal text-slate-500">
            {currentIndex + 1} / {trail.length}
          </span>
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        {/* Progress bar */}
        <div
          className="relative h-4 bg-slate-100 rounded-full cursor-pointer overflow-hidden"
          onClick={handleTimelineClick}
        >
          {/* Progress fill */}
          <div
            className="absolute top-0 left-0 h-full bg-blue-500 transition-all duration-150"
            style={{ width: `${progress * 100}%` }}
          />

          {/* Gap indicators */}
          {gapPositions.map((gap, i) => (
            <div
              key={i}
              className="absolute top-0 h-full w-1 bg-amber-400"
              style={{ left: `${gap.position * 100}%` }}
              title={`Time gap: ${Math.round(gap.durationMs / 60000)} minutes`}
            />
          ))}

          {/* Current position indicator */}
          <div
            className="absolute top-0 h-full w-1 bg-slate-900 z-10"
            style={{ left: `${progress * 100}%` }}
          />
        </div>

        {/* Time labels */}
        <div className="flex items-center justify-between text-xs text-slate-500">
          <span>{startTime ? format(startTime, 'h:mm:ss a') : '—'}</span>
          <span className="font-medium text-slate-700">
            {currentTime ? format(currentTime, 'h:mm:ss a') : '—'}
          </span>
          <span>{endTime ? format(endTime, 'h:mm:ss a') : '—'}</span>
        </div>

        {/* Large gap warning */}
        {hasLargeGap && (
          <div className="flex items-center gap-2 p-2 bg-amber-50 border border-amber-200 rounded-lg text-xs text-amber-800">
            <AlertTriangle className="h-4 w-4 flex-shrink-0" />
            <span>
              Large time gap ahead - GPS tracking may have been interrupted
            </span>
          </div>
        )}
      </CardContent>
    </Card>
  );
}
