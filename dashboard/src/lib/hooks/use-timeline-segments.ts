'use client';

import { useCustom } from '@refinedev/core';
import { useMemo } from 'react';
import type {
  TimelineSegment,
  TimelineSegmentRow,
  TimelineSummary,
  computeTimelineSummary,
} from '@/types/location';

/**
 * Hook to fetch timeline segments for a shift.
 * Uses the get_shift_timeline RPC which returns pre-computed segments.
 */
export function useTimelineSegments(shiftId: string | null) {
  const { query, result } = useCustom<TimelineSegmentRow[]>({
    url: '',
    method: 'get',
    meta: {
      rpc: 'get_shift_timeline',
    },
    config: {
      payload: {
        p_shift_id: shiftId,
      },
    },
    queryOptions: {
      enabled: !!shiftId,
      staleTime: 5 * 60 * 1000, // Cache for 5 minutes
    },
  });

  const rawData = result?.data as TimelineSegmentRow[] | undefined;

  // Transform RPC rows to frontend types
  const segments: TimelineSegment[] = useMemo(() => {
    if (!rawData || !Array.isArray(rawData)) return [];
    return rawData.map((row) => ({
      segmentIndex: row.segment_index,
      segmentType: row.segment_type,
      startTime: new Date(row.start_time),
      endTime: new Date(row.end_time),
      durationSeconds: row.duration_seconds,
      pointCount: row.point_count,
      locationId: row.location_id,
      locationName: row.location_name,
      locationType: row.location_type,
      avgConfidence: row.avg_confidence,
    }));
  }, [rawData]);

  // Compute timeline summary from segments
  const summary: TimelineSummary | null = useMemo(() => {
    if (!shiftId || segments.length === 0) return null;

    const totalDurationSeconds = segments.reduce(
      (sum, seg) => sum + seg.durationSeconds,
      0
    );
    const totalGpsPoints = segments.reduce(
      (sum, seg) => sum + seg.pointCount,
      0
    );

    // Calculate durations by segment type
    let matchedDuration = 0;
    let travelDuration = 0;
    let unmatchedDuration = 0;

    // Track duration by location type and individual locations
    const locationTypeMap = new Map<
      string,
      {
        duration: number;
        locations: Map<string, { name: string; duration: number }>;
      }
    >();

    for (const segment of segments) {
      switch (segment.segmentType) {
        case 'matched':
          matchedDuration += segment.durationSeconds;
          if (segment.locationType && segment.locationId && segment.locationName) {
            let typeData = locationTypeMap.get(segment.locationType);
            if (!typeData) {
              typeData = { duration: 0, locations: new Map() };
              locationTypeMap.set(segment.locationType, typeData);
            }
            typeData.duration += segment.durationSeconds;

            const existing = typeData.locations.get(segment.locationId);
            if (existing) {
              existing.duration += segment.durationSeconds;
            } else {
              typeData.locations.set(segment.locationId, {
                name: segment.locationName,
                duration: segment.durationSeconds,
              });
            }
          }
          break;
        case 'travel':
          travelDuration += segment.durationSeconds;
          break;
        case 'unmatched':
          unmatchedDuration += segment.durationSeconds;
          break;
      }
    }

    const safeDivide = (num: number, denom: number) =>
      denom > 0 ? (num / denom) * 100 : 0;

    // Build location type summaries
    const byLocationType = Array.from(locationTypeMap.entries())
      .map(([locationType, data]) => ({
        locationType: locationType as TimelineSegment['locationType'],
        durationSeconds: data.duration,
        percentage: safeDivide(data.duration, totalDurationSeconds),
        locations: Array.from(data.locations.entries())
          .map(([locationId, locData]) => ({
            locationId,
            locationName: locData.name,
            durationSeconds: locData.duration,
          }))
          .sort((a, b) => b.durationSeconds - a.durationSeconds),
      }))
      .sort((a, b) => b.durationSeconds - a.durationSeconds);

    return {
      shiftId,
      totalDurationSeconds,
      totalGpsPoints,
      matchedDurationSeconds: matchedDuration,
      matchedPercentage: safeDivide(matchedDuration, totalDurationSeconds),
      travelDurationSeconds: travelDuration,
      travelPercentage: safeDivide(travelDuration, totalDurationSeconds),
      unmatchedDurationSeconds: unmatchedDuration,
      unmatchedPercentage: safeDivide(unmatchedDuration, totalDurationSeconds),
      byLocationType: byLocationType as TimelineSummary['byLocationType'],
    };
  }, [shiftId, segments]);

  // Total shift duration based on first and last segment
  const shiftDuration = useMemo(() => {
    if (segments.length === 0) return 0;
    const first = segments[0];
    const last = segments[segments.length - 1];
    return Math.floor(
      (last.endTime.getTime() - first.startTime.getTime()) / 1000
    );
  }, [segments]);

  return {
    segments,
    summary,
    shiftDuration,
    isLoading: query.isLoading,
    isFetching: query.isFetching,
    error: query.isError
      ? ((query.error as unknown as Error)?.message ?? 'Unknown error')
      : null,
    refetch: query.refetch,
  };
}

/**
 * Calculate segment width percentages for timeline bar visualization
 */
export function calculateSegmentWidths(
  segments: TimelineSegment[],
  totalDuration: number
): Array<{
  segment: TimelineSegment;
  widthPercent: number;
  startPercent: number;
}> {
  if (segments.length === 0 || totalDuration <= 0) return [];

  const result: Array<{
    segment: TimelineSegment;
    widthPercent: number;
    startPercent: number;
  }> = [];

  let currentStartPercent = 0;

  for (const segment of segments) {
    const widthPercent = Math.max(0.5, (segment.durationSeconds / totalDuration) * 100);
    result.push({
      segment,
      widthPercent,
      startPercent: currentStartPercent,
    });
    currentStartPercent += widthPercent;
  }

  return result;
}
