/**
 * Segment color utilities for location geofences and timeline visualization
 * Provides consistent colors for location types and segment classifications
 */

import type { LocationType, SegmentType } from '@/types/location';

/**
 * Color configuration for each location type
 */
export interface LocationTypeColor {
  color: string;
  bgColor: string;
  textColor: string;
  label: string;
  icon: string;
}

/**
 * Color mappings for location types (hex values from Tailwind palette)
 */
export const LOCATION_TYPE_COLORS: Record<LocationType, LocationTypeColor> = {
  office: {
    color: '#3b82f6', // blue-500
    bgColor: 'bg-blue-100 dark:bg-blue-900/30',
    textColor: 'text-blue-700 dark:text-blue-300',
    label: 'Office',
    icon: 'Building2',
  },
  building: {
    color: '#f59e0b', // amber-500
    bgColor: 'bg-amber-100 dark:bg-amber-900/30',
    textColor: 'text-amber-700 dark:text-amber-300',
    label: 'Construction Site',
    icon: 'HardHat',
  },
  vendor: {
    color: '#8b5cf6', // violet-500
    bgColor: 'bg-violet-100 dark:bg-violet-900/30',
    textColor: 'text-violet-700 dark:text-violet-300',
    label: 'Vendor',
    icon: 'Truck',
  },
  home: {
    color: '#22c55e', // green-500
    bgColor: 'bg-green-100 dark:bg-green-900/30',
    textColor: 'text-green-700 dark:text-green-300',
    label: 'Home',
    icon: 'Home',
  },
  other: {
    color: '#6b7280', // gray-500
    bgColor: 'bg-gray-100 dark:bg-gray-800',
    textColor: 'text-gray-700 dark:text-gray-300',
    label: 'Other',
    icon: 'MapPin',
  },
};

/**
 * Color configuration for segment types
 */
export interface SegmentTypeColor {
  color: string;
  bgColor: string;
  textColor: string;
  label: string;
}

/**
 * Color mappings for segment types (non-matched segments)
 */
export const SEGMENT_TYPE_COLORS: Record<SegmentType, SegmentTypeColor> = {
  matched: {
    color: '#3b82f6', // blue-500 (placeholder, use location type color)
    bgColor: 'bg-blue-100 dark:bg-blue-900/30',
    textColor: 'text-blue-700 dark:text-blue-300',
    label: 'At Location',
  },
  travel: {
    color: '#eab308', // yellow-500
    bgColor: 'bg-yellow-100 dark:bg-yellow-900/30',
    textColor: 'text-yellow-700 dark:text-yellow-300',
    label: 'Travel',
  },
  unmatched: {
    color: '#ef4444', // red-500
    bgColor: 'bg-red-100 dark:bg-red-900/30',
    textColor: 'text-red-700 dark:text-red-300',
    label: 'Unknown',
  },
};

/**
 * Get color for a segment based on its type and location
 * For matched segments, use the location type color
 * For travel/unmatched, use the segment type color
 */
export function getSegmentColor(
  segmentType: SegmentType,
  locationType?: LocationType | null
): string {
  if (segmentType === 'matched' && locationType) {
    return LOCATION_TYPE_COLORS[locationType].color;
  }
  return SEGMENT_TYPE_COLORS[segmentType].color;
}

/**
 * Get segment display label
 */
export function getSegmentLabel(
  segmentType: SegmentType,
  locationName?: string | null,
  locationType?: LocationType | null
): string {
  if (segmentType === 'matched' && locationName) {
    return locationName;
  }
  if (segmentType === 'matched' && locationType) {
    return LOCATION_TYPE_COLORS[locationType].label;
  }
  return SEGMENT_TYPE_COLORS[segmentType].label;
}

/**
 * Get Tailwind background class for a segment
 */
export function getSegmentBgClass(
  segmentType: SegmentType,
  locationType?: LocationType | null
): string {
  if (segmentType === 'matched' && locationType) {
    return LOCATION_TYPE_COLORS[locationType].bgColor;
  }
  return SEGMENT_TYPE_COLORS[segmentType].bgColor;
}

/**
 * Get Tailwind text class for a segment
 */
export function getSegmentTextClass(
  segmentType: SegmentType,
  locationType?: LocationType | null
): string {
  if (segmentType === 'matched' && locationType) {
    return LOCATION_TYPE_COLORS[locationType].textColor;
  }
  return SEGMENT_TYPE_COLORS[segmentType].textColor;
}

/**
 * Get location type color by type value
 */
export function getLocationTypeColor(locationType: LocationType): string {
  return LOCATION_TYPE_COLORS[locationType].color;
}

/**
 * Get location type label by type value
 */
export function getLocationTypeLabel(locationType: LocationType): string {
  return LOCATION_TYPE_COLORS[locationType].label;
}

/**
 * Get all location type entries for UI rendering (e.g., legend)
 */
export function getAllLocationTypes(): Array<{
  type: LocationType;
  color: string;
  label: string;
}> {
  return (Object.entries(LOCATION_TYPE_COLORS) as [LocationType, LocationTypeColor][]).map(
    ([type, config]) => ({
      type,
      color: config.color,
      label: config.label,
    })
  );
}

/**
 * Get all segment type entries for UI rendering (e.g., legend)
 */
export function getAllSegmentTypes(): Array<{
  type: SegmentType;
  color: string;
  label: string;
}> {
  return (Object.entries(SEGMENT_TYPE_COLORS) as [SegmentType, SegmentTypeColor][]).map(
    ([type, config]) => ({
      type,
      color: config.color,
      label: config.label,
    })
  );
}

/**
 * Format duration for display
 */
export function formatDuration(seconds: number): string {
  if (seconds < 60) {
    return `${seconds}s`;
  }
  const minutes = Math.floor(seconds / 60);
  const remainingSeconds = seconds % 60;
  if (minutes < 60) {
    return remainingSeconds > 0 ? `${minutes}m ${remainingSeconds}s` : `${minutes}m`;
  }
  const hours = Math.floor(minutes / 60);
  const remainingMinutes = minutes % 60;
  if (remainingMinutes > 0) {
    return `${hours}h ${remainingMinutes}m`;
  }
  return `${hours}h`;
}

/**
 * Format percentage for display
 */
export function formatPercentage(percentage: number): string {
  if (percentage < 1) {
    return '<1%';
  }
  return `${Math.round(percentage)}%`;
}
