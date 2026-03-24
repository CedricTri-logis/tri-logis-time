/**
 * Pure utility functions and constants extracted from day-approval-detail.tsx
 * for better code splitting and testability.
 */

import { CheckCircle2, XCircle, AlertTriangle, type LucideIcon } from 'lucide-react';
import type { ProcessedActivity } from '@/lib/utils/merge-clock-events';
import type {
  ApprovalActivity,
  ApprovalAutoStatus,
  ProjectSession,
} from '@/types/mileage';

// --- Project session overlap helpers ---

export interface ProjectSlice {
  type: 'session' | 'gap';
  session?: ProjectSession;
  started_at: string;
  ended_at: string;
  duration_minutes: number;
}

/**
 * Given an activity's time range, location, and all project sessions for the day,
 * return the overlapping sessions + gaps within that range.
 * Filters by location_id match when provided (stops/merged groups have a location).
 */
export function getProjectSlices(
  activityStart: string,
  activityEnd: string,
  projectSessions: ProjectSession[],
): ProjectSlice[] {
  const aStart = new Date(activityStart).getTime();
  const aEnd = new Date(activityEnd).getTime();
  if (aEnd <= aStart) return [];

  // Find sessions that overlap with this activity (time-only, show all projects)
  const overlappingRaw = projectSessions
    .filter(ps => {
      const psStart = new Date(ps.started_at).getTime();
      const psEnd = new Date(ps.ended_at).getTime();
      return psStart < aEnd && psEnd > aStart;
    })
    .sort((a, b) => new Date(a.started_at).getTime() - new Date(b.started_at).getTime());

  // Deduplicate: merge sessions with same building+unit that overlap
  const overlapping: ProjectSession[] = [];
  for (const ps of overlappingRaw) {
    const prev = overlapping[overlapping.length - 1];
    if (
      prev &&
      prev.building_name === ps.building_name &&
      (prev.unit_label ?? '') === (ps.unit_label ?? '') &&
      prev.session_type === ps.session_type &&
      new Date(ps.started_at).getTime() - new Date(prev.ended_at).getTime() < 60000 // within 1 min
    ) {
      // Merge: extend prev to cover both
      const prevEnd = new Date(prev.ended_at).getTime();
      const psEnd = new Date(ps.ended_at).getTime();
      if (psEnd > prevEnd) {
        prev.ended_at = ps.ended_at;
        prev.duration_minutes = Math.round(
          (Math.min(psEnd, aEnd) - Math.max(new Date(prev.started_at).getTime(), aStart)) / 60000
        );
      }
    } else {
      overlapping.push({ ...ps });
    }
  }

  if (overlapping.length === 0) {
    // Entire activity has no project
    const dur = Math.round((aEnd - aStart) / 60000);
    if (dur > 0) {
      return [{ type: 'gap', started_at: activityStart, ended_at: activityEnd, duration_minutes: dur }];
    }
    return [];
  }

  const slices: ProjectSlice[] = [];
  let cursor = aStart;

  for (const ps of overlapping) {
    const psStart = Math.max(new Date(ps.started_at).getTime(), aStart);
    const psEnd = Math.min(new Date(ps.ended_at).getTime(), aEnd);

    // Gap before this session
    if (psStart > cursor) {
      const gapMin = Math.round((psStart - cursor) / 60000);
      if (gapMin > 0) {
        slices.push({
          type: 'gap',
          started_at: new Date(cursor).toISOString(),
          ended_at: new Date(psStart).toISOString(),
          duration_minutes: gapMin,
        });
      }
    }

    // The session slice
    const sesMin = Math.round((psEnd - psStart) / 60000);
    if (sesMin > 0) {
      slices.push({
        type: 'session',
        session: ps,
        started_at: new Date(psStart).toISOString(),
        ended_at: new Date(psEnd).toISOString(),
        duration_minutes: sesMin,
      });
    }

    cursor = Math.max(cursor, psEnd);
  }

  // Gap after last session
  if (cursor < aEnd) {
    const gapMin = Math.round((aEnd - cursor) / 60000);
    if (gapMin > 0) {
      slices.push({
        type: 'gap',
        started_at: new Date(cursor).toISOString(),
        ended_at: new Date(aEnd).toISOString(),
        duration_minutes: gapMin,
      });
    }
  }

  return slices;
}

// --- Same-location GPS gap merging ---

export interface MergedGroup {
  /** The primary stop activity (first stop — used for location info, approval actions) */
  primaryStop: ProcessedActivity<ApprovalActivity>;
  /** All stop activities folded into this group */
  stops: ProcessedActivity<ApprovalActivity>[];
  /** Same-location gap activities nested inside (for expand) */
  gaps: ApprovalActivity[];
  /** Earliest started_at across all stops */
  startedAt: string;
  /** Latest ended_at across all stops */
  endedAt: string;
  /** Full span in minutes (from startedAt to endedAt) */
  spanMinutes: number;
  /** Total gap minutes */
  totalGapMinutes: number;
}

