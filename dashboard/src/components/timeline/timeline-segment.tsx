'use client';

import { useState } from 'react';
import { format } from 'date-fns';
import type { TimelineSegment } from '@/types/location';
import {
  getSegmentColor,
  getSegmentLabel,
  formatDuration,
  formatPercentage,
  LOCATION_TYPE_COLORS,
  SEGMENT_TYPE_COLORS,
} from '@/lib/utils/segment-colors';

interface TimelineSegmentBarProps {
  segment: TimelineSegment;
  widthPercent: number;
  totalDuration: number;
  isSelected?: boolean;
  onClick?: (segment: TimelineSegment) => void;
}

/**
 * Individual segment bar within the timeline visualization.
 * Shows color based on segment type/location, with hover tooltip.
 */
export function TimelineSegmentBar({
  segment,
  widthPercent,
  totalDuration,
  isSelected = false,
  onClick,
}: TimelineSegmentBarProps) {
  const [isHovered, setIsHovered] = useState(false);

  const color = getSegmentColor(segment.segmentType, segment.locationType);
  const label = getSegmentLabel(
    segment.segmentType,
    segment.locationName,
    segment.locationType
  );
  const percentage = totalDuration > 0
    ? (segment.durationSeconds / totalDuration) * 100
    : 0;

  return (
    <div
      className="relative h-full cursor-pointer transition-all duration-150"
      style={{
        width: `${widthPercent}%`,
        backgroundColor: color,
        opacity: isSelected ? 1 : isHovered ? 0.9 : 0.8,
        transform: isHovered || isSelected ? 'scaleY(1.1)' : 'scaleY(1)',
      }}
      onMouseEnter={() => setIsHovered(true)}
      onMouseLeave={() => setIsHovered(false)}
      onClick={() => onClick?.(segment)}
    >
      {/* Tooltip on hover */}
      {isHovered && (
        <div className="absolute z-50 bottom-full left-1/2 -translate-x-1/2 mb-2 pointer-events-none">
          <SegmentTooltip segment={segment} percentage={percentage} />
        </div>
      )}
    </div>
  );
}

interface SegmentTooltipProps {
  segment: TimelineSegment;
  percentage: number;
}

/**
 * Tooltip showing segment details on hover
 */
export function SegmentTooltip({ segment, percentage }: SegmentTooltipProps) {
  const color = getSegmentColor(segment.segmentType, segment.locationType);
  const label = getSegmentLabel(
    segment.segmentType,
    segment.locationName,
    segment.locationType
  );

  return (
    <div className="bg-slate-900 text-white text-xs rounded-lg px-3 py-2 shadow-lg min-w-[180px]">
      <div className="flex items-center gap-2 mb-1">
        <div
          className="h-3 w-3 rounded-full"
          style={{ backgroundColor: color }}
        />
        <span className="font-medium">{label}</span>
      </div>
      <div className="space-y-0.5 text-slate-300">
        <div className="flex justify-between">
          <span>Duration:</span>
          <span className="font-medium text-white">
            {formatDuration(segment.durationSeconds)}
          </span>
        </div>
        <div className="flex justify-between">
          <span>Percentage:</span>
          <span className="font-medium text-white">
            {formatPercentage(percentage)}
          </span>
        </div>
        <div className="flex justify-between">
          <span>GPS Points:</span>
          <span className="font-medium text-white">{segment.pointCount}</span>
        </div>
        <div className="border-t border-slate-700 pt-1 mt-1">
          <div className="text-slate-400">
            {format(segment.startTime, 'HH:mm:ss')} -{' '}
            {format(segment.endTime, 'HH:mm:ss')}
          </div>
        </div>
        {segment.avgConfidence !== null && (
          <div className="flex justify-between text-slate-400">
            <span>Confidence:</span>
            <span>{Math.round(segment.avgConfidence * 100)}%</span>
          </div>
        )}
      </div>
      {/* Arrow pointing down */}
      <div className="absolute left-1/2 -translate-x-1/2 top-full">
        <div className="border-8 border-transparent border-t-slate-900" />
      </div>
    </div>
  );
}

interface SegmentLegendProps {
  showLocationTypes?: boolean;
}

/**
 * Legend showing segment type and location type colors
 */
export function SegmentLegend({ showLocationTypes = true }: SegmentLegendProps) {
  return (
    <div className="flex flex-wrap gap-4 text-xs">
      {/* Segment types */}
      <div className="flex items-center gap-3">
        <span className="text-slate-500">Segment Types:</span>
        {Object.entries(SEGMENT_TYPE_COLORS).map(([type, config]) => (
          <div key={type} className="flex items-center gap-1.5">
            <div
              className="h-3 w-3 rounded-full"
              style={{ backgroundColor: config.color }}
            />
            <span className="text-slate-600">{config.label}</span>
          </div>
        ))}
      </div>

      {/* Location types (optional) */}
      {showLocationTypes && (
        <div className="flex items-center gap-3">
          <span className="text-slate-500">Location Types:</span>
          {Object.entries(LOCATION_TYPE_COLORS).map(([type, config]) => (
            <div key={type} className="flex items-center gap-1.5">
              <div
                className="h-3 w-3 rounded-full"
                style={{ backgroundColor: config.color }}
              />
              <span className="text-slate-600">{config.label}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

interface SegmentDetailProps {
  segment: TimelineSegment;
  onClose?: () => void;
}

/**
 * Detailed view of a selected segment
 */
export function SegmentDetail({ segment, onClose }: SegmentDetailProps) {
  const color = getSegmentColor(segment.segmentType, segment.locationType);
  const label = getSegmentLabel(
    segment.segmentType,
    segment.locationName,
    segment.locationType
  );

  return (
    <div className="bg-white border rounded-lg p-4 shadow-sm">
      <div className="flex items-start justify-between mb-3">
        <div className="flex items-center gap-2">
          <div
            className="h-4 w-4 rounded-full"
            style={{ backgroundColor: color }}
          />
          <h4 className="font-medium text-slate-900">{label}</h4>
        </div>
        {onClose && (
          <button
            onClick={onClose}
            className="text-slate-400 hover:text-slate-600"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              width="16"
              height="16"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
            >
              <line x1="18" y1="6" x2="6" y2="18" />
              <line x1="6" y1="6" x2="18" y2="18" />
            </svg>
          </button>
        )}
      </div>

      <div className="grid grid-cols-2 gap-3 text-sm">
        <div>
          <span className="text-slate-500">Duration</span>
          <p className="font-medium">{formatDuration(segment.durationSeconds)}</p>
        </div>
        <div>
          <span className="text-slate-500">GPS Points</span>
          <p className="font-medium">{segment.pointCount}</p>
        </div>
        <div>
          <span className="text-slate-500">Start Time</span>
          <p className="font-medium">{format(segment.startTime, 'HH:mm:ss')}</p>
        </div>
        <div>
          <span className="text-slate-500">End Time</span>
          <p className="font-medium">{format(segment.endTime, 'HH:mm:ss')}</p>
        </div>
        {segment.avgConfidence !== null && (
          <div>
            <span className="text-slate-500">Avg Confidence</span>
            <p className="font-medium">
              {Math.round(segment.avgConfidence * 100)}%
            </p>
          </div>
        )}
        {segment.locationType && (
          <div>
            <span className="text-slate-500">Location Type</span>
            <p className="font-medium">
              {LOCATION_TYPE_COLORS[segment.locationType].label}
            </p>
          </div>
        )}
      </div>
    </div>
  );
}
