'use client';

import { useMemo, useState } from 'react';
import { format } from 'date-fns';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';
import { TimelineSegmentBar, SegmentLegend, SegmentDetail } from './timeline-segment';
import { calculateSegmentWidths } from '@/lib/hooks/use-timeline-segments';
import { formatDuration } from '@/lib/utils/segment-colors';
import type { TimelineSegment } from '@/types/location';

interface TimelineBarProps {
  segments: TimelineSegment[];
  totalDuration: number;
  isLoading?: boolean;
  showLegend?: boolean;
  showTimeMarkers?: boolean;
  onSegmentClick?: (segment: TimelineSegment) => void;
  selectedSegment?: TimelineSegment | null;
  className?: string;
}

/**
 * Horizontal timeline bar showing shift segments proportionally.
 * Each segment is colored by location type or segment type.
 */
export function TimelineBar({
  segments,
  totalDuration,
  isLoading = false,
  showLegend = true,
  showTimeMarkers = true,
  onSegmentClick,
  selectedSegment,
  className = '',
}: TimelineBarProps) {
  const segmentWidths = useMemo(
    () => calculateSegmentWidths(segments, totalDuration),
    [segments, totalDuration]
  );

  // Time range for markers
  const timeRange = useMemo(() => {
    if (segments.length === 0) return null;
    return {
      start: segments[0].startTime,
      end: segments[segments.length - 1].endTime,
    };
  }, [segments]);

  if (isLoading) {
    return <TimelineBarSkeleton />;
  }

  if (segments.length === 0) {
    return (
      <Card className={className}>
        <CardContent className="flex items-center justify-center py-8">
          <p className="text-sm text-slate-500">Aucune donnée de chronologie disponible</p>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card className={className}>
      <CardHeader className="pb-2">
        <div className="flex items-center justify-between">
          <CardTitle className="text-base font-medium">Chronologie du quart</CardTitle>
          <span className="text-sm text-slate-500">
            Total : {formatDuration(totalDuration)}
          </span>
        </div>
      </CardHeader>
      <CardContent className="space-y-4">
        {/* Timeline bar */}
        <div className="relative">
          {/* Time markers */}
          {showTimeMarkers && timeRange && (
            <div className="flex justify-between text-xs text-slate-400 mb-1">
              <span>{format(timeRange.start, 'HH:mm')}</span>
              <span>{format(timeRange.end, 'HH:mm')}</span>
            </div>
          )}

          {/* Segment bar container */}
          <div className="h-8 bg-slate-100 rounded-lg overflow-hidden flex">
            {segmentWidths.map(({ segment, widthPercent }) => (
              <TimelineSegmentBar
                key={segment.segmentIndex}
                segment={segment}
                widthPercent={widthPercent}
                totalDuration={totalDuration}
                isSelected={selectedSegment?.segmentIndex === segment.segmentIndex}
                onClick={onSegmentClick}
              />
            ))}
          </div>

          {/* Hour markers (optional) */}
          {showTimeMarkers && totalDuration > 3600 && (
            <TimeMarkers
              startTime={timeRange!.start}
              totalDuration={totalDuration}
            />
          )}
        </div>

        {/* Legend */}
        {showLegend && <SegmentLegend showLocationTypes={true} />}

        {/* Selected segment detail */}
        {selectedSegment && (
          <SegmentDetail
            segment={selectedSegment}
            onClose={() => onSegmentClick?.(selectedSegment)}
          />
        )}
      </CardContent>
    </Card>
  );
}

/**
 * Hour markers below the timeline bar for long shifts
 */
interface TimeMarkersProps {
  startTime: Date;
  totalDuration: number;
}

function TimeMarkers({ startTime, totalDuration }: TimeMarkersProps) {
  const markers = useMemo(() => {
    const result: Array<{ time: Date; percent: number }> = [];
    const startHour = new Date(startTime);
    startHour.setMinutes(0, 0, 0);
    startHour.setHours(startHour.getHours() + 1);

    const endTime = new Date(startTime.getTime() + totalDuration * 1000);
    let current = startHour;

    while (current < endTime) {
      const elapsedSeconds = (current.getTime() - startTime.getTime()) / 1000;
      const percent = (elapsedSeconds / totalDuration) * 100;
      if (percent > 0 && percent < 100) {
        result.push({ time: new Date(current), percent });
      }
      current = new Date(current.getTime() + 60 * 60 * 1000);
    }

    return result;
  }, [startTime, totalDuration]);

  return (
    <div className="relative h-4 mt-1">
      {markers.map(({ time, percent }) => (
        <div
          key={time.getTime()}
          className="absolute transform -translate-x-1/2"
          style={{ left: `${percent}%` }}
        >
          <div className="w-px h-2 bg-slate-300" />
          <span className="text-xs text-slate-400 block mt-0.5">
            {format(time, 'HH:mm')}
          </span>
        </div>
      ))}
    </div>
  );
}

/**
 * Compact timeline bar for use in lists/tables
 */
interface CompactTimelineBarProps {
  segments: TimelineSegment[];
  totalDuration: number;
  className?: string;
}

export function CompactTimelineBar({
  segments,
  totalDuration,
  className = '',
}: CompactTimelineBarProps) {
  const segmentWidths = useMemo(
    () => calculateSegmentWidths(segments, totalDuration),
    [segments, totalDuration]
  );

  if (segments.length === 0) {
    return (
      <div className={`h-2 bg-slate-100 rounded-full ${className}`} />
    );
  }

  return (
    <div className={`h-2 bg-slate-100 rounded-full overflow-hidden flex ${className}`}>
      {segmentWidths.map(({ segment, widthPercent }) => (
        <div
          key={segment.segmentIndex}
          className="h-full"
          style={{
            width: `${widthPercent}%`,
            backgroundColor:
              segment.segmentType === 'matched' && segment.locationType
                ? undefined
                : segment.segmentType === 'travel'
                ? '#eab308'
                : '#ef4444',
            background:
              segment.segmentType === 'matched' && segment.locationType
                ? getLocationColor(segment.locationType)
                : undefined,
          }}
        />
      ))}
    </div>
  );
}

function getLocationColor(locationType: string): string {
  const colors: Record<string, string> = {
    office: '#3b82f6',
    building: '#f59e0b',
    vendor: '#8b5cf6',
    home: '#22c55e',
    other: '#6b7280',
  };
  return colors[locationType] ?? '#6b7280';
}

function TimelineBarSkeleton() {
  return (
    <Card>
      <CardHeader className="pb-2">
        <div className="flex items-center justify-between">
          <Skeleton className="h-5 w-32" />
          <Skeleton className="h-4 w-20" />
        </div>
      </CardHeader>
      <CardContent className="space-y-4">
        <Skeleton className="h-8 w-full rounded-lg" />
        <div className="flex gap-4">
          <Skeleton className="h-4 w-24" />
          <Skeleton className="h-4 w-24" />
          <Skeleton className="h-4 w-24" />
        </div>
      </CardContent>
    </Card>
  );
}