export type DisplayItem =
  | { type: 'activity'; pa: ProcessedActivity<ApprovalActivity> }
  | { type: 'merged'; group: MergedGroup }
  | { type: 'lunch_group'; lunch: ProcessedActivity<ApprovalActivity>; children: DisplayItem[] };

/**
 * Detect consecutive same-location stop/gap chains and merge them.
 * A "same-location gap" is a trip or gap where start_location_id === end_location_id
 * and both are non-null (GPS signal lost while stationary — RPC classifies these as trips).
 */
export function mergeSameLocationGaps(items: ProcessedActivity<ApprovalActivity>[]): DisplayItem[] {
  const result: DisplayItem[] = [];
  let i = 0;

  while (i < items.length) {
    const pa = items[i];

    // Only attempt merge starting from a stop or stop_segment
    if (pa.item.activity_type !== 'stop' && pa.item.activity_type !== 'stop_segment') {
      result.push({ type: 'activity', pa });
      i++;
      continue;
    }

    // Look ahead: collect stop→sameLocationGap→stop→... chains
    const stops: ProcessedActivity<ApprovalActivity>[] = [pa];
    const gaps: ApprovalActivity[] = [];
    let j = i + 1;

    while (j < items.length) {
      const next = items[j];

      // Next must be a same-location gap (trip or gap with identical start/end location)
      if (
        (next.item.activity_type === 'trip' || next.item.activity_type === 'gap') &&
        next.item.start_location_id &&
        next.item.end_location_id &&
        next.item.start_location_id === next.item.end_location_id
      ) {
        // And after the gap, there should be a stop at the same location
        const afterGap = items[j + 1];
        if (
          afterGap &&
          (afterGap.item.activity_type === 'stop' || afterGap.item.activity_type === 'stop_segment') &&
          afterGap.item.matched_location_id === pa.item.matched_location_id
        ) {
          gaps.push(next.item);
          stops.push(afterGap);
          j += 2; // skip gap + stop
          continue;
        }
      }
      break;
    }

    if (gaps.length === 0) {
      // No merging happened — emit as normal activity
      result.push({ type: 'activity', pa });
      i++;
    } else {
      // Build merged group
      const startedAt = stops[0].item.started_at;
      const endedAt = stops[stops.length - 1].item.ended_at;
      const spanMs = new Date(endedAt).getTime() - new Date(startedAt).getTime();
      const totalGapMinutes = gaps.reduce((sum, g) => sum + g.duration_minutes, 0);

      result.push({
        type: 'merged',
        group: {
          primaryStop: pa,
          stops,
          gaps,
          startedAt,
          endedAt,
          spanMinutes: Math.round(spanMs / 60000),
          totalGapMinutes,
        },
      });
      i = j; // skip past all consumed items
    }
  }

  return result;
}

// --- Formatting helpers ---

export function formatHours(minutes: number): string {
  if (minutes === 0) return '0h';
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m > 0 ? `${h}h${m.toString().padStart(2, '0')}` : `${h}h`;
}

export function formatDate(dateStr: string): string {
  return new Date(dateStr + 'T12:00:00').toLocaleDateString('fr-CA', {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    year: 'numeric',
  });
}

// --- Shift grouping for day detail view ---

export interface ShiftGroup {
  shiftId: string;
  shiftNumber: number;
  startedAt: string;
  endedAt: string;
  durationMinutes: number;
  shiftType: 'regular' | 'call' | null;
  shiftTypeSource: 'auto' | 'manual' | null;
  items: DisplayItem[];
}

/**
 * Group display items by shift_id, preserving display order.
 * Each group gets a computed time range and shift metadata.
 */
