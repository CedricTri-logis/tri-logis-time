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
  activityLocationId?: string | null,
): ProjectSlice[] {
  const aStart = new Date(activityStart).getTime();
  const aEnd = new Date(activityEnd).getTime();
  if (aEnd <= aStart) return [];

  // Find sessions that overlap with this activity
  const overlappingRaw = projectSessions
    .filter(ps => {
      const psStart = new Date(ps.started_at).getTime();
      const psEnd = new Date(ps.ended_at).getTime();
      const timeOverlap = psStart < aEnd && psEnd > aStart;
      if (!timeOverlap) return false;
      // If we have a location to match against, only show sessions at this location
      if (activityLocationId && ps.location_id) {
        return ps.location_id === activityLocationId;
      }
      // No location filter — include all time-overlapping sessions
      return true;
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
  | { type: 'merged'; group: MergedGroup };

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

    // Only attempt merge starting from a stop
    if (pa.item.activity_type !== 'stop') {
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
          afterGap.item.activity_type === 'stop' &&
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
