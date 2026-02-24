'use client';

import { useMemo } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';
import type { TimelineSummary } from '@/types/location';
import {
  formatDuration,
  formatPercentage,
  LOCATION_TYPE_COLORS,
  SEGMENT_TYPE_COLORS,
} from '@/lib/utils/segment-colors';
import { Clock, MapPin, Truck, HelpCircle } from 'lucide-react';

// Need to add Progress component - let me create a simple one inline
interface ProgressBarProps {
  value: number;
  color: string;
  className?: string;
}

function ProgressBar({ value, color, className = '' }: ProgressBarProps) {
  return (
    <div className={`h-2 bg-slate-100 rounded-full overflow-hidden ${className}`}>
      <div
        className="h-full rounded-full transition-all"
        style={{ width: `${Math.min(100, Math.max(0, value))}%`, backgroundColor: color }}
      />
    </div>
  );
}

interface TimelineSummaryCardProps {
  summary: TimelineSummary | null;
  isLoading?: boolean;
  className?: string;
}

/**
 * Summary panel showing time breakdown by segment type and location.
 */
export function TimelineSummaryCard({
  summary,
  isLoading = false,
  className = '',
}: TimelineSummaryCardProps) {
  if (isLoading) {
    return <TimelineSummarySkeleton className={className} />;
  }

  if (!summary) {
    return (
      <Card className={className}>
        <CardContent className="flex items-center justify-center py-8">
          <p className="text-sm text-slate-500">No timeline data available</p>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card className={className}>
      <CardHeader className="pb-2">
        <CardTitle className="text-base font-medium flex items-center gap-2">
          <Clock className="h-4 w-4 text-slate-500" />
          Timeline Summary
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-6">
        {/* Overview stats */}
        <div className="grid grid-cols-3 gap-4">
          <StatCard
            label="Total Duration"
            value={formatDuration(summary.totalDurationSeconds)}
            icon={Clock}
          />
          <StatCard
            label="GPS Points"
            value={summary.totalGpsPoints.toString()}
            icon={MapPin}
          />
          <StatCard
            label="Coverage"
            value={formatPercentage(summary.matchedPercentage)}
            subtext="at known locations"
            icon={MapPin}
          />
        </div>

        {/* Segment type breakdown */}
        <div className="space-y-3">
          <h4 className="text-sm font-medium text-slate-700">Time Breakdown</h4>

          {/* Matched time */}
          <SegmentTypeStat
            label="At Locations"
            duration={summary.matchedDurationSeconds}
            percentage={summary.matchedPercentage}
            color={SEGMENT_TYPE_COLORS.matched.color}
            icon={<MapPin className="h-4 w-4" />}
          />

          {/* Travel time */}
          <SegmentTypeStat
            label="Travel"
            duration={summary.travelDurationSeconds}
            percentage={summary.travelPercentage}
            color={SEGMENT_TYPE_COLORS.travel.color}
            icon={<Truck className="h-4 w-4" />}
          />

          {/* Unmatched time */}
          <SegmentTypeStat
            label="Unknown"
            duration={summary.unmatchedDurationSeconds}
            percentage={summary.unmatchedPercentage}
            color={SEGMENT_TYPE_COLORS.unmatched.color}
            icon={<HelpCircle className="h-4 w-4" />}
          />
        </div>

        {/* Location type breakdown (if any matched segments) */}
        {summary.byLocationType.length > 0 && (
          <div className="space-y-3">
            <h4 className="text-sm font-medium text-slate-700">
              Time by Location Type
            </h4>
            {summary.byLocationType.map((typeData) => (
              <LocationTypeStat
                key={typeData.locationType}
                locationType={typeData.locationType!}
                duration={typeData.durationSeconds}
                percentage={typeData.percentage}
                locations={typeData.locations}
              />
            ))}
          </div>
        )}
      </CardContent>
    </Card>
  );
}

interface StatCardProps {
  label: string;
  value: string;
  subtext?: string;
  icon?: React.ElementType;
}

function StatCard({ label, value, subtext, icon: Icon }: StatCardProps) {
  return (
    <div className="text-center p-3 bg-slate-50 rounded-lg">
      {Icon && <Icon className="h-4 w-4 text-slate-400 mx-auto mb-1" />}
      <div className="text-lg font-semibold text-slate-900">{value}</div>
      <div className="text-xs text-slate-500">{label}</div>
      {subtext && <div className="text-xs text-slate-400">{subtext}</div>}
    </div>
  );
}

interface SegmentTypeStatProps {
  label: string;
  duration: number;
  percentage: number;
  color: string;
  icon: React.ReactNode;
}

function SegmentTypeStat({
  label,
  duration,
  percentage,
  color,
  icon,
}: SegmentTypeStatProps) {
  return (
    <div className="space-y-1.5">
      <div className="flex items-center justify-between text-sm">
        <div className="flex items-center gap-2" style={{ color }}>
          {icon}
          <span className="text-slate-700">{label}</span>
        </div>
        <div className="flex items-center gap-2 text-slate-600">
          <span>{formatDuration(duration)}</span>
          <span className="text-slate-400">({formatPercentage(percentage)})</span>
        </div>
      </div>
      <ProgressBar value={percentage} color={color} />
    </div>
  );
}

interface LocationTypeStatProps {
  locationType: string;
  duration: number;
  percentage: number;
  locations: Array<{
    locationId: string;
    locationName: string;
    durationSeconds: number;
  }>;
}

function LocationTypeStat({
  locationType,
  duration,
  percentage,
  locations,
}: LocationTypeStatProps) {
  const config = LOCATION_TYPE_COLORS[locationType as keyof typeof LOCATION_TYPE_COLORS];
  if (!config) return null;

  return (
    <div className="space-y-2">
      <div className="flex items-center justify-between text-sm">
        <div className="flex items-center gap-2">
          <div
            className="h-3 w-3 rounded-full"
            style={{ backgroundColor: config.color }}
          />
          <span className="text-slate-700">{config.label}</span>
        </div>
        <div className="flex items-center gap-2 text-slate-600">
          <span>{formatDuration(duration)}</span>
          <span className="text-slate-400">({formatPercentage(percentage)})</span>
        </div>
      </div>
      <ProgressBar value={percentage} color={config.color} />

      {/* Individual locations within this type */}
      {locations.length > 1 && (
        <div className="ml-5 space-y-1 text-xs text-slate-500">
          {locations.slice(0, 5).map((loc) => (
            <div key={loc.locationId} className="flex justify-between">
              <span className="truncate max-w-[150px]">{loc.locationName}</span>
              <span>{formatDuration(loc.durationSeconds)}</span>
            </div>
          ))}
          {locations.length > 5 && (
            <div className="text-slate-400">
              +{locations.length - 5} more locations
            </div>
          )}
        </div>
      )}
    </div>
  );
}

interface TimelineSummarySkeletonProps {
  className?: string;
}

function TimelineSummarySkeleton({ className = '' }: TimelineSummarySkeletonProps) {
  return (
    <Card className={className}>
      <CardHeader className="pb-2">
        <Skeleton className="h-5 w-32" />
      </CardHeader>
      <CardContent className="space-y-6">
        <div className="grid grid-cols-3 gap-4">
          {[...Array(3)].map((_, i) => (
            <Skeleton key={i} className="h-20 w-full rounded-lg" />
          ))}
        </div>
        <div className="space-y-3">
          <Skeleton className="h-4 w-24" />
          {[...Array(3)].map((_, i) => (
            <div key={i} className="space-y-1.5">
              <div className="flex justify-between">
                <Skeleton className="h-4 w-20" />
                <Skeleton className="h-4 w-16" />
              </div>
              <Skeleton className="h-2 w-full" />
            </div>
          ))}
        </div>
      </CardContent>
    </Card>
  );
}

/**
 * Compact summary for inline display
 */
interface CompactTimelineSummaryProps {
  summary: TimelineSummary | null;
  className?: string;
}

export function CompactTimelineSummary({
  summary,
  className = '',
}: CompactTimelineSummaryProps) {
  if (!summary) return null;

  return (
    <div className={`flex items-center gap-4 text-sm ${className}`}>
      <div className="flex items-center gap-1.5">
        <div
          className="h-2.5 w-2.5 rounded-full"
          style={{ backgroundColor: SEGMENT_TYPE_COLORS.matched.color }}
        />
        <span className="text-slate-600">
          {formatPercentage(summary.matchedPercentage)} at locations
        </span>
      </div>
      {summary.travelPercentage > 0 && (
        <div className="flex items-center gap-1.5">
          <div
            className="h-2.5 w-2.5 rounded-full"
            style={{ backgroundColor: SEGMENT_TYPE_COLORS.travel.color }}
          />
          <span className="text-slate-600">
            {formatPercentage(summary.travelPercentage)} travel
          </span>
        </div>
      )}
      {summary.unmatchedPercentage > 0 && (
        <div className="flex items-center gap-1.5">
          <div
            className="h-2.5 w-2.5 rounded-full"
            style={{ backgroundColor: SEGMENT_TYPE_COLORS.unmatched.color }}
          />
          <span className="text-slate-600">
            {formatPercentage(summary.unmatchedPercentage)} unknown
          </span>
        </div>
      )}
    </div>
  );
}