export function groupDisplayItemsByShift(displayItems: DisplayItem[]): ShiftGroup[] {
  if (!displayItems.length) return [];

  const groupMap = new Map<string, {
    items: DisplayItem[];
    shiftType: 'regular' | 'call' | null;
    shiftTypeSource: 'auto' | 'manual' | null;
  }>();

  for (const item of displayItems) {
    const activity = item.type === 'merged'
      ? item.group.primaryStop.item
      : item.type === 'lunch_group'
        ? item.lunch.item
        : item.pa.item;
    const shiftId = activity.shift_id;

    if (!groupMap.has(shiftId)) {
      groupMap.set(shiftId, {
        items: [],
        shiftType: activity.shift_type,
        shiftTypeSource: activity.shift_type_source,
      });
    } else if (!groupMap.get(shiftId)!.shiftType && activity.shift_type) {
      // Stops/trips/gaps return NULL shift_type from the RPC; only clock events
      // carry the actual value. Update the group when we find a non-null value.
      groupMap.get(shiftId)!.shiftType = activity.shift_type;
      groupMap.get(shiftId)!.shiftTypeSource = activity.shift_type_source;
    }
    groupMap.get(shiftId)!.items.push(item);
  }

  return Array.from(groupMap.entries()).map(([shiftId, group], idx) => {
    let earliest = '';
    let latest = '';

    for (const item of group.items) {
      const startedAt = item.type === 'merged'
        ? item.group.startedAt
        : item.type === 'lunch_group'
          ? item.lunch.item.started_at
          : item.pa.item.started_at;
      const endedAt = item.type === 'merged'
        ? item.group.endedAt
        : item.type === 'lunch_group'
          ? item.lunch.item.ended_at
          : item.pa.item.ended_at;
      if (!earliest || startedAt < earliest) earliest = startedAt;
      if (!latest || endedAt > latest) latest = endedAt;
    }

    return {
      shiftId,
      shiftNumber: idx + 1,
      startedAt: earliest,
      endedAt: latest,
      durationMinutes: Math.round(
        (new Date(latest).getTime() - new Date(earliest).getTime()) / 60000,
      ),
      shiftType: group.shiftType,
      shiftTypeSource: group.shiftTypeSource,
      items: group.items,
    };
  });
}

// --- Nest activities during lunch breaks ---

/**
 * Group activities that fall within a lunch break's time window as children of
 * that lunch item. The lunch row becomes expandable; sub-activities are hidden
 * by default.
 */
export function nestLunchActivities(items: DisplayItem[]): DisplayItem[] {
  // Find lunch items and their time ranges
  const lunchRanges: { index: number; start: number; end: number; pa: ProcessedActivity<ApprovalActivity> }[] = [];

  items.forEach((item, i) => {
    if (item.type === 'activity' && item.pa.item.activity_type === 'lunch') {
      lunchRanges.push({
        index: i,
        start: new Date(item.pa.item.started_at).getTime(),
        end: new Date(item.pa.item.ended_at).getTime(),
        pa: item.pa,
      });
    }
  });

  if (lunchRanges.length === 0) return items;

  // Build a set of indices consumed by lunch groups
  const consumed = new Set<number>();
  const lunchGroups = new Map<number, DisplayItem[]>();

  for (const lunch of lunchRanges) {
    consumed.add(lunch.index);
    const children: DisplayItem[] = [];

    items.forEach((item, i) => {
      if (i === lunch.index) return;
      if (consumed.has(i)) return;

      // Never absorb stop_segments — they are explicitly created by supervisors
      // for independent approval and must always remain visible as standalone rows.
      if (item.type === 'activity' && (
        item.pa.item.activity_type === 'stop_segment' ||
        item.pa.item.activity_type === 'trip_segment' ||
        item.pa.item.activity_type === 'gap_segment'
      )) return;

      // Get the activity's time range
      let itemStart: number;
      let itemEnd: number;
      if (item.type === 'merged') {
        itemStart = new Date(item.group.startedAt).getTime();
        itemEnd = new Date(item.group.endedAt).getTime();
      } else if (item.type === 'activity') {
        itemStart = new Date(item.pa.item.started_at).getTime();
        itemEnd = new Date(item.pa.item.ended_at).getTime();
      } else {
        return;
      }

      // Activity is "during lunch" if its midpoint falls within the lunch window
      const midpoint = (itemStart + itemEnd) / 2;
      if (midpoint >= lunch.start && midpoint <= lunch.end) {
        children.push(item);
        consumed.add(i);
      }
    });

    lunchGroups.set(lunch.index, children);
  }

  // Rebuild the list
  const result: DisplayItem[] = [];
  items.forEach((item, i) => {
    if (consumed.has(i)) {
      // If this is a lunch item, emit the group
      if (lunchGroups.has(i)) {
        const lunch = lunchRanges.find(l => l.index === i)!;
        result.push({
          type: 'lunch_group',
          lunch: lunch.pa,
          children: lunchGroups.get(i)!,
        });
      }
      // Otherwise it was consumed as a child — skip
    } else {
      result.push(item);
    }
  });

  return result;
}

// --- Status badge configuration ---

export const STATUS_BADGE: Record<ApprovalAutoStatus, { className: string; icon: LucideIcon; label: string }> = {
  approved: {
    className: 'bg-green-100 text-green-700 hover:bg-green-100',
    icon: CheckCircle2,
    label: 'Approuvé',
  },
  rejected: {
    className: 'bg-red-100 text-red-700 hover:bg-red-100',
    icon: XCircle,
    label: 'Rejeté',
  },
  needs_review: {
    className: 'bg-yellow-100 text-yellow-700 hover:bg-yellow-100',
    icon: AlertTriangle,
    label: 'À vérifier',
  },
};
